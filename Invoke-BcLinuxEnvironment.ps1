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
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc290 -PortlessRouter   # Kiri: no host ports; http://dev.bc290.kiri.local, ...

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -EnvFile ./example.env

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -Remove     # compose down -v: containers and volumes

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -Snapshot base         # database backup (online, seconds)
    ./Invoke-BcLinuxEnvironment.ps1 -Name test1 -FromSnapshot base     # new environment, restored database
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -RestoreSnapshot base  # reset bc285 to the snapshot

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -Clone gold            # whole environment (stopped while copied)
    ./Invoke-BcLinuxEnvironment.ps1 -Name test2 -FromClone gold        # no download, no patching, same build

.EXAMPLE
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -ListApps
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -UninstallApp 'My App' -InstallApp 'Other App'
    ./Invoke-BcLinuxEnvironment.ps1 -Name bc285 -Update -Apps ./apps/MyApp.app -CompanyName Demo -ConfigPackages ./pkgs
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
    # Kiri only. Publish no host ports (no port planning between environments) and add a small
    # nginx 'router' container, so every BC endpoint gets a name: bc./dev./odata./api./client.
    # <Name>.kiri.local. Kiri routes a name to exactly one container port, hence the router.
    # A port given explicitly (e.g. -SqlPort 11433 for SSMS) is still published.
    [switch] $PortlessRouter,

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

    [Parameter(ParameterSetName = 'Remove', Mandatory)] [switch] $Remove,

    # --- Snapshots and clones (state in ~/.bcvm/snapshots and ~/.bcvm/clones) ---
    # Back up the database of the environment -Name (online, seconds) as snapshot <name>.
    [Parameter(ParameterSetName = 'Snapshot', Mandatory)] [string] $Snapshot,
    # Copy the whole environment -Name (database, downloaded artifacts, patched service tier,
    # compiled cache) into clone <name>. The environment is stopped while copying, then started again.
    [Parameter(ParameterSetName = 'Clone', Mandatory)] [string] $Clone,
    # Create -Name with the database of a snapshot. BC build, country and license come from the snapshot.
    [Parameter(ParameterSetName = 'Create')] [string] $FromSnapshot,
    # Create -Name from a clone: no artifact download, no patching, same build and runner image.
    [Parameter(ParameterSetName = 'Create')] [string] $FromClone,
    # Replace the database of the existing environment -Name with a snapshot of the same BC build.
    [Parameter(ParameterSetName = 'RestoreSnapshot', Mandatory)] [string] $RestoreSnapshot,
    [Parameter(ParameterSetName = 'RemoveSnapshot', Mandatory)] [string] $RemoveSnapshot,
    [Parameter(ParameterSetName = 'RemoveClone', Mandatory)] [string] $RemoveClone,
    # List environments, snapshots and clones.
    [Parameter(ParameterSetName = 'List', Mandatory)] [switch] $List,

    # --- Administering an existing, running environment -Name ---
    # Publish -Apps, create -CompanyName and import -ConfigPackages into it, and refresh its status
    # page and router configuration (admin API) to this script's version.
    [Parameter(ParameterSetName = 'Update', Mandatory)] [switch] $Update,
    # List its extensions (all except Microsoft's global ones).
    [Parameter(ParameterSetName = 'ListApps', Mandatory)] [switch] $ListApps,
    # Extensions by name, app id or package id (as -ListApps shows them). Order: uninstall,
    # unpublish (uninstalls first), install (newest published version).
    [Parameter(ParameterSetName = 'AppAction')] [string[]] $UninstallApp,
    [Parameter(ParameterSetName = 'AppAction')] [string[]] $UnpublishApp,
    [Parameter(ParameterSetName = 'AppAction')] [string[]] $InstallApp,
    # With -UninstallApp/-UnpublishApp: also delete the extension's data.
    [Parameter(ParameterSetName = 'AppAction')] [switch] $DeleteData,
    # JSON output for -List and -ListApps (for agents and scripts).
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Progress status: ~/.bcvm/<Name>/www/status.json, for agents and the status page
# ---------------------------------------------------------------------------
# Written from the moment creation starts (after the 'already exists' check) until the environment
# is ready or the run fails. Every console step/note/warning is mirrored into it. With
# -PortlessRouter, nginx serves it as GET http://<Name>.kiri.local/api/status plus a small page.
$status = $null; $statusFile = $null
function Get-UtcNow { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Save-Status {
    if (-not $status) { return }
    $status.updatedAt = Get-UtcNow
    $tmp = "$statusFile.tmp"
    Set-Content -LiteralPath $tmp -Value ($status | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $statusFile -Force      # atomic replace: readers never see half a file
}
function Add-StatusLog([string] $Level, [string] $Message) {
    if (-not $status) { return }
    $status.log.Add([ordered]@{ time = Get-UtcNow; level = $Level; message = $Message })
    while ($status.log.Count -gt 200) { $status.log.RemoveAt(0) }
    Save-Status
}
function Set-StatusStep([string] $Title) {
    if (-not $status) { return }
    $now = Get-UtcNow
    foreach ($st in $status.steps) { if ($st.status -eq 'running') { $st.status = 'done'; $st.endedAt = $now } }
    $status.steps.Add([ordered]@{ title = $Title; status = 'running'; startedAt = $now; endedAt = $null; detail = $null })
    $status.step = $Title; $status.detail = $null
}
function Set-StatusDetail([string] $Detail) {
    if (-not $status) { return }
    $status.detail = $Detail
    if ($status.steps.Count) { $status.steps[$status.steps.Count - 1].detail = $Detail }
    Save-Status
}
function Write-Step([string] $Message) {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor Cyan
    Set-StatusStep $Message; Add-StatusLog 'step' $Message
}
function Write-Note([string] $Message) { Write-Host "           $Message" -ForegroundColor DarkGray; Add-StatusLog 'info' $Message }
function Write-Warning([string] $Message) { Add-StatusLog 'warning' $Message; Microsoft.PowerShell.Utility\Write-Warning $Message }
# Any terminating error marks the status failed, then propagates unchanged.
trap {
    if ($status -and $status.state -eq 'running') {
        $now = Get-UtcNow
        foreach ($st in $status.steps) { if ($st.status -eq 'running') { $st.status = 'failed'; $st.endedAt = $now } }
        $status.state = 'failed'; $status.error = "$($_.Exception.Message)"; $status.finishedAt = $now
        Add-StatusLog 'error' $status.error
    }
    break
}

# Status page served by the router (-PortlessRouter): plain HTML + JS, no external files.
$statusPageHtml = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BC environment</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --fg:#1d2330; --muted:#667085; --line:#e4e7ec; --btn:#eef1f5;
          --ok:#12805c; --run:#1d64d8; --bad:#c3342b; --warn:#a15c07; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#111418; --card:#1a1f26; --fg:#e6e9ee; --muted:#98a2b3; --line:#2a313b; --btn:#252c36;
            --ok:#3ccb8f; --run:#6ea8fe; --bad:#f2786e; --warn:#f0b35a; } }
  * { box-sizing: border-box; min-width: 0; }
  body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.45 -apple-system,"Segoe UI",Roboto,sans-serif; }
  main { max-width: 960px; margin: 0 auto; padding: 24px 16px 48px; }
  h1 { font-size: 20px; margin: 0 0 4px; overflow-wrap:anywhere; }
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 0 0 10px; }
  .sub { color: var(--muted); margin-bottom: 16px; overflow-wrap:anywhere; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px; margin-bottom:14px; overflow:hidden; }
  .badge { display:inline-block; padding:2px 10px; border-radius:999px; font-weight:600; font-size:12px; color:#fff; }
  .running { background:var(--run); } .ready { background:var(--ok); } .failed { background:var(--bad); }
  .now { font-size:16px; font-weight:600; margin-top:8px; overflow-wrap:anywhere; }
  .detail { color:var(--muted); overflow-wrap:anywhere; word-break:break-word; }
  .err { color:var(--bad); font-weight:600; white-space:pre-wrap; overflow-wrap:anywhere; }
  .steps { display:grid; grid-template-columns: 20px minmax(0,1fr) auto; column-gap:10px; }
  .steps > div { padding:6px 0; border-top:1px solid var(--line); overflow-wrap:anywhere; word-break:break-word; }
  .steps .t { color:var(--muted); white-space:nowrap; text-align:right; }
  .s-done { color:var(--ok); } .s-running { color:var(--run); } .s-failed { color:var(--bad); }
  pre { margin:0; max-height:320px; overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; font:12px/1.5 ui-monospace,Menlo,monospace; }
  .warning { color:var(--warn); } .error { color:var(--bad); } .step { font-weight:600; }
  a { color:var(--run); }
  .links { display:grid; grid-template-columns: 150px minmax(0,1fr) auto; gap:8px 12px; align-items:center; }
  .links .k { color:var(--muted); }
  .links code { font:12.5px/1.4 ui-monospace,Menlo,monospace; overflow-wrap:anywhere; word-break:break-all; white-space:pre-wrap; }
  .links .b { display:flex; gap:6px; }
  button, .open { font:12px -apple-system,"Segoe UI",sans-serif; border:1px solid var(--line); background:var(--btn); color:var(--fg);
                  border-radius:6px; padding:3px 10px; cursor:pointer; text-decoration:none; white-space:nowrap; }
  button:hover, .open:hover { border-color:var(--run); }
  .hint { color:var(--muted); font-size:12px; margin-top:8px; }
  @media (max-width: 640px) { .links { grid-template-columns: minmax(0,1fr) auto; } .links .k { grid-column: 1 / -1; margin-top:6px; } }
  .toolbar { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin-bottom:10px; }
  input[type=text], select { font:13px -apple-system,"Segoe UI",sans-serif; padding:4px 8px; border:1px solid var(--line);
                             border-radius:6px; background:var(--card); color:var(--fg); max-width:100%; }
  input[type=file] { font-size:12px; max-width:100%; }
  button:disabled { opacity:.5; cursor:default; }
  .tw { overflow-x:auto; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th, td { text-align:left; padding:6px 8px; border-top:1px solid var(--line); vertical-align:middle; }
  th { color:var(--muted); font-weight:600; font-size:12px; }
  td.b { white-space:nowrap; text-align:right; }
  td.b button { margin-left:4px; }
  .msg { white-space:pre-wrap; overflow-wrap:anywhere; margin:0 0 10px; min-height:1px; }
  .msg.ok { color:var(--ok); } .msg.bad { color:var(--bad); } .msg.run { color:var(--run); }
</style>
</head>
<body>
<main>
  <h1 id="name">BC environment</h1>
  <div class="sub" id="sub">Loading…</div>
  <div class="card">
    <span class="badge" id="state">…</span> <span id="elapsed" class="detail"></span>
    <div class="now" id="step"></div><div class="detail" id="detail"></div>
    <div class="err" id="error"></div>
  </div>
  <div class="card" id="linksCard" hidden>
    <h2>Services</h2>
    <div class="links" id="links"></div>
    <div class="hint" id="linksHint"></div>
  </div>
  <div class="card admin" id="appsCard" hidden>
    <h2>Extensions</h2>
    <div class="toolbar">
      <input type="file" id="appFile" accept=".app" multiple>
      <button id="publishBtn">Publish and install</button>
      <label class="detail"><input type="checkbox" id="showMs"> Microsoft's global apps</label>
      <button id="appsRefresh">Refresh</button>
    </div>
    <div class="msg" id="appsMsg"></div>
    <div class="tw"><table id="apps"></table></div>
  </div>
  <div class="card admin" id="pkgCard" hidden>
    <h2>Configuration packages</h2>
    <div class="toolbar">
      <span class="detail">Company</span> <select id="company"></select>
      <input type="text" id="newCompany" placeholder="New company name"> <button id="createCompany">Create company</button>
    </div>
    <div class="toolbar">
      <input type="file" id="pkgFile" accept=".rapidstart" multiple>
      <button id="importBtn">Import and apply</button>
      <button id="pkgRefresh">Refresh</button>
    </div>
    <div class="msg" id="pkgMsg"></div>
    <div class="tw"><table id="pkgs"></table></div>
    <div class="hint">Files are imported in the order chosen (sorted by name). Each upload is rewritten so BC imports every table
      synchronously (parallel import does not work on Linux).</div>
  </div>
  <div class="card"><h2>Steps</h2><div class="steps" id="steps"></div></div>
  <div class="card"><h2>Log</h2><pre id="log"></pre></div>
  <div class="sub">JSON for agents: <a href="api/status">api/status</a><span id="apiHint" hidden> · BC APIs without login:
    <a href="BC/api/microsoft/automation/v2.0/companies">BC/api/…</a>, BC/dev/…, BC/ODataV4/…</span></div>
</main>
<script>
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const dur = (a, b) => { if (!a) return ''; const s = Math.max(0, Math.round(((b ? new Date(b) : new Date()) - new Date(a)) / 1000));
  return s >= 3600 ? `${Math.floor(s/3600)}h ${Math.floor(s%3600/60)}m` : s >= 60 ? `${Math.floor(s/60)}m ${s%60}s` : `${s}s`; };
const time = t => t ? new Date(t).toLocaleTimeString() : '';
// Plain http is not a secure context, so navigator.clipboard may be missing: fall back to execCommand.
async function copy(text, btn) {
  let ok = false;
  try { if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); ok = true; } } catch (e) {}
  if (!ok) { const ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select(); try { ok = document.execCommand('copy'); } catch (e) {} ta.remove(); }
  const old = btn.textContent; btn.textContent = ok ? 'Copied' : 'Copy failed'; setTimeout(() => btn.textContent = old, 1200);
}
let last = null, linksKey = '';
function renderLinks(st) {
  const links = st.links || [];
  $('linksCard').hidden = !links.length;
  const key = JSON.stringify(links);
  if (key !== linksKey) {
    linksKey = key;
    $('links').innerHTML = links.map((l, i) => `<div class="k">${esc(l.name)}</div><code>${esc(l.url)}</code><div class="b">` +
      (l.kind === 'http' ? `<a class="open" href="${esc(l.url)}" target="_blank" rel="noopener">Open</a>` : '') +
      `<button data-i="${i}">Copy</button></div>`).join('');
    $('links').querySelectorAll('button').forEach(b => b.onclick = () => copy(links[+b.dataset.i].url, b));
  }
  $('linksHint').textContent = st.state === 'ready' ? '' : (st.state === 'failed' ? 'The environment did not finish; services may not respond.' : 'Services respond once the environment is ready.');
}
function render(st) {
  last = st;
  document.title = `${st.name} – ${st.state}`;
  $('name').textContent = st.name;
  const cfg = st.settings || {};
  $('sub').textContent = [cfg.bcType, cfg.bcVersion, cfg.country, cfg.apps ? `${cfg.apps} app(s)` : '',
    cfg.company ? `company "${cfg.company}"` : '', cfg.configPackages ? `${cfg.configPackages} package step(s)` : ''].filter(Boolean).join(' · ');
  $('state').textContent = st.state; $('state').className = 'badge ' + st.state;
  $('step').textContent = st.state === 'running' ? (st.step || '') : (st.state === 'ready' ? 'Ready' : `Failed during: ${st.step || ''}`);
  $('detail').textContent = st.detail || '';
  $('error').textContent = st.error || '';
  renderLinks(st);
  if (st.state === 'ready' && !admin.on && !admin.trying) initAdmin();
  $('steps').innerHTML = (st.steps || []).map(x => `<div class="s-${x.status}">${x.status === 'running' ? '●' : x.status === 'done' ? '✓' : '✗'}</div>` +
    `<div>${esc(x.title)}${x.detail ? `<div class="detail">${esc(x.detail)}</div>` : ''}</div><div class="t">${dur(x.startedAt, x.endedAt)}</div>`).join('');
  const atBottom = $('log').scrollTop + $('log').clientHeight >= $('log').scrollHeight - 20;
  $('log').innerHTML = (st.log || []).slice(-80).map(l => `<span class="${l.level}">${time(l.time)}  ${esc(l.message)}</span>`).join('\n');
  if (atBottom) $('log').scrollTop = $('log').scrollHeight;
  tick();
}
function tick() { if (last) $('elapsed').textContent = 'elapsed ' + dur(last.startedAt, last.finishedAt); }
async function poll() {
  try {
    const r = await fetch('api/status', { cache: 'no-store' });
    if (r.ok) render(await r.json()); else $('sub').textContent = `Status not available (HTTP ${r.status})`;
  } catch (e) { $('sub').textContent = 'Status not reachable'; }
  setTimeout(poll, last && last.state !== 'running' ? 15000 : 3000);
}

