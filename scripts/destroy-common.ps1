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

function Get-LabDestroyDriver {
    $result = Invoke-LabMultipassProbe -Arguments @('get', 'local.driver')
    if ($result.ExitCode -ne 0) { throw "Cannot read Multipass driver: $($result.Output)" }
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
            if ($result.ExitCode -ne 0) { throw $result.Output }
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
        if ($result.ExitCode -ne 0) { Write-Warning "Driver change acknowledgement failed; verifying state. $($result.Output)" }
    }
    Wait-LabDestroyDriver -Driver $Driver
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
                    Write-Host "[$driver] Deleting all $(@($before.list).Count) instances and their disks/snapshots..."
                    $result = Invoke-LabMultipassProbe -TimeoutSeconds 180 -Arguments @('delete', '--all', '--purge')
                    if ($result.ExitCode -ne 0) { Write-Warning "Delete acknowledgement failed; verifying state. $($result.Output)" }
                }
                # Purge is idempotent. Retry a transient daemon/TLS disconnect.
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    $result = Invoke-LabMultipassProbe -TimeoutSeconds 120 -Arguments @('purge')
                    if ($result.ExitCode -eq 0) { break }
                    if ($attempt -eq 3) { throw "Purge failed: $($result.Output)" }
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
