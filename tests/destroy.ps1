#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/destroy-common.ps1')
$stopImplementation = ${function:Stop-LabDestroyInstances}
$serviceImplementation = ${function:Start-LabDestroyService}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Start-Sleep { param([int]$Seconds) }
function Get-VM {
    [CmdletBinding()] param()
    [pscustomobject]@{ Name = 'fixture-target'; State = 'Running' }
    [pscustomobject]@{ Name = 'fixture-off'; State = 'Off' }
    [pscustomobject]@{ Name = 'unrelated-vm'; State = 'Running' }
}
function Stop-VM {
    [CmdletBinding()] param($VM, [switch]$TurnOff, [switch]$Force)
    $script:poweredOff.Add($VM.Name)
}
function New-Result([int]$Code, [string]$Stdout = '', [string]$Stderr = '') {
    [pscustomobject]@{ ExitCode = $Code; StandardOutput = $Stdout; StandardError = $Stderr; Output = "$Stdout$Stderr"; TimedOut = ($Code -eq -1) }
}
function Reset-Fixture {
    $script:active = 'hyperv'
    $script:instances = @{ hyperv = 2; hcs = 1; virtualbox = 1 }
    $script:transient = 0
    $script:broken = ''
    $script:keepInstances = $false
    $script:lostAcknowledgement = $false
    $script:purgeFailures = 0
    $script:invalidJson = $false
    $script:driverFailures = 0
    $script:serviceRestarts = 0
    $script:recoverOnRestart = $false
    $script:guestsStopped = $false
    $script:calls = [Collections.Generic.List[string]]::new()
}
function Stop-LabDestroyInstances {
    param([string]$Driver, [object[]]$Instances)
    $script:guestsStopped = $true
}
function Start-LabDestroyService {
    param([switch]$Restart)
    if ($Restart) {
        $script:serviceRestarts++
        if ($script:recoverOnRestart) { $script:driverFailures = 0 }
    }
}
function Invoke-LabMultipassProbe {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    $script:calls.Add(($Arguments -join ' '))
    switch ($Arguments[0]) {
        'get' {
            if ($script:driverFailures -gt 0) { $script:driverFailures--; return New-Result -1 }
            return New-Result 0 $script:active
        }
        'set' { $script:active = $Arguments[1].Split('=')[1]; return New-Result 0 }
        'list' {
            if ($script:active -eq $script:broken) { return New-Result 1 '' 'certificate verify failed' }
            if ($script:transient -gt 0) { $script:transient--; return New-Result 1 '' 'cannot connect to the multipass socket' }
            if ($script:invalidJson) { return New-Result 0 '{"unexpected":[]}' }
            $items = @(for ($i = 0; $i -lt $script:instances[$script:active]; $i++) { @{ name = "fixture-$i" } })
            return New-Result 0 (@{ list = $items } | ConvertTo-Json -Compress) 'gRPC shutdown warning'
        }
        'delete' {
            Assert-True $script:guestsStopped 'Permanent deletion started before guest shutdown.'
            Assert-True (($Arguments -join ' ') -eq 'delete --all --purge') 'Deletion must include all instances and snapshots.'
            if (-not $script:keepInstances) { $script:instances[$script:active] = 0 }
            if ($script:lostAcknowledgement) { return New-Result -1 '' 'request timed out after deletion' }
            return New-Result 0
        }
        'purge' {
            if ($script:purgeFailures -gt 0) { $script:purgeFailures--; return New-Result 1 '' 'TLS reconnecting' }
            return New-Result 0
        }
        default { throw "Unexpected command: $Arguments" }
    }
}

& {
    # Simulate the observed SCM behavior: force-stopping a stuck daemon can
    # jump straight from StopPending to Running through automatic recovery.
    $script:serviceRecovered = $false
    $script:forcedDaemonStops = 0
    $script:fakeService = [pscustomobject]@{ Status = 'StopPending' }
    $script:fakeService | Add-Member ScriptMethod Refresh {
        if ($script:serviceRecovered) { $this.Status = 'Running' }
    }
    $script:fakeService | Add-Member ScriptMethod WaitForStatus {
        param($Status, $Timeout)
        if ($this.Status -ne $Status.ToString()) { throw 'Simulated SCM status timeout' }
    }
    function Get-Service { [CmdletBinding()] param($Name) $script:fakeService }
    function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) [pscustomobject]@{ ProcessId = 789 } }
    function Get-Process {
        [CmdletBinding()] param($Id)
        $fake = [pscustomobject]@{ Id = 789; ProcessName = 'multipassd' }
        $fake | Add-Member ScriptMethod WaitForExit { param($Timeout) return $true }
        $fake
    }
    function Stop-Process {
        [CmdletBinding()] param($Id, [switch]$Force)
        Assert-True ($Id -eq 789) 'Unexpected daemon PID was terminated.'
        $script:forcedDaemonStops++
        $script:serviceRecovered = $true
    }
    & $serviceImplementation
    Assert-True ($script:forcedDaemonStops -eq 1 -and $script:fakeService.Status -eq 'Running') 'SCM automatic restart was reported as a recovery failure.'
}

