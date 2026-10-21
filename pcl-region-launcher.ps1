#requires -Version 5.1
<#
  PCL-CE region-lock bypass launcher (for 2.15.1+ with RegionPolicy)

  PCL only reads local Windows signals; no network is involved. Decision order:
    1) GetUserDefaultGeoName/GeoID == CN/45                        -> restricted
    2) HKLM DeviceRegion (region chosen at OOBE) == 45             -> restricted
    3) China time zone AND (locale or preferred UI lang is zh-CN)  -> restricted
    4) any other valid country code                                -> allowed
  This script temporarily flips those signals and restores them when PCL exits.

  Usage:
    Double-click Start-PCL-CE-Bypass.cmd
    powershell -File pcl-region-launcher.ps1 -Status
    powershell -File pcl-region-launcher.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$BackupPath = '',
    [switch]$Status,
    [switch]$Restore,
    [switch]$NoLaunch,
    [switch]$DryRun,
    [switch]$SkipDeviceRegion,
    [int]$AutoClose = 0
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Join-Path $PSScriptRoot 'pcl-region-backup.json' }

$GeoKeyPath      = 'HKCU:\Control Panel\International\Geo'
$DeviceRegionKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion'
$DeviceRegionSub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion'
$HelperPath      = Join-Path $PSScriptRoot 'pcl-region-elevated.ps1'
$SpoofGeoName    = 'US'
$SpoofGeoId      = 244
$SpoofTimeZone   = 'Singapore Standard Time'

