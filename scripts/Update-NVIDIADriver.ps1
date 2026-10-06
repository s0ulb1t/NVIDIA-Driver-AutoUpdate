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

#endregion

$LookupTimeoutSec = 300

#region Product mapping
# Keep this region identical in scripts/Update-NVIDIADriver.ps1 and intune/Detect-NVIDIADriver.ps1.
# Both scripts must resolve a GPU to the same NVIDIA product. The calling script defines Write-Log and
# $LookupTimeoutSec.

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

function Get-NvidiaLookup {
    # TypeID 2 = product series (Value = psid), TypeID 3 = products (ParentID = psid, Value = pfid).
    param ([Parameter(Mandatory)][int]$TypeId)

    $Response = Invoke-WebRequest -Uri "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=$TypeId" -UseBasicParsing -TimeoutSec $LookupTimeoutSec
    [xml]$Xml = $Response.Content

    return @(
        foreach ($Node in $Xml.SelectNodes("//*[local-name()='LookupValue']")) {
            [pscustomobject]@{
                Name     = ([string]$Node.Name -replace '\s+', ' ').Trim()
                ParentID = [int]$Node.ParentID
                Value    = [int]$Node.Value
            }
        }
    )
}

function Get-NvidiaDownloadId {
    param (
        [Parameter(Mandatory)][int]$SeriesId,
        [Parameter(Mandatory)][int]$ProductId,
        [Parameter(Mandatory)][int]$OsId
    )

    $Uri = "https://www.nvidia.com/Download/processDriver.aspx?psid=$SeriesId&pfid=$ProductId&osid=$OsId&dtcid=1&dtid=1"
    $Result = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $LookupTimeoutSec).Content.Trim()

    # NVIDIA returns either the legacy 'driverResults.aspx/<id>/' or the newer '/drivers/details/<id>/' format.
    if ($Result -notmatch '(?:driverResults\.aspx|/drivers/details)/(\d+)') { throw "Unexpected processDriver response for psid $SeriesId, pfid ${ProductId}: $Result" }
    return $Matches[1]
}

function Get-NvidiaSeriesFormFactor {
    # Classify an NVIDIA product series (TypeID 2 entry). Returns FormFactor and the basis for it.
    # Desktop is only assigned by heuristic: a sibling series with the same name plus "(Notebooks)" exists
    # under the same product type. This is an observed naming pattern, not a documented NVIDIA convention.
    param (
        [Parameter(Mandatory)][pscustomobject]$Series,
        [Parameter(Mandatory)][object[]]$AllSeries
    )

    if ($Series.Name -match '\b(Notebooks?|Laptops?|Mobile)\b') {
        return [pscustomobject]@{ FormFactor = 'Notebook'; Basis = 'series name keyword' }
    }
    if ($Series.Name -match '\b(Embedded|Blade)\b') {
        return [pscustomobject]@{ FormFactor = 'Embedded'; Basis = 'series name keyword' }
    }

    $SiblingPattern = '^' + [regex]::Escape($Series.Name) + '\s*\((Notebooks?|Laptops?)\)$'
    $Siblings = @($AllSeries | Where-Object { $_.ParentID -eq $Series.ParentID -and $_.Name -match $SiblingPattern })
    if ($Siblings.Count -gt 0) {
        return [pscustomobject]@{ FormFactor = 'Desktop'; Basis = "heuristic: notebook sibling series '$($Siblings[0].Name)' exists" }
    }

    return [pscustomobject]@{ FormFactor = 'Unknown'; Basis = 'no keyword and no notebook sibling series' }
}

function Get-DeviceFormFactor {
    # Form factor from firmware (SMBIOS chassis type and ACPI power profile). All known signals must agree.
    $Evidence = [System.Collections.Generic.List[string]]::new()
    $Classes = [System.Collections.Generic.List[string]]::new()

    try {
        $ChassisTypes = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | ForEach-Object { $_.ChassisTypes } | Where-Object { $null -ne $_ })
        foreach ($Type in $ChassisTypes) {
            $Class = if ([int]$Type -in 8, 9, 10, 11, 14, 30, 31, 32) { 'Notebook' }
                elseif ([int]$Type -in 3, 4, 5, 6, 7, 15, 16, 24, 35, 36) { 'Desktop' }
                elseif ([int]$Type -eq 34) { 'Embedded' }
                else { 'Unknown' }
            $Evidence.Add("ChassisType $Type=$Class")
            if ($Class -ne 'Unknown') { $Classes.Add($Class) }
        }
        if ($ChassisTypes.Count -eq 0) { $Evidence.Add('ChassisType none') }
    }
    catch {
        $Evidence.Add("ChassisType error: $($_.Exception.Message)")
    }

    try {
        $PcSystemType = [int](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PCSystemType
        # 1 = Desktop, 2 = Mobile. Workstation (3), servers and appliances do not imply a form factor.
        $Class = switch ($PcSystemType) { 1 { 'Desktop' } 2 { 'Notebook' } default { 'Unknown' } }
        $Evidence.Add("PCSystemType $PcSystemType=$Class")
        if ($Class -ne 'Unknown') { $Classes.Add($Class) }
    }
    catch {
        $Evidence.Add("PCSystemType error: $($_.Exception.Message)")
    }

    $Known = @($Classes | Select-Object -Unique)
    $Result = if ($Known.Count -eq 1) { $Known[0] } else { 'Unknown' }
    if ($Known.Count -gt 1) { $Evidence.Add('signals conflict') }

    return [pscustomobject]@{ FormFactor = $Result; Evidence = ($Evidence -join ', ') }
}

