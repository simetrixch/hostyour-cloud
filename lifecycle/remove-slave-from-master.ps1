# =============================================================================
# remove-slave-from-master.ps1 — take ONE slave's registration off the master it
# stands on. Bash twin: remove-slave-from-master.sh (same folder), which does the
# same in the same order and prints the same lines. lifecycle/test.sh measures
# that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   pwsh ./lifecycle/remove-slave-from-master.ps1 <slave-fqdn> [config] [-EvenIfRunning]
#
# THE TWO INPUTS
#   slave-fqdn — WHICH SLAVE is taken off. It is the domain of the slave's
#             cluster and the name of the map the master keeps for it under
#             clusters/active. A pure slave has no install branch of its own.
#   config  — the MASTER's key=value file, the same one install-machine.ps1 is
#             given for the master and in the same grammar. It states the master
#             this runs on, the account that machine is reached as, the password
#             that raises a command there, and the stage every path the removal
#             writes is spelled along. Defaults to config.env beside this file.
#
# THE CONFIG IS THE MASTER'S AND NOT THE SLAVE'S, because a registration stands
# on the master: the auth mount, the three policies, the entries in the slaves
# tier, the reconciler project and the membership at the coordinator are all
# objects of the master's own installation. The slave contributes one fact — its
# domain — and that is the argument.
#
# THIS IS THE INVERSE OF register-slave AND ONLY OF ITS HALF. What goes is the
# master-side management plane of one slave. What stays is the git side: the ONE
# map clusters/active/<slave-fqdn>.yaml on the master's own branch. A pure slave
# has no install branch of its own, so that map is the whole of the git side.
# Dropping it is what tears the per-slave reconciler instance down, it is a
# separate act with a separate blast radius, and the last line this prints says
# so.
#
# WHAT THE REGISTRATION LEAVES BEHIND when nothing takes it off: a slave keeps
# its auth mount, its policies, its KV entries, its reconciler project, its
# membership at the coordinator and its map for as long as the master stands, and
# a fresh registration of the same name then meets objects it means to create.
#
# NOTHING IS TOUCHED BEFORE THE TARGET IS KNOWN GOOD. The master's branch, the
# map it keeps for this slave, what that map says the slave is, and whether the
# slave still answers are all asked before a session is opened. Every refusal
# below says that nothing has been changed, because at every one of them nothing
# has.
#
# A SLAVE THAT STILL ANSWERS IS REFUSED unless the run is told otherwise.
# Cleaning up after a machine that is gone and cutting a running cluster off its
# master are two different acts: the second leaves every workload on the slave
# alive and unable to read a secret, its reconciler without a project and its
# node without a tailnet, and a person should say that they mean it rather than
# learn it afterwards.
#
# THE CONFIG IS READ BEFORE ITS TWO EXPOSURE GUARDS ARE ASKED, and the order is
# deliberate. The shape check stands first, because the far side reads this file
# with a shell. The two guards under it are about who else can reach the
# credentials in it and whether a commit could sweep them up — neither is a
# reason to read a branch or to ask a slave whether it is alive — so they stand
# immediately before the file leaves this workstation, which is the thing they
# are about.
#
# THE PATH A PERSON TYPED IS THE PATH A REFUSAL NAMES, and it is deliberately not
# resolved to its full form first. Every message below carries it, and the twin
# carries the path it was given; a path rewritten here would be the one thing in
# this file the two spellings could not print the same bytes for.
#
# WHAT ACTUALLY REMOVES A REGISTRATION is remove-slave.yaml in the catalogue
# repository, run by the engine on the master. This opens ONE session, carries
# the config over it, and starts remove-slave-driver.sh there — the same shape
# install-machine.ps1 uses to start driver.sh, and for the same reason: what runs
# on a machine is fetched by that machine, and what this carries over is the
# operator's own config and nothing else.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $SlaveFqdn = '',
  [Parameter(Position = 1)][string] $ConfigFile = '',
  # A RUNNING SLAVE GOES ONLY WHEN SAID. The twin takes --even-if-running where
  # this takes -EvenIfRunning: PowerShell binds a double dash as a parameter name
  # of its own.
  [switch] $EvenIfRunning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY git AND ssh CALL BELOW IS READ BY ITS EXIT CODE, and several of them are
