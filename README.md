# PCL2-CE BypassRegion

A tiny PowerShell wrapper that lets **PCL-CE** download / install / repair Minecraft in regions where the launcher refuses to.

No patching, no modified binaries. It just flips a few local Windows signals before PCL starts, and puts them back when PCL exits.

## Why a proxy does not help

PCL-CE decides entirely on local signals - there is no network call involved:

| Signal | Where it comes from | Value that gets blocked |
| --- | --- | --- |
| Geo name / Geo ID | `GetUserDefaultGeoName` / `GetUserGeoID` | `CN` / `45` |
| Device region | `HKLM\...\Control Panel\DeviceRegion` | `45` |
| Time zone | `TimeZoneInfo.Local` | `China Standard Time` |
| Locale / UI language | `GetUserDefaultLocaleName` / `GetUserPreferredUILanguages` | `zh-CN` |

So VPNs, proxies and DNS tricks do nothing here. The check runs before any download starts.

## What it changes (and restores)

| Key | Temporary value |
| --- | --- |
| `HKCU\Control Panel\International\Geo\Name` | `US` |
| `HKCU\Control Panel\International\Geo\Nation` | `244` |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion` | `244` |
| Time zone | `Singapore Standard Time` (UTC+8, clock does not move) |

Everything is backed up to `pcl-region-backup.json` and restored automatically. If the script is killed, just run it again (or `-Restore`) and it will clean up.

## Requirements

- Windows 10/11
- PowerShell 5.1 (ships with Windows)
- PCL-CE, i.e. a `PCL2_CE*.exe`
- Optional: PowerShell 7 (`pwsh`) - used to write the device region **without a UAC prompt**. Without it the script asks for elevation instead.

## Usage

```text
Start-PCL-CE-Bypass.cmd
```

or

```powershell
powershell -File pcl-region-launcher.ps1            # spoof, launch PCL, restore on exit
powershell -File pcl-region-launcher.ps1 -Status    # show current signals + verdict
powershell -File pcl-region-launcher.ps1 -Restore   # manual restore after a crash
powershell -File pcl-region-launcher.ps1 -DryRun    # only resolve which exe would be used
```

The launcher auto-discovers `PCL2_CE*.exe` next to the script (and in the current folder):

- one match -> used directly
- several matches -> you pick one from a menu
- none -> it offers to open https://github.com/PCL-Community/PCL-CE/releases

If you pass `-ExePath` pointing at a non-CE executable, it warns you first, because the upstream PCL2 has its download page hard-disabled.

## Files

| File | Purpose |
| --- | --- |
| `pcl-region-launcher.ps1` | backup -> spoof -> launch -> restore |
| `pcl-region-elevated.ps1` | helper that writes `DeviceRegion` and restores it later |
| `Start-PCL-CE-Bypass.cmd` | double-click entry point |

## Notes

- While PCL is running, your Windows "country or region" reads United States and the time zone name is Singapore. Same UTC+8, so the clock does not change. A few apps (Store, etc.) may notice.
- This only changes what the launcher sees. It does not provide game files, accounts or licenses.
- The upstream block exists for a reason (account bans around Minecraft in mainland China). Use at your own risk.
- Tested with PCL-CE 2.15.1 (build 524, commit `1a76531`).
