function Get-LabDestroyPlan {
    param([string]$OriginalDriver, [version]$Version, [bool]$HyperVAvailable, [bool]$VirtualBoxAvailable)
    $drivers = [Collections.Generic.List[string]]::new()
    $skipped = [Collections.Generic.List[string]]::new()
    $drivers.Add($OriginalDriver)
    if ($HyperVAvailable) {
        $drivers.Add('hyperv')
        if ($Version -ge [version]'1.17') { $drivers.Add('hcs') }
        else { $skipped.Add('hcs: requires Multipass 1.17 or newer') }
    } else { $skipped.Add('additional Hyper-V drivers: Hyper-V module unavailable') }
    if ($VirtualBoxAvailable) { $drivers.Add('virtualbox') }
    elseif ($OriginalDriver -ne 'virtualbox') { $skipped.Add('virtualbox: VirtualBox is not installed') }
    [pscustomobject]@{ Drivers = @($drivers | Select-Object -Unique); Skipped = $skipped.ToArray() }
}

function Format-LabDestroyFailure {
    param($Result, [int]$TimeoutSeconds)
    $detail = if ([string]::IsNullOrWhiteSpace($Result.Output)) { '<no stdout/stderr>' } else { $Result.Output }
    "exit=$($Result.ExitCode), timedOut=$($Result.TimedOut), timeout=${TimeoutSeconds}s; $detail"
}

function Invoke-LabDestroyRead {
    param([string[]]$Arguments, [int]$Attempts = 3, [int]$TimeoutSeconds = 30)
    $lastError = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Host "Multipass $($Arguments -join ' '): attempt $attempt/$Attempts (timeout ${TimeoutSeconds}s)"
        try {
            $result = Invoke-LabMultipassProbe -TimeoutSeconds $TimeoutSeconds -Arguments $Arguments
            if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StandardOutput)) { return $result }
            $lastError = Format-LabDestroyFailure -Result $result -TimeoutSeconds $TimeoutSeconds
        } catch { $lastError = $_.Exception.Message }
        Write-Warning $lastError
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    throw "Multipass $($Arguments -join ' ') failed after $Attempts attempts: $lastError"
}

function Start-LabDestroyService {
    param([switch]$Restart)
    $service = Get-Service -Name Multipass -ErrorAction Stop
    if ($Restart) {
        Write-Host 'Restarting the Multipass Windows service once to recover CLI connectivity...'
        if ($service.Status -notin @('Stopped', 'StopPending')) { $service.Stop() }
        $service.Refresh()
    }
    if ($service.Status -eq 'StopPending') {
        try { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30)) }
        catch {
            $service.Refresh()
            if ($service.Status -ne 'StopPending') { throw }
            # The 1.16 daemon can deadlock and never acknowledge SCM stop.
            # Target only the process registered to this service, after timeout.
            $registration = Get-CimInstance Win32_Service -Filter "Name='Multipass'" -ErrorAction Stop
            if ($registration.ProcessId -le 0) { throw 'Multipass stop timed out without a valid service PID.' }
            $daemon = Get-Process -Id $registration.ProcessId -ErrorAction Stop
            if ($daemon.ProcessName -ne 'multipassd') { throw 'Refusing to terminate an unexpected service process.' }
            Write-Warning 'Multipass is stuck in StopPending; terminating only its registered daemon process to finish the restart.'
            Stop-Process -Id $daemon.Id -Force -ErrorAction Stop
            if (-not $daemon.WaitForExit(15000)) { throw 'The unresponsive Multipass daemon did not exit.' }
            # SCM recovery may immediately restart the daemon: waiting only for
            # Stopped would falsely fail even though it is already Running.
            for ($attempt = 0; $attempt -lt 15; $attempt++) {
                $service.Refresh()
                if ($service.Status -ne 'StopPending') { break }
                Start-Sleep -Seconds 1
            }
        }
        $service.Refresh()
    }
    if ($service.Status -eq 'Stopped') {
        Write-Host 'Starting the Multipass Windows service...'
        $service.Start()
    }
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
}

function Initialize-LabDestroyConnection {
    Start-LabDestroyService
    try { return Get-LabDestroyDriver -Attempts 3 } catch {
        Write-Warning "Initial Multipass connection failed. $($_.Exception.Message)"
    }
    # Bounded recovery before reading inventory or deleting anything. Keep all
    # certificates/settings intact; never guess a driver after a failed read.
    Start-LabDestroyService -Restart
    try { return Get-LabDestroyDriver -Attempts 3 } catch {
        throw "Multipass is still unreachable after one service restart. No VM deletion started. $($_.Exception.Message)"
    }
}