function Find-NvidiaProductHits {
    # Exact name match against the lookup, using the normalized name variants.
    param (
        [Parameter(Mandatory)][object[]]$Products,
        [Parameter(Mandatory)][string]$Name
    )

    $Candidates = Get-NameCandidates -Name $Name
    Write-Log "Name candidates: $($Candidates -join ' | ')"

    $IsLaptop = $Name -match '\bLaptop\b'

    return @(
        $Products |
            Where-Object { $Candidates -contains $_.Name } |
            Where-Object { ($_.Name -match '\bLaptop\b') -eq $IsLaptop } |
            Sort-Object -Property ParentID, Value -Unique
    )
}

function Add-NvidiaSeriesFormFactor {
    # Attach the product series name and its form factor to each candidate.
    param ([Parameter(Mandatory)][object[]]$Hits)

    $AllSeries = @(Get-NvidiaLookup -TypeId 2)
    return @(
        foreach ($Hit in $Hits) {
            $SeriesEntries = @($AllSeries | Where-Object { $_.Value -eq $Hit.ParentID })
            if ($SeriesEntries.Count -eq 1) {
                $SeriesName = $SeriesEntries[0].Name
                $Class = Get-NvidiaSeriesFormFactor -Series $SeriesEntries[0] -AllSeries $AllSeries
            }
            else {
                $SeriesName = "<$($SeriesEntries.Count) series entries>"
                $Class = [pscustomobject]@{ FormFactor = 'Unknown'; Basis = 'series not uniquely found' }
            }
            Write-Log "Candidate $($Hit.Name) [$($Hit.ParentID)/$($Hit.Value)]: series '$SeriesName' = $($Class.FormFactor) ($($Class.Basis))"
            $Hit | Select-Object Name, ParentID, Value,
                @{ Name = 'SeriesName'; Expression = { $SeriesName } },
                @{ Name = 'FormFactor'; Expression = { $Class.FormFactor } },
                @{ Name = 'FormFactorBasis'; Expression = { $Class.Basis } }
        }
    )
}

function Select-NvidiaProduct {
    # Return the chosen candidate with the reason, and log it.
    param (
        [Parameter(Mandatory)][pscustomobject]$Candidate,
        [Parameter(Mandatory)][string]$Reason
    )

    Write-Log "Lookup match: $($Candidate.Name); psid: $($Candidate.ParentID); pfid: $($Candidate.Value); reason: $Reason"
    return $Candidate | Select-Object Name, ParentID, Value, @{ Name = 'MappingReason'; Expression = { $Reason } }
}

function Select-EquivalentNvidiaProduct {
    # Continue only when all candidates resolve to the same driver package; the choice then does not change the result.
    param (
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][int]$OsId,
        [Parameter(Mandatory)][string]$Context,
        [string]$ReasonPrefix = ''
    )

    $DownloadIds = @(
        foreach ($Candidate in $Candidates) {
            try {
                $Id = Get-NvidiaDownloadId -SeriesId $Candidate.ParentID -ProductId $Candidate.Value -OsId $OsId
            }
            catch {
                throw "$Context Could not compare their driver packages: $($_.Exception.Message) Supply validated ProductSeriesId and ProductId values."
            }
            Write-Log "Candidate [$($Candidate.ParentID)/$($Candidate.Value)] resolves to download ID $Id."
            $Id
        }
    )

    if (@($DownloadIds | Select-Object -Unique).Count -ne 1) {
        throw "$Context They resolve to different driver packages and cannot be told apart. Supply validated ProductSeriesId and ProductId values."
    }

    # Deterministic pick; any candidate yields the same package.
    $Pick = @($Candidates | Sort-Object -Property ParentID, Value)[0]
    return Select-NvidiaProduct -Candidate $Pick -Reason "$($ReasonPrefix)all $($Candidates.Count) candidates resolve to the same driver package (download ID $($DownloadIds[0]))"
}

