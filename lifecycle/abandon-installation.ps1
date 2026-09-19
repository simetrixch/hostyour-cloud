# =============================================================================
# abandon-installation.ps1 — take down what ONE installation left outside its
# machines: the DNS records it wrote, its install branches and its books branch
# in the catalog. Bash twin: abandon-installation.sh (same folder), which does
# the same in the same order and prints the same lines. lifecycle/test.sh
# measures that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   pwsh ./lifecycle/abandon-installation.ps1 <master-fqdn> [config]
#
# THE TWO INPUTS
#   master-fqdn — WHICH INSTALLATION is abandoned, named by the cluster that
#             keeps its books: the domain of the master, the name of its install
#             branch, the name of its map under clusters/active and the name of
#             the installation's books branch in the catalog.
#   config  — that installation's own key=value file, the one install-machine.ps1
#             was given for the master and in the same grammar. Two values are
#             read out of it and nothing is run: the DNS token the installation
#             wrote its records with, and the catalog its tenants are registered
#             in. Defaults to config.<first label of the fqdn>.env beside this
#             file, which is the name release-platform.ps1 looks for too.
#
# WHAT AN INSTALLATION LEAVES OUTSIDE ITS MACHINES. Restoring a machine to its
# bare point takes back everything on it and nothing beside it: the unit records
# in the zone still answer with the old address, the install branch on origin
# still carries the map a release would pin, and the catalog still carries the
# books branch with every tenant registration. The next installation meets each
# of them — a unit record that answers with a machine that is gone refuses the
# onboarding of the same unit, and a release regenerates a branch of a machine
# that no longer exists.
#
# EVERYTHING IS DERIVED FROM THE INSTALL BRANCH ON ORIGIN, never typed and never
# read off a local checkout: the cluster map of the master and of every slave it
# records say what the machines were and where they stood (nodeCidrs), the
# consumer registrations on the same branch and the tenant registrations on the
# catalog's books branch say which unit names were written, and the map's two
# sender domains say which mail records were published. A record is DELETED only
# where its content proves it the installation's — an A or AAAA at one of the
# installation's addresses, or an SPF that authorises those addresses and nobody
# else. Everything else standing under a derived name is listed by name and
# left: a foreign address at the same name, a DKIM key whose private half lived
# in the Vault that is gone, a DMARC policy the operator wrote, an SPF merged
# with another sender's mechanisms. Listed, because the person tearing the
# installation down needs to see what still stands.
#
# A LIVING INSTALLATION IS REFUSED. Before anything is asked of the operator,
# every address of every cluster is asked whether the cluster's API still
# answers there. THE API PORT AND NOT THE SSH PORT, on purpose: a machine
# restored to its bare point still answers on 22 — that is how the next
# installation reaches it — so the ssh port cannot tell an installation that is
# gone from a bare machine standing at the same address, and it would refuse the
# very case this act exists for. What a living installation has and a bare
# machine has not is the cluster, and the cluster answers on its API port. A
# living installation is offboarded through the Manager and taken back with
# remove-slave and the reset, never abandoned.
#
# THE ORDER IS READ, GUARD, CONFIRM, DNS, BRANCHES, and nothing is written before
# the operator has typed the master's domain. The records go before the
# branches because the branch is what the records are derived FROM: a branch
# deleted first would leave records nobody can attribute any more. A failure in
# the DNS phase therefore stops before the branches and says so, and a second
# run derives the same names again — an absent record and an absent branch are
# not errors, so every run of this is safe to repeat.
#
# THE CONFIG STAYS. A local config is the record of the answers a machine was
# installed with, nothing but the file itself carries it, and the next machine
# of that name is installed from it. This names it and leaves it.
#
# THE PATH A PERSON TYPED IS THE PATH A REFUSAL NAMES, and it is deliberately not
# resolved to its full form first. Every message below carries it, and the twin
# carries the path it was given; a path rewritten here would be the one thing in
# this file the two spellings could not print the same bytes for.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $MasterFqdn = '',
  [Parameter(Position = 1)][string] $ConfigFile = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]] $More = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY git AND curl CALL BELOW IS READ BY ITS EXIT CODE, and several of them are
# probes that are MEANT to fail. Newer PowerShell turns a non-zero native exit
# into a terminating error under the preference above, which would end this run on
# the first probe; stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

