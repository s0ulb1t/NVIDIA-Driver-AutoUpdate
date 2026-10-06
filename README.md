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
| `-CheckOnly` | Only report current and available version. Nothing is installed. |
| `-Clean` | Clean install (`-clean`), only when an update is needed. |
| `-IntuneLog` | Log to the Intune Management Extension log folder. |
| `-LogPath` | Log to a custom folder. |
| `-ProductSeriesId` / `-ProductId` | Fixed NVIDIA psid/pfid. Must be used together. Skips name matching. |
| `-DriverPath` + `-TargetVersion` | Use a local package (e.g. `596.58`) instead of downloading. |
| `-DownloadTimeoutMinutes` | Total download time limit including retries. Default 90. |
| `-StallTimeoutSeconds` | Retry when no data arrives for this long. Default 120. |

Test locally (elevated PowerShell):

```powershell
.\scripts\Update-NVIDIADriver.ps1 -CheckOnly
```

## Intune example

See [intune/README.md](intune/README.md) for deploying this as a Win32 app with detection and requirement rules.

## Notes

- Windows 10/11, 64-bit only. Single NVIDIA GPU per device is in scope.
- Scripts are unsigned in this repository. Sign them with your own code-signing certificate if your execution policy requires it.
- Provided as is, test on a pilot group first.

## License

MIT. See [LICENSE](LICENSE). Original work copyright (c) 2022 Dmitry Nefedov.
