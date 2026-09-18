# =============================================================================
# create-github-app.ps1 — create the platform's GitHub App in the customer's
# organisation, install it there, and write its three answers into the config.
# Bash twin: create-github-app.sh (same folder), which does the same in the
# same order and prints the same lines. lifecycle/test.sh measures that.
# =============================================================================
#
# USAGE (run from anywhere)
#   pwsh ./lifecycle/create-github-app.ps1 <config> [organisation]
#
# THE TWO INPUTS
#   config        — the installation's own key=value file, the one
#                   install-machine.ps1 is given and in the same grammar. Read
#                   for CATALOG_REPO and UNIT_APEX and never run. The three
#                   answers GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and
#                   GITHUB_APP_PRIVATE_KEY are written into it in place.
#   organisation  — the GitHub organisation the App is created in and installed
#                   on. Defaults to the owner of CATALOG_REPO, because that is
#                   the customer's organisation the tenant repositories live in.
#
# WHAT GITHUB ALLOWS, AND WHY TWO CLICKS STAY. No API creates an App from
# nothing. The App Manifest flow is the closest: a browser posts a manifest —
# the name, the homepage, the address to send the browser back to, the six
# repository permissions, no webhook — to the organisation's new-App page, the
# person clicks Create GitHub App ONCE, GitHub sends the browser back with a
# temporary code, and one unauthenticated request turns that code into the App:
# its id, its slug, its private key. No API installs an App on an organisation
# either: the person opens the App's installation page and clicks Install with
# All repositories, the second and last click. From then on the App's own JWT,
# signed with the key, can ask GitHub for that installation and its id.
#
# THE ORDER IS READ, GUARD, CREATE, WRITE, INSTALL, WRITE. The config is asked
# whether it already carries the answers and whether anybody but the owner can
# read it BEFORE the browser opens, because the private key lands in that file:
# a file refused after the App exists would leave an App on GitHub whose key no
# file holds. The two answers the creation gives, the id and the key, are
# written the moment the App stands and before the installation is asked for.
# The key exists in this run's memory and in that file and nowhere else, so a
# run that ends between the two clicks leaves a config a second run picks up:
# it finds the id and the key, skips the creation, and installs. A config
# carrying all three refuses, so every run of this is safe to repeat.
#
# THE LISTENER is a TcpListener on 127.0.0.1 at a port the system picks, in this
# process, and a TcpListener rather than an HttpListener because the latter
# asks Windows for a URL reservation and this needs none. It serves the manifest
# page, which submits itself, answers GitHub's redirect with one line, and
# records the code. After ten minutes without the redirect this refuses.
#
# THE KEY TOUCHES DISK IN ONE PLACE, the config: the JWT is signed in memory
# with the runtime's own RSA.
#
# THE PATH A PERSON TYPED IS THE PATH EVERY LINE NAMES, and it is deliberately
# not resolved to its full form first: the twin carries the path it was given,
# and a path rewritten here would be the one thing in this file the two
# spellings could not print the same bytes for.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $ConfigFile = '',
  [Parameter(Position = 1)][string] $Organisation = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]] $More = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY curl CALL BELOW IS READ BY ITS EXIT CODE. Newer PowerShell turns a
# non-zero native exit into a terminating error under the preference above;
# stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

