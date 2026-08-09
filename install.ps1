<#
.SYNOPSIS
    Installs the LV1 to REAPER importer and everything it needs, on Windows.

.DESCRIPTION
    Puts the two REAPER extensions (ReaPack and ReaImGui) in place, installs
    the importer itself, and checks for Node.js. After it finishes, restart
    REAPER and load the action.

    Nothing here needs administrator rights: everything is written inside
    REAPER's own resource folder, which belongs to your user account.

.PARAMETER ResourcePath
    REAPER's resource folder, if it is not the default one. Find yours in
    REAPER under Options > Show REAPER resource path in explorer/finder.
    Use this for a portable REAPER install.

.PARAMETER DryRun
    Print what would happen without writing or downloading anything.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -ResourcePath "D:\REAPER-portable"
#>
[CmdletBinding()]
param(
    [string] $ResourcePath,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$REPO = 'malik-malassis/lv1-to-reaper'

function Step($msg)  { Write-Host "==> $msg" }
function Info($msg)  { Write-Host "    $msg" }
function Warn($msg)  { Write-Host "    ! $msg" -ForegroundColor Yellow }
function Good($msg)  { Write-Host "    ok $msg" -ForegroundColor Green }

# ── REAPER must not be running ────────────────────────────────────────────
# Extensions are only read at start-up, and Windows locks a DLL that is
# loaded, so writing over it while REAPER is open fails in a confusing way.
if (Get-Process reaper -ErrorAction SilentlyContinue) {
    Write-Host ""
    if ($DryRun) {
        Warn "REAPER is running. A real run would stop here."
    } else {
        Warn "REAPER is running. Close it completely, then run this again."
        exit 1
    }
}

# ── where REAPER keeps its files ──────────────────────────────────────────
if (-not $ResourcePath) {
    $ResourcePath = Join-Path $env:APPDATA 'REAPER'
}
if (-not (Test-Path $ResourcePath)) {
    Write-Host ""
    Warn "REAPER's resource folder was not found at: $ResourcePath"
    Info "Open REAPER, go to Options > Show REAPER resource path in explorer/finder,"
    Info "then run this script again with:  .\install.ps1 -ResourcePath ""<that folder>"""
    exit 1
}

Step "REAPER folder: $ResourcePath"

# ── which build to download ───────────────────────────────────────────────
# Both extensions name their files reaper_<name>-<arch>.dll. Windows on ARM
# runs the x64 build through emulation, so it is the right choice there too.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and -not $env:PROCESSOR_ARCHITEW6432) { 'x86' } else { 'x64' }
Step "Architecture: $arch"

$plugins = Join-Path $ResourcePath 'UserPlugins'
$scripts = Join-Path $ResourcePath 'Scripts\lv1-reaper'

function Get-File($url, $dest) {
    if ($DryRun) { Info "would download $url"; return }
    $dir = Split-Path $dest -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # A partial download must never replace a working file, so write to a
    # temporary name and move it into place only once it is complete.
    $tmp = "$dest.part"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Move-Item $tmp $dest -Force
}

# ── extensions ────────────────────────────────────────────────────────────
foreach ($ext in @(
    @{ Name = 'ReaPack';  Repo = 'cfillion/reapack';  File = "reaper_reapack-$arch.dll" },
    @{ Name = 'ReaImGui'; Repo = 'cfillion/reaimgui'; File = "reaper_imgui-$arch.dll" }
)) {
    $dest = Join-Path $plugins $ext.File
    if (Test-Path $dest) {
        Step "$($ext.Name) already installed"
        continue
    }
    Step "Installing $($ext.Name)"
    Get-File "https://github.com/$($ext.Repo)/releases/latest/download/$($ext.File)" $dest
    Good $ext.File
}

# imgui.lua is optional: the importer works without it, through ReaImGui's
# older interface. Installing it lets the modern one be used instead.
$imguiLua = Join-Path $ResourcePath 'Scripts\ReaTeam Extensions\API\imgui.lua'
if (-not (Test-Path $imguiLua)) {
    Step "Installing the ReaImGui Lua module"
    try {
        Get-File 'https://github.com/cfillion/reaimgui/releases/latest/download/imgui.lua' $imguiLua
        Good "imgui.lua"
    } catch {
        Warn "could not fetch imgui.lua, continuing without it (the importer does not need it)"
    }
}

# ── the importer ──────────────────────────────────────────────────────────
Step "Installing the importer"
foreach ($f in @('LV1_Track_Importer.lua', 'lv1_fetch.js')) {
    $local = Join-Path $PSScriptRoot $f
    $dest = Join-Path $scripts $f
    if (Test-Path $local) {
        # Running from a clone: use the files sitting next to this script.
        if (-not $DryRun) {
            if (-not (Test-Path $scripts)) { New-Item -ItemType Directory -Force -Path $scripts | Out-Null }
            Copy-Item $local $dest -Force
        }
        Good "$f (from this folder)"
    } else {
        Get-File "https://raw.githubusercontent.com/$REPO/main/$f" $dest
        Good "$f (downloaded)"
    }
}

# A result file left over from an older install would be read as if it were
# fresh, so clear it.
foreach ($stale in @('lv1_tracks.json', 'lv1_fetch.log')) {
    $p = Join-Path $scripts $stale
    if ((Test-Path $p) -and -not $DryRun) { Remove-Item $p -Force }
}

# ── Node.js ───────────────────────────────────────────────────────────────
# Deliberately not installed automatically: it is a system-wide program, and
# a script that silently installs those is a script you should not trust.
Step "Checking Node.js"
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    Good "$((& node --version)) at $($node.Source)"
} else {
    Warn "Node.js is not installed. The importer needs it to reach your console."
    Info "Download it from https://nodejs.org and run the installer,"
    Info "or, in a terminal:  winget install OpenJS.NodeJS.LTS"
}

# ── what is left to do ────────────────────────────────────────────────────
Write-Host ""
Step "Done. Two things left:"
Info "1. Start REAPER."
Info "2. Actions > Show action list > New action > Load ReaScript,"
Info "   then pick:"
Info "   $(Join-Path $scripts 'LV1_Track_Importer.lua')"
Write-Host ""
Info "Give it a keyboard shortcut while you are there. Instructions and"
Info "troubleshooting: https://github.com/$REPO"
if ($DryRun) { Write-Host ""; Warn "dry run: nothing was actually written" }
