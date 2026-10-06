# Intune requirement script: returns the number of NVIDIA GPUs (PCI vendor 10DE).
# Requirement rule: output data type Integer, operator Equals, value 1.
try {
    $Count = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
        Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' }).Count
}
catch {
    $Count = 0
}
Write-Output $Count
exit 0