# probes that are MEANT to fail. Newer PowerShell turns a non-zero native exit
# into a terminating error under the preference above, which would end this run on
# the first probe; stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

# EVERY REFUSAL SAYS THAT NOTHING HAS BEEN CHANGED, and it is appended here
# rather than written out a dozen times: every one of them stands before the
# session is opened, so the sentence is true of all of them by construction and
# cannot be forgotten on the one that is added next.
#
# AND EVERY LINE ENDS IN ONE BYTE. Write-Host and WriteLine end a line with what
# the running system calls a newline, which on Windows is two bytes and on Linux
# one, so the same script would print different bytes on two machines and the
# twin could never be held to matching it. The newline is written out here
# instead, and a carriage return never enters the output at all.
function Stop-Here([string] $Because, [int] $Code = 65) {
  [Console]::Error.Write("remove-slave: $Because. Nothing has been changed`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

# THE VALUE OF ONE TOP-LEVEL KEY of a cluster map, read the way the catalogue's
# own step writes it: a line beginning at column one with the key and a colon. A
# key of the same name indented under `global:` is a different key and is
# deliberately not seen. Surrounding quotes are the notation's and are taken off,
# which is what the catalogue's reading step does too.
function Read-MapValue([string[]] $Text, [string] $Key) {
  foreach ($line in $Text) {
    if (-not $line.StartsWith("${Key}:")) { continue }
    $value = $line.Substring($Key.Length + 1).Trim()
    if ($value.Length -ge 2) {
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }
    return $value
  }
  return ''
}

if (-not $SlaveFqdn) {
  Stop-Here 'usage: lifecycle/remove-slave-from-master.ps1 <slave-fqdn> [config] [-EvenIfRunning]' 64
}

$driver = Join-Path $PSScriptRoot 'remove-slave-driver.sh'
if (-not (Test-Path -LiteralPath $driver)) {
  Stop-Here 'remove-slave-driver.sh is not beside this file. It IS the removal on the machine, and this only starts it' 66
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-Here 'git is not on this path, and the master keeps its books in git'
}
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'not inside a git repository. Run this from a checkout of the platform tree' 66
}

# ------------------------------------------- the config, for the two facts in it
# THE SAME FILE install-machine.ps1 IS GIVEN FOR THE MASTER, in the same grammar.
# It carries the account the master is reached as, the password that raises a
# command there, and the two facts that name this act: the master's own domain,
# which is the branch its books stand on, and the stage every path the removal
# writes is spelled along.
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.env' }
if (-not (Test-Path -LiteralPath $ConfigFile)) {
  Stop-Here "there is no config at $ConfigFile. It states the MASTER this removal runs on: copy config.example.env beside it, fill it in, and name it as the second argument" 66
}

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked here although the file is read by
# a shell on the far side: a shell `.` executes every line, so a config carrying a
# command would run it there with the operator's own rights. Refusing it on this
# side tells the operator which line is wrong while the file is still open in
# front of them, rather than after a session has been opened to the machine.
$lines = @(Get-Content -Path $ConfigFile)
$shaped = "^\s*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'\s*(#.*)?$"
$bad = @(@(for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -notmatch $shaped) { '{0}:{1}' -f ($i + 1), $lines[$i] }
}) | Select-Object -First 3)
if ($bad.Count -gt 0) {
  Stop-Here "$ConfigFile carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $($bad -join "`n")" 65
}

# READ, NEVER EXECUTED. The same assignments the shell will source, parsed here
# only to name a missing value before a session is opened.
$stated = @{}
foreach ($line in $lines) {
  if ($line -match "^([A-Z][A-Z0-9_]*)='([^']*)'\s*(#.*)?$") { $stated[$Matches[1]] = $Matches[2] }
}
function Stated([string] $Named) {
  if (-not $stated.ContainsKey($Named)) { return '' }
  return $stated[$Named]
}

foreach ($named in @('FQDN', 'OPERATOR_USER', 'STAGE')) {
  if (-not (Stated $named)) { Stop-Here "$ConfigFile states no $named, and nothing here may choose one" 65 }
}
if (-not (Stated 'ELEVATION_PASSWORD')) {
  Stop-Here "$ConfigFile states no ELEVATION_PASSWORD, and a removal is run elevated" 65
}

$master = Stated 'FQDN'
$operator = Stated 'OPERATOR_USER'

# ------------------------------------------------- the registration, asked of git
# ASKED OF THE REMOTE AND NOT OF THIS CHECKOUT, for the reason every act here
# reads the remote: an install branch moves without this workstation — a release
# writes its pin onto it, a migration writes its record onto it, a registration
# writes a map onto it — so a local view of that branch answers about whenever it
# last looked.
git ls-remote --exit-code --heads origin "refs/heads/$master" *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here "origin has no branch $master, and $ConfigFile states that as the master. A master keeps its books on its own install branch, and there is none of that name" 66
}
git fetch --quiet origin "refs/heads/$master" *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here "the branch $master could not be fetched from origin, so what it records about $SlaveFqdn cannot be read" 69
}

# THE MAP THE MASTER KEEPS FOR THIS SLAVE, which is the git side of the
# registration this takes off. It stands on the MASTER's branch, because that is
# the branch the books live on: the slaves generator reads it there, and a slave
# nobody registered on this master has no file there at all.
$map = "clusters/active/$SlaveFqdn.yaml"
$mapText = @(git show "FETCH_HEAD:$map" 2>$null)
if ($LASTEXITCODE -ne 0) {
  # A MAP THAT IS GONE IS THE NORMAL CASE AND NOT A REFUSAL. Dropping the slave's part of the books
  # is the GIT side of this removal, and the program's own header says the caller does it FIRST, so
  # that the generated Application is already gone when its project goes. By the time the rest is
  # wanted the map has done its work and left. Refusing here refuses every removal performed in the
  # order the program states.
  #
  # WHAT STILL PROTECTS A TYPED NAME. Every row of remove-slave names objects after the slave - the
  # mount kubernetes-<name>, the three policies, the three consumables, the coordinator user, the
  # project. A name nothing was registered under therefore removes nothing, and each row says so.
  # Where the map stands it adds the two checks below; where it does not, this says as much.
  Say "remove-slave: branch $master keeps no $map, which is what the git side of a removal leaves behind. Nothing here confirms $SlaveFqdn stood as a slave of $master, and every row names objects after it, so a name nothing holds removes nothing"
}
else {
  # WHAT THAT MAP SAYS THE CLUSTER IS. A role is one or several parts joined by a plus, and what this
  # removal is about is the slave part - so the parts are read rather than the whole word compared,
  # and a machine carrying master and slave at once is a slave like any other.
  $role = Read-MapValue $mapText 'role'
  if ("+$role+" -notlike '*+slave+*') {
    $said = if ($role) { $role } else { 'none' }
    Stop-Here "$map on branch $master states role '$said', so what stands under that name is no slave. This takes a slave's management plane off its master. Nothing has been changed" 65
  }

  # AND WHICH MASTER IT STANDS ON. `booksCluster` is the cluster that keeps the maps and the
  # registrations, which for a slave is its master - it is the value the slave's own generator
  # selector is stamped from, so a map naming another cluster is a slave of that one and not of this.
  $books = Read-MapValue $mapText 'booksCluster'
  if ($books -ne $master) {
    $said = if ($books) { $books } else { 'none' }
    Stop-Here "$map on branch $master states booksCluster '$said', and $ConfigFile states the master $master. A slave is registered on the master its books name. Nothing has been changed" 65
  }

  Say "remove-slave: $map on branch $master records $SlaveFqdn as a slave of $master, and its registration on that master is what this takes off"
}

# --------------------------------------------------- the slave itself, asked
# WHETHER THE SLAVE IS STILL THERE, asked before anything is decided about it.
# The question is only whether something answers on the ssh port: an account that
# is refused is a machine that is running, and so is a machine whose host key no
# longer matches. Which account is asked with does not matter and the master's
# own is used, because no credential of the slave's is anywhere near this act.
$port = 22
$asked = @('-p', "$port", '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes')
$answer = (& ssh @asked ('{0}@{1}' -f $operator, $SlaveFqdn) true 2>&1 | Out-String)
$answered = ($LASTEXITCODE -eq 0) -or
            ($answer -match 'Permission denied|REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed')

if ($answered) {
  # BOTH SPELLINGS OF THE ARGUMENT ARE NAMED, because this file and its twin are
  # held to printing the same bytes and the person reading this refusal typed one
  # of the two.
  if (-not $EvenIfRunning) {
    Stop-Here "$SlaveFqdn answers on port $port, so it is a RUNNING slave. Taking it off its master leaves every workload on it alive and unable to read a secret, its reconciler without a project and its node without a tailnet. If that is what you mean, start this again with --even-if-running, which the PowerShell spelling writes -EvenIfRunning" 69
  }
  Say "remove-slave: $SlaveFqdn answers on port $port, and this run was told to take a running slave off its master anyway"
}
else {
  Say "remove-slave: $SlaveFqdn does not answer on port $port, so what this takes off $master is the registration of a machine that is gone"
}

# ------------------------------------------------- the config, and its guards
# INSIDE A GIT TREE AND NOT IGNORED BY IT is refused first of the two, because it
# is the mistake that cannot be taken back: a token that reached a remote must be
# rotated, while an access list is corrected where it stands. IGNORED IS ENOUGH —
# what this stops is `git add .` sweeping the file up, and a file the tree ignores
# takes a deliberate `git add -f`, which is somebody choosing.
$configDir = Split-Path -Parent $ConfigFile
if (-not $configDir) { $configDir = '.' }
git -C $configDir rev-parse --show-toplevel *> $null
if ($LASTEXITCODE -eq 0) {
  git -C $configDir check-ignore -q $ConfigFile *> $null
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "$ConfigFile stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
  }
}

# OWNER-ONLY OR NOTHING. Windows says this with an access list rather than a mode,
# so the question asked here is the one the bash twin asks and only the answer is
# read differently: which accounts hold rights on it, beyond the owner and the
# system.
$acl = Get-Acl -Path $ConfigFile
$owner = $acl.Owner
$strangers = @($acl.Access | Where-Object {
  $who = $_.IdentityReference.Value
  $who -ne $owner -and
  $who -notmatch '(?i)\\SYSTEM$' -and
  $who -notmatch '(?i)\\Administrators$'
} | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
if ($strangers.Count -gt 0) {
  Stop-Here "$ConfigFile can be read by $($strangers -join ', ') and it carries credentials, the elevation password of the machine among them. Run: icacls `"$ConfigFile`" /inheritance:r /grant:r `"$($env:USERNAME):(F)`"" 77
}

