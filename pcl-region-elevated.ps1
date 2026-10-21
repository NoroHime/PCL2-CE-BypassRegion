#requires -Version 5.1
# Region helper: writes HKLM\...\DeviceRegion, restores it after the parent exits or a finish signal.
param(
    [int]$SetValue = -1,
    [int]$RestoreValue = -1,
    [int]$ParentPid = 0,
    [string]$ReadyFile = '',
    [string]$FinishFile = ''
)

$ErrorActionPreference = 'Stop'
$subKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion'

function Write-DeviceRegion([int]$Value) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subKey, $true)
    if (-not $key) { throw 'Cannot open the DeviceRegion registry key' }
    $key.SetValue('DeviceRegion', $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.Close()
}

Write-DeviceRegion $SetValue
if ($ReadyFile) { New-Item -ItemType File -Path $ReadyFile -Force | Out-Null }

if ($ParentPid -gt 0 -and $RestoreValue -ge 0) {
    while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
        if ($FinishFile -and (Test-Path $FinishFile)) { break }
        Start-Sleep -Milliseconds 400
    }
    Write-DeviceRegion $RestoreValue
    if ($ReadyFile) { Remove-Item -Path $ReadyFile -Force -ErrorAction SilentlyContinue }
}