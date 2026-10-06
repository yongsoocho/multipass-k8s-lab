#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/network.ps1')

# Isolated probes simulate SSH disappearing while the detached job continues.
function Invoke-Mp { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if ($script:invalidConfig) { throw 'invalid netplan configuration' }
}
function Start-Sleep { param([int]$Seconds) }
function Invoke-LabMultipassProbe {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    if ($script:results.Count -eq 0) { throw 'Unexpected extra probe.' }
    $script:results.Dequeue()
}
function New-Result([int]$Code, [string]$Output) {
    [pscustomobject]@{ ExitCode = $Code; Output = $Output; TimedOut = ($Code -eq -1) }
}
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern"
}
$script:invalidConfig = $false
$script:results = [Collections.Generic.Queue[object]]::new()
$script:results.Enqueue((New-Result -1 'SSH acknowledgement lost'))
$script:results.Enqueue((New-Result -1 'SSH reconnecting'))
$script:results.Enqueue((New-Result 0 'PENDING'))
$script:results.Enqueue((New-Result 0 "EXIT:0`nStatic IP verified"))
Set-LabNodeNetwork -Node test-node -Address 192.168.35.200 -Mac 02:35:00:00:00:c8
if ($script:results.Count) { throw 'Reconnect sequence was not fully checked.' }

$script:results.Enqueue((New-Result 0 ''))
$script:results.Enqueue((New-Result 0 "EXIT:124`nnetplan timed out"))
Assert-Fails { Set-LabNodeNetwork -Node test-node } 'netplan job failed \(exit 124\)'

$script:results.Enqueue((New-Result 0 ''))
Assert-Fails { Set-LabNodeNetwork -Node test-node -TimeoutSeconds 0 } 'Network verification timed out.*[\s\S]*apply.log'

$script:invalidConfig = $true
Assert-Fails { Set-LabNodeNetwork -Node test-node } 'invalid netplan configuration'
if ($script:results.Count) { throw 'Unexpected unconsumed probes.' }
Write-Host 'Network reconnect, job failure, timeout, and validation checks passed.'