# ------------------------------------------------------------- the machine
# A MACHINE IS ADDRESSED BY ITS NAME, and by nothing else — the name in the map,
# which is the name of the branch and the name on the certificate. The machine
# here is the MASTER: the store, the coordinator and the reconciler this removal
# reaches into are all its own.
$target = '{0}@{1}' -f $operator, $master
$base = @('-p', "$port", '-o', 'ConnectTimeout=20', '-o', 'StrictHostKeyChecking=accept-new')

# WHICH DOOR THIS MACHINE OPENS, asked before anything is sent. An installation
# that stands carries the operator key — deploy-host's install_authorized_key row
# put it there and disable-password-login shut the password door — so the key is
# the case here, and the password is the exception a machine still at its birth
# would need. The key is tried first and the password only where the key is
# refused, so neither case needs a flag.
$probe = (& ssh @base -o BatchMode=yes $target true 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) {
  $door = @('-o', 'BatchMode=yes')
  Say "remove-slave: $target opens to the operator key"
}
elseif ($probe -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
  # NOT ACCEPTED SILENTLY, and accept-new deliberately does not cover it: a
  # machine whose host key changed is either one that was rebuilt or one that is
  # not the machine any more, and only the operator knows which.
  Stop-Here "$master answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $master and start again. If you have not, clear nothing: something else is answering for $master" 74
}
elseif ($probe -match 'Permission denied') {
  if ([Console]::IsInputRedirected) {
    Stop-Here "$target refuses the operator key, so this could only be a password session, and there is no terminal here to ask on. Start it from a terminal" 69
  }
  $door = @('-o', 'BatchMode=no', '-o', 'NumberOfPasswordPrompts=1')
  Say "remove-slave: $target refuses the operator key, so ssh asks for the login password ONCE, on this terminal. It is not read from the config and it is not kept"
}
else {
  Stop-Here "$target could not be reached: $(($probe -replace '\r?\n', ' ').Trim())" 69
}