// ---- Administration: BC's automation API and dev endpoint, forwarded by the router with the login ----
const API = 'BC/api/microsoft/automation/v2.0';
const admin = { on: false, trying: false, busy: false, label: '', companies: [], apps: [], pkgs: [] };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const q = s => String(s).replace(/'/g, "''");              // OData string literal
async function bc(method, path, body, headers) {
  const r = await fetch(path, { method, body, headers: headers || {}, cache: 'no-store' });
  const text = await r.text(); let json = null;
  try { json = text ? JSON.parse(text) : null; } catch (e) {}
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(json && json.error && json.error.message) || text.slice(0, 600) || r.statusText}`);
  return json;
}
// Kiri drops requests through a name that get no answer within 30 s; fetch then fails with a TypeError.
// The router lets BC finish them, so long calls fall back to waiting for their outcome.
const isCut = e => e instanceof TypeError;
async function waitFor(check, minutes, failure) {
  const until = Date.now() + minutes * 60000;
  for (;;) {
    if (await check()) return;
    if (Date.now() > until) throw new Error(failure);
    await sleep(5000);
  }
}
async function longPost(path, obj, label, check, minutes, failure) {
  try { return await post(path, obj); }
  catch (e) {
    if (!isCut(e)) throw e;
    progress(`${label} (the connection was closed after 30 s; BC carries on, waiting for the result)`);
    await waitFor(check, minutes, failure);
  }
}
const post = (path, obj) => bc('POST', path, obj === undefined ? undefined : JSON.stringify(obj), obj === undefined ? {} : { 'Content-Type': 'application/json' });
function say(id, text, cls) { const e = $(id); e.textContent = text || ''; e.className = 'msg ' + (cls || ''); }
function progress(text) { admin.label = text; }
// One operation at a time; all admin buttons are disabled meanwhile, the message shows the elapsed time.
async function run(msgId, label, fn) {
  if (admin.busy) return;
  admin.busy = true; admin.label = label;
  document.querySelectorAll('.admin button').forEach(b => b.disabled = true);
  const t0 = new Date().toISOString();
  const show = () => say(msgId, `${admin.label} … ${dur(t0)}`, 'run');
  show(); const timer = setInterval(show, 1000);
  try { const res = await fn(); clearInterval(timer); say(msgId, `${res || label + ': done'} (${dur(t0)})`, 'ok'); }
  catch (e) { clearInterval(timer); say(msgId, `${admin.label} failed after ${dur(t0)}: ${e.message}`, 'bad'); }
  finally { admin.busy = false; document.querySelectorAll('.admin button').forEach(b => b.disabled = false); }
}
async function initAdmin() {
  admin.trying = true;
  try { admin.companies = (await bc('GET', `${API}/companies`)).value; }
  catch (e) { admin.trying = false; return; }       // no admin API (environment created by an older script: run it with -Update)
  admin.on = true; $('appsCard').hidden = false; $('pkgCard').hidden = false; $('apiHint').hidden = false;
  fillCompanies();
  loadApps().catch(e => say('appsMsg', e.message, 'bad'));
  loadPkgs().catch(e => say('pkgMsg', e.message, 'bad'));
}

// Extensions
const ver = e => `${e.versionMajor}.${e.versionMinor}.${e.versionBuild}.${e.versionRevision}`;
const scope = e => String(e.publishedAs || '').trim();
const extUrl = () => `${API}/companies(${admin.companies[0].id})/extensions`;
async function loadApps() {
  const all = (await bc('GET', extUrl())).value;
  const showMs = $('showMs').checked;
  admin.apps = all.filter(e => showMs || e.publisher !== 'Microsoft' || scope(e) !== 'Global')
    .sort((a, b) => (a.publisher + a.displayName).localeCompare(b.publisher + b.displayName));
  $('apps').innerHTML = '<tr><th>Name</th><th>Publisher</th><th>Version</th><th>Scope</th><th>State</th><th></th></tr>' +
    admin.apps.map((e, i) => `<tr><td>${esc(e.displayName)}</td><td>${esc(e.publisher)}</td><td>${ver(e)}</td><td>${esc(scope(e))}</td>` +
      `<td>${e.isInstalled ? '<span class="s-done">installed</span>' : 'published'}</td><td class="b">` +
      (e.isInstalled ? `<button data-a="uninstall" data-i="${i}">Uninstall</button>` : `<button data-a="install" data-i="${i}">Install</button>`) +
      (scope(e) !== 'Global' ? `<button data-a="unpublish" data-i="${i}">Unpublish</button>` : '') + '</td></tr>').join('');
  $('apps').querySelectorAll('button').forEach(b => b.onclick = () => appAction(admin.apps[+b.dataset.i], b.dataset.a));
}
async function waitApp(packageId, done) {
  const until = Date.now() + 60 * 60 * 1000;
  for (;;) {
    const e = (await bc('GET', extUrl())).value.find(x => x.packageId === packageId);
    if (done(e)) return;
    if (Date.now() > until) throw new Error('no result after 60 min');
    await sleep(3000);
  }
}
function appAction(e, action) {
  if (action !== 'install' && !confirm(`${action[0].toUpperCase() + action.slice(1)} ${e.displayName} ${ver(e)}?`)) return;
  const base = `${extUrl()}(${e.packageId})`;
  run('appsMsg', `${action} ${e.displayName}`, async () => {
    const call = async (a, label) => {
      progress(label);
      try { await post(`${base}/Microsoft.NAV.${a}`); }
      catch (err) { if (!isCut(err)) throw err; progress(`${label} (the connection was closed after 30 s; BC carries on, waiting for the result)`); }
    };
    if (action === 'unpublish' && e.isInstalled) {
      await call('uninstall', `Uninstalling ${e.displayName}`); await waitApp(e.packageId, x => !x || !x.isInstalled);
    }
    await call(action, `${action[0].toUpperCase() + action.slice(1)} ${e.displayName}`);
    await waitApp(e.packageId, action === 'install' ? x => x && x.isInstalled : action === 'unpublish' ? x => !x : x => !x || !x.isInstalled);
    await loadApps();
    return `${e.displayName} ${ver(e)}: ${action === 'install' ? 'installed' : action === 'uninstall' ? 'uninstalled' : 'unpublished'}`;
  });
}
$('publishBtn').onclick = () => {
  const files = [...$('appFile').files];
  if (!files.length) return say('appsMsg', 'Choose one or more .app files first.', 'bad');
  run('appsMsg', 'Publishing', async () => {
    const done = [];
    for (const [i, f] of files.entries()) {
      const label = `Publishing ${i + 1}/${files.length}: ${f.name}`;
      progress(label);
      const man = await appManifest(f).catch(() => null);         // null for runtime packages
      const before = new Set((await bc('GET', extUrl())).value.filter(x => x.isInstalled).map(x => x.packageId));
      const fd = new FormData(); fd.append('file', f, f.name);
      let r;
      try { r = await fetch('BC/dev/apps?SchemaUpdateMode=forcesync', { method: 'POST', body: fd }); }
      catch (e) {
        if (!isCut(e)) throw e;
        progress(`${label} (the connection was closed after 30 s; BC carries on, waiting until it is installed)`);
        await waitFor(async () => (await bc('GET', extUrl())).value.some(x => x.isInstalled &&
            (man ? x.id.toLowerCase() === man.id && ver(x) === man.version : !before.has(x.packageId))), 60,
          `${f.name} was not installed within 60 min. BC may have rejected it; publish it with the script (-Update -Apps) to see BC's message.`);
        done.push(f.name); continue;
      }
      const t = await r.text();
      // Same benign-422 rule as upstream's publish-app.sh.
      const benign = r.status === 422 && /already (deployed|installed|published|exists)|duplicate package/i.test(t) &&
                     !/publishing failed|could not install the extension|original extensions have been restored/i.test(t);
      if (!r.ok && !benign) throw new Error(`${f.name}: HTTP ${r.status} ${t.slice(0, 800)}`);
      done.push(f.name);
    }
    $('appFile').value = '';
    await loadApps();
    return `Published and installed: ${done.join(', ')}`;
  });
};
$('appsRefresh').onclick = () => loadApps().then(() => say('appsMsg', ''), e => say('appsMsg', e.message, 'bad'));
$('showMs').onchange = () => loadApps().catch(e => say('appsMsg', e.message, 'bad'));

