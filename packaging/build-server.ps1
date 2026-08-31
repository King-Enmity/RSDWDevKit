param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$Output = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'dist\RSDWServerKit')
)

$ErrorActionPreference = 'Stop'

if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
New-Item -ItemType Directory -Path $Output | Out-Null

# Server package is assembled explicitly instead of cloning the full client kit.
# This prevents client UI/binaries from leaking into a cloud deployment.
$ue4ssOut = Join-Path $Output 'ue4ss'
$modsOut = Join-Path $ue4ssOut 'Mods'
New-Item -ItemType Directory -Path $modsOut -Force | Out-Null

# Windows dedicated-server bootstrap baseline. Validate these binaries against
# the actual dedicated-server executable before production deployment.
foreach ($file in @('UE4SS.dll', 'UE4SS-settings.ini')) {
    $src = Join-Path $Root ('ue4ss\' + $file)
    if (Test-Path $src) { Copy-Item $src $ue4ssOut -Force }
}
if (Test-Path (Join-Path $Root 'dwmapi.dll')) {
    Copy-Item (Join-Path $Root 'dwmapi.dll') $Output -Force
}

# Shared/general UE4SS mods currently required by the modding stack.
foreach ($mod in @('BPML_GenericFunctions', 'BPModLoaderMod')) {
    $src = Join-Path $Root ('ue4ss\Mods\' + $mod)
    if (Test-Path $src) { Copy-Item $src (Join-Path $modsOut $mod) -Recurse -Force }
}

# Add the dedicated server runtime. This package deliberately does not copy the
# legacy RSDWTools mod, desktop app, client console, camera, UMG or hotkeys.
$serverDst = Join-Path $modsOut 'RSDWServer'
New-Item -ItemType Directory -Path $serverDst -Force | Out-Null
Copy-Item (Join-Path $Root 'server\RSDWServer\*') $serverDst -Recurse -Force

@(
    'BPML_GenericFunctions : 1',
    'BPModLoaderMod : 1',
    'RSDWServer : 1'
) | Set-Content (Join-Path $modsOut 'mods.txt') -Encoding ASCII

Write-Host "Built RSDWServerKit at $Output"