# ONE SESSION, so that a password is typed at most once. The stream is the config
# inside a quoted heredoc with the driver behind it: the config lands on the
# machine under a mask that admits nobody else, and the driver shreds it on every
# path it can end on. Neither is ever an argument, because an argument stands in a
# process listing. The heredoc marker cannot collide with anything in the config,
# because the guard above admits no line but a comment and NAME='value'.
#
# THE TWO NAMES THE PROGRAM TAKES ARE APPENDED AS THE LAST LINES, in the config's
# own grammar, so the driver composes them into the answers exactly as it composes
# every other value and holds no special case for either. MASTER_FQDN is this
# config's own FQDN under the name remove-slave declares for it, and SLAVE_FQDN is
# the argument. Last, because the composer reads the file top to bottom and a
# later line wins: a config that states either of them itself is stating a fact
# about some other run, and the two this act is about are these.
#
# A CARRIAGE RETURN IS TAKEN OFF BOTH, and on Windows that is not a formality: the
# config is written in whatever editor the operator has and Notepad writes CRLF,
# while the far side is a bash that reads a CR as part of the value.
$lf = "`n"
$stream = ("umask 077${lf}cat > `"`$1`" <<'AW_CONFIG_END'${lf}" +
           ((Get-Content -Raw -Path $ConfigFile) -replace "`r", '') + $lf +
           "MASTER_FQDN='$master'${lf}" +
           "SLAVE_FQDN='$SlaveFqdn'${lf}" +
           "AW_CONFIG_END${lf}" +
           ((Get-Content -Raw -Path $driver) -replace "`r", ''))

# UTF-8 ON THE WAY OUT. $OutputEncoding is what PowerShell SENDS to a native
# command, and the config carries credentials an operator may have written in any
# alphabet — a password re-encoded into the console's code page is a password the
# machine refuses. Without a BOM, because bash would read those three bytes as
# part of `umask`. It is put back: this runs in the operator's own session, so an
# encoding changed here would outlive the removal.
$spokenBefore = $OutputEncoding
try {
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $stream | & ssh @base @door $target 'bash -s -- "$HOME/.aw-remove-slave.env"'
  $removed = $LASTEXITCODE
}
finally {
  $OutputEncoding = $spokenBefore
}

if ($removed -eq 0) {
  Say "remove-slave: $SlaveFqdn is off $master"
  Say "remove-slave: $map on branch $master still stands. It is the git side of the registration, and dropping it is what tears the per-slave reconciler instance down"
}
else {
  Say "remove-slave: taking $SlaveFqdn off $master ended with exit $removed. The line above it says which mode stopped and why"
}
exit $removed
