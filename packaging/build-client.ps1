param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$Output = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'dist\RSDWClientKit')
)

$ErrorActionPreference = 'Stop'

if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
New-Item -ItemType Directory -Path $Output | Out-Null

# Compatibility baseline: start from the existing working Windows client kit.
Copy-Item (Join-Path $Root 'dwmapi.dll') $Output -Force
if (Test-Path (Join-Path $Root 'RSDWTools_Installer.exe')) {
    Copy-Item (Join-Path $Root 'RSDWTools_Installer.exe') $Output -Force
}
Copy-Item (Join-Path $Root 'ue4ss') (Join-Path $Output 'ue4ss') -Recurse -Force

$mods = Join-Path $Output 'ue4ss\Mods'

# Overlay the new client-only runtime.
$clientDst = Join-Path $mods 'RSDWClient'
New-Item -ItemType Directory -Path $clientDst -Force | Out-Null
Copy-Item (Join-Path $Root 'client\RSDWClient\*') $clientDst -Recurse -Force

# Client package must never contain the dedicated-server runtime.
$serverDst = Join-Path $mods 'RSDWServer'
if (Test-Path $serverDst) { Remove-Item $serverDst -Recurse -Force }

Write-Host "Built RSDWClientKit at $Output"
