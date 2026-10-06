# NVIDIA-Driver-AutoUpdate

A PowerShell script that detects the NVIDIA GPU in a Windows device, finds the latest driver at NVIDIA and installs it unattended. Run it by hand, from a scheduled task or from any deployment tool. Example scripts for deploying it with Microsoft Intune are included.

Based on [jakelmg/NVIDIA-Driver-Downloader](https://github.com/jakelmg/NVIDIA-Driver-Downloader) (MIT), reworked for unattended use.

## Scripts

| Script | Purpose |
| --- | --- |
| [`scripts/Update-NVIDIADriver.ps1`](scripts/Update-NVIDIADriver.ps1) | The main script. Finds the GPU, looks up the latest driver at NVIDIA, downloads, verifies and installs it. |
| [`intune/Detect-NVIDIADriver.ps1`](intune/Detect-NVIDIADriver.ps1) | Optional, Intune example. Detection rule: not detected (exit 1) when a newer driver exists or the lookup fails. |
| [`intune/Requirement-NVIDIAGPU.ps1`](intune/Requirement-NVIDIAGPU.ps1) | Optional, Intune example. Requirement rule: returns the number of NVIDIA GPUs. |

## What the update script does

- Detects the GPU by PCI vendor ID (`10DE`), not by display name.
- Maps the Windows GPU name to NVIDIA's product list (handles "Generation" naming, keeps laptop and desktop variants apart).
- Never downgrades and never reinstalls the same version.
- Downloads with resume, retries, mirror failover and a stall timeout (suited for slow links).
- Validates the NVIDIA Authenticode signature before running the package.
- Installs silently (`-s -noreboot`, optional `-clean`) and verifies exit code and resulting driver version.
- Logs to `%ProgramData%\NVIDIA-DriverAutoUpdate\Logs\NVIDIA-Driver.log` (rotates at 5 MB). Use `-IntuneLog` for the Intune Management Extension log folder or `-LogPath` for any folder.
- Exit codes: `0` success/compliant, `1` error, `3010` success, reboot required.

### Parameters

| Parameter | Description |
| --- | --- |
| `-CheckOnly` | Only report the current and the latest available version. Nothing is downloaded or installed. The script does not require administrator rights for this mode. |
| `-Clean` | Adds NVIDIA's `-clean` switch, so the installer does a clean installation (the same as ticking "Perform a clean installation" in the setup): previous driver files and NVIDIA settings are removed and reset to defaults. **Without `-Clean` the script runs a normal silent upgrade** (`-s -noreboot`) that keeps your existing settings. Only used when an update is actually needed. |
| `-IntuneLog` | Log to the Intune Management Extension log folder instead of the default. |
| `-LogPath <folder>` | Log to a custom folder. |
| `-ProductSeriesId <n>` and `-ProductId <n>` | NVIDIA's numeric IDs for your GPU (`psid` and `pfid`). Always use both together. They skip the automatic name matching, which is useful when the GPU name cannot be matched to exactly one product. See [Finding the product IDs](#finding-the-product-ids). |
| `-DriverPath <file>` and `-TargetVersion <version>` | Install a driver package you already downloaded instead of downloading one. `-TargetVersion` is the version of that package (format `596.58`) and is required, because the script compares it with the installed version before installing. The signature is still checked and the file is not deleted afterwards. |
| `-DownloadTimeoutMinutes <n>` | Total download time limit including retries. Default 90. |
| `-StallTimeoutSeconds <n>` | Retry when no data arrives for this long. Default 120. |

### Examples

Check what would happen (safe, nothing changes):

```powershell
.\scripts\Update-NVIDIADriver.ps1 -CheckOnly
```

Install the latest driver (elevated PowerShell):

```powershell
.\scripts\Update-NVIDIADriver.ps1
```

Clean install:

```powershell
.\scripts\Update-NVIDIADriver.ps1 -Clean
```

The GPU name cannot be matched, so supply the IDs yourself:

```powershell
.\scripts\Update-NVIDIADriver.ps1 -ProductSeriesId 127 -ProductId 1000
```

Use a package you downloaded earlier (for example on a slow or offline device):

```powershell
.\scripts\Update-NVIDIADriver.ps1 -DriverPath "C:\Temp\596.58-desktop-win10-win11-64bit-international-dch-whql.exe" -TargetVersion 596.58
```

Log to the Intune folder, or to a folder of your choice:

```powershell
.\scripts\Update-NVIDIADriver.ps1 -IntuneLog
.\scripts\Update-NVIDIADriver.ps1 -LogPath "D:\Logs"
```

The numbers in the examples are placeholders. Use your own values.

### Finding the product IDs

1. Run `.\scripts\Update-NVIDIADriver.ps1 -CheckOnly`.
2. Open the log (default `C:\ProgramData\NVIDIA-DriverAutoUpdate\Logs\NVIDIA-Driver.log`).
3. Look for the line `Lookup match: <name>; psid: <number>; pfid: <number>`. Those are the values.

If the script reports `Found N unique NVIDIA lookup matches`, the error lists the candidates as `name [psid/pfid]`. Pick the one that matches your GPU and pass its two numbers as `-ProductSeriesId` and `-ProductId`.

You can also look the IDs up manually on [nvidia.com/Download](https://www.nvidia.com/Download/index.aspx).

## Intune example

See [intune/README.md](intune/README.md) for deploying this as a Win32 app with detection and requirement rules.

## Notes

- Windows 10/11, 64-bit only. Single NVIDIA GPU per device is in scope.
- Scripts are unsigned in this repository. Sign them with your own code-signing certificate if your execution policy requires it.
- Provided as is, test on a pilot group first.

## License

MIT. See [LICENSE](LICENSE). Original work copyright (c) 2022 Dmitry Nefedov.
