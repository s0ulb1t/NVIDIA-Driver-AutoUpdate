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
    # Include the product mapping steps so the reason is visible in the IME logs.
    foreach ($Line in $MappingLog) { [Console]::Error.WriteLine($Line) }
    exit 1
}

# Collects product mapping messages; used by the shared Product mapping region.
$MappingLog = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param ([string]$Message, [string]$Level = 'INFO')
    $MappingLog.Add("[$Level] $Message")
}

function ConvertTo-NvidiaVersion {
    # Convert a Windows driver version (32.0.15.9716) to the NVIDIA public version (597.16).
    param ([string]$WindowsVersion)
    $Version = [version]$WindowsVersion
    $Digits = '{0}{1:D4}' -f $Version.Build, $Version.Revision
    $Digits = $Digits.Substring($Digits.Length - 5)
    return $Digits.Insert(3, '.')
}

$LookupTimeoutSec = 60

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
    $OsId = if ([Environment]::OSVersion.Version.Build -ge 22000) { 135 } else { 57 }
    $MappingReason = 'fixed product IDs'
    if (-not ($ProductSeriesId -and $ProductId)) {
        $Product = Resolve-NvidiaProduct -GpuName $Gpu.Name -OsId $OsId
        $ProductSeriesId = $Product.ParentID
        $ProductId = $Product.Value
        $MappingReason = $Product.MappingReason
    }

    $DownloadId = Get-NvidiaDownloadId -SeriesId $ProductSeriesId -ProductId $ProductId -OsId $OsId

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
    Set-Detected "Driver $CurrentVersion meets latest $LatestVersion (psid $ProductSeriesId, pfid $ProductId; mapping: $MappingReason)."
}

Set-NotDetected "Driver $CurrentVersion is older than latest $LatestVersion (psid $ProductSeriesId, pfid $ProductId; mapping: $MappingReason)."

