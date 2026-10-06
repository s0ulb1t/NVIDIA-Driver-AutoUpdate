<#
.SYNOPSIS
    Checks for and installs the latest NVIDIA driver for the single NVIDIA GPU in this device.

.DESCRIPTION
    Designed for unattended use (scheduled task, RMM/deployment tool, Intune or manual, SYSTEM or administrator, 64-bit PowerShell).
    - Logs to a dedicated file (default C:\ProgramData\NVIDIA-DriverAutoUpdate\Logs, or the Intune IME log folder with -IntuneLog).
    - Detects the GPU via PCI vendor ID 10DE.
    - Maps the Windows GPU name to NVIDIA's product lookup list (handles "Generation" naming differences
      and keeps laptop and desktop variants apart).
    - Never downgrades. Validates the NVIDIA Authenticode signature before execution.
    - Runs the signed NVIDIA package directly. The package is self-extracting, no extra tooling needed.
    - Verifies the installer exit code and the installed driver version afterwards.

.PARAMETER CheckOnly
    Only report current and available versions. Nothing is downloaded or installed.

.PARAMETER Clean
    Request a clean install (-clean). Only used when an update is actually needed.

.PARAMETER IntuneLog
    Write the log to the Intune Management Extension log folder instead of the default location.

.PARAMETER LogPath
    Optional custom log folder. Overrides the default and -IntuneLog.

.PARAMETER ProductSeriesId
    Optional NVIDIA psid (ParentID). Must be combined with ProductId.

.PARAMETER ProductId
    Optional NVIDIA pfid (Value). Must be combined with ProductSeriesId.

.PARAMETER DriverPath
    Optional local driver package. Skips the online lookup. Requires TargetVersion.

.PARAMETER TargetVersion
    Driver version of the local package, for example 596.58.

.PARAMETER DownloadTimeoutMinutes
    Maximum total time for the driver download, including retries. Default 90.

.PARAMETER StallTimeoutSeconds
    Abort and retry a download attempt when no data is received for this many seconds. Default 120.

.NOTES
    Exit codes: 0 = success / compliant / check finished, 1 = error, 3010 = success, reboot required.
#>
[CmdletBinding()]
param (
    [switch]$CheckOnly,
    [switch]$Clean,
    [switch]$IntuneLog,
    [string]$LogPath,
    [int]$ProductSeriesId,
    [int]$ProductId,
    [string]$DriverPath,
    [string]$TargetVersion,
    [ValidateRange(5, 600)][int]$DownloadTimeoutMinutes = 90,
    [ValidateRange(30, 900)][int]$StallTimeoutSeconds = 120
)

