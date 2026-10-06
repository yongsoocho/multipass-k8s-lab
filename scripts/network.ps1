function Invoke-LabMultipassProbe {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 15)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command multipass).Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
    $standardOutput = $stdout.GetAwaiter().GetResult()
    $standardError = $stderr.GetAwaiter().GetResult()
    $output = $standardOutput + $standardError
    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    $process.Dispose()
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output.Trim(); TimedOut = $timedOut; StandardOutput = $standardOutput; StandardError = $standardError }
}

function Set-LabNodeNetwork {
    param([string]$Node, [string]$Address, [string]$Mac, [int]$TimeoutSeconds = 240)
    # Validate without touching live links, then let systemd own the apply job.
    Invoke-Mp @('exec', $Node, '--', 'sudo', 'netplan', 'generate') | Out-Null
    $runId = [guid]::NewGuid().ToString('N')
    $state = "/run/multipass-k8s-network/$runId"
    $dispatch = Invoke-LabMultipassProbe -TimeoutSeconds 20 -Arguments @(
        'exec', $Node, '--', 'sudo', 'systemd-run', '--quiet', "--unit=k8s-network-$runId",
        '--on-active=2s', '--timer-property=AccuracySec=1s', '/bin/bash',
        '/usr/local/lib/multipass-k8s/apply-network.sh', $Address, $Mac, $state
    )
    if ($dispatch.ExitCode -ne 0) { Write-Warning "[$Node] Network job acknowledgement unavailable; checking its saved result. $($dispatch.Output)" }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $dispatch.Output
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-LabMultipassProbe -Arguments @('exec', $Node, '--', 'bash', '-c', "if test -f '$state/exit-code'; then printf 'EXIT:'; cat '$state/exit-code'; cat '$state/apply.log'; else echo PENDING; fi")
        if ($probe.ExitCode -eq 0 -and $probe.Output -match '^EXIT:(\d+)\r?\n?') {
            $result = [int]$Matches[1]
            if ($result -ne 0) { throw "[$Node] netplan job failed (exit $result). $($probe.Output)" }
            Write-Host "[$Node] Network applied and Multipass connection restored."
            Write-Host $probe.Output
            return
        }
        if ($probe.ExitCode -ne 0) { $lastError = "exit $($probe.ExitCode): $($probe.Output)" }
        Write-Host "[$Node] Waiting for network apply/reconnection ($([int]$watch.Elapsed.TotalSeconds)s)..."
        Start-Sleep -Seconds 3
    }
    throw "[$Node] Network verification timed out. $lastError`nVM log: $state/apply.log. Check with: multipass exec $Node -- sudo cat $state/apply.log"
}