# EVERY LINE ENDS IN ONE BYTE. Write-Host and WriteLine end a line with what the
# running system calls a newline, which on Windows is two bytes and on Linux one,
# so the same script would print different bytes on two machines and the twin
# could never be held to matching it. The newline is written out here instead,
# and a carriage return never enters the output at all.
function Stop-Here([string] $Because, [int] $Code = 65) {
  [Console]::Error.Write("abandon: $Because`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

# THE VALUE OF ONE KEY of a map or a registration, read the way the catalogue's
# own step writes it: a line beginning at column one with the key and a colon. A
# key under `global:` is asked for WITH its two spaces of indentation, so a key
# of the same name at the top level is a different key and is not seen.
# Surrounding quotes are the notation's and are taken off.
function Read-Value([string[]] $Text, [string] $Key) {
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

# THE ADDRESSES OF ONE CLUSTER, out of its map's nodeCidrs, the prefix length
# taken off. The branch program writes the list as a flow sequence on one line
# and the Manager writes a slave's as a block sequence, one address per line
# under the key, so both spellings are read.
function Read-Addresses([string[]] $Text) {
  $found = @()
  $inBlock = $false
  foreach ($line in $Text) {
    if ($inBlock) {
      if ($line.StartsWith('    - ')) { $found += ($line.Substring(6).Trim() -split '/')[0]; continue }
      break
    }
    if (-not $line.StartsWith('  nodeCidrs:')) { continue }
    $value = $line.Substring(12).Trim()
    if ($value.StartsWith('[') -and $value.EndsWith(']')) {
      foreach ($entry in $value.Substring(1, $value.Length - 2) -split ',') {
        $entry = ($entry.Trim() -split '/')[0]
        if ($entry) { $found += $entry }
      }
      break
    }
    if ($value -eq '') { $inBlock = $true }
  }
  return $found
}

if ($More.Count -gt 0) {
  Stop-Here "lifecycle/abandon-installation.ps1 was given more than it takes: $($More[0])" 64
}
if (-not $MasterFqdn) {
  Stop-Here 'usage: lifecycle/abandon-installation.ps1 <master-fqdn> [config]' 64
}

foreach ($tool in @('git', 'curl')) {
  if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
    Stop-Here "$tool is not on this path, and this act is nothing but git against origin and curl against the DNS provider"
  }
}
# THE PROGRAM AND NOT AN ALIAS: an older PowerShell spells a web request `curl`,
# and what this needs is the program the bash twin runs.
$curl = @(Get-Command curl -CommandType Application)[0].Source
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'not inside a git repository. Run this from a checkout of the platform tree' 66
}

# ------------------------------------------------------------- the config
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot ('config.{0}.env' -f ($MasterFqdn -split '\.')[0]) }
if (-not (Test-Path -LiteralPath $ConfigFile)) {
  Stop-Here "there is no config at $ConfigFile. It is the installation's own, the one it was installed with: name it as the second argument" 66
}
# READ, NEVER EXECUTED: two values are all this act needs out of a file that
# carries thirteen credentials.
$stated = @{}
foreach ($line in @(Get-Content -Path $ConfigFile)) {
  if ($line -match "^([A-Z][A-Z0-9_]*)='([^']*)'") { if (-not $stated.ContainsKey($Matches[1])) { $stated[$Matches[1]] = $Matches[2] } }
}
function Stated([string] $Named) {
  if (-not $stated.ContainsKey($Named)) { return '' }
  return $stated[$Named]
}
$configFqdn = Stated 'FQDN'
if ($configFqdn -ne $MasterFqdn) {
  Stop-Here "$ConfigFile states FQDN='$configFqdn', and this abandons $MasterFqdn. The config has to be the installation's own, because its token and its catalog are what this writes with" 65
}
$token = Stated 'CLOUDFLARE_DNS_API_TOKEN'
if (-not $token) {
  Stop-Here "$ConfigFile states no CLOUDFLARE_DNS_API_TOKEN, and the records were written with it" 65
}
$catalogRepo = Stated 'CATALOG_REPO'
if (-not $catalogRepo) {
  Stop-Here "$ConfigFile states no CATALOG_REPO, and the installation's books branch stands in that repository" 65
}
$catalogUrl = "https://github.com/$catalogRepo.git"

