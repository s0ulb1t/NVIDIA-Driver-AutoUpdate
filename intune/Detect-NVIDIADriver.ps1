<#
.SYNOPSIS
    Intune Win32 app detection script for Update-NVIDIADriver.ps1.

.DESCRIPTION
    Detected (exit 0 + STDOUT):
      - Installed driver is equal to or newer than the latest NVIDIA driver for this GPU.
        This is the ONLY case that reports detected.
    Not detected (exit 1, no STDOUT; the reason is written to STDERR):
      - A newer NVIDIA driver is available. Intune then runs the install command.
      - No NVIDIA GPU, or more than one. Intune evaluates detection before requirements, so reporting
        "detected" here would show the app as Installed on devices without an NVIDIA GPU. Reporting
        "not detected" lets the requirement rule (Requirement-NVIDIAGPU.ps1) mark them Not applicable.
      - The local or online evaluation fails (offline, NVIDIA API change, unmatched GPU name, unexpected
        response). This is deliberately NOT treated as compliant, so a broken lookup or download
        mechanism stays visible instead of silently reporting "up to date". The install command then
        fails and logs the cause.

    Configure in Intune: run as 32-bit process = No, enforce signature check = No.
#>

# Optional fixed product IDs. Leave 0 to resolve automatically from the GPU name.
$ProductSeriesId = 0
$ProductId = 0

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Set-Detected {
    param ([string]$Reason)
    Write-Output "Detected: $Reason"
    exit 0
}

function Set-NotDetected {
    param ([string]$Reason)
    [Console]::Error.WriteLine("Not detected: $Reason")
    exit 1
}

function ConvertTo-NvidiaVersion {
    # Convert a Windows driver version (32.0.15.9716) to the NVIDIA public version (597.16).
    param ([string]$WindowsVersion)
    $Version = [version]$WindowsVersion
    $Digits = '{0}{1:D4}' -f $Version.Build, $Version.Revision
    $Digits = $Digits.Substring($Digits.Length - 5)
    return $Digits.Insert(3, '.')
}

# Step 1: local state. Errors here mean "cannot evaluate", treated as not detected.
try {
    $ErrorActionPreference = 'Stop'

    $Gpus = @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' })
    if ($Gpus.Count -ne 1) { Set-NotDetected "Found $($Gpus.Count) NVIDIA GPUs. Out of scope; the requirement rule marks this device Not applicable." }

    $Gpu = $Gpus[0]
    $CurrentVersion = ConvertTo-NvidiaVersion -WindowsVersion $Gpu.DriverVersion
}
catch {
    Set-NotDetected "Local evaluation failed: $($_.Exception.Message)"
}

# Step 2: online lookup. Any failure is treated as not detected.
try {
    if (-not ($ProductSeriesId -and $ProductId)) {
        $Response = Invoke-WebRequest -Uri 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3' -UseBasicParsing -TimeoutSec 60
        [xml]$Xml = $Response.Content

        $Products = foreach ($Node in $Xml.SelectNodes("//*[local-name()='LookupValue']")) {
            [pscustomobject]@{
                Name     = ([string]$Node.Name -replace '\s+', ' ').Trim()
                ParentID = [int]$Node.ParentID
                Value    = [int]$Node.Value
            }
        }

        # Same name normalization as the install script. Laptop designation is preserved.
        $Base = ($Gpu.Name -replace '\s+', ' ').Trim()
        $NoGeneration = ($Base -replace '\s+Generation\b', '').Trim()
        $Candidates = @(
            foreach ($Item in @($Base, $NoGeneration)) {
                $Item
                ($Item -replace '^NVIDIA\s+', '').Trim()
                if ($Item -notmatch '^NVIDIA\s') { "NVIDIA $Item" }
            }
        ) | Select-Object -Unique

        $IsLaptop = $Gpu.Name -match '\bLaptop\b'
        $Hits = @(
            $Products |
                Where-Object { $Candidates -contains $_.Name } |
                Where-Object { ($_.Name -match '\bLaptop\b') -eq $IsLaptop } |
                Sort-Object -Property ParentID, Value -Unique
        )

        if ($Hits.Count -ne 1) { Set-NotDetected "Found $($Hits.Count) lookup matches for '$($Gpu.Name)'. Cannot evaluate." }

        $ProductSeriesId = $Hits[0].ParentID
        $ProductId = $Hits[0].Value
    }

    $OsId = if ([Environment]::OSVersion.Version.Build -ge 22000) { 135 } else { 57 }
    $Uri = "https://www.nvidia.com/Download/processDriver.aspx?psid=$ProductSeriesId&pfid=$ProductId&osid=$OsId&dtcid=1&dtid=1"
    $Result = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60).Content.Trim()

    if ($Result -notmatch '(?:driverResults\.aspx|/drivers/details)/(\d+)') { Set-NotDetected "Unexpected processDriver response." }
    $DownloadId = $Matches[1]

    $AjaxUri = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=GetDownloadDetails&downloadID=$DownloadId"
    $Info = (Invoke-RestMethod -Uri $AjaxUri -Method Get -TimeoutSec 60).IDS[0].downloadInfo

    $LatestVersion = [string]$Info.Version
    if ($LatestVersion -notmatch '^\d{3}\.\d{2}$') {
        $Url = [uri]::UnescapeDataString([string]$Info.DownloadURL)
        if ($Url -match '/(\d{3}\.\d{2})/') { $LatestVersion = $Matches[1] } else { Set-NotDetected 'Latest version unknown.' }
    }
}
catch {
    Set-NotDetected "Online lookup failed: $($_.Exception.Message)"
}

# Step 3: compare.
if ([version]$CurrentVersion -ge [version]$LatestVersion) {
    Set-Detected "Driver $CurrentVersion meets latest $LatestVersion (psid $ProductSeriesId, pfid $ProductId)."
}

Set-NotDetected "Driver $CurrentVersion is older than latest $LatestVersion (psid $ProductSeriesId, pfid $ProductId)."