$script:poweredOff = [Collections.Generic.List[string]]::new()
& $stopImplementation -Driver hyperv -Instances @(@{ name = 'fixture-target' }, @{ name = 'fixture-off' })
Assert-True (($script:poweredOff -join ',') -eq 'fixture-target') 'Power-off touched an unrelated or already stopped VM.'

$plan = Get-LabDestroyPlan -OriginalDriver hyperv -Version 1.16.4 -HyperVAvailable $true -VirtualBoxAvailable $false
Assert-True (($plan.Drivers -join ',') -eq 'hyperv') 'Unavailable drivers were selected.'
$plan = Get-LabDestroyPlan -OriginalDriver hyperv -Version 1.17.0 -HyperVAvailable $true -VirtualBoxAvailable $true
Assert-True (($plan.Drivers -join ',') -eq 'hyperv,hcs,virtualbox') 'Available drivers were omitted.'
$plan = Get-LabDestroyPlan -OriginalDriver virtualbox -Version 1.16.4 -HyperVAvailable $true -VirtualBoxAvailable $false
Assert-True ($plan.Drivers -contains 'virtualbox') 'The active driver must never be silently skipped.'

Reset-Fixture
$script:driverFailures = 2
Assert-True ((Initialize-LabDestroyConnection) -eq 'hyperv') 'Initial empty-output timeouts were not retried.'
Assert-True ($script:serviceRestarts -eq 0) 'Transient failure unnecessarily restarted the service.'

Reset-Fixture
$script:driverFailures = 20
$script:recoverOnRestart = $true
Assert-True ((Initialize-LabDestroyConnection) -eq 'hyperv') 'Service restart did not recover the initial connection.'
Assert-True ($script:serviceRestarts -eq 1) 'Service recovery did not stay bounded to one restart.'

Reset-Fixture
$script:driverFailures = 20
$failure = ''
try { Initialize-LabDestroyConnection } catch { $failure = $_.Exception.Message }
Assert-True ($failure -match 'exit=-1, timedOut=True, timeout=30s; <no stdout/stderr>') 'Empty timeout diagnostics are missing.'
Assert-True ($script:serviceRestarts -eq 1 -and $script:calls.Count -eq 6) 'Permanent failure did not stop at the retry limit.'
Assert-True (-not @($script:calls | Where-Object { $_ -like 'delete *' -or $_ -like 'set *' }).Count) 'Failed startup performed a destructive action or guessed a driver.'

Reset-Fixture
$script:transient = 2
$script:purgeFailures = 1
$script:lostAcknowledgement = $true
$result = Invoke-LabDestroyDrivers -OriginalDriver hyperv -Drivers @('hyperv', 'virtualbox')
Assert-True ($result.Failures.Count -eq 0 -and $result.Purged.Count -eq 2) 'Transient TLS or lost acknowledgement recovery failed.'
Assert-True ($script:active -eq 'hyperv') 'Original driver was not restored.'

Reset-Fixture
$script:broken = 'virtualbox'
$result = Invoke-LabDestroyDrivers -OriginalDriver hyperv -Drivers @('hyperv', 'virtualbox', 'hcs')
Assert-True ($result.Failures.Count -eq 1) 'Permanent TLS failure was hidden.'
Assert-True (($result.Purged -join ',') -eq 'hyperv,hcs') 'A failed backend prevented other backend cleanup.'
Assert-True ($script:active -eq 'hyperv') 'Driver restoration failed after an error.'

Reset-Fixture
$script:keepInstances = $true
$result = Invoke-LabDestroyDrivers -OriginalDriver hyperv -Drivers @('hyperv')
Assert-True ($result.Failures.Count -eq 1 -and $result.Purged.Count -eq 0) 'Remaining instances were reported as deleted.'

Reset-Fixture
$script:instances.hyperv = 0
$result = Invoke-LabDestroyDrivers -OriginalDriver hyperv -Drivers @('hyperv')
Assert-True ($result.Failures.Count -eq 0) 'Empty repeat cleanup failed.'
Assert-True (-not @($script:calls | Where-Object { $_ -like 'set *' -or $_ -like 'delete *' }).Count) 'Empty cleanup performed unnecessary mutations.'

Reset-Fixture
$script:invalidJson = $true
$result = Invoke-LabDestroyDrivers -OriginalDriver hyperv -Drivers @('hyperv')
Assert-True ($result.Purged.Count -eq 0 -and $result.Failures.Count -gt 0) 'Invalid JSON was treated as an empty list.'
Assert-True (-not @($script:calls | Where-Object { $_ -like 'delete *' }).Count) 'Invalid inventory triggered deletion.'
Write-Host 'Destroy driver selection, TLS retry, stderr separation, partial failure, restoration, and repeat cleanup checks passed.'