// Companies and configuration packages
function fillCompanies(select) {
  const keep = select || $('company').value;
  $('company').innerHTML = admin.companies.map(c => `<option value="${c.id}">${esc(c.name)}</option>`).join('');
  if (keep && admin.companies.some(c => c.id === keep)) $('company').value = keep;
}
const pkgUrl = () => `${API}/companies(${$('company').value})/configurationPackages`;
async function loadPkgs() {
  if (!$('company').value) return;
  admin.pkgs = (await bc('GET', pkgUrl())).value.sort((a, b) => a.code.localeCompare(b.code));
  $('pkgs').innerHTML = '<tr><th>Code</th><th>Name</th><th>Tables</th><th>Records</th><th>Errors</th><th>Import</th><th>Apply</th><th></th></tr>' +
    admin.pkgs.map((p, i) => `<tr><td>${esc(p.code)}</td><td>${esc(p.packageName)}</td><td>${p.numberOfTables}</td><td>${p.numberOfRecords}</td>` +
      `<td>${p.numberOfErrors ? `<span class="error">${p.numberOfErrors}</span>` : 0}</td><td>${esc(p.importStatus)}</td><td>${esc(p.applyStatus)}</td>` +
      `<td class="b"><button data-a="apply" data-i="${i}">Apply</button><button data-a="delete" data-i="${i}">Delete</button></td></tr>`).join('') +
    (admin.pkgs.length ? '' : '<tr><td colspan="8" class="detail">No configuration packages in this company.</td></tr>');
  $('pkgs').querySelectorAll('button').forEach(b => b.onclick = () => pkgAction(admin.pkgs[+b.dataset.i], b.dataset.a));
}
async function waitPkg(id, field) {
  const until = Date.now() + 3 * 60 * 60 * 1000;
  for (;;) {
    await sleep(5000);
    const s = await bc('GET', `${pkgUrl()}(${id})`);
    if (s[field] === 'Completed' || s[field] === 'Error') { loadPkgs().catch(() => {}); return s; }
    if (Date.now() > until) throw new Error(`${field} still ${s[field]} after 3 h`);
  }
}
async function applyPkg(id, code) {
  await post(`${pkgUrl()}(${id})/Microsoft.NAV.apply`);
  const s = await waitPkg(id, 'applyStatus');
  if (s.applyStatus === 'Error') throw new Error(`${code}: apply failed: ${s.applyError}`);
  return s;
}
function pkgAction(p, action) {
  if (action === 'delete') {
    if (!confirm(`Delete configuration package ${p.code}? (Data already applied stays.)`)) return;
    return run('pkgMsg', `Deleting ${p.code}`, async () => { await bc('DELETE', `${pkgUrl()}(${p.id})`, undefined, { 'If-Match': '*' }); await loadPkgs(); return `${p.code} deleted`; });
  }
  run('pkgMsg', `Applying ${p.code}`, async () => {
    const s = await applyPkg(p.id, p.code);
    return `${p.code} applied: ${s.numberOfErrors} error(s)`;
  });
}
// .rapidstart = gzip of UTF-16 XML. Read the package code and name from the <DataList> header and set
// MinCountForAsyncImport so BC imports every table synchronously: its parallel import exchanges data
// through named memory-mapped files, which .NET does not support on Linux.
const unxml = s => s.replace(/&(amp|lt|gt|quot|apos);/g, (m, e) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" })[e]);
// Id and version of a .app file, from NavxManifest.xml in the zip that follows the NAVX header.
async function appManifest(file) {
  const b = new Uint8Array(await file.arrayBuffer()), dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let eocd = -1;
  for (let i = b.length - 22; i >= Math.max(0, b.length - 65557); i--) if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) return null;
  const cdSize = dv.getUint32(eocd + 12, true), cdOff = dv.getUint32(eocd + 16, true), base = eocd - cdSize - cdOff;
  for (let p = base + cdOff; p + 46 <= b.length && dv.getUint32(p, true) === 0x02014b50; ) {
    const method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true), nlen = dv.getUint16(p + 28, true),
          elen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true), lho = dv.getUint32(p + 42, true);
    if (new TextDecoder().decode(b.subarray(p + 46, p + 46 + nlen)) === 'NavxManifest.xml') {
      const lh = base + lho, off = lh + 30 + dv.getUint16(lh + 26, true) + dv.getUint16(lh + 28, true);
      let data = b.subarray(off, off + csize);
      if (method === 8) data = new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
      else if (method !== 0) return null;
      const app = /<App\b([^>]*)>/.exec(new TextDecoder().decode(data));
      if (!app) return null;
      const a = k => { const m = new RegExp('\\b' + k + '="([^"]*)"').exec(app[1]); return m ? unxml(m[1]) : ''; };
      return { id: a('Id').toLowerCase(), name: a('Name'), publisher: a('Publisher'), version: a('Version') };
    }
    p += 46 + nlen + elen + clen;
  }
  return null;
}
async function preparePackage(file) {
  const buf = new Uint8Array(await new Response(file.stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
  let enc = 'utf-8', bom = 0;
  if (buf[0] === 0xFF && buf[1] === 0xFE) { enc = 'utf-16le'; bom = 2; }
  else if (buf[0] === 0xFE && buf[1] === 0xFF) { enc = 'utf-16be'; bom = 2; }
  else if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) { bom = 3; }
  let xml = new TextDecoder(enc, { ignoreBOM: true }).decode(buf.subarray(bom));
  const head = /<DataList\b([^>]*)>/.exec(xml);
  if (!head) throw new Error(`${file.name} is not a configuration package (no <DataList> element)`);
  const attr = k => { const m = new RegExp('\\b' + k + '="([^"]*)"').exec(head[1]); return m ? unxml(m[1]) : ''; };
  const code = attr('Code'), name = attr('PackageName');
  if (!code) throw new Error(`${file.name}: the package header has no Code`);
  xml = /MinCountForAsyncImport="\d+"/.test(xml) ? xml.replace(/MinCountForAsyncImport="\d+"/, 'MinCountForAsyncImport="2147483647"')
                                                 : xml.replace('<DataList ', '<DataList MinCountForAsyncImport="2147483647" ');
  let out;
  if (enc !== 'utf-8') {
    const le = enc === 'utf-16le'; out = new Uint8Array(2 + xml.length * 2); const dv = new DataView(out.buffer);
    dv.setUint16(0, 0xFEFF, le); for (let i = 0; i < xml.length; i++) dv.setUint16(2 + i * 2, xml.charCodeAt(i), le);
  } else {
    const b = new TextEncoder().encode(xml); out = new Uint8Array(bom + b.length);
    if (bom) out.set([0xEF, 0xBB, 0xBF]); out.set(b, bom);
  }
  const blob = await new Response(new Blob([out]).stream().pipeThrough(new CompressionStream('gzip'))).blob();
  return { code, name, blob };
}
async function importPackage(file, i, n) {
  const tag = `${i}/${n} ${file.name}`;
  progress(`${tag}: reading`);
  const p = await preparePackage(file);
  for (const o of (await bc('GET', `${pkgUrl()}?$filter=${encodeURIComponent(`code eq '${q(p.code)}'`)}`)).value)
    await bc('DELETE', `${pkgUrl()}(${o.id})`, undefined, { 'If-Match': '*' });
  const pkg = await post(pkgUrl(), { code: p.code, packageName: p.name });
  progress(`${tag}: uploading ${p.code}`);
  await bc('PATCH', `${pkgUrl()}(${pkg.id})/file('${encodeURIComponent(q(p.code))}')/content`, p.blob,
           { 'If-Match': '*', 'Content-Type': 'application/octet-stream' });
  await loadPkgs();
  progress(`${tag}: importing ${p.code}`);
  await post(`${pkgUrl()}(${pkg.id})/Microsoft.NAV.import`);
  const s = await waitPkg(pkg.id, 'importStatus');
  if (s.importStatus === 'Error') throw new Error(`${p.code}: import failed: ${s.importError}`);
  progress(`${tag}: applying ${p.code} (${s.numberOfTables} tables, ${s.numberOfRecords} records)`);
  const a = await applyPkg(pkg.id, p.code);
  return `${p.code}: ${a.numberOfTables} tables, ${a.numberOfRecords} records, ${a.numberOfErrors} error(s)`;
}
$('importBtn').onclick = () => {
  const files = [...$('pkgFile').files].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
  if (!files.length) return say('pkgMsg', 'Choose one or more .rapidstart files first.', 'bad');
  if (!$('company').value) return say('pkgMsg', 'Create or choose a company first.', 'bad');
  run('pkgMsg', 'Importing', async () => {
    const results = [];
    for (const [i, f] of files.entries()) results.push(await importPackage(f, i + 1, files.length));
    $('pkgFile').value = '';
    return results.join('\n');
  });
};
$('createCompany').onclick = () => {
  const name = $('newCompany').value.trim();
  if (!name) return say('pkgMsg', 'Type the new company name first.', 'bad');
  run('pkgMsg', `Creating company ${name}`, async () => {
    await longPost(`${API}/companies(${admin.companies[0].id})/automationCompanies`, { name, displayName: name }, `Creating company ${name}`,
      async () => (await bc('GET', `${API}/companies`)).value.some(c => c.name === name), 30,
      `Company ${name} did not appear within 30 min. Creating a company needs SQL Full-Text Search (-FullTextSearch).`);
    admin.companies = (await bc('GET', `${API}/companies`)).value;
    const c = admin.companies.find(x => x.name === name);
    fillCompanies(c && c.id); $('newCompany').value = '';
    await loadPkgs();
    return `Company ${name} created`;
  });
};
$('company').onchange = () => loadPkgs().catch(e => say('pkgMsg', e.message, 'bad'));
$('pkgRefresh').onclick = () => loadPkgs().then(() => say('pkgMsg', ''), e => say('pkgMsg', e.message, 'bad'));
setInterval(tick, 1000); poll();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# Settings resolution: defaults < env file < BCVM_* env vars < parameters
# ---------------------------------------------------------------------------
# A switch written as -WebClient:$false in zsh/bash without quotes reaches pwsh as '-WebClient:'
# ($false expanded to nothing), which PowerShell silently ignores, keeping the default. Refuse it.
$emptySwitch = @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-[A-Za-z]+:$' })
if ($emptySwitch) {
    throw "$($emptySwitch[0]) has no value: the shell expanded `$false to nothing. Write it as $($emptySwitch[0])false (or quote '$($emptySwitch[0])`$false')."
}

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
    PortlessRouter        = $false
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
    FromSnapshot          = ''
    FromClone             = ''
}
# KEY names accepted in the env file / as BCVM_<KEY> environment variables.
$keyMap = @{
    NAME = 'Name'; BC_VERSION = 'BcVersion'; BC_COUNTRY = 'Country'; BC_TYPE = 'BcType'
    BC_ARTIFACT_URL = 'ArtifactUrl'; BC_SERVER_USERNAME = 'Username'; BC_SERVER_PASSWORD = 'Password'
    SA_PASSWORD = 'SaPassword'; BC_WEBCLIENT = 'WebClient'; APPS = 'Apps'
    LICENSE_FILE = 'LicenseFile'; BC_LICENSE_HOST_PATH = 'LicenseFile'
    PORTLESS_ROUTER = 'PortlessRouter'; PORT_OFFSET = 'PortOffset'; BC_DEV_PORT = 'DevPort'; BC_ODATA_PORT = 'ODataPort'; BC_API_PORT = 'ApiPort'
    BC_MGMT_PORT = 'MgmtPort'; BC_CLIENT_PORT = 'ClientPort'; BC_WEBCLIENT_PORT = 'WebClientPort'; SQL_PORT = 'SqlPort'
    ENGINE = 'Engine'; REPO_PATH = 'RepoPath'; REPO_REF = 'RepoRef'
    BC_RUNNER_IMAGE = 'BcImage'; BC_SQL_IMAGE = 'SqlImage'; MSSQL_MEMORY_LIMIT_MB = 'SqlMemoryMB'
    PERSIST_DATABASE = 'PersistDatabase'; TIMEOUT_MINUTES = 'TimeoutMinutes'
    PUBLISH_TIMEOUT_SECONDS = 'PublishTimeoutSeconds'
    COMPANY_NAME = 'CompanyName'; CONFIG_PACKAGES = 'ConfigPackages'; FULL_TEXT_SEARCH = 'FullTextSearch'
    FROM_SNAPSHOT = 'FromSnapshot'; FROM_CLONE = 'FromClone'
}
$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
$passThroughEnv = [ordered]@{}
# Settings given explicitly (env file, BCVM_* variable or parameter), as opposed to defaults.
$explicitKeys = [Collections.Generic.HashSet[string]]::new()

