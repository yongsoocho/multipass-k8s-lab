$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($args.Count -ne 0) { throw 'Usage: .\destroy.ps1' }
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) { throw 'Multipass is not installed.' }

# This intentionally removes every instance visible under the active Multipass driver.
$list = & multipass list --format json | Out-String | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot list Multipass instances.' }
$names = @($list.info.PSObject.Properties.Name)
if ($names.Count -gt 0) {
    & multipass delete --purge @names
    if ($LASTEXITCODE -ne 0) { throw 'Multipass instance deletion failed.' }
}
& multipass purge
if ($LASTEXITCODE -ne 0) { throw 'Multipass purge failed.' }

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
Write-Host 'All instances and VM disks in the active Multipass driver were purged; the MultipassK8s switch was removed if present.'
