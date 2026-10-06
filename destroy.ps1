#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'scripts/host-access.ps1')
. (Join-Path $PSScriptRoot 'scripts/network.ps1')
. (Join-Path $PSScriptRoot 'scripts/destroy-common.ps1')

if ($args.Count -ne 0) { throw 'Usage: .\destroy.ps1' }
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) { throw 'Multipass is not installed.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell 7 as Administrator. No cleanup has started.'
}

$originalDriver = Get-LabDestroyDriver
$versionResult = Invoke-LabMultipassProbe -Arguments @('version')
if ($versionResult.ExitCode -ne 0 -or $versionResult.StandardOutput -notmatch '(?m)^multipass\s+(\d+\.\d+\.\d+)') {
    throw "Cannot determine Multipass version: $($versionResult.Output)"
}
$version = [version]$Matches[1]
$vboxRegistry = Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction SilentlyContinue
$vboxPaths = @((Join-Path $env:ProgramFiles 'Oracle/VirtualBox/VBoxManage.exe'))
if ($vboxRegistry -and $vboxRegistry.PSObject.Properties['InstallDir'] -and $vboxRegistry.InstallDir) { $vboxPaths += Join-Path $vboxRegistry.InstallDir 'VBoxManage.exe' }
$vboxAvailable = [bool](Get-Command VBoxManage -ErrorAction SilentlyContinue) -or @($vboxPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
$plan = Get-LabDestroyPlan -OriginalDriver $originalDriver -Version $version -HyperVAvailable ([bool](Get-Command Get-VMSwitch -ErrorAction SilentlyContinue)) -VirtualBoxAvailable $vboxAvailable
foreach ($reason in $plan.Skipped) { Write-Host "Skipping $reason" }
$result = Invoke-LabDestroyDrivers -OriginalDriver $originalDriver -Drivers $plan.Drivers
$failures = [Collections.Generic.List[string]]::new()
foreach ($failure in $result.Failures) { $failures.Add($failure) }

# Finish independent cleanup even if a different backend failed. Do not remove
# a switch still attached to any VM (including non-Multipass Hyper-V VMs).
try {
    if (-not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue)) { throw 'Cannot verify/remove the lab switch: Hyper-V module unavailable.' }
    $switch = @(Get-VMSwitch -ErrorAction Stop | Where-Object Name -eq 'MultipassK8s')
    if ($switch.Count) {
        $attached = @(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Where-Object SwitchName -eq 'MultipassK8s')
        if ($attached.Count) { throw 'MultipassK8s still has attached VMs; switch was preserved.' }
        Remove-VMSwitch -Name 'MultipassK8s' -Force -ErrorAction Stop
    }
    Write-Host 'Lab Hyper-V switch removed (or already absent).'
} catch { $failures.Add("Network cleanup: $($_.Exception.Message)") }
try {
    if ('hyperv' -notin $result.Purged) { throw 'Hyper-V deletion was not verified; lab SSH access was preserved.' }
    Remove-LabHostAccess
    Write-Host 'Lab SSH configuration and dedicated keys removed (or already absent).'
} catch { $failures.Add("SSH cleanup: $($_.Exception.Message)") }
if ($failures.Count) { throw "Cleanup incomplete. Fix the following and rerun destroy.ps1:`n$($failures -join "`n")" }
Write-Host "Cleanup complete. Verified empty drivers: $($result.Purged -join ', ')."