# The MicroK8s API port — a constant of the distribution, the same the Manager
# and the cluster maps carry — and where the DNS provider answers for everybody.
$apiPort = 16443
$cloudflareApi = 'https://api.cloudflare.com/client/v4'
# Every host label the platform tree composes on a cluster's own domain: the four
# bootstrap templates (argo, idp, kube, vault), the registry (zot), the tailnet
# coordinator (tale), the relay (mail), and the ingress hosts of dbgate, grafana,
# the manager, the release cycle's webhook, tekton and the two push routes.
$platformHostLabels = 'argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot'

# ================================================================== READ
# ASKED OF THE REMOTE AND NOT OF THIS CHECKOUT, for the reason every act here
# reads the remote: an install branch moves without this workstation.
git ls-remote --exit-code --heads origin "refs/heads/$MasterFqdn" *> $null
switch ($LASTEXITCODE) {
  0 { $books = $true }
  2 { $books = $false }
  default { Stop-Here 'origin could not be asked for its branches, so nothing here would be about what origin carries' 69 }
}

$names = [System.Collections.Generic.List[object]]::new()  # every derived record name, with what it is
$addresses = @()                                            # every address of the installation
$clusters = [System.Collections.Generic.List[object]]::new() # every cluster of the installation, with its addresses
function Add-Name([string] $Name, [string] $What) { $script:names.Add(@{ name = $Name; what = $What }) }
function Test-Address([string] $Content) { return ($script:addresses -contains $Content) }
# A CNAME whose content is one of this installation's own cluster names is the installation's: the
# wildcard deploy-branch writes, `*.<fqdn>` -> `<fqdn>` (hostyour-deploy#35).
function Test-ClusterName([string] $Content) { return [bool] ($script:clusters | Where-Object { $_.fqdn -ceq $Content }) }
function Get-StageApex([string] $Stage) { if ($Stage -eq 'prod') { return $script:unitApex } else { return "$Stage.$script:unitApex" } }

