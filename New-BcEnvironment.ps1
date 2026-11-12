<#
.SYNOPSIS
    Creates a Microsoft Dynamics 365 Business Central environment with Docker or Podman
    Compose, on Windows, Linux and macOS, using MsDyn365Bc.On.Linux.

.DESCRIPTION
    The script follows the supported MsDyn365Bc.On.Linux workflow (docker compose up) and
    adds what that workflow leaves to the user:
      1. Detects the container engine (docker or podman; override with -Engine) and its
         compose command (`docker compose`, `podman compose`, or `docker-compose`).
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
    ./New-BcEnvironment.ps1 -Name bc285 -BcVersion 28.5 -Country w1 -WebClient `
        -LicenseFile ./dev.bclicense -Apps ./apps/a.app, ./apps/b.app

.EXAMPLE
    ./New-BcEnvironment.ps1 -EnvFile ./bc285-lscentral.env

.EXAMPLE
    ./New-BcEnvironment.ps1 -Name bc285 -Remove     # compose down -v: containers and volumes
#>
#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    # Environment name = compose project name (containers <Name>-bc-1, <Name>-sql-1).
    [string] $Name,
    # BC version: short ("28.5") resolves to the newest build, or a full build number.
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

    # Self-host the BC web client (http://localhost:<WebClientPort>).
    [switch] $WebClient,

    # .app files and/or folders, published in the given order. A folder contributes its
    # *.app files sorted by name; apps whose dependencies are not there yet are retried
    # after the others.
    [string[]] $Apps,
    # Optional .bclicense file (e.g. a partner developer license) imported before the service
    # tier starts, instead of the CRONUS demo license. Needed for ISV apps such as LS Central.
    [Alias('BcLicenseHostPath')] [string] $LicenseFile,
    # Additional environment variables for the BC container.
    [hashtable] $ContainerEnv,
    # KEY=VALUE file with settings (see the .DESCRIPTION).
    [string] $EnvFile,

    # Host ports. -PortOffset is added to every default port (7045/7048/7049/7052/7085/8080/11433).
    [int] $PortOffset,
    [int] $DevPort, [int] $ODataPort, [int] $ApiPort, [int] $MgmtPort, [int] $ClientPort,
    [int] $WebClientPort, [int] $SqlPort,

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
    BcVersion             = '28.5'
    Country               = 'w1'
    BcType                = 'sandbox'
    ArtifactUrl           = ''
    Username              = 'BCRUNNER'
    Password              = 'Admin123!'
    SaPassword            = 'Passw0rd123!'
    WebClient             = $false
    Apps                  = @()
    LicenseFile           = ''
    PortOffset            = 0
    Engine                = 'auto'
    RepoPath              = ''
    RepoRef               = 'master'
    BcImage               = ''
    SqlImage              = ''
    SqlMemoryMB           = 3072
    PersistDatabase       = $true
    TimeoutMinutes        = 45
    PublishTimeoutSeconds = 3600
}
# KEY names accepted in the env file / as BCVM_<KEY> environment variables.
$keyMap = @{
    NAME = 'Name'; BC_VERSION = 'BcVersion'; BC_COUNTRY = 'Country'; BC_TYPE = 'BcType'
    BC_ARTIFACT_URL = 'ArtifactUrl'; BC_SERVER_USERNAME = 'Username'; BC_SERVER_PASSWORD = 'Password'
    SA_PASSWORD = 'SaPassword'; BC_WEBCLIENT = 'WebClient'; APPS = 'Apps'
    LICENSE_FILE = 'LicenseFile'; BC_LICENSE_HOST_PATH = 'LicenseFile'
    PORT_OFFSET = 'PortOffset'; BC_DEV_PORT = 'DevPort'; BC_ODATA_PORT = 'ODataPort'; BC_API_PORT = 'ApiPort'
    BC_MGMT_PORT = 'MgmtPort'; BC_CLIENT_PORT = 'ClientPort'; BC_WEBCLIENT_PORT = 'WebClientPort'; SQL_PORT = 'SqlPort'
    ENGINE = 'Engine'; REPO_PATH = 'RepoPath'; REPO_REF = 'RepoRef'
    BC_RUNNER_IMAGE = 'BcImage'; BC_SQL_IMAGE = 'SqlImage'; MSSQL_MEMORY_LIMIT_MB = 'SqlMemoryMB'
    PERSIST_DATABASE = 'PersistDatabase'; TIMEOUT_MINUTES = 'TimeoutMinutes'
    PUBLISH_TIMEOUT_SECONDS = 'PublishTimeoutSeconds'
}
$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
$passThroughEnv = [ordered]@{}

function ConvertTo-Setting([string] $Key, [string] $Value) {
    switch ($Key) {
        { $_ -in 'WebClient', 'PersistDatabase' } { return $Value -match '^(1|true|yes|on)$' }
        'Apps' { return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
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
foreach ($k in @($ports.Keys)) {
    $ports[$k] = if ($cfg.Contains($k) -and $cfg[$k]) { [int] $cfg[$k] } else { $ports[$k] + [int] $cfg.PortOffset }
}

$n = $cfg.Name
if ($n -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Invalid -Name '$n' (compose project names: lowercase letters, digits, '_', '-')." }
$stateRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.bcvm'
$stateDir = Join-Path $stateRoot $n

# ---------------------------------------------------------------------------
# Container engine and compose command
# ---------------------------------------------------------------------------
# Plain functions on purpose: everything after the name lands in $args unparsed,
# so flags like -a / --format reach the engine instead of PowerShell's binder.
function Invoke-Engine {
    $out = & $script:engineExe @args 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | ForEach-Object { "$_" }) -join "`n" }
}
function Invoke-Compose {
    $all = @($script:composePrefix) + @('-p', $script:n) + $script:composeFileArgs + @($args)
    $out = & $script:composeExe @all 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | ForEach-Object { "$_" }) -join "`n" }
}
function Assert-Ok($Result, [string] $What) {
    if ($Result.ExitCode -ne 0) { throw "$What failed (rc=$($Result.ExitCode)):`n$($Result.Output)" }
    $Result.Output
}