function ConvertTo-Setting([string] $Key, [string] $Value) {
    switch ($Key) {
        { $_ -in 'WebClient', 'PersistDatabase', 'PortlessRouter', 'FullTextSearch' } { return $Value -match '^(1|true|yes|on)$' }
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
        if ($keyMap.ContainsKey($key)) { $cfg[$keyMap[$key]] = ConvertTo-Setting $keyMap[$key] $val; $null = $explicitKeys.Add($keyMap[$key]) }
        else { $passThroughEnv[$Matches[1]] = $val }
    }
}
foreach ($key in $keyMap.Keys) {
    $val = [Environment]::GetEnvironmentVariable("BCVM_$key")
    if ($null -ne $val -and $val -ne '') { $cfg[$keyMap[$key]] = ConvertTo-Setting $keyMap[$key] $val; $null = $explicitKeys.Add($keyMap[$key]) }
}
foreach ($p in $PSBoundParameters.GetEnumerator()) {
    if ($p.Key -in 'EnvFile', 'ContainerEnv', 'Recreate', 'Remove', 'Verbose', 'Debug', 'Snapshot', 'Clone', 'RestoreSnapshot',
        'RemoveSnapshot', 'RemoveClone', 'List', 'Update', 'ListApps', 'UninstallApp', 'UnpublishApp', 'InstallApp', 'DeleteData', 'AsJson') { continue }
    $cfg[$p.Key] = if ($p.Value -is [switch]) { $p.Value.IsPresent } else { $p.Value }
    $null = $explicitKeys.Add($p.Key)
}
if ($ContainerEnv) { foreach ($k in $ContainerEnv.Keys) { $passThroughEnv[$k] = [string] $ContainerEnv[$k] } }

$n = $cfg.Name
if ($n -cnotmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Invalid -Name '$n' (compose project names: lowercase letters, digits, '_', '-')." }
$stateRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.bcvm'
$stateDir = Join-Path $stateRoot $n
$snapshotRoot = Join-Path $stateRoot 'snapshots'
$cloneRoot = Join-Path $stateRoot 'clones'
$mode = $PSCmdlet.ParameterSetName
# Modes that work on an environment created earlier by this script.
$existingModes = 'Snapshot', 'Clone', 'RestoreSnapshot', 'Update', 'ListApps', 'AppAction'

function Read-ComposeEnv([string] $Dir) {
    $h = [ordered]@{}
    $f = Join-Path $Dir 'compose.env'
    if (Test-Path -LiteralPath $f) {
        foreach ($l in Get-Content -LiteralPath $f) { if ($l -match "^([A-Za-z_][A-Za-z0-9_]*)='(.*)'$") { $h[$Matches[1]] = $Matches[2] } }
    }
    $h
}

# An existing environment keeps the settings it was created with (generated compose.env/override);
# explicit parameters still win (e.g. -Password after changing it in BC).
$sqlPortPublished = $false
if ($mode -in $existingModes) {
    $envState = Read-ComposeEnv $stateDir
    if (-not $envState.Count) { throw "Environment '$n' not found ($stateDir has no compose.env). Check -Name; -List shows the environments." }
    $fromState = [ordered]@{ BC_VERSION = 'BcVersion'; BC_COUNTRY = 'Country'; BC_TYPE = 'BcType'; BC_ARTIFACT_URL = 'ArtifactUrl'
        BC_SERVER_USERNAME = 'Username'; BC_SERVER_PASSWORD = 'Password'; SA_PASSWORD = 'SaPassword'; BC_RUNNER_IMAGE = 'BcImage'
        BC_SQL_IMAGE = 'SqlImage'; BC_LICENSE_HOST_PATH = 'LicenseFile' }
    foreach ($e in $fromState.GetEnumerator()) {
        if ($envState.Contains($e.Key) -and -not $PSBoundParameters.ContainsKey($e.Value)) { $cfg[$e.Value] = $envState[$e.Key] }
    }
    $cfg.WebClient = $envState['BC_WEBCLIENT'] -eq '1'
    $ovr = Join-Path $stateDir 'compose.override.yml'
    $ovrText = if (Test-Path -LiteralPath $ovr) { Get-Content -Raw -LiteralPath $ovr } else { '' }
    $cfg.PortlessRouter = $ovrText -match '(?m)^  router:'
    $cfg.PersistDatabase = $ovrText -match '(?m)^\s+- sql-data:'
    $sqlPortPublished = $ovrText -match '"\d+:1433"'
    if ($ovrText -match '(?m)^\s+BC_DATABASE:\s*"([^"]+)"' -and -not $passThroughEnv.Contains('BC_DATABASE')) { $passThroughEnv['BC_DATABASE'] = $Matches[1] }
    foreach ($e in @{ BC_DEV_PORT = 'DevPort'; BC_ODATA_PORT = 'ODataPort'; BC_API_PORT = 'ApiPort'; BC_MGMT_PORT = 'MgmtPort'
                      BC_CLIENT_PORT = 'ClientPort'; BC_WEBCLIENT_PORT = 'WebClientPort'; SQL_PORT = 'SqlPort' }.GetEnumerator()) {
        if ($envState.Contains($e.Key) -and -not $PSBoundParameters.ContainsKey($e.Value)) { $cfg[$e.Value] = [int] $envState[$e.Key] }
    }
}

# -FromSnapshot / -FromClone: the new environment must run the build its database (and, for a clone,
# its artifact and service volumes) belongs to. Those settings come from the snapshot/clone; an
# explicit different value is an error rather than a silently broken environment.
$fromInfo = $null; $fromDir = $null
if ($mode -eq 'Create' -and ($cfg.FromSnapshot -or $cfg.FromClone)) {
    if ($cfg.FromSnapshot -and $cfg.FromClone) { throw 'Use -FromSnapshot or -FromClone, not both.' }
    $fromKind = if ($cfg.FromSnapshot) { 'snapshot' } else { 'clone' }
    $fromName = if ($cfg.FromSnapshot) { $cfg.FromSnapshot } else { $cfg.FromClone }
    $fromDir = Join-Path $(if ($cfg.FromSnapshot) { $snapshotRoot } else { $cloneRoot }) $fromName
    $metaFile = Join-Path $fromDir "$fromKind.json"
    if (-not (Test-Path -LiteralPath $metaFile)) { throw "No $fromKind '$fromName' ($metaFile not found). -List shows the snapshots and clones." }
    $fromInfo = Get-Content -Raw -LiteralPath $metaFile | ConvertFrom-Json
    $fs = $fromInfo.settings
    $pins = [ordered]@{ BcVersion = $fs.bcVersion; Country = $fs.country; BcType = $fs.bcType; ArtifactUrl = $fs.artifactUrl }
    foreach ($pin in $pins.GetEnumerator()) {
        $want = "$($pin.Value)"; $have = "$($cfg[$pin.Key])"
        if ($explicitKeys.Contains($pin.Key) -and $have -ne $want -and -not ($pin.Key -eq 'BcVersion' -and $want.StartsWith("$have."))) {
            throw "-$($pin.Key) '$have' does not match $fromKind '$fromName' ($(if ($want) { $want } else { 'not set' })): its database belongs to that build. Leave -$($pin.Key) out."
        }
        $cfg[$pin.Key] = $want
    }
    if ($fs.username -and -not $explicitKeys.Contains('Username')) { $cfg.Username = $fs.username }
    if ($fs.password -and -not $explicitKeys.Contains('Password')) { $cfg.Password = $fs.password }
    if ($fs.licenseFile -and -not $explicitKeys.Contains('LicenseFile')) {
        if ([IO.File]::Exists($fs.licenseFile)) { $cfg.LicenseFile = $fs.licenseFile }
        else { Write-Warning "The $fromKind was made with license $($fs.licenseFile), which no longer exists; BC imports the demo license instead (pass -LicenseFile)." }
    }
    if ($fs.fullTextSearch -and -not $explicitKeys.Contains('FullTextSearch')) { $cfg.FullTextSearch = $true }
    if ($fs.database -and $fs.database -ne 'CRONUS' -and -not $passThroughEnv.Contains('BC_DATABASE')) { $passThroughEnv['BC_DATABASE'] = $fs.database }
    if ($fromKind -eq 'clone') {
        # The copied master database keeps the source's sa password; the stamps in the copied volumes
        # expect the same runner image (else the tier is patched again) and the same SQL image.
        if ($explicitKeys.Contains('SaPassword') -and $cfg.SaPassword -ne $fs.saPassword) { throw "-SaPassword must be the clone's sa password (the copied SQL Server keeps it). Leave it out." }
        if ($explicitKeys.Contains('PersistDatabase') -and -not $cfg.PersistDatabase) { throw '-FromClone needs the database volume; leave out -PersistDatabase:$false.' }
        $cfg.SaPassword = $fs.saPassword
        if (-not $explicitKeys.Contains('BcImage')) { $cfg.BcImage = $fromInfo.bcImage }
        if ($fs.sqlImage -and -not $explicitKeys.Contains('SqlImage')) { $cfg.SqlImage = $fs.sqlImage }
    }
}

$ports = [ordered]@{
    DevPort = 7049; ODataPort = 7048; ApiPort = 7052; MgmtPort = 7045; ClientPort = 7085; WebClientPort = 8080; SqlPort = 11433
}
$explicitPorts = @($ports.Keys | Where-Object { $cfg.Contains($_) -and $cfg[$_] })
foreach ($k in @($ports.Keys)) {
    $ports[$k] = if ($k -in $explicitPorts) { [int] $cfg[$k] } else { $ports[$k] + [int] $cfg.PortOffset }
}
# Host ports actually published: all of them, or with -PortlessRouter only explicit ones.
$publishedPorts = if ($cfg.PortlessRouter) { $explicitPorts } else { @($ports.Keys) }
if ($mode -in $existingModes -and $cfg.PortlessRouter) { $publishedPorts = @(if ($sqlPortPublished) { 'SqlPort' }) }


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
    if ($cfg.WebClient) { $hostNames.WebClientPort = "bc.$n.$suffix" }
    if ($cfg.PortlessRouter) {
        foreach ($e in @{ DevPort = 'dev'; ODataPort = 'odata'; ApiPort = 'api'; ClientPort = 'client' }.GetEnumerator()) {
            $hostNames[$e.Key] = "$($e.Value).$n.$suffix"
        }
        $hostNames.Status = "$n.$suffix"      # status page + GET /api/status, served by the router
    }
} elseif ($cfg.PortlessRouter) {
    throw "-PortlessRouter needs Kiri (container names under *.kiri.local); this engine ($(if ($isPodman) { podman } else { $engineInfo.OperatingSystem })) has none. Without it, use -PortOffset to run environments side by side."
}
$engineDesc = if ($isPodman) { "podman $($engineInfo.version.Version)" }
              elseif ($isKiri) { "Kiri (Docker API $($engineInfo.ServerVersion))" }
              else { "$($engineInfo.OperatingSystem) $($engineInfo.ServerVersion)".Trim() }

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
# Helpers for a running environment: readiness, SQL, BC APIs, publishing, volumes
# ---------------------------------------------------------------------------
# They use $bcContainer / $sqlContainer, set before the first call (create: after compose up;
# other modes: from the existing containers).
$bcContainer = $null; $sqlContainer = $null
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
    if ($line -and $line -ne $lastLine -and $line -match '^\[(entrypoint|artifacts)\]') { Write-Note $line; Set-StatusDetail $line; $lastLine = $line }
    if ((Get-Date) -gt $deadline) { throw "Timed out after $($cfg.TimeoutMinutes) min waiting for BC. Check: $engineExe logs $bcContainer" }
    Start-Sleep -Seconds 5
  }
  @($resp.value | ForEach-Object Name)
}

