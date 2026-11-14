<#
.SYNOPSIS
    Creates a Microsoft Dynamics 365 Business Central environment with Docker or Podman
    Compose, on Windows, Linux and macOS, using MsDyn365Bc.On.Linux.

.DESCRIPTION
    The script follows the supported MsDyn365Bc.On.Linux workflow (docker compose up) and
    adds what that workflow leaves to the user:
      1. Uses the docker CLI and its current context (Docker Desktop, Docker Engine, Kiri,
         OrbStack, ...) or podman (override with -Engine), with its compose plugin.
      2. Fetches the upstream repository once (git clone, or a zip download without git)
         into a cache folder, or uses -RepoPath.
      3. Runs `compose up` with the upstream docker-compose.yml, the upstream macOS
         overlay when the amd64 image has to be emulated (Apple Silicon / ARM), and a
         generated override (persistent database, extra container env, emulation fixes).
         Every setting is handed to compose through a generated --env-file using the
         upstream variable names (BC_VERSION, BC_COUNTRY, BC_LICENSE_HOST_PATH, ...).
      4. Waits until the service tier is ready and answers OData.
      5. Publishes and installs extensions (.app files) through the dev endpoint, in the
         given order.

    Settings come from, in increasing order of precedence:
      built-in defaults  <  -EnvFile (KEY=VALUE lines)  <  BCVM_* environment variables
      <  explicit parameters.
    Any other KEY=VALUE in -EnvFile, and every entry in -ContainerEnv, is passed through
    to the BC container unchanged (e.g. BC_SERVER_SETTINGS, BC_ALLOW_PUBLISH_FAILURES).

    State (generated compose override and env file) is kept in ~/.bcvm/<Name>.

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1      # latest public BC release, W1 sandbox, web client, name 'bc'

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -BcVersion 28.5 -Country w1 `
        -LicenseFile ./dev.bclicense -Apps './apps/a.app;./apps/b.app'

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc290 -PublishPorts:$false   # Kiri: http://dev.bc290.kiri.local, ... no ports

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -EnvFile ./example.env

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -Remove     # compose down -v: containers and volumes
#>
#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    # Environment name = compose project name (containers <Name>-bc-1, <Name>-sql-1).
    [string] $Name,
    # BC version: 'latest' (default) = newest public release of BcType/Country; short ("28.5")
    # = newest build of that minor; or a full build number.
    [string] $BcVersion,
    # Localization, e.g. w1, us, de, dk, is.
    [string] $Country,
    # sandbox | onprem
    [ValidateSet('sandbox', 'onprem')] [string] $BcType,
    # Explicit artifact URL; overrides BcVersion/Country/BcType.
    [string] $ArtifactUrl,

    [string] $Username,
    [string] $Password,
    [string] $SaPassword,

    # Self-host the BC web client (http://localhost:<WebClientPort>). On by default; -WebClient:$false turns it off.
    [switch] $WebClient,

    # .app files and/or folders, published in the given order. Preferred form: one string
    # separated by ';' ('a.app;b.app'), the same in every shell and in env files; arrays and ','
    # also work. A folder contributes its *.app files sorted by name; apps whose dependencies
    # are not there yet are retried after the others.
    [string[]] $Apps,
    # Optional .bclicense file (e.g. a partner developer license) imported before the service
    # tier starts, instead of the CRONUS demo license. Needed for ISV apps such as LS Central.
    [Alias('BcLicenseHostPath')] [string] $LicenseFile,
    # Company to create (if missing) for -ConfigPackages. Creating a company needs SQL Full-Text
    # Search, so -FullTextSearch is turned on automatically when this is set.
    [string] $CompanyName,
    # RapidStart configuration packages imported and applied into -CompanyName, in order: one ';'
    # separated string or an array of .rapidstart files, folders (their *.rapidstart sorted by name)
    # and 'feature:<Id>' steps that enable a Feature Management feature at that point
    # (e.g. 'base.rapidstart;feature:SalesPrices;./ls-packages').
    [string[]] $ConfigPackages,
    # SQL Server with Full-Text Search (needed to create companies and by apps that use
    # OptimizeForTextSearch). ARM hosts build a CU17-based image once; x86 uses upstream's 2022-fts.
    [switch] $FullTextSearch,
    # Additional environment variables for the BC container.
    [hashtable] $ContainerEnv,
    # KEY=VALUE file with settings (see the .DESCRIPTION).
    [string] $EnvFile,

    # Host ports. -PortOffset is added to every default port (7045/7048/7049/7052/7085/8080/11433).
    [int] $PortOffset,
    [int] $DevPort, [int] $ODataPort, [int] $ApiPort, [int] $MgmtPort, [int] $ClientPort,
    [int] $WebClientPort, [int] $SqlPort,
    # Publish the BC/SQL ports on localhost (default). -PublishPorts:$false publishes none, so no
    # port planning is needed; endpoints are then reached by name (Kiri: http://dev.<Name>.kiri.local
    # ...). A port given explicitly (e.g. -SqlPort 11433) is still published.
    [switch] $PublishPorts,

    [ValidateSet('auto', 'docker', 'podman')] [string] $Engine,
    # Existing clone of MsDyn365Bc.On.Linux. Default: cached clone in ~/.bcvm/MsDyn365Bc.On.Linux.
    [string] $RepoPath,
    # Branch or tag of the upstream repository to fetch when no -RepoPath is given.
    [string] $RepoRef,
    # Overrides for the upstream images (BC_RUNNER_IMAGE / SQL image).
    [string] $BcImage,
    [string] $SqlImage,
    [int] $SqlMemoryMB,
    # Keep the database in a volume so the environment survives restarts (default),
    # or use -PersistDatabase:$false for upstream's throw-away in-memory (tmpfs) database.
    [switch] $PersistDatabase,
    # Remove an existing environment of the same name (including its volumes) first.
    [switch] $Recreate,
    # Minutes to wait for the service tier.
    [int] $TimeoutMinutes,
    # Seconds a single extension publish may take.
    [int] $PublishTimeoutSeconds,

    [Parameter(ParameterSetName = 'Remove', Mandatory)] [switch] $Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string] $Message) { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor Cyan }
function Write-Note([string] $Message) { Write-Host "           $Message" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Settings resolution: defaults < env file < BCVM_* env vars < parameters
# ---------------------------------------------------------------------------
$defaults = [ordered]@{
    Name                  = 'bc'
    BcVersion             = 'latest'
    Country               = 'w1'
    BcType                = 'sandbox'
    ArtifactUrl           = ''
    Username              = 'BCRUNNER'
    Password              = 'Admin123!'
    SaPassword            = 'Passw0rd123!'
    WebClient             = $true
    Apps                  = @()
    LicenseFile           = ''
    PortOffset            = 0
    PublishPorts          = $true
    Engine                = 'auto'
    RepoPath              = ''
    RepoRef               = 'master'
    BcImage               = ''
    SqlImage              = ''
    SqlMemoryMB           = 3072
    PersistDatabase       = $true
    TimeoutMinutes        = 45
    PublishTimeoutSeconds = 3600
    CompanyName           = ''
    ConfigPackages        = @()
    FullTextSearch        = $null     # auto: on when CompanyName is set
}
# KEY names accepted in the env file / as BCVM_<KEY> environment variables.
$keyMap = @{
    NAME = 'Name'; BC_VERSION = 'BcVersion'; BC_COUNTRY = 'Country'; BC_TYPE = 'BcType'
    BC_ARTIFACT_URL = 'ArtifactUrl'; BC_SERVER_USERNAME = 'Username'; BC_SERVER_PASSWORD = 'Password'
    SA_PASSWORD = 'SaPassword'; BC_WEBCLIENT = 'WebClient'; APPS = 'Apps'
    LICENSE_FILE = 'LicenseFile'; BC_LICENSE_HOST_PATH = 'LicenseFile'
    PUBLISH_PORTS = 'PublishPorts'; PORT_OFFSET = 'PortOffset'; BC_DEV_PORT = 'DevPort'; BC_ODATA_PORT = 'ODataPort'; BC_API_PORT = 'ApiPort'
    BC_MGMT_PORT = 'MgmtPort'; BC_CLIENT_PORT = 'ClientPort'; BC_WEBCLIENT_PORT = 'WebClientPort'; SQL_PORT = 'SqlPort'
    ENGINE = 'Engine'; REPO_PATH = 'RepoPath'; REPO_REF = 'RepoRef'
    BC_RUNNER_IMAGE = 'BcImage'; BC_SQL_IMAGE = 'SqlImage'; MSSQL_MEMORY_LIMIT_MB = 'SqlMemoryMB'
    PERSIST_DATABASE = 'PersistDatabase'; TIMEOUT_MINUTES = 'TimeoutMinutes'
    PUBLISH_TIMEOUT_SECONDS = 'PublishTimeoutSeconds'
    COMPANY_NAME = 'CompanyName'; CONFIG_PACKAGES = 'ConfigPackages'; FULL_TEXT_SEARCH = 'FullTextSearch'
}
$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
$passThroughEnv = [ordered]@{}

function ConvertTo-Setting([string] $Key, [string] $Value) {
    switch ($Key) {
        { $_ -in 'WebClient', 'PersistDatabase', 'PublishPorts', 'FullTextSearch' } { return $Value -match '^(1|true|yes|on)$' }
        { $_ -in 'Apps', 'ConfigPackages' } { return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        { $_ -in 'PortOffset', 'DevPort', 'ODataPort', 'ApiPort', 'MgmtPort', 'ClientPort', 'WebClientPort', 'SqlPort', 'SqlMemoryMB', 'TimeoutMinutes', 'PublishTimeoutSeconds' } { return [int] $Value }
        default { return $Value }
    }
}

$envFileDir = $PWD.Path
if ($EnvFile) {
    $EnvFile = (Resolve-Path -LiteralPath $EnvFile).Path
    $envFileDir = Split-Path -Parent $EnvFile
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { continue }
        $key = $Matches[1].ToUpperInvariant(); $val = $Matches[2].Trim().Trim('"').Trim("'")
        if ($keyMap.ContainsKey($key)) { $cfg[$keyMap[$key]] = ConvertTo-Setting $keyMap[$key] $val }
        else { $passThroughEnv[$Matches[1]] = $val }
    }
}
foreach ($key in $keyMap.Keys) {
    $val = [Environment]::GetEnvironmentVariable("BCVM_$key")
    if ($null -ne $val -and $val -ne '') { $cfg[$keyMap[$key]] = ConvertTo-Setting $keyMap[$key] $val }
}
foreach ($p in $PSBoundParameters.GetEnumerator()) {
    if ($p.Key -in 'EnvFile', 'ContainerEnv', 'Recreate', 'Remove', 'Verbose', 'Debug') { continue }
    $cfg[$p.Key] = if ($p.Value -is [switch]) { $p.Value.IsPresent } else { $p.Value }
}
if ($ContainerEnv) { foreach ($k in $ContainerEnv.Keys) { $passThroughEnv[$k] = [string] $ContainerEnv[$k] } }

$ports = [ordered]@{
    DevPort = 7049; ODataPort = 7048; ApiPort = 7052; MgmtPort = 7045; ClientPort = 7085; WebClientPort = 8080; SqlPort = 11433
}
$explicitPorts = @($ports.Keys | Where-Object { $cfg.Contains($_) -and $cfg[$_] })
foreach ($k in @($ports.Keys)) {
    $ports[$k] = if ($k -in $explicitPorts) { [int] $cfg[$k] } else { $ports[$k] + [int] $cfg.PortOffset }
}
# Host ports actually published: all of them, or with -PublishPorts:$false only explicit ones.
$publishedPorts = if ($cfg.PublishPorts) { @($ports.Keys) } else { $explicitPorts }

$n = $cfg.Name
if ($n -cnotmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Invalid -Name '$n' (compose project names: lowercase letters, digits, '_', '-')." }
$stateRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.bcvm'
$stateDir = Join-Path $stateRoot $n

# ---------------------------------------------------------------------------
# Container engine and compose command
# ---------------------------------------------------------------------------
# Shared state for the helper functions. No $script: variables: when the script runs as an
# in-memory script block (README "Run without cloning"), $script: is the CALLER's scope, so
# values set here would be invisible and leak into the user's session. Functions see $ctx
# through normal scope lookup and update it in place (it is a reference type).
$ctx = @{ EngineExe = $null; ComposeExe = $null; ComposePrefix = @(); ComposeFileArgs = @(); Project = $n }

# Plain functions on purpose: everything after the name lands in $args unparsed,
# so flags like -a / --format reach the engine instead of PowerShell's binder.
function Invoke-Engine {
    $out = & $ctx.EngineExe @args 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | ForEach-Object { "$_" }) -join "`n" }
}
function Invoke-Compose {
    $all = @($ctx.ComposePrefix) + @('-p', $ctx.Project) + @($ctx.ComposeFileArgs) + @($args)
    $out = & $ctx.ComposeExe @all 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | ForEach-Object { "$_" }) -join "`n" }
}
function Assert-Ok($Result, [string] $What) {
    if ($Result.ExitCode -ne 0) { throw "$What failed (rc=$($Result.ExitCode)):`n$($Result.Output)" }
    $Result.Output
}