$engineExe = $null
$candidates = if ($cfg.Engine -eq 'auto') { @('docker', 'podman') } else { @($cfg.Engine) }
foreach ($c in $candidates) {
    if (-not (Get-Command $c -CommandType Application -ErrorAction SilentlyContinue)) { continue }
    $script:engineExe = $c
    if ((Invoke-Engine info).ExitCode -eq 0) { $engineExe = $c; break }
    Write-Note "$c is installed but its engine is not reachable (start Docker Desktop / 'podman machine start')."
    $script:engineExe = $null
}
if (-not $engineExe) { throw "No running container engine found (tried: $($candidates -join ', '))." }
$script:engineExe = $engineExe
# `docker` may be podman's docker-compatible alias (podman-docker); --version tells them apart.
$isPodman = (Invoke-Engine --version).Output -match 'podman'

$composeExe = $null; $composePrefix = @()
if ((& $engineExe compose version 2>&1 | Out-String) -match 'version' -and $LASTEXITCODE -eq 0) {
    $composeExe = $engineExe; $composePrefix = @('compose')
} elseif (Get-Command docker-compose -CommandType Application -ErrorAction SilentlyContinue) {
    $composeExe = 'docker-compose'
    if ($isPodman -and -not $env:DOCKER_HOST) {
        $sock = (Invoke-Engine info --format '{{.Host.RemoteSocket.Path}}').Output
        if ($sock) { $env:DOCKER_HOST = if ($sock -match '^\w+://') { $sock } else { "unix://$sock" } }
    }
} else {
    throw "No compose command found. Install Docker Compose v2 ('docker compose' / 'docker-compose'); with podman, 'podman compose' needs docker-compose as its provider."
}
$script:composeExe = $composeExe; $script:composePrefix = $composePrefix

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
        $script:composeFileArgs = @(Get-Content -LiteralPath $filesList | Where-Object { $_ } | ForEach-Object { '-f'; $_ }) +
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
foreach ($a in @($cfg.Apps)) {
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

if ((Invoke-Engine ps -aq --filter $composeLabel).Output) {
    if ($Recreate) { Remove-BcEnvironment }
    else { throw "Environment '$n' already exists. Use -Recreate to replace it, -Remove to delete it, or another -Name." }
}

# Upstream always publishes the web client port, so check it too.
foreach ($p in $ports.Values) {
    $l = $null
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $p); $l.Start() }
    catch { throw "Host port $p is already in use. Use -PortOffset or the individual -*Port parameters." }
    finally { if ($l) { $l.Stop() } }
}