# Relaunch in 64-bit PowerShell when started from a 32-bit host (for example the IME agent).
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $PowerShell64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($Parameter in $PSBoundParameters.GetEnumerator()) {
        if ($Parameter.Value -is [switch]) {
            if ($Parameter.Value.IsPresent) { $Arguments += "-$($Parameter.Key)" }
        }
        else {
            $Arguments += "-$($Parameter.Key)"
            $Arguments += "`"$($Parameter.Value)`""
        }
    }
    $Relaunch = Start-Process -FilePath $PowerShell64 -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    exit $Relaunch.ExitCode
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region Logging
$WorkRoot = Join-Path $env:ProgramData 'NVIDIA-DriverAutoUpdate'
$LogDirectory = if ($LogPath) { $LogPath }
    elseif ($IntuneLog) { Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs' }
    else { Join-Path $WorkRoot 'Logs' }
$LogFile = Join-Path $LogDirectory 'NVIDIA-Driver.log'
$RunId = [guid]::NewGuid().ToString('N')

New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

# Rotate the log when it exceeds 5 MB.
if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -ge 5MB) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
}

function Write-Log {
    param (
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $Line = '{0} [{1}] [PID:{2}] [Run:{3}] {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $PID, $RunId, $Message
    Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
    Write-Host $Line
}
#endregion

#region Helpers
function Get-NvidiaGpu {
    # Use the PCI vendor ID instead of the display name.
    $Gpus = @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' })

    if ($Gpus.Count -eq 0) { throw 'No NVIDIA GPU detected.' }
    if ($Gpus.Count -gt 1) { throw "Multiple NVIDIA GPUs detected ($($Gpus.Name -join ', ')). Supply ProductSeriesId and ProductId." }

    return $Gpus[0]
}

function ConvertTo-NvidiaVersion {
    # Convert a Windows driver version (32.0.15.9658) to the NVIDIA public version (596.58).
    param ([Parameter(Mandatory)][string]$WindowsVersion)

    $Version = [version]$WindowsVersion
    $Digits = '{0}{1:D4}' -f $Version.Build, $Version.Revision
    if ($Digits.Length -lt 5) { throw "Unexpected NVIDIA driver version format: $WindowsVersion" }

    $Digits = $Digits.Substring($Digits.Length - 5)
    return $Digits.Insert(3, '.')
}

function Get-NameCandidates {
    # Build normalized name variants. Laptop designation is always preserved.
    param ([Parameter(Mandatory)][string]$Name)

    $Base = ($Name -replace '\s+', ' ').Trim()
    $NoGeneration = ($Base -replace '\s+Generation\b', '').Trim()

    $Candidates = foreach ($Item in @($Base, $NoGeneration)) {
        $Item
        ($Item -replace '^NVIDIA\s+', '').Trim()
        if ($Item -notmatch '^NVIDIA\s') { "NVIDIA $Item" }
    }

    return @($Candidates | Select-Object -Unique)
}

function Resolve-NvidiaProduct {
    param ([Parameter(Mandatory)][string]$GpuName)

    Write-Log 'Retrieving NVIDIA product lookup data.'
    $Response = Invoke-WebRequest -Uri 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3' -UseBasicParsing -TimeoutSec 300
    [xml]$Xml = $Response.Content

    $Products = @(
        foreach ($Node in $Xml.SelectNodes("//*[local-name()='LookupValue']")) {
            [pscustomobject]@{
                Name     = ([string]$Node.Name -replace '\s+', ' ').Trim()
                ParentID = [int]$Node.ParentID
                Value    = [int]$Node.Value
            }
        }
    )
    if ($Products.Count -eq 0) { throw 'NVIDIA lookup returned no product entries.' }
    Write-Log "Lookup entries received: $($Products.Count)"

    $Candidates = Get-NameCandidates -Name $GpuName
    Write-Log "Name candidates: $($Candidates -join ' | ')"

    $IsLaptop = $GpuName -match '\bLaptop\b'

    $Hits = @(
        $Products |
            Where-Object { $Candidates -contains $_.Name } |
            Where-Object { ($_.Name -match '\bLaptop\b') -eq $IsLaptop } |
            Sort-Object -Property ParentID, Value -Unique
    )

    if ($Hits.Count -ne 1) {
        $Found = ($Hits | ForEach-Object { "$($_.Name) [$($_.ParentID)/$($_.Value)]" }) -join '; '
        throw "Found $($Hits.Count) unique NVIDIA lookup matches for '$GpuName'. $Found Supply validated ProductSeriesId and ProductId values."
    }

    Write-Log "Lookup match: $($Hits[0].Name); psid: $($Hits[0].ParentID); pfid: $($Hits[0].Value)"
    return $Hits[0]
}

function Get-NvidiaDownload {
    param (
        [Parameter(Mandatory)][int]$SeriesId,
        [Parameter(Mandatory)][int]$GpuId,
        [Parameter(Mandatory)][int]$OsId
    )

    $Uri = "https://www.nvidia.com/Download/processDriver.aspx?psid=$SeriesId&pfid=$GpuId&osid=$OsId&dtcid=1&dtid=1"
    Write-Log "Querying driver: $Uri"
    $Result = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 300).Content.Trim()

    # NVIDIA returns either the legacy 'driverResults.aspx/<id>/' or the newer '/drivers/details/<id>/' format.
    if ($Result -notmatch '(?:driverResults\.aspx|/drivers/details)/(\d+)') { throw "Unexpected processDriver response: $Result" }
    $DownloadId = $Matches[1]

    $AjaxUri = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=GetDownloadDetails&downloadID=$DownloadId"
    $Json = Invoke-RestMethod -Uri $AjaxUri -Method Get -TimeoutSec 300

    $Info = $Json.IDS[0].downloadInfo
    if (-not $Info.DownloadURL) { throw "No download URL returned for download ID $DownloadId." }

    $Url = [uri]::UnescapeDataString([string]$Info.DownloadURL)
    $Version = [string]$Info.Version
    if ($Version -notmatch '^\d{3}\.\d{2}$') {
        if ($Url -match '/(\d{3}\.\d{2})/') { $Version = $Matches[1] } else { throw "Unable to determine target version from $Url" }
    }

    return [pscustomobject]@{ Url = $Url; Version = $Version; DownloadId = $DownloadId }
}

function Save-NvidiaPackage {
    # Resumable download with retries and mirror failover. Designed for slow or unstable links.
    param (
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int]$TimeoutMinutes = 90,
        [int]$StallSeconds = 120
    )

    $SourceUri = [uri]$Url
    $Mirrors = @($SourceUri.Host, 'cn.download.nvidia.com', 'international.download.nvidia.com', 'us.download.nvidia.com') |
        Select-Object -Unique
    $PartFile = "$Destination.part"
    $Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $Attempt = 0

    while ($true) {
        foreach ($Mirror in $Mirrors) {
            if ((Get-Date) -gt $Deadline) {
                throw "Download did not complete within $TimeoutMinutes minutes. Partial file kept for resume: $PartFile"
            }

            $Attempt++
            $Builder = New-Object System.UriBuilder $SourceUri
            $Builder.Host = $Mirror
            $MirrorUrl = $Builder.Uri.AbsoluteUri

            $Existing = if (Test-Path -LiteralPath $PartFile) { (Get-Item -LiteralPath $PartFile).Length } else { 0 }
            $Response = $null
            $Stream = $null
            $File = $null

            try {
                $Request = [Net.HttpWebRequest]::Create($MirrorUrl)
                $Request.Timeout = $StallSeconds * 1000
                $Request.ReadWriteTimeout = $StallSeconds * 1000
                $Request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
                if ($Existing -gt 0) { $Request.AddRange([long]$Existing) }

                Write-Log "Download attempt $Attempt via $Mirror (resume from $([math]::Round($Existing / 1MB, 1)) MB)."
                $Response = $Request.GetResponse()

                # Server ignored the range request: start over.
                if ($Existing -gt 0 -and $Response.StatusCode -ne [Net.HttpStatusCode]::PartialContent) {
                    Write-Log 'Server does not support resume. Restarting download.' -Level WARN
                    $Existing = 0
                }

                $Total = $Existing + $Response.ContentLength
                $Mode = if ($Existing -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }

                $Stream = $Response.GetResponseStream()
                $File = [IO.File]::Open($PartFile, $Mode, [IO.FileAccess]::Write, [IO.FileShare]::None)

                $Buffer = New-Object byte[] (1MB)
                $Written = $Existing
                $NextLog = [math]::Floor($Written / $Total * 10) * 10 + 10
                $Started = Get-Date

                while (($Read = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                    $File.Write($Buffer, 0, $Read)
                    $Written += $Read

                    $Percent = [math]::Floor($Written / $Total * 100)
                    if ($Percent -ge $NextLog) {
                        $Seconds = [math]::Max(1, ((Get-Date) - $Started).TotalSeconds)
                        $Speed = [math]::Round(($Written - $Existing) / 1MB / $Seconds, 2)
                        Write-Log "Download $Percent% ($([math]::Round($Written / 1MB, 1)) of $([math]::Round($Total / 1MB, 1)) MB, $Speed MB/s)."
                        $NextLog += 10
                    }

                    if ((Get-Date) -gt $Deadline) {
                        throw "Download did not complete within $TimeoutMinutes minutes."
                    }
                }

                $File.Close(); $File = $null

                $Size = (Get-Item -LiteralPath $PartFile).Length
                if ($Size -ne $Total) { throw "Incomplete download: $Size of $Total bytes." }

                if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
                Move-Item -LiteralPath $PartFile -Destination $Destination
                Write-Log "Download complete: $([math]::Round($Size / 1MB, 1)) MB via $Mirror."
                return
            }
            catch {
                if ($_.Exception.Message -like 'Download did not complete*') { throw }

                # Unwrap to the underlying WebException to read the HTTP status code.
                $WebError = $_.Exception
                while ($WebError -and $WebError -isnot [Net.WebException]) { $WebError = $WebError.InnerException }
                $Status = if ($WebError -and $WebError.Response) { [int]$WebError.Response.StatusCode } else { 0 }

                if ($Status -eq 416) {
                    # Requested range not satisfiable: the partial file is invalid. Start over.
                    Write-Log 'Partial file rejected by server (HTTP 416). Restarting download.' -Level WARN
                    Remove-Item -LiteralPath $PartFile -Force -ErrorAction SilentlyContinue
                }
                else {
                    Write-Log "Attempt $Attempt via $Mirror failed: $($_.Exception.Message)" -Level WARN
                }
            }
            finally {
                if ($File) { $File.Dispose() }
                if ($Stream) { $Stream.Dispose() }
                if ($Response) { $Response.Close() }
            }

            Start-Sleep -Seconds 15
        }
    }
}

function Assert-NvidiaSignature {
    param ([Parameter(Mandatory)][string]$Path)

    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid') { throw "Invalid signature on ${Path}: $($Signature.Status)" }
    if ($Signature.SignerCertificate.Subject -notmatch 'O=NVIDIA Corporation') {
        throw "Unexpected signer on ${Path}: $($Signature.SignerCertificate.Subject)"
    }
    Write-Log "Signature valid: $($Signature.SignerCertificate.Subject)"
}
#endregion

#region Main
$ExitCode = 0

try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Log 'Starting NVIDIA driver update.'
    Write-Log "Identity: $Identity; Log: $LogFile; PowerShell: $($PSVersionTable.PSVersion); 64-bit process: $([Environment]::Is64BitProcess); CheckOnly: $CheckOnly; Clean: $Clean"

    # Validate parameter combinations.
    if ([bool]$ProductSeriesId -xor [bool]$ProductId) { throw 'ProductSeriesId and ProductId must be supplied together.' }
    if ($DriverPath -and -not $TargetVersion) { throw 'DriverPath requires TargetVersion.' }
    if ($TargetVersion -and $TargetVersion -notmatch '^\d{3}\.\d{2}$') { throw "TargetVersion must look like 596.58, got '$TargetVersion'." }

    # OS checks.
    $Os = Get-CimInstance -ClassName Win32_OperatingSystem
    $Build = [Environment]::OSVersion.Version.Build
    Write-Log "OS: $($Os.Caption); build: $Build"
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit OS is required.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Run this script in 64-bit PowerShell.' }
    if ($Build -lt 10240) { throw 'Windows 10 or later is required.' }

    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $CheckOnly -and -not $IsAdmin) { throw 'Administrator or SYSTEM rights are required to install.' }

    # GPU and current version.
    $Gpu = Get-NvidiaGpu
    $CurrentVersion = ConvertTo-NvidiaVersion -WindowsVersion $Gpu.DriverVersion
    Write-Log "GPU: $($Gpu.Name); device ID: $($Gpu.PNPDeviceID)"
    Write-Log "Current NVIDIA driver: $CurrentVersion; Windows version: $($Gpu.DriverVersion)"

    # Determine target package.
    if ($DriverPath) {
        $DriverPath = (Resolve-Path -LiteralPath $DriverPath).Path
        $Target = [pscustomobject]@{ Url = $null; Version = $TargetVersion }
        Write-Log "Using local package: $DriverPath; target version: $TargetVersion"
    }
    else {
        if (-not $ProductSeriesId) {
            $Product = Resolve-NvidiaProduct -GpuName $Gpu.Name
            $ProductSeriesId = $Product.ParentID
            $ProductId = $Product.Value
        }
        else {
            Write-Log "Using supplied psid: $ProductSeriesId; pfid: $ProductId"
        }

        $OsId = if ($Build -ge 22000) { 135 } else { 57 }
        $Target = Get-NvidiaDownload -SeriesId $ProductSeriesId -GpuId $ProductId -OsId $OsId
        Write-Log "Latest NVIDIA driver: $($Target.Version); URL: $($Target.Url)"
    }

    # Never downgrade or reinstall the same version.
    if ([version]$CurrentVersion -ge [version]$Target.Version) {
        Write-Log "Installed driver $CurrentVersion already meets target $($Target.Version). No action needed."
    }
    elseif ($CheckOnly) {
        Write-Log "Update available: $CurrentVersion -> $($Target.Version). CheckOnly, nothing installed."
    }
    else {
        $CacheFolder = Join-Path $WorkRoot 'Cache'
        # Default extraction folder used by the NVIDIA self-extracting package.
        $ExtractFolder = Join-Path $env:SystemDrive "NVIDIA\DisplayDriver\$($Target.Version)"
        New-Item -Path $CacheFolder -ItemType Directory -Force | Out-Null

        # Download when no local package was supplied.
        $IsDownloaded = $false
        if (-not $DriverPath) {
            $IsDownloaded = $true
            $DriverPath = Join-Path $CacheFolder (Split-Path ([uri]$Target.Url).AbsolutePath -Leaf)

            $NeedDownload = $true
            if (Test-Path -LiteralPath $DriverPath) {
                try {
                    Assert-NvidiaSignature -Path $DriverPath
                    $NeedDownload = $false
                    Write-Log "Using cached package: $DriverPath"
                }
                catch {
                    Write-Log "Cached package rejected: $($_.Exception.Message)" -Level WARN
                    Remove-Item -LiteralPath $DriverPath -Force
                }
            }

            if ($NeedDownload) {
                Write-Log "Downloading to $DriverPath (timeout: $DownloadTimeoutMinutes min, stall timeout: $StallTimeoutSeconds s)."
                Save-NvidiaPackage -Url $Target.Url -Destination $DriverPath -TimeoutMinutes $DownloadTimeoutMinutes -StallSeconds $StallTimeoutSeconds
            }
        }

        Assert-NvidiaSignature -Path $DriverPath

        # Remove leftovers from an earlier attempt so the package extracts cleanly.
        if (Test-Path -LiteralPath $ExtractFolder) { Remove-Item -LiteralPath $ExtractFolder -Recurse -Force }

        # Run the self-extracting package directly. It extracts itself and passes the arguments to setup.exe.
        $InstallArgs = @('-s', '-noreboot')
        if ($Clean) { $InstallArgs += '-clean' }
        Write-Log "Starting installer: $(Split-Path $DriverPath -Leaf) $($InstallArgs -join ' ')"

        $Install = Start-Process -FilePath $DriverPath -ArgumentList $InstallArgs -Wait -PassThru -WindowStyle Hidden

        # Safety net: wait for any setup.exe still running from the extraction folder (max 30 minutes).
        $Deadline = (Get-Date).AddMinutes(30)
        while ((Get-Date) -lt $Deadline) {
            $Running = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'setup.exe'" |
                Where-Object { $_.ExecutablePath -like "$ExtractFolder*" })
            if ($Running.Count -eq 0) { break }
            Write-Log "Waiting for NVIDIA setup.exe (PID $($Running.ProcessId -join ', ')) to finish."
            Start-Sleep -Seconds 15
        }

        Write-Log "Installer exit code: $($Install.ExitCode)"

        switch ($Install.ExitCode) {
            0    { Write-Log 'Installer reported success.' }
            3010 { Write-Log 'Installer reported success. Restart required.' -Level WARN; $ExitCode = 3010 }
            default { throw "NVIDIA installation failed with exit code $($Install.ExitCode). Extracted files (if any) kept in $ExtractFolder." }
        }

        # Verify the installed version.
        Start-Sleep -Seconds 10
        $NewVersion = ConvertTo-NvidiaVersion -WindowsVersion (Get-NvidiaGpu).DriverVersion
        Write-Log "Driver version after install: $NewVersion"

        if ([version]$NewVersion -lt [version]$Target.Version) {
            if ($ExitCode -eq 3010) {
                Write-Log "Version not yet active. Expected after restart: $($Target.Version)." -Level WARN
            }
            else {
                throw "Driver version $NewVersion is lower than target $($Target.Version) after install."
            }
        }

        # Final step: clean up after success. On failure files are kept for troubleshooting and reuse.
        if (Test-Path -LiteralPath $ExtractFolder) {
            Remove-Item -LiteralPath $ExtractFolder -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Extracted files removed: $ExtractFolder"
        }

        # Only remove the package when this script downloaded it. A supplied -DriverPath is left untouched.
        if ($IsDownloaded -and (Test-Path -LiteralPath $CacheFolder)) {
            Remove-Item -LiteralPath $CacheFolder -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $CacheFolder) {
                Write-Log "Could not fully remove $CacheFolder." -Level WARN
            }
            else {
                Write-Log "Downloaded package removed: $CacheFolder"
            }
        }
    }
}
catch {
    Write-Log "Error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    $ExitCode = 1
}

Write-Log "Finished with exit code $ExitCode."
exit $ExitCode
#endregion