# One CLI, one `info`, one `compose version`. `docker` covers Docker Desktop, Docker Engine,
# Kiri, OrbStack, Colima, ... (whatever the current docker context points at).
$engineName = if ($cfg.Engine -eq 'auto') { 'docker' } else { $cfg.Engine }
# Symlinks are resolved to their final target: uninstalling Docker Desktop leaves dangling links such as
# /usr/local/bin/docker, which Get-Command still returns. Kiri links its CLI into ~/.kiri/bin,
# which its profile lines append to the END of PATH (and only for login/interactive zsh).
function Find-Cli([string] $Name, [string[]] $Extra) {
    @(Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Source) + $Extra |
        Where-Object { $_ -and ([IO.FileInfo]::new($_).ResolveLinkTarget($true) ?? [IO.FileInfo]::new($_)).Exists } |
        Select-Object -First 1
}
$cmd = Find-Cli $engineName $(if ($engineName -eq 'docker') { Join-Path $HOME '.kiri/bin/docker' })
if (-not $cmd -and $cfg.Engine -eq 'auto') { $engineName = 'podman'; $cmd = Find-Cli podman }
if (-not $cmd) { throw 'No container CLI found. Install Docker, Kiri or Podman (or pass -Engine docker|podman).' }
$engineExe = $cmd
$ctx.EngineExe = $engineExe

