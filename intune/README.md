# Intune example (Win32 app)

This is one way to use the update script. The three scripts work together as one Win32 app.

## 1. Package

Create an `.intunewin` with the [Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):

1. Copy `scripts/Update-NVIDIADriver.ps1` to a source folder.
2. Run `IntuneWinAppUtil.exe -c <source folder> -s Update-NVIDIADriver.ps1 -o <output folder>`.

The detection and requirement scripts are uploaded separately in the portal, not in the package.

## 2. App information

Intune admin center → Apps → Windows → Add → **Windows app (Win32)**. Upload the `.intunewin`; name and publisher are free to choose (for example "NVIDIA GPU Driver Updater").

## 3. Program

| Setting | Value |
| --- | --- |
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-NVIDIADriver.ps1 -IntuneLog` |
| Uninstall command | `cmd /c exit 0` (the app is an updater, there is nothing to uninstall) |
| Installation time required | `120` minutes (large download and install) |
| Install behavior | System |
| Device restart behavior | Determine behavior based on return codes |

Return codes: keep the defaults (`0` success, `3010` soft reboot, `1` failed). Add `1618` retry if you like.

`-IntuneLog` writes the log to the Intune Management Extension log folder. Add `-Clean` for a clean install.

## 4. Requirements

| Setting | Value |
| --- | --- |
| OS architecture | 64-bit |
| Minimum OS | Windows 10 1607 or newer |

**Additional requirement rule** (type: Script):

| Setting | Value |
| --- | --- |
| Script file | `Requirement-NVIDIAGPU.ps1` |
| Run script as 32-bit process | No |
| Enforce script signature check | No (unless you sign the scripts) |
| Output data type | Integer |
| Operator | Equals |
| Value | `1` |

Devices with zero or multiple NVIDIA GPUs are skipped and show as **Not applicable**.

> Intune evaluates the detection rule before the requirement rule, and a detected app is reported as Installed. The detection script therefore reports "not detected" on devices without exactly one NVIDIA GPU, so the requirement rule can mark them Not applicable. Without the requirement rule those devices would run the install, which fails with "No NVIDIA GPU detected."

## 5. Detection rule

Rules format: **Use a custom detection script**, file `Detect-NVIDIADriver.ps1`.

| Setting | Value |
| --- | --- |
| Run script as 32-bit process | No |
| Enforce script signature check | No (unless you sign the scripts) |

Behavior:

- Exit 0 + output: the driver is current. This is the only "detected" case.
- Exit 1, no output: a newer driver exists, or the lookup failed (offline, NVIDIA API change, unmatched GPU name). Intune then runs the install command. When the lookup is broken the install fails too and logs the cause, so a broken link or download mechanism stays visible. The reason is written to STDERR. Offline devices therefore report a failed install until they reconnect.

## 6. Assignment

Assign as **Required** to a device group. Start with a pilot group. Intune re-evaluates detection regularly, so new NVIDIA releases are picked up automatically.

## Troubleshooting

- Log: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\NVIDIA-Driver.log` (with `-IntuneLog`; default is `C:\ProgramData\NVIDIA-DriverAutoUpdate\Logs`)
- Dry run on a device: `.\Update-NVIDIADriver.ps1 -CheckOnly`
- "Found N lookup matches": the GPU name did not map to exactly one NVIDIA product. Pass `-ProductSeriesId` and `-ProductId` (see the log for the candidate list).
- Partial downloads are kept in `C:\ProgramData\NVIDIA-DriverAutoUpdate\Cache` and resumed on the next run.