$stage = ''; $unitApex = ''; $platformDomain = ''
if ($books) {
  git fetch --quiet origin "refs/heads/$MasterFqdn" *> $null
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "the branch $MasterFqdn could not be fetched from origin, so what it records cannot be read" 69
  }
  Say "abandon: $MasterFqdn keeps its books on branch $MasterFqdn of origin, and everything below is read there"
  $files = @(git ls-tree -r --name-only FETCH_HEAD -- clusters/active registrations 2>$null)

  $map = "clusters/active/$MasterFqdn.yaml"
  $mapText = @(git show "FETCH_HEAD:$map" 2>$null)
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "branch $MasterFqdn carries no $map. That map is where an installation records what it is, and nothing can be derived without it" 66
  }
  $stage = Read-Value $mapText 'stage'
  $unitApex = Read-Value $mapText '  unitApex'
  $platformDomain = Read-Value $mapText '  platformDomain'
  if (-not $stage) { Stop-Here "$map on branch $MasterFqdn states no stage, and the DKIM record is named after it" 65 }
  if (-not $unitApex) { Stop-Here "$map on branch $MasterFqdn states no unitApex, and every unit record stands under a zone of it" 65 }

  # THE MASTER FIRST, THEN EVERY OTHER MAP ON THE BRANCH. The branch is the
  # installation's books, so every map standing there is a cluster of it.
  $maps = @($map) + @($files | Where-Object { $_ -like 'clusters/active/*.yaml' -and $_ -ne $map })
  foreach ($file in $maps) {
    $fqdn = $file.Substring('clusters/active/'.Length)
    $fqdn = $fqdn.Substring(0, $fqdn.Length - 5)
    $text = @(git show "FETCH_HEAD:$file" 2>$null)
    $role = Read-Value $text 'role'
    $addrs = @(Read-Addresses $text)
    if ($addrs.Count -eq 0) {
      Stop-Here "$file on branch $MasterFqdn states no nodeCidrs, so where $fqdn stood is unknown: it can neither be asked whether it still answers nor can a record be attributed to it" 65
    }
    $said = if ($role) { $role } else { 'a cluster of unstated role' }
    Say "abandon: $file records $fqdn as $said at $($addrs -join ', ')"
    $addresses += $addrs
    $clusters.Add(@{ fqdn = $fqdn; addresses = $addrs })
    Add-Name "*.$fqdn" "the platform host names of $fqdn"
    foreach ($label in $platformHostLabels -split ' ') { Add-Name "$label.$fqdn" "a platform host name of $fqdn" }
    if ($fqdn -ne $MasterFqdn) {
      $short = ($fqdn -split '\.')[0]
      Add-Name "argo-$short.$MasterFqdn" "the reconciler of the slave $fqdn on its master"
      Say "abandon: the platform host names of ${fqdn}: *.$fqdn, argo-$short.$MasterFqdn and the labels $platformHostLabels below $fqdn"
    }
    else {
      Say "abandon: the platform host names of ${fqdn}: *.$fqdn and the labels $platformHostLabels below it"
    }
  }

  # EVERY CONSUMER AT EVERY STAGE, off the path of its registration: the stage is
  # the file's name, the host label is the registration's `host`, and the name is
  # <label>.<stage apex> — the one composition the Manager and the ApplicationSets
  # share.
  foreach ($file in $files) {
    if ($file -notmatch '^registrations/([^/]+)/(dev|test|prod)\.yaml$') { continue }
    $unit = $Matches[1]; $unitStage = $Matches[2]
    $text = @(git show "FETCH_HEAD:$file" 2>$null)
    $hostLabel = Read-Value $text 'host'
    if (-not $hostLabel) { $hostLabel = Read-Value $text 'name' }
    if (-not $hostLabel) { $hostLabel = $unit }
    $name = "$hostLabel.$(Get-StageApex $unitStage)"
    Say "abandon: $file stands at $name"
    Add-Name $name "the consumer $unit at $unitStage"
  }

  # THE TWO SENDER DOMAINS, off the master's map: customer mail as the platform
  # domain, alert mail as the unit apex. Each carries the address record and the
  # SPF at the apex, the DKIM key under the relay's selector, which is the stage,
  # and the DMARC policy.
  $mailDomains = @($unitApex)
  if ($platformDomain -and $platformDomain -ne $unitApex) {
    $mailDomains = @($platformDomain, $unitApex)
  }
  elseif (-not $platformDomain) {
    Say "abandon: $map names no platformDomain, so no mail record of a platform domain is derived"
  }
  foreach ($domain in $mailDomains) {
    Say "abandon: the mail records of ${domain}: $domain (its address and SPF), $stage._domainkey.$domain (DKIM), _dmarc.$domain (DMARC)"
    Add-Name $domain "the sender domain $domain"
    Add-Name "$stage._domainkey.$domain" "the DKIM record of $domain"
    Add-Name "_dmarc.$domain" "the DMARC record of $domain"
  }
}
else {
  Say "abandon: origin carries no branch $MasterFqdn, so no map, no address and no registration of it can be read: no DNS record can be derived or attributed, and the zone is left as it stands"
}

