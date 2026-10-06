function Test-LabCluster {
    param([string[]]$ExpectedNodes, [string]$Master = 'k8s-master-1')
    # Only fetch names: full Node JSON is large and some Windows Multipass
    # clients hang while draining large exec output through a pipe.
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $result = Invoke-LabMultipassProbe -Arguments @('exec', $Master, '--', 'kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[*].metadata.name}')
        if ($result.ExitCode -eq 0) {
            $registered = @($result.Output.Trim() -split '\s+')
            if (@($ExpectedNodes | Where-Object { $_ -notin $registered }).Count -eq 0) { break }
        }
        if ($attempt -eq 29) { throw "Timed out checking registered nodes. $($result.Output)" }
        Start-Sleep -Seconds 2
    }
    foreach ($command in @(@('get', '--raw=/readyz'), @('get', 'nodes', '-o', 'wide'))) {
        $result = Invoke-LabMultipassProbe -TimeoutSeconds 30 -Arguments (@('exec', $Master, '--', 'kubectl') + $command)
        if ($result.ExitCode -ne 0) { throw "Cluster verification failed: $($result.Output)" }
        Write-Host $result.Output
    }
    Write-Host 'Bootstrap complete. No CNI was installed: NotReady nodes and Pending CoreDNS are expected.'
    Write-Host 'Install one CNI manually, or run .\install-calico.ps1 OR .\install-flannel.ps1.'
    Write-Host 'SSH: ssh k8s-master-1 | SFTP: sftp k8s-master-1 | Ubuntu password fallback: test'
}
