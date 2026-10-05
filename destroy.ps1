$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($args.Count -ne 0) { throw 'Usage: .\destroy.ps1' }
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) { throw 'Multipass is not installed.' }

$originalDriver = (& multipass get local.driver | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Multipass driver.' }
$drivers = @($originalDriver, 'hyperv', 'hcs', 'virtualbox') | Select-Object -Unique
$failedDrivers = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($driver in $drivers) {
        if ($driver -ne $originalDriver) {
            & multipass set "local.driver=$driver" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not switch to '$driver' (possibly unsupported by this Multipass version)."
                $failedDrivers.Add($driver)
                continue
            }
        }
        $list = & multipass list --format json | Out-String | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Cannot list Multipass instances under '$driver'." }
        $names = @($list.info.PSObject.Properties.Name)
        if ($names.Count -gt 0) {
            & multipass delete --purge @names
            if ($LASTEXITCODE -ne 0) { throw "Multipass deletion failed under '$driver'." }
        }
        & multipass purge
        if ($LASTEXITCODE -ne 0) { throw "Multipass purge failed under '$driver'." }
    }
}
finally {
    & multipass set "local.driver=$originalDriver" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not restore Multipass driver '$originalDriver'." }
}

$switchName = 'MultipassK8s'
if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
    $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($switch) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Instances were deleted; rerun as Administrator to remove Hyper-V switch $switchName."
        }
        Remove-VMSwitch -Name $switchName -Force
    }
}
if ($failedDrivers.Count -gt 0) { throw "Cleanup completed for available drivers, but these drivers could not be inspected: $($failedDrivers -join ', ')." }
Write-Host 'All Multipass instances and VM disks in available Windows drivers were purged; the MultipassK8s switch was removed if present.'
