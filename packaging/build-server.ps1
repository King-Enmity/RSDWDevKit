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

# Temporary compatibility copy: RSDWServer currently reuses shared Lua modules
# from the legacy RSDWTools package (notably feature_net). Remove client-only
# assets immediately after copying.
$legacySrc = Join-Path $Root 'ue4ss\Mods\RSDWTools'
$legacyDst = Join-Path $modsOut 'RSDWToolsShared'
if (Test-Path $legacySrc) {
    Copy-Item $legacySrc $legacyDst -Recurse -Force
    foreach ($name in @('RSDWTools.exe', 'web')) {
        $p = Join-Path $legacyDst $name
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
}

# Add the dedicated server runtime.
$serverDst = Join-Path $modsOut 'RSDWServer'
New-Item -ItemType Directory -Path $serverDst -Force | Out-Null
Copy-Item (Join-Path $Root 'server\RSDWServer\*') $serverDst -Recurse -Force

# Explicitly excluded client-only mods/binaries:
# ConsoleEnablerMod, CheatManagerEnablerMod, ConsoleCommandsMod,
# RSDWTools.exe, RSDWTools_Installer.exe, UMG/hotkey/camera UI package pieces.

@(
    'BPML_GenericFunctions : 1',
    'BPModLoaderMod : 1',
    'RSDWToolsShared : 1',
    'RSDWServer : 1'
) | Set-Content (Join-Path $modsOut 'mods.txt') -Encoding ASCII

Write-Host "Built RSDWServerKit at $Output"