# The bc-runner image is linux/amd64 only. On ARM hosts (Apple Silicon, ARM Linux/Windows)
# it runs under emulation (Rosetta / qemu).
$hostArch = "$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
$engineArch = if ($isPodman) { (Invoke-Engine info --format '{{.Host.Arch}}').Output } else { (Invoke-Engine info --format '{{.Architecture}}').Output }
$emulated = $hostArch -match 'Arm' -or $engineArch -match 'arm|aarch'
if ($isPodman -and $emulated -and -not $IsLinux) {
    $rootful = (Invoke-Engine machine inspect --format '{{.Rootful}}').Output
    if ($rootful -match 'false') { Write-Warning "The podman machine is rootless; MsDyn365Bc.On.Linux needs 'podman machine set --rootful' and Rosetta (see its MacOS.md)." }
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
if ($cfg.WebClient) { $composeEnv.BC_WEBCLIENT_PUBLIC_URL = "http://localhost:$($ports.WebClientPort)/" }
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
$yaml.Add('# Generated by New-BcEnvironment.ps1 - layered on top of the upstream compose files.')
$yaml.Add('services:')
$yaml.Add('  bc:')
$yaml.Add('    restart: unless-stopped')
if ($bcExtraEnv.Count) {
    $yaml.Add('    environment:')
    foreach ($k in $bcExtraEnv.Keys) { $yaml.Add("      $($k): $(ConvertTo-YamlScalar $bcExtraEnv[$k])") }
}
$yaml.Add('  sql:')
$yaml.Add('    restart: unless-stopped')
if ($cfg.SqlImage) { $yaml.Add("    image: $(ConvertTo-YamlScalar $cfg.SqlImage)") }
if ($cfg.PersistDatabase) {
    # Upstream keeps the database on tmpfs (fast, lost on restart). A volume keeps it, and the
    # entrypoint reuses an existing database on the next start. Root, because a fresh volume
    # is root-owned and the image's mssql user cannot write to it.
    $yaml.Add('    user: "0:0"')
    $yaml.Add('    tmpfs: !reset []')
    $yaml.Add('    volumes:')
    $yaml.Add('      - sql-data:/var/opt/mssql')
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
$script:composeFileArgs = @($composeFiles | ForEach-Object { '-f'; $_ }) + @('--env-file', $composeEnvFile)

$sw = [Diagnostics.Stopwatch]::StartNew()
$versionText = if ($cfg.ArtifactUrl) { $cfg.ArtifactUrl } else { "$($cfg.BcType) $($cfg.BcVersion) ($($cfg.Country))" }
Write-Step "Creating BC environment '$n': $versionText via $composeExe $($composePrefix -join ' ')$(if ($emulated) { ' (amd64 emulation)' })"
Write-Note "Compose files: $(($composeFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ' + ')  (state: $stateDir)"
Write-Note "Ports: dev $($ports.DevPort), OData $($ports.ODataPort), API $($ports.ApiPort), mgmt $($ports.MgmtPort), client $($ports.ClientPort), SQL $($ports.SqlPort)$(if ($cfg.WebClient) { ", web $($ports.WebClientPort)" })"
if ($licensePath) { Write-Note "License: $licensePath" }
if ($appFiles.Count) { Write-Note "Extensions: $($appFiles.Count) to publish after startup" }

$null = Assert-Ok (Invoke-Compose config --quiet) 'compose config'

# ---------------------------------------------------------------------------
# Images and start
# ---------------------------------------------------------------------------
Write-Step 'Pulling images (compose pull)'
$r = Invoke-Compose pull --ignore-pull-failures
if ($r.ExitCode -ne 0 -or $r.Output -match 'error|denied|failed') {
    Write-Warning "Some images could not be pulled; locally cached images are used where present.`n$(($r.Output -split "`n" | Select-String -Pattern 'error|denied|failed' | Select-Object -First 3) -join "`n")"
}

Write-Step 'Starting containers (compose up -d)'
$null = Assert-Ok (Invoke-Compose up -d) 'compose up'
$bcContainer = Get-ServiceContainer bc
if (-not $bcContainer) { throw 'compose up returned, but no bc container exists.' }

# ---------------------------------------------------------------------------
# Wait for readiness
# ---------------------------------------------------------------------------
$pair = "$($cfg.Username):$($cfg.Password)"
$authHeader = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) }
$odataUrl = "http://localhost:$($ports.ODataPort)/BC/ODataV4/Company"