$database = if ($passThroughEnv.Contains('BC_DATABASE')) { $passThroughEnv['BC_DATABASE'] } else { 'CRONUS' }
function Invoke-Sql([string] $Query, [string] $Database = $database) {
    Invoke-Engine exec $sqlContainer /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $cfg.SaPassword -C -b -h -1 -W -d $Database -Q "SET NOCOUNT ON; $Query"
}
# Login user without Windows Security ID (see "Background tasks" below). Returns the number of rows changed.
function Clear-UserSid {
    $r = Invoke-Sql ("UPDATE [User] SET [Windows Security ID] = '' WHERE [User Name] = N'{0}' AND [Windows Security ID] <> ''; SELECT @@ROWCOUNT" -f $cfg.Username.Replace("'", "''"))
    if ($r.ExitCode -ne 0) { Write-Warning "Could not clear the Windows Security ID of $($cfg.Username); background tasks may not run.`n$($r.Output)"; return 0 }
    [int] "$($r.Output)".Trim()
}
function Wait-SqlReady([int] $Seconds = 300) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Invoke-Sql 'SELECT 1' -Database master).ExitCode -ne 0) {
        if ((Get-Date) -gt $deadline) { throw "SQL Server in $sqlContainer did not answer within $Seconds s." }
        Start-Sleep -Seconds 3
    }
}
function ConvertTo-SqlName([string] $Value) { $Value.Replace(']', ']]') }
function ConvertTo-SqlText([string] $Value) { $Value.Replace("'", "''") }
# Online, consistent backup (COPY_ONLY: does not disturb any backup chain), copied to the host.
function Backup-BcDatabase([string] $Target) {
    $remote = '/var/opt/mssql/bcvm-snapshot.bak'
    try {
        $null = Assert-Ok (Invoke-Sql "BACKUP DATABASE [$(ConvertTo-SqlName $database)] TO DISK = N'$remote' WITH COPY_ONLY, COMPRESSION, CHECKSUM, INIT" -Database master) "backing up database $database"
        $null = Assert-Ok (Invoke-Engine cp "$($sqlContainer):$remote" $Target) 'copying the backup out of the sql container'
    } finally { $null = Invoke-Engine exec $sqlContainer rm -f $remote }
}
# Restores a backup as $database (replacing it). The service tier must not be running.
function Restore-BcDatabase([string] $BackupFile) {
    $remote = '/var/opt/mssql/bcvm-restore.bak'
    $null = Assert-Ok (Invoke-Engine cp $BackupFile "$($sqlContainer):$remote") 'copying the backup into the sql container'
    try {
        $r = Invoke-Engine exec $sqlContainer /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $cfg.SaPassword -C -b -h -1 -W -s '|' -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'$remote'"
        $files = @((Assert-Ok $r 'reading the backup file list') -split "`n" | Where-Object { $_ -match '\|' } | ForEach-Object {
            $c = $_ -split '\|'; [pscustomobject]@{ Logical = $c[0].Trim(); Type = $c[2].Trim() } })
        $data = $files | Where-Object Type -eq 'D' | Select-Object -First 1
        $log = $files | Where-Object Type -eq 'L' | Select-Object -First 1
        if (-not $data -or -not $log) { throw "Unexpected file list in the backup:`n$($r.Output)" }
        $db = ConvertTo-SqlName $database; $dbText = ConvertTo-SqlText $database
        $null = Assert-Ok (Invoke-Sql -Database master ("IF DB_ID(N'$dbText') IS NOT NULL ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; " +
            "RESTORE DATABASE [$db] FROM DISK = N'$remote' WITH REPLACE, " +
            "MOVE N'$(ConvertTo-SqlText $data.Logical)' TO N'/var/opt/mssql/data/$dbText.mdf', MOVE N'$(ConvertTo-SqlText $log.Logical)' TO N'/var/opt/mssql/data/$($dbText)_log.ldf'; " +
            "ALTER DATABASE [$db] SET MULTI_USER;")) "restoring database $database"
    } finally { $null = Invoke-Engine exec $sqlContainer rm -f $remote }
    $null = Clear-UserSid      # before the tier starts, so no restart is needed for background tasks
}
# Exact BC build of the downloaded artifacts (the entrypoint's cache stamp). Works on a stopped container.
function Get-ArtifactBuild {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "bcvm-$([guid]::NewGuid().ToString('N')).stamp"
    try {
        if ((Invoke-Engine cp "$($bcContainer):/bc/artifacts/.bc-artifact-cache" $tmp).ExitCode -ne 0) { return $null }
        if ((Get-Content -Raw -LiteralPath $tmp) -match '/(sandbox|onprem)/(\d+(?:\.\d+){3})/([A-Za-z0-9]+)') {
            [pscustomobject]@{ BcType = $Matches[1]; Version = $Matches[2]; Country = $Matches[3].ToLowerInvariant() }
        }
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
# Compose-labelled volumes of a project, or clone volumes ('<label>=<value>'), with their short names.
function Get-LabelledVolumes([string] $Filter, [string] $KeyLabel) {
    @((Invoke-Engine volume ls --filter "label=$Filter" --format "{{.Name}}|{{.Label `"$KeyLabel`"}}").Output -split "`n" | Where-Object { $_ -match '\|' } |
        ForEach-Object { $c = $_ -split '\|', 2; [pscustomobject]@{ Name = $c[0]; Key = $c[1] } })
}
# Copies a volume inside the engine (no round trip through the host). Returns the copied size in bytes.
function Copy-Volume([string] $From, [string] $To, [string] $Image) {
    $r = Invoke-Engine run --rm -u 0 --entrypoint sh -v "$($From):/from:ro" -v "$($To):/to" $Image -c 'cp -a /from/. /to/ && du -sk /to | cut -f1'
    [long] ((Assert-Ok $r "copying volume $From to $To") -split "`n" | Select-Object -Last 1) * 1024
}

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

# Extensions as seen by the automation API (any company; the list is per tenant).
function Get-BcExtensionList {
    $cid = @((Invoke-BcApi GET "$automation/companies").Json.value)[0].id
    if (-not $cid) { throw 'The automation API returned no company (is the environment ready?).' }
    $r = Invoke-BcApi GET "$automation/companies($cid)/extensions"
    if ($r.Code -ne 200) { throw "Listing extensions failed (HTTP $($r.Code)):`n$($r.Raw)" }
    [pscustomobject]@{
        CompanyId = $cid
        Items = @(@($r.Json.value) | ForEach-Object {
            [pscustomobject][ordered]@{
                name = $_.displayName; publisher = $_.publisher
                version = "$($_.versionMajor).$($_.versionMinor).$($_.versionBuild).$($_.versionRevision)"
                scope = "$($_.publishedAs)".Trim(); installed = [bool] $_.isInstalled; packageId = $_.packageId; id = $_.id
            } })
    }
}

# Router configuration (-PortlessRouter). Every BC endpoint gets a name (dev./odata./api./client.
# <Name>.kiri.local), forwarded to the bc service inside the compose network; 'bc' is resolved per
# request (Docker DNS), so the router starts before bc and survives bc restarts. <Name>.kiri.local
# serves the status page, GET /api/status, and the admin API: /BC/api/, /BC/dev/ and /BC/ODataV4/
# forwarded to BC with the environment's login added, so the page and agents need no credentials
# (a local development environment: *.kiri.local resolves to 127.0.0.1 only).
# Kiri closes a request through a name after 30 s without an answer (verified 2026-11-16 against nginx
# and a plain socket server); proxy_ignore_client_abort lets BC finish it anyway, and the page then
# waits for the outcome (company listed, extension installed) instead of the response.
# Folders, not single files, are mounted: status.json is replaced atomically (new inode), which a
# single-file bind mount would not see.
$wwwDir = Join-Path $stateDir 'www'
$routerDir = Join-Path $stateDir 'router'
function Write-RouterFiles {
    $null = New-Item -ItemType Directory -Force -Path $routerDir
    $backend = @{ DevPort = 7049; ODataPort = 7048; ApiPort = 7052; ClientPort = 7085 }
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = 'proxy_set_header Host $host; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $conn_upgrade; ' +
               "proxy_set_header Authorization `"$auth`";"
    $servers = @(foreach ($k in 'DevPort', 'ODataPort', 'ApiPort', 'ClientPort') {
        "server { listen 80; server_name $($hostNames[$k]); location / { set `$u http://bc:$($backend[$k]); proxy_pass `$u; } }"
    }) + @(
        "server { listen 80; server_name $($hostNames.Status); root /usr/share/nginx/html; add_header Cache-Control `"no-store`" always;"
        '  location = /api/status { default_type application/json; add_header Cache-Control "no-store" always; add_header Access-Control-Allow-Origin "*" always; try_files /status.json =404; }'
        "  location /BC/api/ { $headers set `$u http://bc:7052; proxy_pass `$u; }"
        "  location /BC/dev/ { $headers set `$u http://bc:7049; proxy_pass `$u; }"
        "  location /BC/ODataV4/ { $headers set `$u http://bc:7048; proxy_pass `$u; }"
        '  location / { try_files $uri /index.html; } }'
    )
    Set-Content -LiteralPath (Join-Path $routerDir 'default.conf') -Encoding utf8NoBOM -Value (@(
        '# Generated by Invoke-BcLinuxEnvironment.ps1'
        'map $http_upgrade $conn_upgrade { default upgrade; '''' close; }'
        'proxy_http_version 1.1;'
        'proxy_set_header Host $host;'
        'proxy_set_header Upgrade $http_upgrade;'
        'proxy_set_header Connection $conn_upgrade;'
        'proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 0; proxy_request_buffering off;'
        # Kiri's name router drops a request that gets no answer within 30 s (company creation, large
        # publishes). Without this, nginx would then abort the request to BC and BC would cancel it.
        'proxy_ignore_client_abort on;'
        'resolver 127.0.0.11 valid=10s;'
        'server { listen 80 default_server; return 404; }'
    ) + $servers)
}

# ---------------------------------------------------------------------------
# Snapshots, clones, listing and administration of existing environments
# ---------------------------------------------------------------------------
$cloneLabel = 'dev.bclinuxenvironment.clone'
function Assert-ItemName([string] $Kind, [string] $Value) {
    if ($Value -cnotmatch '^[a-z0-9][a-z0-9_.-]*$') { throw "Invalid $Kind name '$Value' (lowercase letters, digits, '.', '_', '-')." }
}
function Read-Json([string] $Path) { try { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { $null } }
function Write-Table($Rows, [string] $Title) {
    Write-Host $Title -ForegroundColor Cyan
    if (@($Rows).Count) { Write-Host (($Rows | Format-Table -AutoSize | Out-String -Width 250).TrimEnd()) } else { Write-Host '  (none)' }
    Write-Host ''
}
function Format-Size([long] $Bytes) { if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } else { '{0:N0} MB' -f ($Bytes / 1MB) } }

if ($mode -eq 'List') {
    $projects = @{}
    foreach ($l in (Invoke-Engine ps -a --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.State}}').Output -split "`n") {
        $c = $l -split '\|'
        if ($c.Count -eq 3 -and $c[0]) { if (-not $projects.Contains($c[0])) { $projects[$c[0]] = [Collections.Generic.List[string]]::new() }; $projects[$c[0]].Add("$($c[1]) $($c[2])") }
    }
    $envs = @(foreach ($d in @(Get-ChildItem -LiteralPath $stateRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $ce = Read-ComposeEnv $d.FullName
        if (-not $ce.Count) { continue }
        $st = Read-Json (Join-Path $d.FullName 'www/status.json')
        $page = if ($st -and $st.PSObject.Properties['links']) { @($st.links | Where-Object name -eq 'Status page' | ForEach-Object url) | Select-Object -First 1 }
        [pscustomobject][ordered]@{
            name = $d.Name; bcVersion = $ce['BC_VERSION']; country = $ce['BC_COUNTRY']
            containers = $(if ($projects.Contains($d.Name)) { ($projects[$d.Name] | Sort-Object) -join ', ' } else { 'none' })
            status = $(if ($st) { $st.state } else { '' }); page = $page
        }
    })
    $snaps = @(foreach ($d in @(Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = Read-Json (Join-Path $d.FullName 'snapshot.json'); if (-not $m) { continue }
        [pscustomobject][ordered]@{ name = $m.name; source = $m.source; build = $m.build; country = $m.settings.country; createdAt = $m.createdAt
            size = Format-Size ([long] $m.sizeBytes); apps = @($m.apps).Count; companies = (@($m.companies) -join ', ') }
    })
    $clones = @(foreach ($d in @(Get-ChildItem -LiteralPath $cloneRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = Read-Json (Join-Path $d.FullName 'clone.json'); if (-not $m) { continue }
        [pscustomobject][ordered]@{ name = $m.name; source = $m.source; build = $m.build; country = $m.settings.country; createdAt = $m.createdAt
            size = Format-Size ([long] $m.sizeBytes); volumes = @(Get-LabelledVolumes "$cloneLabel=$($m.name)" "$cloneLabel.volume").Count
            apps = @($m.apps).Count; companies = (@($m.companies) -join ', ') }
    })
    if ($AsJson) { return ([ordered]@{ environments = $envs; snapshots = $snaps; clones = $clones } | ConvertTo-Json -Depth 5) }
    Write-Table $envs "Environments ($stateRoot)"; Write-Table $snaps "Snapshots ($snapshotRoot)"; Write-Table $clones "Clones ($cloneRoot)"
    return
}
if ($mode -eq 'RemoveSnapshot') {
    Assert-ItemName snapshot $RemoveSnapshot
    $dir = Join-Path $snapshotRoot $RemoveSnapshot
    if (-not (Test-Path -LiteralPath $dir)) { throw "No snapshot '$RemoveSnapshot' ($dir)." }
    Remove-Item -LiteralPath $dir -Recurse -Force
    Write-Step "Snapshot '$RemoveSnapshot' removed."
    return
}
if ($mode -eq 'RemoveClone') {
    Assert-ItemName clone $RemoveClone
    $dir = Join-Path $cloneRoot $RemoveClone
    $vols = Get-LabelledVolumes "$cloneLabel=$RemoveClone" "$cloneLabel.volume"
    if (-not $vols -and -not (Test-Path -LiteralPath $dir)) { throw "No clone '$RemoveClone'." }
    if ($vols) { $null = Assert-Ok (Invoke-Engine volume rm @($vols.Name)) "removing the volumes of clone '$RemoveClone'" }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Write-Step "Clone '$RemoveClone' removed ($($vols.Count) volume(s))."
    return
}

if ($mode -in $existingModes) {
    $composeFiles = @(Get-Content -LiteralPath (Join-Path $stateDir 'compose-files.txt') -ErrorAction SilentlyContinue | Where-Object { $_ })
    if (-not $composeFiles) { throw "Environment '$n': $stateDir/compose-files.txt is missing." }
    $composeEnvFile = Join-Path $stateDir 'compose.env'
    $ctx.ComposeFileArgs = @($composeFiles | ForEach-Object { '-f'; $_ }) + @('--env-file', $composeEnvFile)
    $bcContainer = Get-ServiceContainer bc; $sqlContainer = Get-ServiceContainer sql
    $fileArgs = ($composeFiles | ForEach-Object { '-f "{0}"' -f $_ }) -join ' '
    $startHint = '{0} compose -p {1} {2} --env-file "{3}" start' -f $engineExe, $n, $fileArgs, $composeEnvFile
    if (-not $bcContainer -or -not $sqlContainer) { throw "Environment '$n' has no containers (removed?). Create it again, or -Remove it." }
    $isRunning = { param($c) (Invoke-Engine inspect -f '{{.State.Status}}' $c).Output.Trim() -eq 'running' }
    $bcRunning = & $isRunning $bcContainer; $sqlRunning = & $isRunning $sqlContainer
    $needs = switch ($mode) { 'Clone' { 'nothing' } { $_ -in 'Snapshot', 'RestoreSnapshot' } { 'sql' } default { 'all' } }
    if (($needs -eq 'sql' -and -not $sqlRunning) -or ($needs -eq 'all' -and -not ($bcRunning -and $sqlRunning))) {
        throw "Environment '$n' is not running. Start it first:`n  $startHint"
    }
    if ($needs -eq 'all') { $null = Wait-BcReady }      # returns at once when ready

    # What a snapshot/clone records about its source: exact build, settings to recreate it, contents.
    function Get-SourceInfo {
        $build = Get-ArtifactBuild
        $apps = @(); $companies = @()
        if ($bcRunning) {
            try {
                $extList = Get-BcExtensionList
                $apps = @($extList.Items | Where-Object { $_.publisher -ne 'Microsoft' -or $_.scope -ne 'Global' })
                $companies = @(@((Invoke-BcApi GET "$automation/companies").Json.value) | ForEach-Object name)
            } catch { Write-Warning "Could not read the companies and extensions: $($_.Exception.Message)" }
        }
        [pscustomobject]@{
            Build = $(if ($build) { $build.Version } else { $null })
            Settings = [ordered]@{
                bcVersion = $cfg.BcVersion; country = $cfg.Country; bcType = $cfg.BcType; artifactUrl = $cfg.ArtifactUrl
                username = $cfg.Username; password = $cfg.Password; licenseFile = $cfg.LicenseFile
                sqlImage = $cfg.SqlImage; database = $database; fullTextSearch = "$($cfg.SqlImage)" -match 'fts'; webClient = [bool] $cfg.WebClient
            }
            Apps = $apps; Companies = $companies
        }
    }
}

if ($mode -eq 'Snapshot') {
    Assert-ItemName snapshot $Snapshot
    $dir = Join-Path $snapshotRoot $Snapshot
    if (Test-Path -LiteralPath $dir) { throw "Snapshot '$Snapshot' already exists ($dir). Remove it with -RemoveSnapshot $Snapshot, or choose another name." }
    $t = [Diagnostics.Stopwatch]::StartNew()
    $info = Get-SourceInfo
    # A snapshot restores into a NEW download of the same build: pin the exact build, not '28.5'.
    if ($info.Build -and -not $cfg.ArtifactUrl) { $info.Settings.bcVersion = $info.Build }
    Write-Step "Snapshot '$Snapshot' of '$n': backing up database $database (online)"
    $null = New-Item -ItemType Directory -Force -Path $dir
    try {
        $bak = Join-Path $dir 'database.bak'
        Backup-BcDatabase $bak
        $meta = [ordered]@{
            schema = 1; kind = 'snapshot'; name = $Snapshot; source = $n; createdAt = Get-UtcNow; build = $info.Build
            settings = $info.Settings; companies = $info.Companies; apps = $info.Apps; sizeBytes = (Get-Item -LiteralPath $bak).Length
        }
        Set-Content -LiteralPath (Join-Path $dir 'snapshot.json') -Value ($meta | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
    } catch { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; throw }
    Write-Step "Snapshot '$Snapshot' saved in $([int]$t.Elapsed.TotalSeconds)s ($(Format-Size $meta.sizeBytes); BC $($info.Build)): $dir"
    Write-Note "New environment from it:  -Name <new> -FromSnapshot $Snapshot      Reset '$n' to it:  -Name $n -RestoreSnapshot $Snapshot"
    return
}

if ($mode -eq 'Clone') {
    Assert-ItemName clone $Clone
    $dir = Join-Path $cloneRoot $Clone
    if ((Test-Path -LiteralPath $dir) -or (Get-LabelledVolumes "$cloneLabel=$Clone" "$cloneLabel.volume")) {
        throw "Clone '$Clone' already exists. Remove it with -RemoveClone $Clone, or choose another name."
    }
    # The volumes the containers actually mount (named <project>_<volume> by compose).
    $vols = @(@(foreach ($c in $bcContainer, $sqlContainer) {
        (Invoke-Engine inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' $c).Output -split "`n" | Where-Object { $_ } |
            ForEach-Object { [pscustomobject]@{ Name = $_; Key = $(if ($_.StartsWith("$($n)_")) { $_.Substring($n.Length + 1) } else { $_ }) } }
    }) | Sort-Object Name -Unique)      # sql mounts bc-artifacts too
    if ('sql-data' -notin $vols.Key) { throw "Environment '$n' keeps its database in memory (-PersistDatabase:`$false); a clone needs the database volume." }
    $t = [Diagnostics.Stopwatch]::StartNew()
    $info = Get-SourceInfo
    # Pin the runner image: the service and assembly-cache stamps in the copied volumes are tied to it.
    $imageId = (Invoke-Engine inspect -f '{{.Image}}' $bcContainer).Output.Trim()
    $digest = @((Invoke-Engine image inspect -f '{{join .RepoDigests "\n"}}' $imageId).Output -split "`n" | Where-Object { $_ -match '@sha256:' }) | Select-Object -First 1
    $info.Settings.saPassword = $cfg.SaPassword
    Write-Step "Clone '$Clone' of '$n': stopping the environment for a consistent copy"
    $null = Assert-Ok (Invoke-Compose stop) 'compose stop'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $created = [Collections.Generic.List[string]]::new()
    $total = 0L
    try {
        foreach ($v in $vols) {
            $target = "bcvm-clone-$Clone-$($v.Key)"
            Set-StatusDetail $v.Key
            $null = Assert-Ok (Invoke-Engine volume create --label "$cloneLabel=$Clone" --label "$cloneLabel.volume=$($v.Key)" $target) "creating volume $target"
            $created.Add($target)
            $vt = [Diagnostics.Stopwatch]::StartNew()
            $size = Copy-Volume $v.Name $target $imageId
            $total += $size
            Write-Note "$($v.Key): $(Format-Size $size) in $([int]$vt.Elapsed.TotalSeconds)s"
        }
        $meta = [ordered]@{
            schema = 1; kind = 'clone'; name = $Clone; source = $n; createdAt = Get-UtcNow; build = $info.Build
            bcImage = $(if ($digest) { $digest } else { $imageId }); bcImageId = $imageId
            settings = $info.Settings; volumes = @($vols.Key); companies = $info.Companies; apps = $info.Apps; sizeBytes = $total
        }
        Set-Content -LiteralPath (Join-Path $dir 'clone.json') -Value ($meta | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
    } catch {
        if ($created.Count) { $null = Invoke-Engine volume rm @created }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        Write-Step "Starting '$n' again"
        $r = Invoke-Compose start
        if ($r.ExitCode -ne 0) { Write-Warning "compose start failed; start it with:`n  $startHint`n$($r.Output)" }
    }
    if (-not $digest) { Write-Warning "The runner image has no registry digest (built locally?); the clone pins image $imageId, which exists on this machine only." }
    if ($bcRunning) { $null = Wait-BcReady }
    Write-Step "Clone '$Clone' saved in $([int]$t.Elapsed.TotalSeconds)s ($(Format-Size $total) in $($vols.Count) volumes; BC $($info.Build))"
    Write-Note "New environment from it:  -Name <new> -FromClone $Clone"
    return
}

if ($mode -eq 'RestoreSnapshot') {
    Assert-ItemName snapshot $RestoreSnapshot
    $dir = Join-Path $snapshotRoot $RestoreSnapshot
    $meta = Read-Json (Join-Path $dir 'snapshot.json')
    if (-not $meta) { throw "No snapshot '$RestoreSnapshot' ($dir). -List shows the snapshots." }
    $have = Get-ArtifactBuild
    if ($have -and $meta.build -and $have.Version -ne $meta.build) {
        throw "Snapshot '$RestoreSnapshot' is BC $($meta.build); '$n' runs $($have.Version). Create a new environment from it instead: -Name <new> -FromSnapshot $RestoreSnapshot"
    }
    $t = [Diagnostics.Stopwatch]::StartNew()
    Write-Step "Restoring snapshot '$RestoreSnapshot' into '$n' (service tier stopped meanwhile)"
    if ($bcRunning) { $null = Assert-Ok (Invoke-Engine stop $bcContainer) 'stopping the bc container' }
    Restore-BcDatabase (Join-Path $dir 'database.bak')
    Write-Step 'Starting the service tier'
    $null = Assert-Ok (Invoke-Engine start $bcContainer) 'starting the bc container'
    $companies = Wait-BcReady
    Write-Step "Environment '$n' restored from snapshot '$RestoreSnapshot' in $([int]$t.Elapsed.TotalSeconds)s. Companies: $($companies -join ', ')"
    return
}

if ($mode -eq 'ListApps') {
    $items = @((Get-BcExtensionList).Items | Where-Object { $_.publisher -ne 'Microsoft' -or $_.scope -ne 'Global' } | Sort-Object publisher, name, version)
    if ($AsJson) { return (ConvertTo-Json -InputObject $items -Depth 3) }
    Write-Table ($items | Select-Object name, publisher, version, scope, installed, packageId) "Extensions in '$n' (without Microsoft's global apps)"
    return
}

if ($mode -eq 'AppAction') {
    if (-not ($InstallApp -or $UninstallApp -or $UnpublishApp)) { throw 'Name the extensions with -InstallApp, -UninstallApp and/or -UnpublishApp.' }
    $extList = Get-BcExtensionList
    $cu = "$automation/companies($($extList.CompanyId))"
    # 'A,B' from pwsh -File arrives as one string: split it unless it is an extension name itself.
    function Resolve-Extension([string[]] $Refs) {
        foreach ($ref in $Refs) {
            $parts = if (@($extList.Items | Where-Object name -eq $ref).Count) { @($ref) } else { @($ref -split '[,;]' | ForEach-Object Trim | Where-Object { $_ }) }
            foreach ($p in $parts) {
                $m = @($extList.Items | Where-Object { $_.name -eq $p -or "$($_.packageId)" -eq $p -or "$($_.id)" -eq $p })
                if (-not $m) { throw "No extension '$p' in '$n'. -ListApps shows names and ids." }
                , $m
            }
        }
    }
    function Invoke-ExtensionAction($Ext, [string] $Action) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        Write-Note "$Action $($Ext.name) $($Ext.version) ..."
        $r = Invoke-BcApi POST "$cu/extensions($($Ext.packageId))/Microsoft.NAV.$Action" -TimeoutSec $cfg.PublishTimeoutSeconds
        if ($r.Code -notin 200, 204) { throw "$Action of $($Ext.name) $($Ext.version) failed (HTTP $($r.Code)):`n$($r.Raw)" }
        # Wait until the extension list shows the result (the action may finish in the background).
        $deadline = (Get-Date).AddSeconds($cfg.PublishTimeoutSeconds)
        while ($true) {
            $now = @((Get-BcExtensionList).Items | Where-Object { "$($_.packageId)" -eq "$($Ext.packageId)" })
            $done = switch ($Action) { 'install' { $now -and $now[0].installed } 'unpublish' { -not $now } default { -not $now -or -not $now[0].installed } }
            if ($done) { break }
            if ((Get-Date) -gt $deadline) { throw "$Action of $($Ext.name): no result after $($cfg.PublishTimeoutSeconds)s." }
            Start-Sleep -Seconds 3
        }
        Write-Note "  done in $([int]$t.Elapsed.TotalSeconds)s"
    }
    $uninstall = if ($DeleteData) { 'uninstallAndDeleteExtensionData' } else { 'uninstall' }
    if ($UninstallApp) {
        Write-Step "Uninstalling in '$n'"
        foreach ($m in Resolve-Extension $UninstallApp) {
            $inst = @($m | Where-Object installed)
            if (-not $inst) { Write-Note "$($m[0].name): not installed"; continue }
            foreach ($e in $inst) { Invoke-ExtensionAction $e $uninstall }
        }
    }
    if ($UnpublishApp) {
        Write-Step "Unpublishing in '$n'"
        foreach ($m in Resolve-Extension $UnpublishApp) {
            foreach ($e in @($m | Where-Object installed)) { Invoke-ExtensionAction $e $uninstall }
            foreach ($e in $m) { Invoke-ExtensionAction $e 'unpublish' }
        }
    }
    if ($InstallApp) {
        Write-Step "Installing in '$n'"
        $extList = Get-BcExtensionList      # fresh state after the steps above
        foreach ($m in Resolve-Extension $InstallApp) {
            if (@($m | Where-Object installed)) { Write-Note "$($m[0].name): already installed"; continue }
            Invoke-ExtensionAction ($m | Sort-Object { [version] $_.version } | Select-Object -Last 1) 'install'
        }
    }
    Write-Step 'Done.'
    return
}

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
if ($cfg.LicenseFile -and $mode -eq 'Create') {
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

# AL launch.json configuration for the dev endpoint (status page and summary).
$alServer = if ($hostNames.Contains('DevPort')) { @("http://$($hostNames.DevPort)", 80) }
            elseif ('DevPort' -in $publishedPorts) { @('http://localhost', $ports.DevPort) }
$alLaunch = if ($alServer) {
    [ordered]@{ name = 'Publish'; type = 'al'; request = 'launch'; server = $alServer[0]; serverInstance = 'BC'
                port = $alServer[1]; authentication = 'UserPassword'; launchBrowser = $false; schemaUpdateMode = 'ForceSync' }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$versionText = if ($cfg.ArtifactUrl) { $cfg.ArtifactUrl } else { "$($cfg.BcType) $($cfg.BcVersion) ($($cfg.Country))" }

if ($mode -eq 'Update') {
    $statusFile = Join-Path $wwwDir 'status.json'      # left as it is (state stays 'ready')
    # Refresh the status page and the router configuration (admin API) to this script's version.
    $routerContainer = Get-ServiceContainer router
    if ($cfg.PortlessRouter -and $routerContainer -and $hostNames.Contains('Status')) {
        $null = New-Item -ItemType Directory -Force -Path $wwwDir
        Set-Content -LiteralPath (Join-Path $wwwDir 'index.html') -Value $statusPageHtml -Encoding utf8NoBOM
        Write-RouterFiles
        $r = Invoke-Engine exec $routerContainer nginx -s reload
        if ($r.ExitCode -ne 0) { Write-Warning "Reloading the router failed:`n$($r.Output)" }
        else { Write-Step "Status page and admin API refreshed: http://$($hostNames.Status)/" }
    }
    $what = @($(if ($appFiles.Count) { "$($appFiles.Count) extension(s)" }), $(if ($cfg.CompanyName) { "company '$($cfg.CompanyName)', $($packageSteps.Count) package step(s)" })) | Where-Object { $_ }
    if ($what) { Write-Step "Updating '$n': $($what -join ', ')" }
}

# ---- Creation (Create mode only). Not indented: the block contains here-strings. ----
if ($mode -eq 'Create') {

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

# Creation starts here: from now on the status file belongs to this run.
$wwwDir = Join-Path $stateDir 'www'
$null = New-Item -ItemType Directory -Force -Path $wwwDir
$statusFile = Join-Path $wwwDir 'status.json'
$status = [ordered]@{
    schema = 1; name = $n; state = 'running'; startedAt = Get-UtcNow; updatedAt = $null; finishedAt = $null
    step = $null; detail = $null; error = $null
    settings = [ordered]@{
        bcVersion = $cfg.BcVersion; country = $cfg.Country; bcType = $cfg.BcType; apps = $appFiles.Count
        company = $(if ($cfg.CompanyName) { $cfg.CompanyName } else { $null }); configPackages = $packageSteps.Count
        portlessRouter = [bool]$cfg.PortlessRouter
        from = $(if ($fromInfo) { "$($fromInfo.kind) $($fromInfo.name)" } else { $null })
    }
    links = @(); steps = [Collections.Generic.List[object]]::new(); log = [Collections.Generic.List[object]]::new(); endpoints = $null
}
Set-Content -LiteralPath (Join-Path $wwwDir 'index.html') -Value $statusPageHtml -Encoding utf8NoBOM
Write-Step 'Preparing'
Write-Note "Progress: $statusFile$(if ($cfg.PortlessRouter) { '  (status page once the containers start)' })"

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
if ($cfg.PortlessRouter) {
    # Replace upstream's port list with only the explicitly requested ports (Compose >= 2.24).
    $portList = @($publishedPorts | Where-Object { $containerPorts.Contains($_) } | ForEach-Object { '"{0}:{1}"' -f $ports[$_], $containerPorts[$_] })
    $yaml.Add("    ports: !override [$($portList -join ', ')]")
}
if ($isKiri -and $cfg.WebClient) {
    $yaml.Add('    labels:')
    $yaml.Add('      dev.kiri.http.port: "8080"')     # bc.<Name>.kiri.local -> web client
}
$yaml.Add('  sql:')
$yaml.Add('    restart: unless-stopped')
if ($cfg.PortlessRouter) {
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
if ($isKiri -and $cfg.PortlessRouter) {
    Write-RouterFiles     # see the function for what the router serves
    $yaml.Add('  router:')
    $yaml.Add('    image: docker.io/library/nginx:alpine')
    $yaml.Add('    restart: unless-stopped')
    $yaml.Add('    volumes:')
    $yaml.Add("      - $(ConvertTo-YamlScalar "$($routerDir):/etc/nginx/conf.d:ro")")
    $yaml.Add("      - $(ConvertTo-YamlScalar "$($wwwDir):/usr/share/nginx/html:ro")")
    $yaml.Add('    labels:')
    $yaml.Add("      dev.kiri.domain: $(ConvertTo-YamlScalar ((('Status', 'DevPort', 'ODataPort', 'ApiPort', 'ClientPort') | ForEach-Object { $hostNames[$_] }) -join ','))")
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

if ($status) {
    $status.settings.bcVersion = $cfg.BcVersion     # 'latest' is resolved by now
    # Service links for the status page/agents, known before BC is up (usable once state = ready).
    $links = [Collections.Generic.List[object]]::new()
    function Add-StatusLink([string] $Name, [string] $Key, [string] $Path, [string] $Scheme = 'http') {
        $url = if ($hostNames.Contains($Key)) { "$($Scheme)://$($hostNames[$Key])$Path" }
               elseif ($Key -in $publishedPorts) { "$($Scheme)://localhost:$($ports[$Key])$Path" }
        if ($url) { $links.Add([ordered]@{ name = $Name; url = $url; kind = $Scheme }) }
    }
    if ($hostNames.Contains('Status')) { $links.Add([ordered]@{ name = 'Status page'; url = "http://$($hostNames.Status)/"; kind = 'http' }) }
    if ($cfg.WebClient) { Add-StatusLink 'Web client' WebClientPort '/' }
    Add-StatusLink 'Dev endpoint' DevPort '/BC/dev'
    Add-StatusLink 'OData v4' ODataPort '/BC/ODataV4'
    Add-StatusLink 'API v2.0' ApiPort '/BC/api/v2.0'
    Add-StatusLink 'Client services' ClientPort '/BC' 'ws'
    if ('SqlPort' -in $publishedPorts) { $links.Add([ordered]@{ name = 'SQL Server (sa)'; url = "localhost,$($ports.SqlPort)"; kind = 'text' }) }
    if ($alLaunch) { $links.Add([ordered]@{ name = 'AL launch.json'; url = ($alLaunch | ConvertTo-Json); kind = 'text' }) }
    $links.Add([ordered]@{ name = 'User name'; url = $cfg.Username; kind = 'text' })
    $status.links = $links
}
Write-Step "Creating BC environment '$n': $versionText on $engineDesc$(if ($emulated) { ' (amd64 emulation)' })"
Write-Note "Compose files: $(($composeFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ' + ')  (state: $stateDir)"
$portText = if (-not $cfg.PortlessRouter) {
    "dev $($ports.DevPort), OData $($ports.ODataPort), API $($ports.ApiPort), mgmt $($ports.MgmtPort), client $($ports.ClientPort), SQL $($ports.SqlPort)$(if ($cfg.WebClient) { ", web $($ports.WebClientPort)" })"
} elseif ($publishedPorts) { "only $(($publishedPorts | ForEach-Object { "$_ $($ports[$_])" }) -join ', ')" } else { 'none published' }
Write-Note "Ports: $portText"
if ($hostNames.Count) { Write-Note "Names: $(@($hostNames.Values) -join ', ')" }
if ($licensePath) { Write-Note "License: $licensePath" }
if ($appFiles.Count) { Write-Note "Extensions: $($appFiles.Count) to publish after startup" }

$null = Assert-Ok (Invoke-Compose config --quiet) 'compose config'

if ($fromInfo -and $fromInfo.kind -eq 'clone') {
    # The project's volumes start as copies of the clone's (labelled for this project, so compose uses
    # them and -Remove deletes them). The entrypoint then finds cached artifacts, a patched service tier
    # and the database, and only starts the tier.
    $cloneVols = Get-LabelledVolumes "$cloneLabel=$($fromInfo.name)" "$cloneLabel.volume"
    if (-not $cloneVols) { throw "Clone '$($fromInfo.name)' has no volumes left (removed?). -RemoveClone $($fromInfo.name) cleans it up." }
    Write-Step "Copying clone '$($fromInfo.name)' ($($cloneVols.Count) volumes)"
    $copyImage = if ((Invoke-Engine image inspect $fromInfo.bcImageId).ExitCode -eq 0) { $fromInfo.bcImageId } else { $cfg.BcImage }
    foreach ($v in $cloneVols) {
        $target = "$($n)_$($v.Key)"
        Set-StatusDetail $v.Key
        $null = Assert-Ok (Invoke-Engine volume create --label "com.docker.compose.project=$n" --label "com.docker.compose.volume=$($v.Key)" $target) "creating volume $target"
        $vt = [Diagnostics.Stopwatch]::StartNew()
        $size = Copy-Volume $v.Name $target $copyImage
        Write-Note "$($v.Key): $(Format-Size $size) in $([int]$vt.Elapsed.TotalSeconds)s"
    }
}

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

if ($fromInfo -and $fromInfo.kind -eq 'snapshot') {
    # SQL first, restore, then the rest: the entrypoint finds the database and uses it.
    Write-Step "Restoring snapshot '$($fromInfo.name)' (BC $($fromInfo.build))"
    $r = Invoke-Compose up -d --no-build sql
    if ($r.ExitCode -ne 0) { throw "compose up sql failed (rc=$($r.ExitCode)).`n$($r.Output)" }
    $sqlContainer = Get-ServiceContainer sql
    Wait-SqlReady
    Restore-BcDatabase (Join-Path $fromDir 'database.bak')
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
if ($hostNames.Contains('Status')) {
    Write-Host ''
    Write-Host "  Track progress: http://$($hostNames.Status)/   (agents: http://$($hostNames.Status)/api/status)" -ForegroundColor Green
    Write-Host ''
    Add-StatusLog 'info' "Status page: http://$($hostNames.Status)/"
}
if (-not $bcContainer) { throw 'compose up returned, but no bc container exists.' }
$sqlContainer = Get-ServiceContainer sql
}
# ---- End of creation ----

# ---------------------------------------------------------------------------
# Wait for readiness
# ---------------------------------------------------------------------------
if ($mode -eq 'Create') {
    $what = if ($fromInfo -and $fromInfo.kind -eq 'clone') { 'artifacts and service tier come from the clone' } else { 'first boot downloads ~2 GB of artifacts' }
    Write-Step "Waiting for the service tier ($what; up to $($cfg.TimeoutMinutes) min)"
}
$companies = Wait-BcReady
if ($mode -eq 'Create') { Write-Step "Service tier ready after $([int]$sw.Elapsed.TotalMinutes) min. Companies: $($companies -join ', ')" }

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
if ((Clear-UserSid) -gt 0 -and ($packageSteps.Count -or $cfg.CompanyName)) {
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

$installed = [Collections.Generic.List[string]]::new()
$installedNames = [Collections.Generic.List[string]]::new()
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
            Set-StatusDetail "$($installed.Count + $deferred.Count + 1)/$($appFiles.Count): $file"
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

}
# Installed extensions (not Microsoft's), checked through the automation API: after publishing, and
# for environments whose apps came with a snapshot or clone.
if ($appFiles.Count -or $fromInfo) {
    try {
        foreach ($e in @((Get-BcExtensionList).Items | Where-Object { $_.publisher -ne 'Microsoft' } | Sort-Object publisher, name)) {
            if ($e.installed) { Write-Note "installed: $($e.publisher) / $($e.name) $($e.version)"; $installedNames.Add("$($e.name) $($e.version)") }
            elseif ($e.scope -ne 'Global') { Write-Warning "published but NOT installed: $($e.publisher) / $($e.name) $($e.version)" }
        }
    } catch { Write-Note "(could not list installed extensions: $($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------
# Company and configuration packages
# ---------------------------------------------------------------------------
# Automation API v2.0, called with curl INSIDE the bc container like the publish: creating a company
# takes ~30 s and package steps minutes, longer than some engines' proxies keep a request open.
# Bodies and files are copied in (no JSON on the command line, so no native-argument quoting issues).

$packageSummary = $null
if ($cfg.CompanyName) {
    $null = Invoke-Engine exec $bcContainer mkdir -p $publishDir
    $all = @((Invoke-BcApi GET "$automation/companies").Json.value)
    $company = $all | Where-Object name -eq $cfg.CompanyName
    if (-not $company) {
        Write-Step "Creating company '$($cfg.CompanyName)'"
        $t = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-BcApi POST "$automation/companies($($all[0].id))/automationCompanies" @{ name = $cfg.CompanyName; displayName = $cfg.CompanyName } -TimeoutSec 1800
        if ($r.Code -notin 200, 201) {
            $hint = if ($r.Raw -match 'Full-Text Search') { "`nThe SQL Server of this environment has no Full-Text Search. Create the environment with -FullTextSearch (or -CompanyName)." } else { '' }
            throw "Creating company '$($cfg.CompanyName)' failed (HTTP $($r.Code)):`n$($r.Raw)$hint"
        }
        $company = @((Invoke-BcApi GET "$automation/companies").Json.value) | Where-Object name -eq $cfg.CompanyName
        Write-Note "created in $([int]$t.Elapsed.TotalSeconds)s"
    }
    $cu = "$automation/companies($($company.id))"
    if ($packageSteps.Count) { Write-Step "Configuration packages: $($packageSteps.Count) step(s) into '$($cfg.CompanyName)'" }
    $totalErrors = 0
    $stepNo = 0
    foreach ($step in $packageSteps) {
        $stepNo++
        Set-StatusDetail "$stepNo/$($packageSteps.Count): $(if ($step.Feature) { "feature:$($step.Feature)" } else { Split-Path -Leaf $step.Path })"
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
Write-Step $(if ($mode -eq 'Update') { "Environment '$n' updated ($([int]$sw.Elapsed.TotalMinutes) min)" } else { "Environment '$n' is ready ($([int]$sw.Elapsed.TotalMinutes) min)" })
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
    Status     = $(if ($hostNames.Contains('Status')) { "http://$($hostNames.Status)/  (agents: /api/status; file: $statusFile)" } else { "file: $statusFile" })
    Admin      = $(if ($hostNames.Contains('Status')) { "http://$($hostNames.Status)/  (extensions and packages; API: /BC/api/..., /BC/dev/... without login)" } else { $null })
    WebClient  = $(if ($cfg.WebClient) { Get-Endpoint WebClientPort '/' } else { '(disabled)' })
    Dev        = Get-Endpoint DevPort '/BC/dev'
    OData      = Get-Endpoint ODataPort '/BC/ODataV4'
    Api        = Get-Endpoint ApiPort '/BC/api/v2.0'
    Client     = Get-Endpoint ClientPort '/BC' 'ws'
    Sql        = $(if ('SqlPort' -in $publishedPorts) { "localhost,$($ports.SqlPort) (sa)" } else { '(not published; -SqlPort <port> publishes it)' })
    Username   = $cfg.Username
    Company    = $(if ($cfg.CompanyName) { "$($cfg.CompanyName)$(if ($packageSummary) { "  (packages: $packageSummary)" })" } else { $null })
    From       = $(if ($fromInfo) { "$($fromInfo.kind) '$($fromInfo.name)' (from '$($fromInfo.source)', BC $($fromInfo.build))" } else { $null })
    Extensions = $(if ($installedNames.Count) { $installedNames -join ', ' } elseif ($installed.Count) { $installed -join ', ' } else { $null })
    Compose    = "$composeHint <logs|stop|start|ps>"
    Remove     = "./Invoke-BcLinuxEnvironment.ps1 -Name $n -Remove"
}
if ($alLaunch) {
    $summary.Remove('Remove'); $summary.Remove('Compose')
    $summary['AL launch'] = $alLaunch | ConvertTo-Json -Compress
    $summary['Compose'] = "$composeHint <logs|stop|start|ps>"
    $summary['Remove'] = "./Invoke-BcLinuxEnvironment.ps1 -Name $n -Remove"
}
$summary.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object { Write-Host ('  {0,-11} {1}' -f $_.Key, $_.Value) }

if ($status) {
    $now = Get-UtcNow
    foreach ($st in $status.steps) { if ($st.status -eq 'running') { $st.status = 'done'; $st.endedAt = $now } }
    $status.state = 'ready'; $status.finishedAt = $now; $status.step = 'Ready'; $status.detail = $null
    $status.endpoints = [ordered]@{}
    foreach ($e in $summary.GetEnumerator()) { if ($null -ne $e.Value -and "$($e.Value)") { $status.endpoints[$e.Key] = "$($e.Value)" } }
    Save-Status
}