if (-not ('PclRegionProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PclRegionProbe
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetUserDefaultGeoName(StringBuilder sb, int n);
    [DllImport("kernel32.dll")]
    private static extern int GetUserGeoID(int c);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetUserDefaultLocaleName(StringBuilder sb, int n);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetUserPreferredUILanguages(uint flags, out uint count, IntPtr buf, ref uint chars);

    public static string Probe()
    {
        var geoBuf = new StringBuilder(16);
        int geoLen = GetUserDefaultGeoName(geoBuf, 16);
        string geo = geoLen > 1 ? geoBuf.ToString(0, geoLen - 1) : "";
        int geoId = GetUserGeoID(16);
        var locBuf = new StringBuilder(85);
        int locLen = GetUserDefaultLocaleName(locBuf, 85);
        string locale = locLen > 1 ? locBuf.ToString(0, locLen - 1) : "";
        string lang = "";
        try
        {
            uint count = 0, chars = 0;
            GetUserPreferredUILanguages(8, out count, IntPtr.Zero, ref chars);
            if (chars > 0 && chars < 32768)
            {
                IntPtr buf = Marshal.AllocHGlobal((int)chars * 2);
                try
                {
                    uint written = 0;
                    if (GetUserPreferredUILanguages(8, out written, buf, ref chars) != 0)
                        lang = Marshal.PtrToStringUni(buf) ?? "";
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        catch { }
        return geo + "|" + geoId + "|" + locale + "|" + lang;
    }
}
'@
}

function Get-Signals {
    $parts = ([PclRegionProbe]::Probe()) -split '\|', 4
    $geoObj = Get-ItemProperty -Path $GeoKeyPath -ErrorAction SilentlyContinue
    $devObj = Get-ItemProperty -Path $DeviceRegionKey -ErrorAction SilentlyContinue
    [pscustomobject]@{
        GeoName      = $parts[0]
        GeoId        = [int]$parts[1]
        Locale       = $parts[2]
        FirstLang    = $parts[3]
        GeoNameReg   = if ($geoObj) { $geoObj.Name } else { $null }
        GeoNationReg = if ($geoObj) { $geoObj.Nation } else { $null }
        DeviceRegion = if ($devObj) { $devObj.DeviceRegion } else { $null }
        DeviceOk     = [bool]$devObj
        TimeZone     = (Get-TimeZone).Id
    }
}

function Test-ChinaLocale([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $normalized = $Name.Replace('_', '-')
    if ($normalized -ieq 'zh-CN') { return $true }
    return ($normalized -match '(^|-)CN$')
}

function Get-Verdict($Sig) {
    if ($Sig.GeoName -ieq 'CN' -or $Sig.GeoName -eq '156') {
        return [pscustomobject]@{ Class = 'Mainland'; Reason = 'geo-cn'; Restricted = $true }
    }
    if ($Sig.DeviceOk -and $Sig.DeviceRegion -eq 45) {
        return [pscustomobject]@{ Class = 'Mainland'; Reason = 'device-region-cn'; Restricted = $true }
    }
    $chinaTz = @('China Standard Time', 'Asia/Shanghai', 'PRC') -contains $Sig.TimeZone
    if ($chinaTz -and ((Test-ChinaLocale $Sig.Locale) -or (Test-ChinaLocale $Sig.FirstLang))) {
        return [pscustomobject]@{ Class = 'Mainland'; Reason = 'china-time-zone-and-locale'; Restricted = $true }
    }
    if ($Sig.GeoName -match '^[A-Za-z]{2}$' -and $Sig.GeoName -ine 'CN') {
        return [pscustomobject]@{ Class = 'Other'; Reason = 'geo-other'; Restricted = $false }
    }
    if (-not $Sig.GeoName -and -not $Sig.FirstLang -and -not $Sig.Locale) {
        return [pscustomobject]@{ Class = 'Unknown'; Reason = 'signals-unavailable'; Restricted = $true }
    }
    return [pscustomobject]@{ Class = 'Unknown'; Reason = 'insufficient-signals'; Restricted = $true }
}

function Show-State([string]$Title) {
    $sig = Get-Signals
    $verdict = Get-Verdict $sig
    Write-Host ''
    Write-Host ('== ' + $Title + ' ==') -ForegroundColor Cyan
    Write-Host ('  GeoName (GetUserDefaultGeoName) : ' + $sig.GeoName + '  [GeoID ' + $sig.GeoId + ']')
    Write-Host ('  User region Geo\Name/Nation    : ' + $sig.GeoNameReg + ' / ' + $sig.GeoNationReg)
    Write-Host ('  Device region (HKLM)           : ' + $(if ($sig.DeviceOk) { $sig.DeviceRegion } else { '<unreadable>' }))
    Write-Host ('  User locale                    : ' + $sig.Locale)
    Write-Host ('  Preferred UI language          : ' + $sig.FirstLang)
    Write-Host ('  Time zone                      : ' + $sig.TimeZone)
    $color = if ($verdict.Restricted) { 'Red' } else { 'Green' }
    Write-Host ('  => PCL verdict: ' + $verdict.Class + ' (' + $verdict.Reason + '), restricted=' + $verdict.Restricted) -ForegroundColor $color
    return $verdict
}

function Save-State {
    $sig = Get-Signals
    $data = [ordered]@{
        SavedAt      = (Get-Date).ToString('o')
        GeoName      = $sig.GeoNameReg
        GeoNation    = $sig.GeoNationReg
        DeviceRegion = $sig.DeviceRegion
        TimeZone     = $sig.TimeZone
    }
    ($data | ConvertTo-Json) | Set-Content -Path $BackupPath -Encoding UTF8
    Write-Host ('Original settings backed up -> ' + $BackupPath) -ForegroundColor DarkGray
}

function Restore-GeoAndTimeZone {
    if (-not (Test-Path $BackupPath)) { return }
    $backup = Get-Content -Path $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $backup.GeoName) {
        try { Set-ItemProperty -Path $GeoKeyPath -Name Name -Value ([string]$backup.GeoName) -Type String } catch { Write-Host ('Failed to restore Geo\Name: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    if ($null -ne $backup.GeoNation) {
        try { Set-ItemProperty -Path $GeoKeyPath -Name Nation -Value ([int]$backup.GeoNation) -Type DWord } catch { Write-Host ('Failed to restore Geo\Nation: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    if ($backup.TimeZone) {
        try { Set-TimeZone -Id ([string]$backup.TimeZone) } catch { Write-Host ('Failed to restore time zone: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
}

function Restore-All {
    Restore-GeoAndTimeZone
    if (Test-Path $BackupPath) { Remove-Item -Path $BackupPath -Force }
    Write-Host 'Region/time zone restored.' -ForegroundColor Green
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DeviceRegionValue {
    try { return [int](Get-ItemProperty -Path $DeviceRegionKey -ErrorAction Stop).DeviceRegion } catch { return $null }
}

function Write-DeviceRegionDirect([int]$Value) {
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($DeviceRegionSub, $true)
        if (-not $key) { return $false }
        $key.SetValue('DeviceRegion', $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Close()
        return $true
    } catch { return $false }
}

function Find-Pwsh7 {
    $candidates = New-Object System.Collections.Generic.List[string]
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }
    $candidates.Add((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))
    $profilesDir = Join-Path $env:USERPROFILE '.dsh\profiles'
    if (Test-Path $profilesDir) {
        Get-ChildItem $profilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $candidates.Add((Join-Path $_.FullName 'node_modules\@dsh-ops\pwsh-win32-x64\bin\pwsh.exe'))
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Start-DeviceRegionWorker([string]$Interpreter, [bool]$Elevate, [int]$SetValue, [int]$RestoreValue, [int]$ParentProcessId, [string]$ReadyFile, [string]$FinishFile) {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $HelperPath + '"'),
        '-SetValue', [string]$SetValue,
        '-RestoreValue', [string]$RestoreValue,
        '-ParentPid', [string]$ParentProcessId
    )
    if ($ReadyFile) { $argList += @('-ReadyFile', ('"' + $ReadyFile + '"')) }
    if ($FinishFile) { $argList += @('-FinishFile', ('"' + $FinishFile + '"')) }
    if ($Elevate) {
        Start-Process -FilePath $Interpreter -Verb RunAs -WindowStyle Hidden -ArgumentList $argList | Out-Null
    } else {
        Start-Process -FilePath $Interpreter -WindowStyle Hidden -ArgumentList $argList | Out-Null
    }
}

function Set-DeviceRegionOneShot([int]$Value) {
    if (Test-IsAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
        if (Write-DeviceRegionDirect $Value) { return $true }
    }
    $pwsh7 = Find-Pwsh7
    if ($pwsh7) {
        Start-DeviceRegionWorker -Interpreter $pwsh7 -Elevate $false -SetValue $Value -RestoreValue -1 -ParentProcessId 0 -ReadyFile ''
        Start-Sleep -Seconds 2
        return ((Get-DeviceRegionValue) -eq $Value)
    }
    try {
        Start-DeviceRegionWorker -Interpreter (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Elevate $true -SetValue $Value -RestoreValue -1 -ParentProcessId 0 -ReadyFile ''
        Start-Sleep -Seconds 2
    } catch { return $false }
    return ((Get-DeviceRegionValue) -eq $Value)
}

function Wait-ForFile([string]$Path, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Apply-DeviceRegionSpoof([int]$Original) {
    Write-Host 'Updating device region (DeviceRegion)...' -ForegroundColor Cyan
    if (Test-IsAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
        if (Write-DeviceRegionDirect $SpoofGeoId) { return $true }
    }
    $readyFile = Join-Path $env:TEMP ('pcl-region-' + $PID + '.ready')
    $script:DeviceFinishFile = Join-Path $env:TEMP ('pcl-region-' + $PID + '.finish')
    Remove-Item -Path $readyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $script:DeviceFinishFile -Force -ErrorAction SilentlyContinue
    $pwsh7 = Find-Pwsh7
    if ($pwsh7) {
        Write-Host ('Using PowerShell 7 (no UAC needed): ' + $pwsh7) -ForegroundColor DarkGray
        try {
            Start-DeviceRegionWorker -Interpreter $pwsh7 -Elevate $false -SetValue $SpoofGeoId -RestoreValue $Original -ParentProcessId $PID -ReadyFile $readyFile -FinishFile $script:DeviceFinishFile
        } catch {
            Write-Host ('Failed to start PowerShell 7: ' + $_.Exception.Message) -ForegroundColor Yellow
            return $false
        }
        return (Wait-ForFile $readyFile 30)
    }
    Write-Host 'A UAC prompt will appear; please click Yes.' -ForegroundColor Yellow
    try {
        Start-DeviceRegionWorker -Interpreter (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Elevate $true -SetValue $SpoofGeoId -RestoreValue $Original -ParentProcessId $PID -ReadyFile $readyFile
    } catch {
        Write-Host ('UAC cancelled or elevation failed: ' + $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
    Write-Host 'Approved, waiting for the write to finish...' -ForegroundColor Yellow
    return (Wait-ForFile $readyFile 60)
}

function Test-IsCeExecutable([string]$Path) {
    $fileName = [System.IO.Path]::GetFileName($Path)
    if ($fileName -like 'PCL2_CE*') { return $true }
    try {
        $versionInfo = (Get-Item -LiteralPath $Path).VersionInfo
        $text = [string]$versionInfo.ProductName + ' ' + [string]$versionInfo.FileDescription
        if ($text -match 'Community Edition') { return $true }
    } catch { }
    return $false
}

function Get-CeCandidates {
    $searchDirs = New-Object System.Collections.Generic.List[string]
    $searchDirs.Add($PSScriptRoot)
    $currentDir = (Get-Location).Path
    if ($currentDir -and $currentDir -ne $PSScriptRoot) { $searchDirs.Add($currentDir) }
    $found = @()
    foreach ($dir in $searchDirs) {
        $found += Get-ChildItem -Path $dir -Filter 'PCL2_CE*.exe' -File -ErrorAction SilentlyContinue
    }
    return @($found | Sort-Object FullName -Unique)
}

function Show-CeDownloadHint([string]$Reason = 'PCL-CE not found (PCL2_CE*.exe).') {
    $url = 'https://github.com/PCL-Community/PCL-CE/releases'
    Write-Host ''
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host ('PCL-CE releases: ' + $url) -ForegroundColor Cyan
    $answer = Read-Host 'Open the download page now? (Y/n)'
    if ($answer -notmatch '^[Nn]') {
        try { Start-Process $url } catch { Write-Host 'Failed to open the browser; please visit the URL above manually.' -ForegroundColor Yellow }
    }
}

function Select-CeExecutable {
    $candidates = Get-CeCandidates
    if ($candidates.Count -eq 0) {
        Show-CeDownloadHint
        return $null
    }
    if ($candidates.Count -eq 1) {
        return $candidates[0].FullName
    }
    Write-Host ''
    Write-Host 'Multiple PCL-CE builds found, please choose one:' -ForegroundColor Cyan
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        $item = $candidates[$index]
        Write-Host ('  [' + ($index + 1) + '] ' + $item.Name + '   version ' + $item.VersionInfo.FileVersion + '   ' + $item.DirectoryName)
    }
    while ($true) {
        $choice = Read-Host ('Enter 1-' + $candidates.Count + ' (press Enter for 1)')
        if ([string]::IsNullOrWhiteSpace($choice)) { return $candidates[0].FullName }
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
            return $candidates[$number - 1].FullName
        }
        Write-Host 'Invalid number, please try again.' -ForegroundColor Yellow
    }
}

function Complete-DeviceRegionRestore([int]$Expected) {
    if (-not $script:DeviceFinishFile) { return }
    New-Item -ItemType File -Path $script:DeviceFinishFile -Force | Out-Null
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if ((Get-DeviceRegionValue) -eq $Expected) { break }
        Start-Sleep -Milliseconds 200
    }
    Remove-Item -Path $script:DeviceFinishFile -Force -ErrorAction SilentlyContinue
}

if ($Restore) {
    $backup = $null
    if (Test-Path $BackupPath) { $backup = Get-Content -Path $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    Restore-GeoAndTimeZone
    if ($backup -and $null -ne $backup.DeviceRegion) {
        $currentDevice = Get-DeviceRegionValue
        if ($currentDevice -ne [int]$backup.DeviceRegion) {
            $written = Set-DeviceRegionOneShot ([int]$backup.DeviceRegion)
            if (-not $written) { Write-Host 'Failed to restore DeviceRegion; run -Restore as administrator.' -ForegroundColor Yellow }
        }
    }
    if (Test-Path $BackupPath) { Remove-Item -Path $BackupPath -Force }
    Write-Host 'Restore complete.' -ForegroundColor Green
    Show-State 'Current state' | Out-Null
    exit 0
}

if ($Status) { Show-State 'Current state' | Out-Null; exit 0 }

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Select-CeExecutable
    if (-not $ExePath) { exit 1 }
} else {
    if (-not (Test-Path -LiteralPath $ExePath)) {
        Write-Host ('PCL not found: ' + $ExePath) -ForegroundColor Red
        exit 1
    }
    if (-not (Test-IsCeExecutable $ExePath)) {
        Write-Host ('Not PCL-CE: ' + $ExePath) -ForegroundColor Yellow
        Show-CeDownloadHint 'This executable is not PCL-CE; its download feature may be disabled upstream.'
        $answer = Read-Host 'Launch it anyway? (y/N)'
        if ($answer -notmatch '^[Yy]') { exit 1 }
    }
}

if ($DryRun) {
    Write-Host ('Using: ' + $ExePath) -ForegroundColor Cyan
    exit 0
}

if (Test-Path $BackupPath) {
    Write-Host 'Found an unrestored backup (previous crash?); restoring it first...' -ForegroundColor Yellow
    Restore-GeoAndTimeZone
    Remove-Item -Path $BackupPath -Force
}

Show-State 'Before spoofing' | Out-Null
Save-State

$originalDevice = Get-DeviceRegionValue
$deviceReady = $true

try {
    Set-ItemProperty -Path $GeoKeyPath -Name Name   -Value $SpoofGeoName -Type String
    Set-ItemProperty -Path $GeoKeyPath -Name Nation -Value $SpoofGeoId   -Type DWord
    Set-TimeZone -Id $SpoofTimeZone
} catch {
    Write-Host ('Failed to update HKCU/time zone: ' + $_.Exception.Message) -ForegroundColor Red
    Restore-All
    exit 1
}

if (-not $SkipDeviceRegion -and $originalDevice -eq 45) {
    $deviceReady = Apply-DeviceRegionSpoof $originalDevice
} elseif ($SkipDeviceRegion) {
    Write-Host 'DeviceRegion update skipped (debug mode; may still be restricted)' -ForegroundColor DarkGray
}

if (-not $deviceReady) {
    Write-Host 'Could not update the device region; PCL would still be restricted. Aborted.' -ForegroundColor Red
    Restore-All
    exit 1
}

$verdict = Show-State 'After spoofing'
if ($verdict.Restricted -and -not $SkipDeviceRegion) {
    Write-Host 'Spoofing incomplete, launch aborted.' -ForegroundColor Red
    Restore-All
    exit 1
}

if ($NoLaunch) {
    Write-Host ''
    Write-Host 'Test mode only: restoring in 3 seconds...' -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
    Restore-All
    Complete-DeviceRegionRestore $originalDevice
    Show-State 'After restore' | Out-Null
    exit 0
}

Write-Host ''
$processName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
$existing = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
try {
    if ($existing.Count -gt 0) {
        Write-Host 'PCL is already running; reusing that window. Settings are restored after it closes.' -ForegroundColor Yellow
        $pclProcess = $existing[0]
    } else {
        Write-Host ('Starting PCL: ' + $ExePath) -ForegroundColor Cyan
        $pclProcess = Start-Process -FilePath $ExePath -PassThru
    }
    if ($AutoClose -gt 0) {
        Start-Sleep -Seconds $AutoClose
        if (-not $pclProcess.HasExited) { try { $null = $pclProcess.CloseMainWindow() } catch { } }
        if (-not $pclProcess.WaitForExit(15000)) { Stop-Process -Id $pclProcess.Id -Force -ErrorAction SilentlyContinue }
    } else {
        $pclProcess.WaitForExit()
    }
}
finally {
    Write-Host ''
    Write-Host 'PCL exited, restoring settings...' -ForegroundColor Cyan
    Restore-All
    Complete-DeviceRegionRestore $originalDevice
}