Write-Step "Waiting for the service tier (first boot downloads ~2 GB of artifacts; up to $($cfg.TimeoutMinutes) min)"
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
        try {
            $resp = Invoke-RestMethod -Uri $odataUrl -Headers $authHeader -TimeoutSec 30
            if ($resp.value) { break }
        } catch { }
    }
    $line = ((Invoke-Engine logs --tail 1 $bcContainer).Output -split "`n" | Select-Object -Last 1)
    if ($line -and $line -ne $lastLine -and $line -match '^\[(entrypoint|artifacts)\]') { Write-Note $line; $lastLine = $line }
    if ((Get-Date) -gt $deadline) { throw "Timed out after $($cfg.TimeoutMinutes) min waiting for BC. Check: $engineExe logs $bcContainer" }
    Start-Sleep -Seconds 5
}
$companies = @($resp.value | ForEach-Object Name)
Write-Step "Service tier ready after $([int]$sw.Elapsed.TotalMinutes) min. Companies: $($companies -join ', ')"

# ---------------------------------------------------------------------------
# Extensions
# ---------------------------------------------------------------------------
function Publish-BcApp([string] $Path) {
    $url = "http://localhost:$($ports.DevPort)/BC/dev/apps?SchemaUpdateMode=forcesync"
    $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -Headers $authHeader -TimeoutSec $cfg.PublishTimeoutSeconds `
            -Form @{ file = Get-Item -LiteralPath $Path } -SkipHttpErrorCheck
    } catch {
        return [pscustomobject]@{ Ok = $false; Retry = $false; Seconds = [int]$t.Elapsed.TotalSeconds; Message = $_.Exception.Message }
    }
    $body = "$($r.Content)"
    # Same benign-422 rule as upstream scripts/publish-app.sh.
    $ok = $r.StatusCode -eq 200 -or ($r.StatusCode -eq 422 -and $body -match 'already (deployed|installed|published|exists)|duplicate package' -and
          $body -notmatch 'publishing failed|could not install the extension|original extensions have been restored')
    $missingDep = $body -match 'dependenc|could not be found|AL1024|symbols'
    [pscustomobject]@{ Ok = $ok; Retry = (-not $ok -and $missingDep); Seconds = [int]$t.Elapsed.TotalSeconds; Message = "HTTP $($r.StatusCode) $body".Trim() }
}

$installed = [Collections.Generic.List[string]]::new()
if ($appFiles.Count) {
    Write-Step "Publishing $($appFiles.Count) extension(s)"
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
        $apiBase = "http://localhost:$($ports.ApiPort)/BC/api"
        $companyId = (Invoke-RestMethod -Headers $authHeader -TimeoutSec 60 -Uri "$apiBase/v2.0/companies").value[0].id
        # isInstalled is not filterable server-side; filter it here.
        $filter = [Uri]::EscapeDataString("publisher ne 'Microsoft'")
        $exts = Invoke-RestMethod -Headers $authHeader -TimeoutSec 60 `
            -Uri "$apiBase/microsoft/automation/v2.0/companies($companyId)/extensions?`$filter=$filter"
        foreach ($e in $exts.value) {
            $v = "$($e.versionMajor).$($e.versionMinor).$($e.versionBuild).$($e.versionRevision)"
            if ($e.isInstalled) { Write-Note "installed: $($e.publisher) / $($e.displayName) $v" }
            else { Write-Warning "published but NOT installed: $($e.publisher) / $($e.displayName) $v" }
        }
    } catch { Write-Note "(could not list installed extensions: $($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Step "Environment '$n' is ready ($([int]$sw.Elapsed.TotalMinutes) min)"
$fileHint = ($composeFiles | ForEach-Object { '-f "{0}"' -f $_ }) -join ' '
$composeHint = ('{0} {1} -p {2} {3} --env-file "{4}"' -f $composeExe, ($composePrefix -join ' '), $n, $fileHint, $composeEnvFile).Replace('  ', ' ')
$summary = [ordered]@{
    Engine     = "$engineExe (compose project '$n')"
    Version    = $versionText
    WebClient  = $(if ($cfg.WebClient) { "http://localhost:$($ports.WebClientPort)/" } else { '(disabled)' })
    Dev        = "http://localhost:$($ports.DevPort)/BC/dev"
    OData      = "http://localhost:$($ports.ODataPort)/BC/ODataV4"
    Api        = "http://localhost:$($ports.ApiPort)/BC/api/v2.0"
    Sql        = "localhost,$($ports.SqlPort) (sa)"
    Username   = $cfg.Username
    Extensions = ($installed -join ', ')
    Compose    = "$composeHint <logs|stop|start|ps>"
    Remove     = "./New-BcEnvironment.ps1 -Name $n -Remove"
}
$summary.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-11} {1}' -f $_.Key, $_.Value) }