$r = Invoke-Engine info --format json
if ($r.ExitCode -ne 0) {
    $hint = if ($engineName -eq 'podman') { "Start it with 'podman machine start'." }
    elseif ($env:DOCKER_HOST) { "DOCKER_HOST is set to '$env:DOCKER_HOST'; start that engine or unset DOCKER_HOST." }
    else {
        $current = (Invoke-Engine context show).Output
        $others = ((Invoke-Engine context ls --format '{{.Name}}').Output -split "`n" | Where-Object { $_ -and $_ -ne $current }) -join ', '
        "The docker context is '$current'. Start that engine, or switch: 'docker context use <name>' (available: $others)."
    }
    # docker prints an empty info JSON (and possibly warnings) around the real error.
    $err = (($r.Output -replace '(?s)\{.*\}', '') -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*Warning:' }) -join "`n"
    throw "The container engine is not reachable ($engineExe info failed). $hint`n$err"
}
$engineInfo = $r.Output | ConvertFrom-Json
$isPodman = $null -ne $engineInfo.PSObject.Properties['host']     # podman's info JSON is lower-case nested
$engineArch = if ($isPodman) { $engineInfo.host.arch } else { $engineInfo.Architecture }
# Kiri (runkiri.com) answers http://<service>.<project>.kiri.local on port 80 with ONE container port
# per name. A small router container (below) gives every BC endpoint its own name.
$isKiri = -not $isPodman -and "$($engineInfo.OperatingSystem)" -eq 'Kiri'
$hostNames = [ordered]@{}
if ($isKiri) {
    # .kiri.local needs 'kiri setup --domains' (writes /etc/resolver/kiri.local); .kiri.localhost always works.
    $suffix = if ($IsMacOS -and -not (Test-Path -LiteralPath '/etc/resolver/kiri.local')) { 'kiri.localhost' } else { 'kiri.local' }
    $hostNames.WebClientPort = "bc.$n.$suffix"
    foreach ($e in @{ DevPort = 'dev'; ODataPort = 'odata'; ApiPort = 'api'; ClientPort = 'client' }.GetEnumerator()) {
        $hostNames[$e.Key] = "$($e.Value).$n.$suffix"
    }
}
$engineDesc = if ($isPodman) { "podman $($engineInfo.version.Version)" } else { "$($engineInfo.OperatingSystem) $($engineInfo.ServerVersion)".Trim() }

$r = Invoke-Engine compose version
if ($r.ExitCode -ne 0) {
    throw "'$engineName compose' does not work. Install Docker Compose v2$(if ($isPodman) { " (podman compose uses docker-compose as its provider)" }).`n$($r.Output)"
}
$composeExe = $engineExe; $composePrefix = @('compose')
$ctx.ComposeExe = $composeExe; $ctx.ComposePrefix = $composePrefix

$composeLabel = "label=com.docker.compose.project=$n"
function Get-ServiceContainer([string] $Service) {
    (Invoke-Engine ps -a --filter $composeLabel --filter "label=com.docker.compose.service=$Service" --format '{{.Names}}').Output -split "`n" |
        Where-Object { $_ } | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
function Remove-BcEnvironment {
    Write-Step "Removing environment '$n' (compose down -v)"
    $filesList = Join-Path $stateDir 'compose-files.txt'
    if (Test-Path -LiteralPath $filesList) {
        $ctx.ComposeFileArgs = @(Get-Content -LiteralPath $filesList | Where-Object { $_ } | ForEach-Object { '-f'; $_ }) +
                               @('--env-file', (Join-Path $stateDir 'compose.env'))
        $r = Invoke-Compose down -v --remove-orphans
        if ($r.ExitCode -ne 0) { Write-Warning $r.Output }
    }
    # Fallback / leftovers (e.g. state folder deleted): remove by compose project label.
    $ids = (Invoke-Engine ps -aq --filter $composeLabel).Output -split "`n" | Where-Object { $_ }
    if ($ids) { $null = Invoke-Engine rm -f -v @ids }
    $vols = (Invoke-Engine volume ls -q --filter $composeLabel).Output -split "`n" | Where-Object { $_ }
    if ($vols) { $null = Invoke-Engine volume rm -f @vols }
    $nets = (Invoke-Engine network ls -q --filter $composeLabel).Output -split "`n" | Where-Object { $_ }
    if ($nets) { $null = Invoke-Engine network rm @nets }
    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }
}
if ($Remove) { Remove-BcEnvironment; Write-Step 'Done.'; return }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
function Resolve-HostPath([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    $fromEnvFile = Join-Path $envFileDir $Path
    if ($EnvFile -and (Test-Path -LiteralPath $fromEnvFile)) { return [IO.Path]::GetFullPath($fromEnvFile) }
    [IO.Path]::GetFullPath((Join-Path $PWD.Path $Path))
}

$appFiles = [Collections.Generic.List[string]]::new()
# `pwsh -File` (how bash/zsh/cmd run the script) passes `-Apps 'a.app','b.app'` as ONE string
# "a.app,b.app". Split such an entry on ',' / ';' unless it exists as a path itself.
$appEntries = foreach ($a in @($cfg.Apps)) {
    # .NET Exists, not Test-Path: Test-Path throws PathTooLongException on a long list.
    $p = Resolve-HostPath $a
    if ($a -match '[,;]' -and -not ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p))) {
        $a -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else { $a }
}
foreach ($a in $appEntries) {
    $full = Resolve-HostPath $a
    if (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Filter *.app -File | Sort-Object Name | ForEach-Object { $appFiles.Add($_.FullName) }
    } elseif (Test-Path -LiteralPath $full -PathType Leaf) { $appFiles.Add($full) }
    else { throw "App file or folder not found: $a" }
}
$licensePath = $null
if ($cfg.LicenseFile) {
    $licensePath = Resolve-HostPath $cfg.LicenseFile
    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) { throw "License file not found: $($cfg.LicenseFile)" }
}

# Configuration packages: files, folders (*.rapidstart, ordinal name order: NO-02 < NO-02A < NO-03)
# and 'feature:<Id>' steps. Same one-string splitting as -Apps.
$packageSteps = [Collections.Generic.List[object]]::new()
foreach ($c in @($cfg.ConfigPackages)) {
    $parts = if ($c -match '[,;]' -and -not ([IO.File]::Exists((Resolve-HostPath $c)) -or [IO.Directory]::Exists((Resolve-HostPath $c)))) {
        $c -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @($c) }
    foreach ($e in $parts) {
        if ($e -match '^feature:(\S+)$') { $packageSteps.Add([pscustomobject]@{ Feature = $Matches[1]; Path = $null }); continue }
        $full = Resolve-HostPath $e
        if ([IO.Directory]::Exists($full)) {
            $files = [IO.Directory]::GetFiles($full, '*.rapidstart')
            [Array]::Sort($files, [StringComparer]::OrdinalIgnoreCase)
            foreach ($f in $files) { $packageSteps.Add([pscustomobject]@{ Feature = $null; Path = $f }) }
        } elseif ([IO.File]::Exists($full)) { $packageSteps.Add([pscustomobject]@{ Feature = $null; Path = $full }) }
        else { throw "Configuration package file or folder not found: $e" }
    }
}
if ($packageSteps.Count -and -not $cfg.CompanyName) { throw '-ConfigPackages needs -CompanyName (the company to import into; it is created if missing).' }
# Creating a company needs SQL Full-Text Search ("Text optimized index cannot be created").
if ($null -eq $cfg.FullTextSearch) { $cfg.FullTextSearch = [bool] $cfg.CompanyName }