# ----------------------------------------------------------- the catalog
# THE INSTALLATION'S BOOKS BRANCH IN THE CATALOG, named like the install branch,
# carries the tenant registrations and the pins. It is asked with this
# workstation's own login, the way every act here reaches a repository.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('abandon-' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work *> $null
try {
  git ls-remote --exit-code --heads $catalogUrl "refs/heads/$MasterFqdn" *> $null
  switch ($LASTEXITCODE) {
    0 { $catalogBooks = $true }
    2 { $catalogBooks = $false }
    default { Stop-Here "the catalog $catalogUrl could not be asked for its branches with this workstation's login, so what it carries of $MasterFqdn cannot be read" 69 }
  }
  $cat = Join-Path $work 'catalog'
  if ($catalogBooks) {
    git clone --quiet --single-branch --branch $MasterFqdn $catalogUrl $cat *> $null
    if ($LASTEXITCODE -ne 0) {
      Stop-Here "the books branch $MasterFqdn of the catalog $catalogUrl could not be cloned, so its registrations cannot be read" 69
    }
    foreach ($file in @(git -C $cat ls-tree -r --name-only HEAD -- registrations 2>$null)) {
      if ($file -notmatch '^registrations/([^/]+)/(dev|test|prod)\.yaml$') { continue }
      $guid = $Matches[1]; $tenantStage = $Matches[2]
      $subdomain = Read-Value @(Get-Content -Path (Join-Path $cat $file)) 'subdomain'
      if ($books -and $subdomain) {
        $name = "*.$subdomain.$(Get-StageApex $tenantStage)"
        Say "abandon: the catalog's books branch $MasterFqdn carries $file, which stands at $name"
        Add-Name $name "the tenant $guid at $tenantStage"
      }
      else {
        $said = if ($subdomain) { $subdomain } else { 'none' }
        Say "abandon: the catalog's books branch $MasterFqdn carries $file (subdomain '$said'), whose wildcard cannot be derived without the map"
      }
    }
  }
  else {
    Say "abandon: the catalog $catalogUrl carries no books branch $MasterFqdn"
  }

  if (-not $books -and -not $catalogBooks) {
    Say "abandon: nothing of $MasterFqdn stands on origin or in the catalog, and nothing can be derived without its branch: nothing to do"
    Say "abandon: $ConfigFile stays. A local config is the record of the answers a machine was installed with, and the next machine of that name is installed from it"
    exit 0
  }

  if ($books) {
    Say "abandon: $MasterFqdn itself is the machine's name and not the installation's, so its own address record stays"
    Say "abandon: $($names.Count) names derived; an A or AAAA record among them at $($addresses -join ', ') is this installation's, so is a CNAME to one of its own cluster names, and so is an SPF that authorises those addresses and nobody else"
  }

  # ================================================================== GUARD
  # EVERY ADDRESS OF EVERY CLUSTER IS ASKED whether the cluster's API still
  # answers there. Asked as an HTTPS request to the API port: an API server
  # answers an anonymous request with a status, and a status of any kind is an
  # answer, while a connection refused (curl 7) or one that times out (curl 28) is
  # not. Anything else — a handshake that failed, a protocol nobody expected — is
  # read as answering, because the safe reading of a doubt is the refusal.
  if ($books) {
    foreach ($cluster in $clusters) {
      foreach ($addr in $cluster.addresses) {
        $at = if ($addr.Contains(':')) { "[$addr]" } else { $addr }
        & $curl -k -sS --connect-timeout 5 --max-time 10 "https://${at}:$apiPort/" *> $null
        $rc = $LASTEXITCODE
        if ($rc -eq 7 -or $rc -eq 28) {
          Say "abandon: $($cluster.fqdn) does not answer on port $apiPort at $addr"
        }
        else {
          Stop-Here "$($cluster.fqdn) answers on port $apiPort at $addr (curl exit $rc), so this is a LIVING installation. A living installation is offboarded through the Manager and taken back with remove-slave-from-master and the reset, never abandoned. Nothing has been changed" 69
        }
      }
    }
  }

  # ------------------------------------------------------ the push access
  # PROVEN BEFORE THE FIRST DELETE, by a dry run of the same push: a deletion this
  # workstation cannot push would be found after the records are gone, with the
  # branch they were derived from still standing and no way to say so in advance.
  $deletable = @()
  if ($books) {
    foreach ($cluster in $clusters) {
      $fqdn = $cluster.fqdn
      $stands = $fqdn -eq $MasterFqdn
      if (-not $stands) {
        git ls-remote --exit-code --heads origin "refs/heads/$fqdn" *> $null
        $stands = $LASTEXITCODE -eq 0
      }
      if ($stands) {
        $refused = @(git push --dry-run --quiet origin --delete "refs/heads/$fqdn" 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
          Stop-Here "this workstation cannot push the deletion of branch $fqdn to origin ($($refused -join ' ')), so the branch could not follow the records. Nothing has been changed" 77
        }
        $deletable += $fqdn
      }
    }
  }
  if ($catalogBooks) {
    $refused = @(git -C $cat push --dry-run --quiet origin --delete "refs/heads/$MasterFqdn" 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
      Stop-Here "this workstation cannot push the deletion of the books branch $MasterFqdn to the catalog $catalogUrl ($($refused -join ' ')), so that branch could not follow the records. Nothing has been changed" 77
    }
  }
  Say 'abandon: this workstation can push a branch deletion to origin and to the catalog, so every branch below can follow the records'

  # ================================================================ CONFIRM
  $goes = ''
  if ($books) { $goes = "every record above that proves itself this installation's, the branches $(($deletable | ForEach-Object { "$_ " }) -join '')on origin" }
  if ($catalogBooks) {
    if ($goes) { $goes += ', and ' }
    $goes += "the books branch $MasterFqdn of the catalog $catalogUrl"
  }
  Say "abandon: what goes: $goes. Type $MasterFqdn to confirm, or anything else to stop"
  $answer = [Console]::In.ReadLine()
  if ($null -eq $answer) { $answer = '' }
  $answer = $answer.TrimEnd("`r")
  if ($answer -ne $MasterFqdn) {
    Stop-Here "the answer was not $MasterFqdn, so this stops. Nothing has been changed" 65
  }

  # ==================================================================== DNS
  # ONE CALL TO THE API: the token rides the Authorization header, handed to curl
  # through a config on its standard input so it stands in no argument list. The
  # API wraps every answer in a success flag and can answer 200 without it, so the
  # flag and not the status is what is read. On a failure Why says what happened
  # and the caller says what it leaves behind.
  $script:Body = ''
  $script:Why = ''
  function Invoke-Cf([string] $Method, [string] $Path, [string[]] $Extra = @()) {
    $lines = @("header = `"Authorization: Bearer $token`"" | & $curl -sS -K - -X $Method @Extra "$cloudflareApi$Path" 2>&1 | ForEach-Object { "$_" })
    $rc = $LASTEXITCODE
    $script:Body = $lines -join "`n"
    if ($rc -ne 0) {
      $script:Why = "the DNS provider could not be reached for $Method $Path (curl exit ${rc}: $($lines -join ' '))"
      return $false
    }
    if ($script:Body.Contains('"success":true')) { return $true }
    $script:Why = "the DNS provider refused $Method $Path"
    if ($script:Body -match '"message":"([^"]*)"') { $script:Why += ": $($Matches[1])" }
    return $false
  }
  $stands = 'What was deleted above stays deleted, every branch stands, and a second run derives the same names again'

  # WHICH ZONE A NAME LIVES IN, found by asking the API and walking the labels: the
  # exact name first, then the name with its leftmost label taken off, down to the
  # last dot. A wildcard label is never part of a zone. Every answer is kept, so a
  # second name under the same domain asks once.
  $zoneCache = @{}
  $script:ZoneId = ''; $script:ZoneName = ''
  function Find-Zone([string] $Name) {
    $candidate = $Name -replace '^\*\.', ''
    $script:ZoneId = ''; $script:ZoneName = ''
    while ($candidate.Contains('.')) {
      if ($zoneCache.ContainsKey($candidate)) {
        if ($zoneCache[$candidate] -ne 'none') { $script:ZoneId = $zoneCache[$candidate]; $script:ZoneName = $candidate; return $true }
      }
      else {
        if (-not (Invoke-Cf 'GET' '/zones' @('-G', '--data-urlencode', "name=$candidate", '--data-urlencode', 'per_page=1'))) { return $false }
        $zones = @(($script:Body | ConvertFrom-Json).result)
        if ($zones.Count -gt 0 -and $zones[0].id) {
          $zoneCache[$candidate] = $zones[0].id
          $script:ZoneId = $zones[0].id; $script:ZoneName = $candidate
          return $true
        }
        $zoneCache[$candidate] = 'none'
      }
      $candidate = $candidate.Substring($candidate.IndexOf('.') + 1)
    }
    return $true
  }

  # A TXT VALUE AS THE ONE TEXT IT IS, however the zone stored it: the API answers
  # a long TXT as quoted chunks, so the outer quotes come off and the chunk seams
  # are joined, the way the Manager and the catalogue's plugin read the same
  # records.
  function Get-TxtText([string] $Value) {
    $v = $Value
    if ($v.StartsWith('"')) { $v = $v.Substring(1) }
    if ($v.EndsWith('"')) { $v = $v.Substring(0, $v.Length - 1) }
    return $v.Replace('" "', '')
  }

  # AN SPF IS THE INSTALLATION'S ALONE when every term is the version, an ip4 of
  # one of its addresses or the closing all-mechanism. A term of anybody else's —
  # an include, an ip4 of another sender — makes the record a merge that the
  # publish step preserved on purpose, and a merge is not deleted.
  function Test-SpfOurs([string] $Lowered) {
    $ours = $false
    foreach ($term in ($Lowered -split '\s+')) {
      if ($term -eq '' -or $term -eq 'v=spf1') { continue }
      if ($term -match '^[-~+?]all$') { continue }
      if ($term.StartsWith('ip4:')) {
        if (-not (Test-Address $term.Substring(4))) { return $false }
        $ours = $true
        continue
      }
      return $false
    }
    return $ours
  }

  $deleted = 0; $left = 0; $empty = 0
  if ($books) {
    foreach ($entry in $names) {
      $name = $entry.name; $what = $entry.what
      if (-not (Find-Zone $name)) { Stop-Here "$script:Why. $stands" 69 }
      if (-not $script:ZoneId) {
        Stop-Here "the token reaches no zone for $name, walked down to its last dot, so its records cannot be read. $stands" 69
      }
      $zoneId = $script:ZoneId; $zoneName = $script:ZoneName
      if (-not (Invoke-Cf 'GET' "/zones/$zoneId/dns_records" @('-G', '--data-urlencode', "name=$name", '--data-urlencode', 'per_page=100'))) {
        Stop-Here "$script:Why. $stands" 69
      }
      $records = @(($script:Body | ConvertFrom-Json).result)
      if ($records.Count -eq 0) { $empty++ }
      foreach ($record in $records) {
        $id = $record.id; $type = $record.type; $content = [string] $record.content
        $ours = $false
        $shown = ''
        switch ($type) {
          { $_ -eq 'A' -or $_ -eq 'AAAA' } {
            if (Test-Address $content) { $ours = $true; $shown = "$type $name -> $content" }
            else { Say "abandon: zone ${zoneName}: left $type $name -> $content, an address this installation never had" }
            break
          }
          'CNAME' {
            if (Test-ClusterName $content) { $ours = $true; $shown = "$type $name -> $content" }
            else { Say "abandon: zone ${zoneName}: left $type $name -> $content, an alias to a name that is no cluster of this installation" }
            break
          }
          'TXT' {
            $text = Get-TxtText $content
            $lowered = $text.ToLowerInvariant()
            if ($lowered.StartsWith('v=spf1')) {
              if (Test-SpfOurs $lowered) { $ours = $true; $shown = "TXT $name ($text)" }
              else { Say "abandon: zone ${zoneName}: left TXT $name ($text): it authorises senders beside this installation, or none of its addresses; take its mechanism out by hand" }
            }
            else {
              Say "abandon: zone ${zoneName}: left TXT $name ($($text.Substring(0, [Math]::Min(48, $text.Length)))): nothing on the branch proves that content the installation's"
            }
            break
          }
          default { Say "abandon: zone ${zoneName}: left $type $name -> ${content}: this act judges A, AAAA, CNAME and TXT records only" }
        }
        if ($ours) {
          if (-not (Invoke-Cf 'DELETE' "/zones/$zoneId/dns_records/$id")) { Stop-Here "$script:Why. $stands" 69 }
          Say "abandon: zone ${zoneName}: deleted $shown, $what"
          $deleted++
        }
        else {
          $left++
        }
      }
    }
    Say "abandon: $deleted records deleted, $left left standing and listed above, $empty of the derived names carried nothing"
  }

  # =============================================================== BRANCHES
  # THE MASTER'S BRANCH, THE SLAVES' BRANCHES, THEN THE CATALOG'S, each named. A
  # cluster carrying only the slave part has no branch of its own today; one cut
  # under the earlier layout is taken down with the rest, and an absent one is
  # said and not refused.
  if ($books) {
    foreach ($cluster in $clusters) {
      $fqdn = $cluster.fqdn
      $stands = $fqdn -eq $MasterFqdn
      if (-not $stands) {
        git ls-remote --exit-code --heads origin "refs/heads/$fqdn" *> $null
        $stands = $LASTEXITCODE -eq 0
      }
      if ($stands) {
        git push --quiet origin --delete "refs/heads/$fqdn" *> $null
        if ($LASTEXITCODE -ne 0) {
          Stop-Here "the branch $fqdn could not be deleted on origin. The records above are gone; every branch not yet named as deleted stands, and a second run takes it down" 74
        }
        Say "abandon: deleted branch $fqdn on origin"
      }
      else {
        Say "abandon: origin carries no branch $fqdn, as a cluster carrying only the slave part has none of its own"
      }
    }
  }
  if ($catalogBooks) {
    git -C $cat push --quiet origin --delete "refs/heads/$MasterFqdn" *> $null
    if ($LASTEXITCODE -ne 0) {
      Stop-Here "the books branch $MasterFqdn could not be deleted in the catalog $catalogUrl. Everything above is gone, that branch stands, and a second run takes it down" 74
    }
    Say "abandon: deleted the books branch $MasterFqdn of the catalog $catalogUrl"
  }

  Say "abandon: $ConfigFile stays. A local config is the record of the answers a machine was installed with, and the next machine of that name is installed from it"
}
finally {
  Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