function Get-LabDestroyDriver {
    param([int]$Attempts = 1)
    $result = Invoke-LabDestroyRead -Arguments @('get', 'local.driver') -Attempts $Attempts
    $driver = $result.StandardOutput.Trim()
    if ($driver -notmatch '^[a-z0-9]+$') { throw 'Unexpected Multipass driver output.' }
    $driver
}

function Wait-LabDestroyDriver {
    param([string]$Driver, [int]$Attempts = 6)
    $lastError = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            if ((Get-LabDestroyDriver) -ne $Driver) { throw "Active driver is not '$Driver'." }
            $result = Invoke-LabMultipassProbe -TimeoutSeconds 10 -Arguments @('list', '--format', 'json')
            if ($result.ExitCode -ne 0) { throw (Format-LabDestroyFailure -Result $result -TimeoutSeconds 10) }
            # Native TLS/gRPC diagnostics belong to stderr, never to the JSON.
            $document = $result.StandardOutput | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $document.PSObject.Properties['list'] -or $document.list -isnot [array]) { throw 'Missing or invalid Multipass instance list.' }
            return $document
        } catch { $lastError = $_.Exception.Message }
        if ($attempt -lt $Attempts) {
            Write-Host "[$Driver] Waiting for Multipass connection ($attempt/$Attempts)..."
            Start-Sleep -Seconds 2
        }
    }
    throw "Multipass driver '$Driver' did not become ready: $lastError"
}

function Set-LabDestroyDriver {
    param([string]$Driver)
    $current = $null
    try { $current = Get-LabDestroyDriver } catch { Write-Host $_.Exception.Message }
    if ($current -ne $Driver) {
        Write-Host "Switching Multipass driver to $Driver..."
        $result = Invoke-LabMultipassProbe -TimeoutSeconds 30 -Arguments @('set', "local.driver=$Driver")
        if ($result.ExitCode -ne 0) { Write-Warning "Driver change acknowledgement failed; verifying state. $(Format-LabDestroyFailure -Result $result -TimeoutSeconds 30)" }
    }
    Wait-LabDestroyDriver -Driver $Driver
}

function Stop-LabDestroyInstances {
    param([string]$Driver, [object[]]$Instances)
    if ($Driver -ne 'hyperv') { return }
    # Multipass 1.16 can stall while deleting running Hyper-V guests. The user
    # requested permanent deletion, so power off only the inventoried guests
    # using Hyper-V first; leave disk/snapshot removal to Multipass.
    $names = @($Instances | ForEach-Object { $_.name })
    foreach ($vm in @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -in $names })) {
        if ($vm.State -notin @('Off', 'Saved')) {
            Write-Host "[hyperv] Powering off $($vm.Name) before permanent deletion..."
            Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop
        }
    }
}

function Invoke-LabDestroyDrivers {
    param([string]$OriginalDriver, [string[]]$Drivers)
    $failures = [Collections.Generic.List[string]]::new()
    $purged = [Collections.Generic.List[string]]::new()
    try {
        foreach ($driver in $Drivers) {
            try {
                $before = Set-LabDestroyDriver -Driver $driver
                if (@($before.list).Count -gt 0) {
                    Stop-LabDestroyInstances -Driver $driver -Instances @($before.list)
                    Write-Host "[$driver] Deleting all $(@($before.list).Count) instances and their disks/snapshots..."
                    $result = Invoke-LabMultipassProbe -TimeoutSeconds 180 -Arguments @('delete', '--all', '--purge')
                    if ($result.ExitCode -ne 0) { Write-Warning "Delete acknowledgement failed; verifying state. $(Format-LabDestroyFailure -Result $result -TimeoutSeconds 180)" }
                }
                # Purge is idempotent. Retry a transient daemon/TLS disconnect.
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    $result = Invoke-LabMultipassProbe -TimeoutSeconds 120 -Arguments @('purge')
                    if ($result.ExitCode -eq 0) { break }
                    if ($attempt -eq 3) { throw "Purge failed: $(Format-LabDestroyFailure -Result $result -TimeoutSeconds 120)" }
                    $null = Wait-LabDestroyDriver -Driver $driver
                }
                $after = Wait-LabDestroyDriver -Driver $driver
                if (@($after.list).Count -ne 0) { throw 'Instances remain after delete/purge.' }
                $purged.Add($driver)
                Write-Host "[$driver] Verified: no remaining instances."
            } catch {
                $failures.Add("${driver}: $($_.Exception.Message)")
                Write-Warning $failures[$failures.Count - 1]
            }
        }
    } finally {
        try {
            $null = Set-LabDestroyDriver -Driver $OriginalDriver
            Write-Host "Original driver restored and reachable: $OriginalDriver"
        } catch { $failures.Add("Driver restore: $($_.Exception.Message)") }
    }
    [pscustomobject]@{ Purged = $purged.ToArray(); Failures = $failures.ToArray() }
}