# Containers OR volumes count: after a plain `compose down` the volumes (database, installed
# apps) are still there, and a new `up` would silently reuse them.
$leftContainers = (Invoke-Engine ps -aq --filter $composeLabel).Output
$leftVolumes = (Invoke-Engine volume ls -q --filter $composeLabel).Output
if ($leftContainers -or $leftVolumes) {
    if ($Recreate) { Remove-BcEnvironment }
    else {
        $what = if ($leftContainers) { 'containers' } else { "volumes only ($(($leftVolumes -split "`n") -join ', '))" }
        throw "Environment '$n' already exists ($what). Use -Recreate to replace it, -Remove to delete it, or another -Name."
    }
}

# Upstream always publishes the web client port, so check it too.
foreach ($p in @($publishedPorts | ForEach-Object { $ports[$_] })) {
    $l = $null
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $p); $l.Start() }
    catch { throw "Host port $p is already in use. Use -PortOffset or the individual -*Port parameters." }
    finally { if ($l) { $l.Stop() } }
}

# 'latest' is resolved here, from the same public artifact index upstream uses for short
# versions (upstream itself only understands prefixes). Released builds only, no insider.
# The full build number goes into compose.env, so later stop/start keeps that exact build.
if (-not $cfg.ArtifactUrl -and (-not $cfg.BcVersion -or $cfg.BcVersion -eq 'latest')) {
    $indexUrl = "https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net/$($cfg.BcType)/indexes/$($cfg.Country.ToLowerInvariant()).json"
    $index = $null
    foreach ($attempt in 1..3) {
        try { $index = Invoke-RestMethod -Uri $indexUrl -TimeoutSec 60; break }
        catch { if ($attempt -eq 3) { throw "Could not resolve the latest BC version from $indexUrl ($($_.Exception.Message)). Pass -BcVersion explicitly, e.g. -BcVersion 28.5." }; Start-Sleep -Seconds 3 }
    }
    $latest = @($index) | Where-Object { $_.Version -match '^\d+(\.\d+){3}$' } |
        Sort-Object { [version] $_.Version } | Select-Object -Last 1
    if (-not $latest) { throw "No BC $($cfg.BcType) versions found for country '$($cfg.Country)' at $indexUrl." }
    $cfg.BcVersion = $latest.Version
    Write-Step "Latest public BC $($cfg.BcType) release for $($cfg.Country): $($cfg.BcVersion)"
}

# The bc-runner image is linux/amd64 only. On ARM hosts (Apple Silicon, ARM Linux/Windows)
# it runs under emulation (Rosetta / qemu).
$hostArch = "$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
$emulated = $hostArch -match 'Arm' -or $engineArch -match 'arm|aarch'
if ($isPodman -and $emulated -and -not $IsLinux -and $engineInfo.host.security.rootless) {
    Write-Warning "The podman machine is rootless; MsDyn365Bc.On.Linux needs 'podman machine set --rootful' and Rosetta (see its MacOS.md)."
}

# SQL Server with Full-Text Search. Upstream's 2022-fts image is built on 2022-latest, which crashes
# under Rosetta (CU18+), so ARM hosts get the FTS package added to CU17, built once from this recipe.
if ($cfg.FullTextSearch -and -not $cfg.SqlImage) {
    if ($emulated) {
        $cfg.SqlImage = 'bclinuxenvironment/mssql:2022-cu17-fts'
        if ((Invoke-Engine image inspect $cfg.SqlImage).ExitCode -ne 0) {
            Write-Step "Building $($cfg.SqlImage): SQL Server 2022 CU17 + Full-Text Search (once, ~2 min)"
            $dockerfile = @'
FROM mcr.microsoft.com/mssql/server:2022-CU17-ubuntu-22.04
# CU17 engine build; the FTS package must match it exactly.
ARG ENGINE=16.0.4175.1
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl gnupg ca-certificates; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg; \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/mssql-server-2022 jammy main" > /etc/apt/sources.list.d/mssql-server-2022.list; \
    apt-get update; \
    VER=$(apt-cache madison mssql-server-fts | awk -v e="$ENGINE" '$3 ~ "^"e"-" {print $3; exit}'); \
    test -n "$VER"; \
    cd /tmp; apt-get download "mssql-server-fts=$VER"; dpkg-deb -x mssql-server-fts_*.deb /; rm -f mssql-server-fts_*.deb; \
    rm -rf /var/lib/apt/lists/*
USER mssql
'@
            $out = $dockerfile.Replace("`r`n", "`n") | & $ctx.EngineExe build --platform linux/amd64 -t $cfg.SqlImage - 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Building $($cfg.SqlImage) failed:`n$(($out | Select-Object -Last 15) -join "`n")" }
        }
    } else {
        $cfg.SqlImage = 'ghcr.io/aldevtools/msdyn365bc.on.linux/mssql:2022-fts'
    }
}

# ---------------------------------------------------------------------------
# Upstream repository (compose files)
# ---------------------------------------------------------------------------
if ($cfg.RepoPath) {
    $repo = Resolve-HostPath $cfg.RepoPath
} else {
    $repo = Join-Path $stateRoot 'MsDyn365Bc.On.Linux'
    if (-not (Test-Path -LiteralPath (Join-Path $repo 'docker-compose.yml'))) {
        Write-Step "Fetching MsDyn365Bc.On.Linux ($($cfg.RepoRef)) into $repo"
        $null = New-Item -ItemType Directory -Force -Path $stateRoot
        if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
            $out = & git clone --quiet --depth 1 --branch $cfg.RepoRef https://github.com/aldevtools/MsDyn365Bc.On.Linux.git $repo 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git clone failed:`n$out" }
        } else {
            $zip = Join-Path ([IO.Path]::GetTempPath()) "bcvm-$([guid]::NewGuid()).zip"
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "bcvm-$([guid]::NewGuid())"
            Invoke-WebRequest -Uri "https://codeload.github.com/aldevtools/MsDyn365Bc.On.Linux/zip/$($cfg.RepoRef)" -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp
            Move-Item -LiteralPath (Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1).FullName -Destination $repo
            Remove-Item -LiteralPath $zip, $tmp -Recurse -Force
        }
    } elseif (Test-Path -LiteralPath (Join-Path $repo '.git')) {
        # Keep the cached clone current; a failure (offline) just keeps the cached copy.
        $null = & git -C $repo pull --quiet --ff-only 2>&1
    }
}
$baseCompose = Join-Path $repo 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $baseCompose)) { throw "docker-compose.yml not found in $repo" }

# ---------------------------------------------------------------------------
# Generated compose env file and override
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $stateDir
$composeEnv = [ordered]@{
    BC_VERSION = $cfg.BcVersion; BC_COUNTRY = $cfg.Country.ToLowerInvariant(); BC_TYPE = $cfg.BcType
    SA_PASSWORD = $cfg.SaPassword; MSSQL_MEMORY_LIMIT_MB = "$($cfg.SqlMemoryMB)"
    BC_SERVER_USERNAME = $cfg.Username; BC_SERVER_PASSWORD = $cfg.Password
    BC_WEBCLIENT = $(if ($cfg.WebClient) { '1' } else { '0' })
    BC_DEV_PORT = $ports.DevPort; BC_ODATA_PORT = $ports.ODataPort; BC_API_PORT = $ports.ApiPort
    BC_MGMT_PORT = $ports.MgmtPort; BC_CLIENT_PORT = $ports.ClientPort; BC_WEBCLIENT_PORT = $ports.WebClientPort
    SQL_PORT = $ports.SqlPort
}
if ($cfg.WebClient) {
    $composeEnv.BC_WEBCLIENT_PUBLIC_URL = if ('WebClientPort' -notin $publishedPorts -and $hostNames.Contains('WebClientPort')) {
        "http://$($hostNames.WebClientPort)/" } else { "http://localhost:$($ports.WebClientPort)/" }
}
if ($cfg.ArtifactUrl) { $composeEnv.BC_ARTIFACT_URL = $cfg.ArtifactUrl }
if ($cfg.BcImage) { $composeEnv.BC_RUNNER_IMAGE = $cfg.BcImage }
if ($cfg.SqlImage) { $composeEnv.BC_SQL_IMAGE = $cfg.SqlImage }
if ($licensePath) {
    $composeEnv.BC_LICENSE_HOST_PATH = $licensePath
    $composeEnv.BC_LICENSE_FILE = '/bc/custom-license.bclicense'
}
$envLines = foreach ($k in $composeEnv.Keys) {
    $v = "$($composeEnv[$k])"
    if ($v.Contains("'")) { throw "Setting $k must not contain a single quote." }
    "$k='$v'"   # single-quoted: compose does not interpolate '$' inside
}
$composeEnvFile = Join-Path $stateDir 'compose.env'
Set-Content -LiteralPath $composeEnvFile -Value $envLines -Encoding utf8NoBOM