# EVERY LINE ENDS IN ONE BYTE. Write-Host and WriteLine end a line with what the
# running system calls a newline, which on Windows is two bytes and on Linux one,
# so the same script would print different bytes on two machines and the twin
# could never be held to matching it. The newline is written out here instead,
# and a carriage return never enters the output at all.
function Stop-Here([string] $Because, [int] $Code = 65) {
  [Console]::Error.Write("create-github-app: $Because`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

if ($More.Count -gt 0) {
  Stop-Here "lifecycle/create-github-app.ps1 was given more than it takes: $($More[0])" 64
}
if (-not $ConfigFile) {
  Stop-Here 'usage: lifecycle/create-github-app.ps1 <config> [organisation]' 64
}
if (-not (Get-Command curl -CommandType Application -ErrorAction SilentlyContinue)) {
  Stop-Here 'curl is not on this path, and this act is curl against GitHub'
}
# THE PROGRAM AND NOT AN ALIAS: an older PowerShell spells a web request `curl`,
# and what this needs is the program the bash twin runs.
$curl = @(Get-Command curl -CommandType Application)[0].Source
if (-not (Test-Path -LiteralPath $ConfigFile)) {
  Stop-Here "there is no config at $ConfigFile. It is the installation's own, the one install-machine is given: name it as the first argument" 66
}
$configPath = (Resolve-Path -LiteralPath $ConfigFile).Path

# THE VALUE OF ONE KEY of the config, READ AND NEVER EXECUTED: two values are
# all this reads out of a file that carries thirteen credentials.
function Read-ConfigValue([string] $Key) {
  foreach ($line in [System.IO.File]::ReadAllLines($configPath)) {
    if ($line -match "^([A-Z][A-Z0-9_]*)='([^']*)'" -and $Matches[1] -eq $Key) { return $Matches[2] }
  }
  return ''
}
# THE LINE IS REPLACED WHERE IT STANDS AND APPENDED ONLY WHERE THE FILE HAS NONE,
# and the file is truncated where it stands rather than replaced by a copy: a
# copy would carry the copy's access list, and the guard below asks for the
# file's own.
function Write-ConfigValue([string] $Key, [string] $Value) {
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in [System.IO.File]::ReadAllLines($configPath)) { $lines.Add($line) }
  $found = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith("${Key}=")) {
      $lines[$i] = "${Key}='$Value'"
      $found = $true
      break
    }
  }
  if (-not $found) { $lines.Add("${Key}='$Value'") }
  [System.IO.File]::WriteAllText($configPath, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}