function Resolve-NvidiaProduct {
    # Map the Windows GPU name to one NVIDIA product (psid/pfid). Stops when the mapping is not certain.
    param (
        [Parameter(Mandatory)][string]$GpuName,
        [Parameter(Mandatory)][int]$OsId
    )

    Write-Log 'Retrieving NVIDIA product lookup data.'
    $Products = @(Get-NvidiaLookup -TypeId 3)
    if ($Products.Count -eq 0) { throw 'NVIDIA lookup returned no product entries.' }
    Write-Log "Lookup entries received: $($Products.Count)"

    # Exact name matches always come first.
    $Hits = @(Find-NvidiaProductHits -Products $Products -Name $GpuName)
    $Found = ($Hits | ForEach-Object { "$($_.Name) [$($_.ParentID)/$($_.Value)]" }) -join '; '

    if ($Hits.Count -eq 1) {
        return Select-NvidiaProduct -Candidate $Hits[0] -Reason 'unique name match'
    }

    if ($Hits.Count -eq 0) {
        # Max-Q fallback: only for "<name> with Max-Q Design", only notebook series, only on a notebook.
        if ($GpuName -notmatch '\s+with\s+Max-Q\s+Design\s*$') {
            throw "Found 0 unique NVIDIA lookup matches for '$GpuName'. Supply validated ProductSeriesId and ProductId values."
        }

        $BaseName = ($GpuName -replace '\s+with\s+Max-Q\s+Design\s*$', '').Trim()
        Write-Log "No exact match for '$GpuName'. Trying notebook-only Max-Q fallback with '$BaseName'." -Level WARN
        $Context = "No exact NVIDIA lookup match for '$GpuName'; Max-Q fallback with '$BaseName':"

        $Device = Get-DeviceFormFactor
        Write-Log "Device form factor: $($Device.FormFactor) ($($Device.Evidence))"
        if ($Device.FormFactor -ne 'Notebook') {
            throw "$Context device form factor is $($Device.FormFactor), Notebook required."
        }

        $FallbackHits = @(Find-NvidiaProductHits -Products $Products -Name $BaseName)
        if ($FallbackHits.Count -eq 0) { throw "$Context 0 matches." }

        $Notebook = @(Add-NvidiaSeriesFormFactor -Hits $FallbackHits | Where-Object { $_.FormFactor -eq 'Notebook' })
        if ($Notebook.Count -eq 0) { throw "$Context no candidate in a Notebook series." }
        if ($Notebook.Count -eq 1) {
            return Select-NvidiaProduct -Candidate $Notebook[0] -Reason "Max-Q fallback: only Notebook-series match for '$BaseName' (series '$($Notebook[0].SeriesName)'; device: $($Device.Evidence))"
        }
        return Select-EquivalentNvidiaProduct -Candidates $Notebook -OsId $OsId -Context "$Context $($Notebook.Count) Notebook-series matches." -ReasonPrefix 'Max-Q fallback: '
    }

    Write-Log "Name matches $($Hits.Count) NVIDIA products: $Found. Disambiguating." -Level WARN
    $Context = "Found $($Hits.Count) unique NVIDIA lookup matches for '$GpuName'. $Found"

    # Step 1: compare the device form factor with the form factor of each candidate's product series.
    $Device = Get-DeviceFormFactor
    Write-Log "Device form factor: $($Device.FormFactor) ($($Device.Evidence))"
    $Classified = @(Add-NvidiaSeriesFormFactor -Hits $Hits)

    $Remaining = $Classified
    if ($Device.FormFactor -eq 'Unknown') {
        Write-Log 'Form factor check skipped: device form factor is unknown.' -Level WARN
    }
    elseif (@($Classified | Where-Object { $_.FormFactor -eq 'Unknown' }).Count -gt 0) {
        Write-Log 'Form factor check skipped: not every candidate series could be classified.' -Level WARN
    }
    else {
        $Matching = @($Classified | Where-Object { $_.FormFactor -eq $Device.FormFactor })
        if ($Matching.Count -eq 1) {
            return Select-NvidiaProduct -Candidate $Matching[0] -Reason "only candidate whose series matches device form factor $($Device.FormFactor) (series '$($Matching[0].SeriesName)', $($Matching[0].FormFactorBasis); device: $($Device.Evidence))"
        }
        if ($Matching.Count -eq 0) {
            # Contradiction (for example an all-in-one with a notebook GPU): do not trust the form factor.
            Write-Log "No candidate series matches device form factor $($Device.FormFactor). Form factor not used." -Level WARN
        }
        else {
            $Remaining = $Matching
            Write-Log "$($Remaining.Count) candidates remain after the form factor check." -Level WARN
        }
    }

    # Step 2: same driver package for all remaining candidates, otherwise stop.
    return Select-EquivalentNvidiaProduct -Candidates $Remaining -OsId $OsId -Context $Context
}
#endregion

#region Download and install helpers
function Get-NvidiaDownload {
    param (
        [Parameter(Mandatory)][int]$SeriesId,
        [Parameter(Mandatory)][int]$GpuId,
        [Parameter(Mandatory)][int]$OsId
    )

    Write-Log "Querying driver: psid $SeriesId; pfid $GpuId; osid $OsId"
    $DownloadId = Get-NvidiaDownloadId -SeriesId $SeriesId -ProductId $GpuId -OsId $OsId

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
        $OsId = if ($Build -ge 22000) { 135 } else { 57 }
        if (-not $ProductSeriesId) {
            $Product = Resolve-NvidiaProduct -GpuName $Gpu.Name -OsId $OsId
            $ProductSeriesId = $Product.ParentID
            $ProductId = $Product.Value
        }
        else {
            Write-Log "Using supplied psid: $ProductSeriesId; pfid: $ProductId"
        }

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