# Extra environment for the bc service: pass-through settings plus emulation fixes.
$bcExtraEnv = [ordered]@{}
if ($emulated) {
    # Under Rosetta/qemu the NST crashes with "rosetta error: rt_tgsigqueueinfo failed in
    # pend_signal" (exit 133): .NET suspends threads for GC by injecting signals, which the
    # emulator cannot deliver reliably. Disable activation injection and cap the server-GC
    # heaps (fewer threads to suspend). Overridable via -ContainerEnv / the env file.
    $bcExtraEnv.DOTNET_INTERNAL_ThreadSuspendInjection = '0'
    $bcExtraEnv.DOTNET_GCHeapCount = '2'
}
foreach ($k in $passThroughEnv.Keys) { $bcExtraEnv[$k] = $passThroughEnv[$k] }

function ConvertTo-YamlScalar([string] $Value) {
    # JSON strings are valid YAML; '$' doubled so compose does not interpolate it.
    (ConvertTo-Json -InputObject $Value -Compress).Replace('$', '$$')
}
$yaml = [Collections.Generic.List[string]]::new()
$yaml.Add('# Generated by Invoke-BcLinuxEnvironment.ps1 - layered on top of the upstream compose files.')
$yaml.Add('services:')
$yaml.Add('  bc:')
$yaml.Add('    restart: unless-stopped')
if ($bcExtraEnv.Count) {
    $yaml.Add('    environment:')
    foreach ($k in $bcExtraEnv.Keys) { $yaml.Add("      $($k): $(ConvertTo-YamlScalar $bcExtraEnv[$k])") }
}
$containerPorts = @{ DevPort = 7049; ODataPort = 7048; ApiPort = 7052; MgmtPort = 7045; ClientPort = 7085; WebClientPort = 8080 }
if (-not $cfg.PublishPorts) {
    # Replace upstream's port list with only the explicitly requested ports (Compose >= 2.24).
    $list = @($publishedPorts | Where-Object { $containerPorts.Contains($_) } | ForEach-Object { '"{0}:{1}"' -f $ports[$_], $containerPorts[$_] })
    $yaml.Add("    ports: !override [$($list -join ', ')]")
}
if ($isKiri -and $cfg.WebClient) {
    $yaml.Add('    labels:')
    $yaml.Add('      dev.kiri.http.port: "8080"')     # bc.<Name>.kiri.local -> web client
}
$yaml.Add('  sql:')
$yaml.Add('    restart: unless-stopped')
if (-not $cfg.PublishPorts) {
    $sqlPorts = if ('SqlPort' -in $publishedPorts) { '"{0}:1433"' -f $ports.SqlPort } else { '' }
    $yaml.Add("    ports: !override [$sqlPorts]")
}
if ($cfg.SqlImage) { $yaml.Add("    image: $(ConvertTo-YamlScalar $cfg.SqlImage)") }
if ($cfg.PersistDatabase) {
    # Upstream keeps the database on tmpfs (fast, lost on restart). A volume keeps it, and the
    # entrypoint reuses an existing database on the next start. Root, because a fresh volume
    # is root-owned and the image's mssql user cannot write to it.
    $yaml.Add('    user: "0:0"')
    $yaml.Add('    tmpfs: !reset []')
    $yaml.Add('    volumes:')
    $yaml.Add('      - sql-data:/var/opt/mssql')
}
if ($isKiri) {
    # Router: one nginx answering dev./odata./api./client.<Name>.kiri.local and forwarding to the bc
    # service's ports inside the compose network. Resolves 'bc' per request (Docker DNS), so it
    # starts before bc and survives bc restarts. WebSocket upgrade for client services.
    $routerConf = Join-Path $stateDir 'router.conf'
    $servers = foreach ($k in 'DevPort', 'ODataPort', 'ApiPort', 'ClientPort') {
        "server { listen 80; server_name $($hostNames[$k]); location / { set `$u http://bc:$($containerPorts[$k]); proxy_pass `$u; } }"
    }
    Set-Content -LiteralPath $routerConf -Encoding utf8NoBOM -Value (@(
        '# Generated by Invoke-BcLinuxEnvironment.ps1'
        'map $http_upgrade $conn_upgrade { default upgrade; '''' close; }'
        'proxy_http_version 1.1;'
        'proxy_set_header Host $host;'
        'proxy_set_header Upgrade $http_upgrade;'
        'proxy_set_header Connection $conn_upgrade;'
        'proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 0; proxy_request_buffering off;'
        'resolver 127.0.0.11 valid=10s;'
        'server { listen 80 default_server; return 404; }'
    ) + $servers)
    $yaml.Add('  router:')
    $yaml.Add('    image: docker.io/library/nginx:alpine')
    $yaml.Add('    restart: unless-stopped')
    $yaml.Add('    volumes:')
    $yaml.Add("      - $(ConvertTo-YamlScalar "$($routerConf):/etc/nginx/conf.d/default.conf:ro")")
    $yaml.Add('    labels:')
    $yaml.Add("      dev.kiri.domain: $(ConvertTo-YamlScalar ((('DevPort', 'ODataPort', 'ApiPort', 'ClientPort') | ForEach-Object { $hostNames[$_] }) -join ','))")
    $yaml.Add('      dev.kiri.http.port: "80"')
}
if ($cfg.PersistDatabase) {          # top-level key, after all services
    $yaml.Add('volumes:')
    $yaml.Add('  sql-data:')
}
$overrideFile = Join-Path $stateDir 'compose.override.yml'
Set-Content -LiteralPath $overrideFile -Value $yaml -Encoding utf8NoBOM

$composeFiles = @($baseCompose)
$macOverlay = Join-Path $repo 'docker-compose.macos.yml'
# Upstream's overlay for emulated amd64: SQL 2022-CU17 (later CUs crash under Rosetta),
# SQL as root, tmpfs without uid/gid options.
if ($emulated -and (Test-Path -LiteralPath $macOverlay)) { $composeFiles += $macOverlay }
$composeFiles += $overrideFile
Set-Content -LiteralPath (Join-Path $stateDir 'compose-files.txt') -Value $composeFiles -Encoding utf8NoBOM
$ctx.ComposeFileArgs = @($composeFiles | ForEach-Object { '-f'; $_ }) + @('--env-file', $composeEnvFile)

$sw = [Diagnostics.Stopwatch]::StartNew()
$versionText = if ($cfg.ArtifactUrl) { $cfg.ArtifactUrl } else { "$($cfg.BcType) $($cfg.BcVersion) ($($cfg.Country))" }
Write-Step "Creating BC environment '$n': $versionText on $engineDesc$(if ($emulated) { ' (amd64 emulation)' })"
Write-Note "Compose files: $(($composeFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ' + ')  (state: $stateDir)"
$portText = if ($cfg.PublishPorts) {
    "dev $($ports.DevPort), OData $($ports.ODataPort), API $($ports.ApiPort), mgmt $($ports.MgmtPort), client $($ports.ClientPort), SQL $($ports.SqlPort)$(if ($cfg.WebClient) { ", web $($ports.WebClientPort)" })"
} elseif ($publishedPorts) { "only $(($publishedPorts | ForEach-Object { "$_ $($ports[$_])" }) -join ', ')" } else { 'none published' }
Write-Note "Ports: $portText$(if ($hostNames.Count) { "  (names: *.$n.$suffix)" })"
if (-not $cfg.PublishPorts -and -not $hostNames.Count) {
    Write-Warning "No ports are published and $engineDesc has no container names, so BC is reachable only from inside the compose network ($engineExe exec)."
}
if ($licensePath) { Write-Note "License: $licensePath" }
if ($appFiles.Count) { Write-Note "Extensions: $($appFiles.Count) to publish after startup" }

$null = Assert-Ok (Invoke-Compose config --quiet) 'compose config'

# ---------------------------------------------------------------------------
# Images and start
# ---------------------------------------------------------------------------
Write-Step 'Pulling images (compose pull)'
# A broken credential helper ('credsStore' in ~/.docker/config.json, e.g. 'desktop' left behind
# after uninstalling Docker Desktop, or a locked keychain) fails every pull, even of public images.
$credHint = "The docker credential helper fails. The images are public: fix or remove 'credsStore' in ~/.docker/config.json (a 'desktop' entry left over from Docker Desktop causes this)."
$r = Invoke-Compose pull --ignore-pull-failures
if ($r.ExitCode -ne 0 -or $r.Output -match 'error|denied|failed') {
    $why = if ($r.Output -match 'credential') { " $credHint" } else { '' }
    Write-Warning "Some images could not be pulled; images already present locally are used.$why`n$(($r.Output -split "`n" | Select-String -Pattern 'error|denied|failed' | Select-Object -First 3) -join "`n")"
}

Write-Step 'Starting containers (compose up -d)'
# --no-build: upstream's bc service has a build: section, so a failed pull would otherwise turn
# into a slow local build of the runner image from source (and that build then shadows the
# published image on every later run, because of pull_policy: missing).
$r = Invoke-Compose up -d --no-build
if ($r.ExitCode -ne 0) {
    throw "compose up failed (rc=$($r.ExitCode)).$(if ($r.Output -match 'credential') { " $credHint" })`n$($r.Output)"
}
$bcContainer = Get-ServiceContainer bc
if (-not $bcContainer) { throw 'compose up returned, but no bc container exists.' }

# ---------------------------------------------------------------------------
# Wait for readiness
# ---------------------------------------------------------------------------
$pair = "$($cfg.Username):$($cfg.Password)"
# BC endpoints are queried from INSIDE the bc container (its own localhost), so the script works
# the same whether or not host ports are published.
function Invoke-BcGet([int] $ContainerPort, [string] $Path) {
    $r = Invoke-Engine exec $bcContainer curl -sf --max-time 60 -u $pair "http://localhost:$ContainerPort$Path"
    if ($r.ExitCode -eq 0 -and $r.Output) { try { $r.Output | ConvertFrom-Json } catch { $null } }
}

function Wait-BcReady {
  $deadline = (Get-Date).AddMinutes($cfg.TimeoutMinutes)
  $lastLine = ''
  $resp = $null
  while ($true) {
    $state = (Invoke-Engine inspect -f '{{.State.Status}}' $bcContainer).Output
    if ($state -notin 'running', 'created', 'restarting') {
        $logs = (Invoke-Engine logs --tail 60 $bcContainer).Output
        throw "BC container stopped (state: $state). Last log lines:`n$logs"
    }
    if ((Invoke-Engine exec $bcContainer test -f /tmp/bc-ready).ExitCode -eq 0) {
        $resp = Invoke-BcGet 7048 '/BC/ODataV4/Company'
        if ($resp -and $resp.value) { break }
    }
    $line = ((Invoke-Engine logs --tail 1 $bcContainer).Output -split "`n" | Select-Object -Last 1)
    if ($line -and $line -ne $lastLine -and $line -match '^\[(entrypoint|artifacts)\]') { Write-Note $line; $lastLine = $line }
    if ((Get-Date) -gt $deadline) { throw "Timed out after $($cfg.TimeoutMinutes) min waiting for BC. Check: $engineExe logs $bcContainer" }
    Start-Sleep -Seconds 5
  }
  @($resp.value | ForEach-Object Name)
}
Write-Step "Waiting for the service tier (first boot downloads ~2 GB of artifacts; up to $($cfg.TimeoutMinutes) min)"
$companies = Wait-BcReady
Write-Step "Service tier ready after $([int]$sw.Elapsed.TotalMinutes) min. Companies: $($companies -join ', ')"

# ---------------------------------------------------------------------------
# Background tasks (task scheduler, job queue, configuration package import/apply)
# ---------------------------------------------------------------------------
# Two gaps in the Linux tier stop every background task (see docs/ROADMAP.md):
# 1. TaskRunner P/Invokes QueryPerformanceCounter from 'Kernel32.dll' (capital K). Upstream links only
#    'kernel32.dll' to its Win32 stubs, and Linux file names are case-sensitive -> DllNotFoundException.
#    The link lives in the persistent service volume.
# 2. The bootstrap user carries a Windows Security ID, so the task scheduler refreshes its Windows
#    groups through System.DirectoryServices (kernel32 CompareString, not stubbed). A NavUserPassword
#    user needs no SID; clearing it skips that path. Takes effect when the tier restarts.
$null = Invoke-Engine exec $bcContainer sh -c 'test -f /bc/hook/libwin32_stubs.so && ln -sf /bc/hook/libwin32_stubs.so /bc/service/Kernel32.dll'
$sqlContainer = Get-ServiceContainer sql
$database = if ($passThroughEnv.Contains('BC_DATABASE')) { $passThroughEnv['BC_DATABASE'] } else { 'CRONUS' }
function Invoke-Sql([string] $Query) {
    Invoke-Engine exec $sqlContainer /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $cfg.SaPassword -C -b -h -1 -W -d $database -Q "SET NOCOUNT ON; $Query"
}
$r = Invoke-Sql ("UPDATE [User] SET [Windows Security ID] = '' WHERE [User Name] = N'{0}' AND [Windows Security ID] <> ''; SELECT @@ROWCOUNT" -f $cfg.Username.Replace("'", "''"))
if ($r.ExitCode -ne 0) { Write-Warning "Could not clear the Windows Security ID of $($cfg.Username); background tasks may not run.`n$($r.Output)" }
elseif ("$($r.Output)".Trim() -ne '0' -and ($packageSteps.Count -or $cfg.CompanyName)) {
    # The user is cached by the running tier; restart it so the package import tasks can run now.
    Write-Step 'Restarting the service tier so background tasks can run'
    $null = Assert-Ok (Invoke-Engine restart $bcContainer) 'restarting the bc container'
    $companies = Wait-BcReady
}

# ---------------------------------------------------------------------------
# Extensions
# ---------------------------------------------------------------------------
# Publishing runs INSIDE the bc container (curl to its own localhost:7049, like upstream's
# scripts/publish-app.sh), started detached and polled through a result file. No host connection
# stays open for the whole publish: Kiri's port forwarding drops connections that carry no data
# for 300 s, and a large app (e.g. LS Central) publishes longer than that, so a host-side POST was
# cut off and BC rolled the publish back.
$publishDir = '/tmp/bcvm-publish'
$publishScript = @'
#!/bin/sh
# $1: .app path in this container, $2: curl --max-time. Writes $1.code (HTTP code, 000 = no answer).
code=$(curl -s -o "$1.body" -w '%{http_code}' --max-time "$2" -u "$BCVM_AUTH" -X POST \
  -F "file=@$1;type=application/octet-stream" \
  'http://localhost:7049/BC/dev/apps?SchemaUpdateMode=forcesync')
echo "$code" > "$1.code.tmp" && mv "$1.code.tmp" "$1.code"
'@
function Publish-BcApp([string] $Path) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $fail = { param($m) [pscustomobject]@{ Ok = $false; Retry = $false; Seconds = [int]$t.Elapsed.TotalSeconds; Message = $m } }
    $remote = "$publishDir/$([guid]::NewGuid().ToString('N')).app"
    $r = Invoke-Engine cp $Path "$($bcContainer):$remote"
    if ($r.ExitCode -ne 0) { return & $fail "copying the app into $bcContainer failed: $($r.Output)" }
    $r = Invoke-Engine exec -d -e "BCVM_AUTH=$pair" $bcContainer sh "$publishDir/publish.sh" $remote $cfg.PublishTimeoutSeconds
    if ($r.ExitCode -ne 0) { return & $fail "starting the publish in $bcContainer failed: $($r.Output)" }
    while ($true) {
        Start-Sleep -Seconds 3
        $c = Invoke-Engine exec $bcContainer cat "$remote.code"
        if ($c.ExitCode -eq 0 -and $c.Output.Trim()) { break }
        if ($t.Elapsed.TotalSeconds -gt $cfg.PublishTimeoutSeconds + 60) { return & $fail "no result after $($cfg.PublishTimeoutSeconds)s (-PublishTimeoutSeconds)." }
    }
    $code = [int]$c.Output.Trim()
    $body = (Invoke-Engine exec $bcContainer cat "$remote.body").Output
    $null = Invoke-Engine exec $bcContainer rm -f $remote "$remote.body" "$remote.code"
    # Same benign-422 rule as upstream scripts/publish-app.sh.
    $ok = $code -eq 200 -or ($code -eq 422 -and $body -match 'already (deployed|installed|published|exists)|duplicate package' -and
          $body -notmatch 'publishing failed|could not install the extension|original extensions have been restored')
    $missingDep = $body -match 'dependenc|could not be found|AL1024|symbols'
    $msg = if ($code -eq 0) { "no HTTP answer from the dev endpoint (curl timeout or connection error). $body" } else { "HTTP $code $body" }
    [pscustomobject]@{ Ok = $ok; Retry = (-not $ok -and $missingDep); Seconds = [int]$t.Elapsed.TotalSeconds; Message = $msg.Trim() }
}

$installed = [Collections.Generic.List[string]]::new()
if ($appFiles.Count) {
    Write-Step "Publishing $($appFiles.Count) extension(s)"
    $helper = Join-Path ([IO.Path]::GetTempPath()) "bcvm-publish-$([guid]::NewGuid().ToString('N')).sh"
    Set-Content -LiteralPath $helper -Value ($publishScript -replace "`r`n", "`n") -NoNewline -Encoding utf8NoBOM
    try {
        $null = Assert-Ok (Invoke-Engine exec $bcContainer mkdir -p $publishDir) 'creating the publish folder in the bc container'
        $null = Assert-Ok (Invoke-Engine cp $helper "$($bcContainer):$publishDir/publish.sh") 'copying the publish helper into the bc container'
    } finally { Remove-Item -LiteralPath $helper -ErrorAction SilentlyContinue }
    $pending = [Collections.Generic.List[string]]::new($appFiles)
    while ($pending.Count) {
        $deferred = [Collections.Generic.List[string]]::new()
        $lastError = @{}
        foreach ($app in $pending) {
            $file = Split-Path -Leaf $app
            Write-Note "publishing $file ..."
            $res = Publish-BcApp $app
            if ($res.Ok) { Write-Note "  OK in $($res.Seconds)s"; $installed.Add($file) }
            elseif ($res.Retry) { Write-Note '  deferred (dependency not there yet)'; $deferred.Add($app); $lastError[$app] = $res.Message }
            else { throw "Publishing $file failed after $($res.Seconds)s:`n$($res.Message)" }
        }
        if ($deferred.Count -eq $pending.Count) {
            $detail = ($deferred | ForEach-Object { "$(Split-Path -Leaf $_): $($lastError[$_])" }) -join "`n"
            throw "These extensions could not be installed (unresolved dependencies):`n$detail"
        }
        $pending = $deferred
    }

    # Verify through the automation API that each app is installed.
    try {
        $companyId = (Invoke-BcGet 7052 '/BC/api/v2.0/companies').value[0].id
        # isInstalled is not filterable server-side; filter it here.
        $filter = [Uri]::EscapeDataString("publisher ne 'Microsoft'")
        $exts = Invoke-BcGet 7052 "/BC/api/microsoft/automation/v2.0/companies($companyId)/extensions?`$filter=$filter"
        foreach ($e in $exts.value) {
            $v = "$($e.versionMajor).$($e.versionMinor).$($e.versionBuild).$($e.versionRevision)"
            if ($e.isInstalled) { Write-Note "installed: $($e.publisher) / $($e.displayName) $v" }
            else { Write-Warning "published but NOT installed: $($e.publisher) / $($e.displayName) $v" }
        }
    } catch { Write-Note "(could not list installed extensions: $($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------
# Company and configuration packages
# ---------------------------------------------------------------------------
# Automation API v2.0, called with curl INSIDE the bc container like the publish: creating a company
# takes ~30 s and package steps minutes, longer than some engines' proxies keep a request open.
# Bodies and files are copied in (no JSON on the command line, so no native-argument quoting issues).
$automation = '/BC/api/microsoft/automation/v2.0'
function Copy-ToBc([string] $LocalPath) {
    $remote = "$publishDir/$([guid]::NewGuid().ToString('N'))$([IO.Path]::GetExtension($LocalPath))"
    $null = Assert-Ok (Invoke-Engine cp $LocalPath "$($bcContainer):$remote") "copying $(Split-Path -Leaf $LocalPath) into $bcContainer"
    $remote
}
function Invoke-BcApi([string] $Method, [string] $Path, $Body, [string] $InFile, [int] $TimeoutSec = 600) {
    $curl = @('exec', $bcContainer, 'curl', '-s', '--max-time', "$TimeoutSec", '-u', $pair, '-X', $Method, '-w', '\n%{http_code}')
    $remote = $null; $tmp = $null
    if ($null -ne $Body) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "bcvm-$([guid]::NewGuid().ToString('N')).json"
        Set-Content -LiteralPath $tmp -Value ($Body | ConvertTo-Json -Depth 5 -Compress) -NoNewline -Encoding utf8NoBOM
        $InFile = $tmp; $type = 'application/json'
    } else { $type = 'application/octet-stream' }
    try {
        if ($InFile) { $remote = Copy-ToBc $InFile; $curl += @('-H', "Content-Type: $type", '--data-binary', "@$remote") }
        if ($Method -in 'PATCH', 'DELETE') { $curl += @('-H', 'If-Match: *') }
        $r = Invoke-Engine @curl "http://localhost:7052$Path"
    } finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        if ($remote) { $null = Invoke-Engine exec $bcContainer rm -f $remote }
    }
    $lines = "$($r.Output)" -split "`n"
    $code = [int]($lines[-1] -replace '\D', '0')
    $raw = ($lines | Select-Object -SkipLast 1) -join "`n"
    $json = if ($raw.Trim()) { try { $raw | ConvertFrom-Json } catch { $null } }
    [pscustomobject]@{ Code = $code; Raw = $raw; Json = $json }
}
function Get-RapidStartHeader([string] $Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $xr = [Xml.XmlReader]::Create([IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionMode]::Decompress))
        $null = $xr.MoveToContent()
        [pscustomobject]@{ Code = $xr.GetAttribute('Code'); Name = $xr.GetAttribute('PackageName') }
    } finally { $fs.Dispose() }
}
# BC imports every table with >= MinCountForAsyncImport rows (package header, default 5) in parallel
# sessions that exchange data through NAMED memory-mapped files, which .NET does not support on
# Linux ("Named maps are not supported"). Upload a copy whose header keeps every table synchronous.
function New-SyncImportCopy([string] $Path) {
    $raw = [IO.MemoryStream]::new()
    $in = [IO.File]::OpenRead($Path)
    try { [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress).CopyTo($raw) } finally { $in.Dispose() }
    $raw.Position = 0
    $reader = [IO.StreamReader]::new($raw, [Text.Encoding]::UTF8, $true)    # BOM decides (packages are UTF-16)
    $xml = $reader.ReadToEnd(); $enc = $reader.CurrentEncoding
    $rx = [regex]'MinCountForAsyncImport="\d+"'
    $xml = if ($rx.IsMatch($xml)) { $rx.Replace($xml, 'MinCountForAsyncImport="2147483647"', 1) }
           else { ([regex]'<DataList ').Replace($xml, '<DataList MinCountForAsyncImport="2147483647" ', 1) }
    $out = Join-Path ([IO.Path]::GetTempPath()) "bcvm-$([guid]::NewGuid().ToString('N')).rapidstart"
    $fs = [IO.File]::Create($out)
    try {
        $gz = [IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionLevel]::Optimal)
        $bytes = $enc.GetPreamble() + $enc.GetBytes($xml); $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
    } finally { $fs.Dispose() }
    $out
}
function Wait-PackageStatus([string] $CompanyPath, [string] $Id, [string] $Field) {
    $deadline = (Get-Date).AddSeconds($cfg.PublishTimeoutSeconds)
    while ($true) {
        Start-Sleep -Seconds 5
        $p = (Invoke-BcApi GET "$CompanyPath/configurationPackages($Id)").Json
        if ($p -and $p.$Field -in 'Completed', 'Error') { return $p }
        if ((Get-Date) -gt $deadline) { throw "Configuration package: $Field still '$($p.$Field)' after $($cfg.PublishTimeoutSeconds)s (-PublishTimeoutSeconds)." }
    }
}

$packageSummary = $null
if ($cfg.CompanyName) {
    $null = Invoke-Engine exec $bcContainer mkdir -p $publishDir
    $all = @((Invoke-BcApi GET "$automation/companies").Json.value)
    $company = $all | Where-Object name -eq $cfg.CompanyName
    if (-not $company) {
        Write-Step "Creating company '$($cfg.CompanyName)'"
        $t = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-BcApi POST "$automation/companies($($all[0].id))/automationCompanies" @{ name = $cfg.CompanyName; displayName = $cfg.CompanyName } -TimeoutSec 1800
        if ($r.Code -notin 200, 201) { throw "Creating company '$($cfg.CompanyName)' failed (HTTP $($r.Code)):`n$($r.Raw)" }
        $company = @((Invoke-BcApi GET "$automation/companies").Json.value) | Where-Object name -eq $cfg.CompanyName
        Write-Note "created in $([int]$t.Elapsed.TotalSeconds)s"
    }
    $cu = "$automation/companies($($company.id))"
    if ($packageSteps.Count) { Write-Step "Configuration packages: $($packageSteps.Count) step(s) into '$($cfg.CompanyName)'" }
    $totalErrors = 0
    foreach ($step in $packageSteps) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        if ($step.Feature) {
            $r = Invoke-BcApi POST "$cu/features('$($step.Feature)')/Microsoft.NAV.activate" @{ updateInBackground = $false; startDateTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } -TimeoutSec 3600
            if ($r.Code -notin 200, 204) { throw "Enabling feature '$($step.Feature)' failed (HTTP $($r.Code)):`n$($r.Raw)" }
            Write-Note "feature $($step.Feature): enabled in $([int]$t.Elapsed.TotalSeconds)s"
            continue
        }
        $hdr = Get-RapidStartHeader $step.Path
        $label = "$($hdr.Code) ($(Split-Path -Leaf $step.Path))"
        $filter = [Uri]::EscapeDataString("code eq '$($hdr.Code.Replace("'", "''"))'")
        foreach ($old in @((Invoke-BcApi GET "$cu/configurationPackages?`$filter=$filter").Json.value)) {
            $null = Invoke-BcApi DELETE "$cu/configurationPackages($($old.id))"
        }
        $r = Invoke-BcApi POST "$cu/configurationPackages" @{ code = $hdr.Code; packageName = $hdr.Name }
        if ($r.Code -notin 200, 201) { throw "Creating package $label failed (HTTP $($r.Code)):`n$($r.Raw)" }
        $id = $r.Json.id
        $copy = New-SyncImportCopy $step.Path
        try { $r = Invoke-BcApi PATCH "$cu/configurationPackages($id)/file('$([Uri]::EscapeDataString($hdr.Code))')/content" -InFile $copy -TimeoutSec 1800 }
        finally { Remove-Item -LiteralPath $copy -ErrorAction SilentlyContinue }
        if ($r.Code -notin 200, 204) { throw "Uploading package $label failed (HTTP $($r.Code)):`n$($r.Raw)" }
        $null = Invoke-BcApi POST "$cu/configurationPackages($id)/Microsoft.NAV.import"
        $p = Wait-PackageStatus $cu $id 'importStatus'
        if ($p.importStatus -eq 'Error') { throw "Importing package $label failed: $($p.importError)" }
        $imported = [int]$t.Elapsed.TotalSeconds; $records = $p.numberOfRecords
        $null = Invoke-BcApi POST "$cu/configurationPackages($id)/Microsoft.NAV.apply"
        $p = Wait-PackageStatus $cu $id 'applyStatus'
        if ($p.applyStatus -eq 'Error') { throw "Applying package $label failed: $($p.applyError)" }
        $totalErrors += [int]$p.numberOfErrors
        $msg = "$label`: $($p.numberOfTables) tables, $records records, import $($imported)s, apply $([int]$t.Elapsed.TotalSeconds - $imported)s"
        if ($p.numberOfErrors) { Write-Warning "$msg, $($p.numberOfErrors) record error(s) (see Configuration Packages in BC)" } else { Write-Note "$msg, no errors" }
    }
    $packageSummary = if ($packageSteps.Count) { "$($packageSteps.Count) step(s), $totalErrors record error(s)" } else { $null }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Step "Environment '$n' is ready ($([int]$sw.Elapsed.TotalMinutes) min)"
$fileHint = ($composeFiles | ForEach-Object { '-f "{0}"' -f $_ }) -join ' '
$composeHint = ('{0} {1} -p {2} {3} --env-file "{4}"' -f $composeExe, ($composePrefix -join ' '), $n, $fileHint, $composeEnvFile).Replace('  ', ' ')
# Name first (Kiri), then localhost if that port is published.
function Get-Endpoint([string] $Key, [string] $Path, [string] $Scheme = 'http') {
    $urls = @()
    if ($hostNames.Contains($Key)) { $urls += "$($Scheme)://$($hostNames[$Key])$Path" }
    if ($Key -in $publishedPorts) { $urls += "$($Scheme)://localhost:$($ports[$Key])$Path" }
    if ($urls) { $urls -join '   ' } else { "(not published; -$Key <port> publishes it)" }
}
$summary = [ordered]@{
    Engine     = "$engineDesc (compose project '$n')"
    Version    = $versionText
    WebClient  = $(if ($cfg.WebClient) { Get-Endpoint WebClientPort '/' } else { '(disabled)' })
    Dev        = Get-Endpoint DevPort '/BC/dev'
    OData      = Get-Endpoint ODataPort '/BC/ODataV4'
    Api        = Get-Endpoint ApiPort '/BC/api/v2.0'
    Client     = Get-Endpoint ClientPort '/BC' 'ws'
    Sql        = $(if ('SqlPort' -in $publishedPorts) { "localhost,$($ports.SqlPort) (sa)" } else { '(not published; -SqlPort <port> publishes it)' })
    Username   = $cfg.Username
    Company    = $(if ($cfg.CompanyName) { "$($cfg.CompanyName)$(if ($packageSummary) { "  (packages: $packageSummary)" })" } else { $null })
    Extensions = ($installed -join ', ')
    Compose    = "$composeHint <logs|stop|start|ps>"
    Remove     = "./Invoke-BcLinuxEnvironment.ps1 -Name $n -Remove"
}
if ($hostNames.Count) {
    $summary.Remove('Remove'); $summary.Remove('Compose')
    $summary['AL launch'] = "`"server`": `"http://$($hostNames.DevPort)`", `"port`": 80, `"serverInstance`": `"BC`", `"authentication`": `"UserPassword`""
    $summary['Compose'] = "$composeHint <logs|stop|start|ps>"
    $summary['Remove'] = "./Invoke-BcLinuxEnvironment.ps1 -Name $n -Remove"
}
$summary.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object { Write-Host ('  {0,-11} {1}' -f $_.Key, $_.Value) }