# OWNER-ONLY OR NOTHING. Windows says this with an access list rather than a mode,
# so the question asked here is the one require-owner-only.sh asks for the bash
# twin and only the answer is read differently: which accounts hold rights on
# it, beyond the owner and the system. A principal admitted here is admitted
# there in the same change. Everywhere else the answer is the mode, 600 or 400.
$script:Reach = ''
$script:OwnerOnlyCommand = ''
function Test-OwnerOnly {
  $script:Reach = ''
  $script:OwnerOnlyCommand = ''
  if ($IsWindows) {
    $acl = Get-Acl -Path $configPath
    $owner = $acl.Owner
    $strangers = @($acl.Access | Where-Object {
      $who = $_.IdentityReference.Value
      $who -ne $owner -and
      $who -notmatch '(?i)\\SYSTEM$' -and
      $who -notmatch '(?i)\\Administrators$'
    } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $script:OwnerOnlyCommand = "icacls `"$configPath`" /inheritance:r /grant:r `"$($env:USERNAME):(F)`""
    if ($strangers.Count -eq 0) { return $true }
    $script:Reach = "can be read by $($strangers -join ', ')"
    return $false
  }
  $mode = & stat -c '%a' $configPath 2>$null
  if ($LASTEXITCODE -ne 0) { $mode = & stat -f '%Lp' $configPath 2>$null }
  if ($mode -eq '600' -or $mode -eq '400') { return $true }
  $script:Reach = "is mode $mode"
  $script:OwnerOnlyCommand = "chmod 600 $ConfigFile"
  return $false
}
# THE BROWSER IS $env:BROWSER WHERE IT IS SET, the way gh reads it, and the
# platform's own opener otherwise. Each returns once the browser was asked, and
# the listener is already standing when it is.
function Open-InBrowser([string] $Url) {
  try {
    if ($env:BROWSER) { & $env:BROWSER $Url *> $null; return ($LASTEXITCODE -eq 0) }
    if ($IsWindows) { Start-Process $Url; return $true }
    if ($IsMacOS) { & open $Url *> $null; return ($LASTEXITCODE -eq 0) }
    & xdg-open $Url *> $null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}
function Field($Object, [string] $Name) { # a JSON field as text, '' where the answer has none
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return '' }
  return "$($property.Value)"
}

# ================================================================== READ
# THE THREE ANSWERS DECIDE WHAT THIS RUN IS: none of them stands and the App is
# created; the id and the key stand and the App is installed; all three stand
# and nothing is done. Any other mix cannot be told apart from a hand-filled
# mistake and is refused.
$appId = Read-ConfigValue 'GITHUB_APP_ID'
$installationId = Read-ConfigValue 'GITHUB_APP_INSTALLATION_ID'
$pemJson = Read-ConfigValue 'GITHUB_APP_PRIVATE_KEY'
if ($appId -and $installationId -and $pemJson) {
  Stop-Here "$ConfigFile already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY. Nothing has been changed" 65
}
elseif ($appId -and $pemJson -and -not $installationId) { $appStands = $true }
elseif (-not $appId -and -not $pemJson -and -not $installationId) { $appStands = $false }
else {
  $carried = @(); $missing = @()
  foreach ($key in @('GITHUB_APP_ID', 'GITHUB_APP_INSTALLATION_ID', 'GITHUB_APP_PRIVATE_KEY')) {
    if (Read-ConfigValue $key) { $carried += $key } else { $missing += $key }
  }
  Stop-Here "$ConfigFile carries $($carried -join ', ') and not $($missing -join ', '), and this act cannot tell which App they belong to. Empty all three to create an App, or fill all three by hand. Nothing has been changed" 65
}

$org = $Organisation
if ($org) {
  $orgFrom = 'named as the second argument'
}
else {
  $catalogRepo = Read-ConfigValue 'CATALOG_REPO'
  if (-not $catalogRepo) {
    Stop-Here "$ConfigFile states no CATALOG_REPO, and the organisation the App is created in is its owner: state it, or name the organisation as the second argument" 65
  }
  $org = ($catalogRepo -split '/')[0]
  $orgFrom = "the owner of CATALOG_REPO in $ConfigFile"
}
if ($org -notmatch '^[A-Za-z0-9-]+$') {
  Stop-Here "'$org' is not a GitHub organisation name, which is letters, digits and hyphens" 65
}
$unitApex = Read-ConfigValue 'UNIT_APEX'
if (-not $unitApex) {
  Stop-Here "$ConfigFile states no UNIT_APEX, and the App's homepage is https://manager.<unit apex>" 65
}
$appName = "$org-platform-manager"
$homepage = "https://manager.$unitApex"

# ================================================================= GUARD
# ASKED BEFORE THE BROWSER OPENS: the private key lands in this file.
if (-not (Test-OwnerOnly)) {
  Stop-Here "$ConfigFile $($script:Reach) and is where the App's private key lands. Run: $($script:OwnerOnlyCommand). Nothing has been changed" 77
}

$github = 'https://github.com'
$githubApi = 'https://api.github.com'
# The six repository permissions the Manager creates and drives a tenant's own
# apps repository with, as GitHub spells them, in byte order.
$permissions = 'actions:write administration:write contents:write metadata:read webhooks:write workflows:write'
$waitSeconds = 600
$pollSeconds = 5

# ONE CALL TO THE API: the JWT rides the Authorization header, handed to curl
# through a config on its standard input so it stands in no argument list. The
# status rides behind the body on a line of its own, because a 404 is an answer
# here (not installed yet) and not a failure.
$script:Body = ''
$script:Status = ''
$script:Message = ''
$script:Why = ''
function Invoke-GitHub([string] $Method, [string] $Path, [string] $Jwt = '') {
  $arguments = @('-sS', '-X', $Method, '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28', '-w', '\n%{http_code}', "$githubApi$Path")
  if ($Jwt) {
    $lines = @("header = `"Authorization: Bearer $Jwt`"" | & $curl -K - @arguments 2>&1 | ForEach-Object { "$_" })
  }
  else {
    $lines = @(& $curl @arguments 2>&1 | ForEach-Object { "$_" })
  }
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    $script:Why = "GitHub could not be reached for $Method $Path (curl exit ${rc}: $($lines -join ' '))"
    return $false
  }
  $script:Status = $lines[-1]
  $script:Body = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] -join "`n" } else { '' }
  $script:Message = ''
  if ($script:Body -match '"message":"([^"]*)"') { $script:Message = ": $($Matches[1])" }
  return $true
}
# THE APP'S OWN JWT: RS256 over {iat, exp, iss}, iss being the App id, dated a
# minute into the past because GitHub refuses a token ahead of its own clock,
# and nine minutes long under GitHub's ten-minute ceiling. The same shape the
# Manager mints.
function ConvertTo-Base64Url([byte[]] $Bytes) {
  return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function New-AppJwt {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $header = ConvertTo-Base64Url ([System.Text.Encoding]::ASCII.GetBytes('{"alg":"RS256","typ":"JWT"}'))
  $claims = '{"iat":' + ($now - 60) + ',"exp":' + ($now + 540) + ',"iss":"' + $appId + '"}'
  $payload = ConvertTo-Base64Url ([System.Text.Encoding]::ASCII.GetBytes($claims))
  $signature = ConvertTo-Base64Url ($script:Key.SignData([System.Text.Encoding]::ASCII.GetBytes("$header.$payload"), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1))
  return "$header.$payload.$signature"
}
function Import-Key([string] $PemJson) { # the key as the config spells it, \n for each line break -> $script:Key; $false when the runtime does not read it
  $script:Key = [System.Security.Cryptography.RSA]::Create()
  try { $script:Key.ImportFromPem($PemJson.Replace('\n', "`n")); return $true } catch { return $false }
}
function Get-SortedPermissions($Answered) { # the permissions object of an answer -> "name:level ..." in byte order
  $pairs = @($Answered.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" })
  [Array]::Sort($pairs, [System.StringComparer]::Ordinal)
  return ($pairs -join ' ')
}
function Send-Http($Client, [string] $StatusLine, [string] $Type, [string] $Content) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
  $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $StatusLine`r`nContent-Type: $Type`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
  $stream = $Client.GetStream()
  $stream.Write($head, 0, $head.Length)
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush()
  $Client.Close()
}

# ================================================================ CREATE
$listener = $null
try {
  if (-not $appStands) {
    Say "create-github-app: the App $appName is created in the organisation $org, $orgFrom, with its homepage $homepage"
    $nonce = [guid]::NewGuid().ToString('N')
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $listener.Start() } catch {
      Stop-Here "no listener could be opened on 127.0.0.1, so GitHub would have nowhere to send the browser back to: $($_.Exception.Message). Nothing has been changed" 69
    }
    $port = ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port
    $pageUrl = "http://127.0.0.1:$port/"
    # THE MANIFEST, and the page that posts it. The page submits itself, so the
    # one click a person makes is GitHub's own Create GitHub App; the button is
    # there for a browser that runs no script. The JSON stands in a single-quoted
    # attribute, so what is escaped is what a single-quoted attribute cannot hold.
    $defaultPermissions = @($permissions -split ' ' | ForEach-Object { $pair = $_ -split ':'; "`"$($pair[0])`":`"$($pair[1])`"" }) -join ','
    $manifest = "{`"name`":`"$appName`",`"url`":`"$homepage`",`"redirect_url`":`"$pageUrl`",`"public`":false,`"hook_attributes`":{`"active`":false},`"default_permissions`":{$defaultPermissions}}"
    $attribute = $manifest.Replace('&', '&amp;').Replace('<', '&lt;').Replace("'", '&#39;')
    $page = "<!DOCTYPE html>`n<html><head><meta charset=`"utf-8`"><title>Create the GitHub App $appName</title></head>`n" +
      "<body onload=`"document.forms[0].submit()`">`n" +
      "<form method=`"post`" action=`"$github/organizations/$org/settings/apps/new?state=$nonce`">`n" +
      "<input type=`"hidden`" name=`"manifest`" value='$attribute'>`n" +
      "<button type=`"submit`">Create GitHub App</button>`n</form></body></html>`n"
    Say "create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes"
    if (Open-InBrowser $pageUrl) {
      Say "create-github-app: opened the manifest page in the browser; it posts to $github/organizations/$org/settings/apps/new. In the browser: click Create GitHub App"
    }
    else {
      Say "create-github-app: no browser could be opened; open $pageUrl yourself. It posts to $github/organizations/$org/settings/apps/new. In the browser: click Create GitHub App"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($waitSeconds)
    $query = $null
    while ($null -eq $query) {
      while (-not $listener.Pending()) {
        if ([DateTime]::UtcNow -ge $deadline) {
          Stop-Here 'GitHub did not send the browser back within 10 minutes. Nothing has been written' 69
        }
        Start-Sleep -Milliseconds 200
      }
      $client = $listener.AcceptTcpClient()
      # The request line is what is read; a connection that sends nothing within
      # five seconds (a browser opening one ahead of need) is dropped.
      $client.ReceiveTimeout = 5000
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 4096
      $request = ''
      try {
        while ($request -notmatch "`r?`n`r?`n" -and $request.Length -lt 65536) {
          $read = $stream.Read($buffer, 0, $buffer.Length)
          if ($read -le 0) { break }
          $request += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        }
      } catch { }
      if ($request -match '^GET /\?(\S*code=\S*) HTTP/') {
        $query = $Matches[1]
        Send-Http $client '200 OK' 'text/html; charset=utf-8' '<!DOCTYPE html><html><head><meta charset="utf-8"><title>done</title></head><body>done, back to the terminal</body></html>'
      }
      elseif ($request -match '^GET /(\?\S*)? HTTP/') {
        Send-Http $client '200 OK' 'text/html; charset=utf-8' $page
      }
      else {
        Send-Http $client '404 Not Found' 'text/plain' 'not the page this run serves'
      }
    }
    $listener.Stop()
    $listener = $null
    $code = ''; $state = ''
    foreach ($pair in $query -split '&') {
      if ($pair.StartsWith('code=')) { $code = $pair.Substring(5) }
      elseif ($pair.StartsWith('state=')) { $state = $pair.Substring(6) }
    }
    if ($state -ne $nonce) {
      Stop-Here "GitHub sent the browser back with a state that is not this run's, so the code is not trusted. Nothing has been written" 65
    }
    if (-not $code) { Stop-Here 'GitHub sent the browser back without a code. Nothing has been written' 65 }
    Say "create-github-app: GitHub sent the browser back with a code, and the state is this run's"

    # THE CODE BECOMES THE APP in one unauthenticated request. The answer carries
    # the key and two more secrets, so no part of it is printed.
    if (-not (Invoke-GitHub 'POST' "/app-manifests/$code/conversions")) { Stop-Here "$($script:Why). Nothing has been written" 69 }
    if ($script:Status -ne '201') {
      Stop-Here "GitHub refused to turn the code into an App (HTTP $($script:Status)$($script:Message)). Nothing has been written" 69
    }
    $app = $script:Body | ConvertFrom-Json
    $appId = Field $app 'id'
    if (-not $appId) { Stop-Here "GitHub's answer to the conversion carries no id, so the App cannot be recorded. Nothing has been written" 69 }
    $slug = Field $app 'slug'
    if (-not $slug) { Stop-Here "GitHub's answer to the conversion carries no slug, so the App cannot be recorded. Nothing has been written" 69 }
    $htmlUrl = Field $app 'html_url'
    if (-not $htmlUrl) { Stop-Here "GitHub's answer to the conversion carries no html_url, so the App cannot be recorded. Nothing has been written" 69 }
    $pem = Field $app 'pem'
    if (-not $pem) { Stop-Here "GitHub's answer to the conversion carries no pem, so the App at $htmlUrl has no key this can write. Delete it there and run this again. Nothing has been written" 69 }
    if ($null -eq $app.PSObject.Properties['permissions'] -or $null -eq $app.permissions) {
      Stop-Here "GitHub's answer to the conversion names no permissions, so the App at $htmlUrl cannot be held to the six asked. Delete it there and run this again. Nothing has been written" 69
    }
    $got = Get-SortedPermissions $app.permissions
    if ($got -ne $permissions) {
      Stop-Here "the App was created at $htmlUrl with the permissions $got and not the six asked: $permissions. Delete it there and run this again. Nothing has been written" 65
    }
    Say "create-github-app: the App stands at $htmlUrl (id $appId) with the six permissions $got"
    # THE KEY IS WRITTEN AS ONE LINE, \n in place of each line break, which is
    # what the Manager turns back and what GitHub's own JSON spelled it as.
    $pemJson = $pem.Replace("`r`n", "`n").Replace("`n", '\n')

    # ================================================================= WRITE
    Write-ConfigValue 'GITHUB_APP_ID' $appId
    Write-ConfigValue 'GITHUB_APP_PRIVATE_KEY' $pemJson
    if (-not (Test-OwnerOnly)) {
      Stop-Here "$ConfigFile $($script:Reach) now that it carries the App's private key. Run: $($script:OwnerOnlyCommand)" 77
    }
    Say "create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into $ConfigFile in place"
  }
  else {
    Say "create-github-app: $ConfigFile carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY and no GITHUB_APP_INSTALLATION_ID, so the App stands and this run installs it"
  }

  # =============================================================== INSTALL
  $stands = "The App stands, and $ConfigFile carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY"
  if ($appStands) {
    # THE APP IS ASKED FOR ITSELF, so the slug is GitHub's and the key is proven
    # to belong to the id the config states before a person is sent to install.
    if (-not (Import-Key $pemJson)) {
      Stop-Here "the key in $ConfigFile is not a private key this can sign a JWT with. Nothing has been changed" 65
    }
    if (-not (Invoke-GitHub 'GET' '/app' (New-AppJwt))) { Stop-Here "$($script:Why). Nothing has been changed" 69 }
    if ($script:Status -ne '200') {
      Stop-Here "GitHub does not answer an App for the key in $ConfigFile (HTTP $($script:Status)$($script:Message)). Nothing has been changed" 69
    }
    $app = $script:Body | ConvertFrom-Json
    $answeredId = Field $app 'id'
    if (-not $answeredId) { Stop-Here "GitHub's answer for the App carries no id. Nothing has been changed" 69 }
    if ($answeredId -ne $appId) {
      Stop-Here "GitHub answers App $answeredId for the key in $ConfigFile, and the config states GITHUB_APP_ID='$appId'. Nothing has been changed" 65
    }
    $slug = Field $app 'slug'
    if (-not $slug) { Stop-Here "GitHub's answer for the App carries no slug. Nothing has been changed" 69 }
    $htmlUrl = Field $app 'html_url'
    if (-not $htmlUrl) { Stop-Here "GitHub's answer for the App carries no html_url. Nothing has been changed" 69 }
    Say "create-github-app: the App stands at $htmlUrl (id $appId)"
  }
  elseif (-not (Import-Key $pemJson)) {
    Stop-Here "the App's key is not a private key this can sign a JWT with. $stands" 65
  }
  $installUrl = "$github/apps/$slug/installations/new"
  $settings = "$github/organizations/$org/settings/installations"
  if (Open-InBrowser $installUrl) {
    Say "create-github-app: opened $installUrl in the browser. In the browser: choose All repositories and click Install"
  }
  else {
    Say "create-github-app: no browser could be opened; open $installUrl yourself. There: choose All repositories and click Install"
  }
  Say "create-github-app: asking GitHub every $pollSeconds seconds whether the App is installed in $org, for up to 10 minutes"
  $deadline = [DateTime]::UtcNow.AddSeconds($waitSeconds)
  while ($true) {
    if (-not (Invoke-GitHub 'GET' "/orgs/$org/installation" (New-AppJwt))) {
      Stop-Here "$($script:Why). ${stands}: install it at $installUrl with All repositories and run this again" 69
    }
    if ($script:Status -eq '200') { break }
    if ($script:Status -ne '404') {
      Stop-Here "GitHub answered HTTP $($script:Status)$($script:Message) when asked whether the App is installed in $org. ${stands}: install it at $installUrl with All repositories and run this again" 69
    }
    if ([DateTime]::UtcNow -ge $deadline) {
      Stop-Here "the App was not installed in $org within 10 minutes. ${stands}: install it at $installUrl with All repositories and run this again" 69
    }
    Start-Sleep -Seconds $pollSeconds
  }
  $installation = $script:Body | ConvertFrom-Json
  $installationId = Field $installation 'id'
  if (-not $installationId) { Stop-Here "GitHub's answer for the installation in $org carries no id. ${stands}: run this again" 69 }
  $selection = Field $installation 'repository_selection'
  if (-not $selection) { Stop-Here "GitHub's answer for the installation in $org carries no repository_selection. ${stands}: run this again" 69 }
  if ($selection -ne 'all') {
    Stop-Here "the App is installed in $org with repository_selection $selection, and the Manager needs all. Choose All repositories at $settings/$installationId, then run this again: $stands, and the next run writes GITHUB_APP_INSTALLATION_ID" 65
  }
  Say "create-github-app: installed in $org on all repositories, installation ${installationId}: $settings/$installationId"

  # ================================================================= WRITE
  Write-ConfigValue 'GITHUB_APP_INSTALLATION_ID' $installationId
  if (-not (Test-OwnerOnly)) {
    Stop-Here "$ConfigFile $($script:Reach) now that it carries the App's private key. Run: $($script:OwnerOnlyCommand)" 77
  }
  Say "create-github-app: GITHUB_APP_INSTALLATION_ID written into $ConfigFile in place"
  Say "create-github-app: $ConfigFile carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY, and nobody but the owner can read it. The App: $htmlUrl. Its installation: $settings/$installationId"
}
finally {
  if ($null -ne $listener) { $listener.Stop() }
}
