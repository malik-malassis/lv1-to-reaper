<#
.SYNOPSIS
    Copies the importer into REAPER's Scripts folder.

.DESCRIPTION
    Both files must travel together: the ReaScript looks for lv1_fetch.js next
    to itself, so copying only the .lua leaves a deployment that fails at fetch
    time with a confusing "no result file" error.

    Run it after every edit:  npm run deploy

.PARAMETER Destination
    Target folder. Defaults to %APPDATA%\REAPER\Scripts\lv1-reaper.

.PARAMETER Portable
    Deploy into a portable REAPER install instead: pass -Portable <reaper dir>.
#>
[CmdletBinding()]
param(
    [string] $Destination,
    [string] $Portable
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$files = @('LV1_Track_Importer.lua', 'lv1_fetch.js', 'README.md', 'LICENSE')

if ($Portable) {
    $Destination = Join-Path $Portable 'Scripts\lv1-reaper'
} elseif (-not $Destination) {
    $Destination = Join-Path $env:APPDATA 'REAPER\Scripts\lv1-reaper'
}

foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $source $f))) {
        throw "Missing source file: $f (run this from the repository root)"
    }
}

if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-Host "Created $Destination"
}

$failed = $false
foreach ($f in $files) {
    $src = Join-Path $source $f
    $dst = Join-Path $Destination $f
    Copy-Item $src $dst -Force

    # Verify rather than trust: a half-written copy that still "succeeds" is
    # exactly the kind of thing that wastes an hour before a soundcheck.
    $a = (Get-FileHash $src -Algorithm SHA256).Hash
    $b = (Get-FileHash $dst -Algorithm SHA256).Hash
    if ($a -eq $b) {
        Write-Host ("  ok   {0}" -f $f)
    } else {
        Write-Warning ("  FAIL {0} - copy does not match the source" -f $f)
        $failed = $true
    }
}

# A stale result file in the destination would be picked up by the script on
# its next run and shown as if it were fresh.
foreach ($stale in @('lv1_tracks.json', 'lv1_fetch.log')) {
    $p = Join-Path $Destination $stale
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host ("  cleaned stale {0}" -f $stale)
    }
}

if ($failed) {
    Write-Error 'Deployment incomplete.'
    exit 1
}

Write-Host ""
Write-Host "Deployed to $Destination"
Write-Host "In REAPER: Actions > Show action list > New action > Load ReaScript... > LV1_Track_Importer.lua"
