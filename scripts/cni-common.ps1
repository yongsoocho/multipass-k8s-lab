. (Join-Path $PSScriptRoot 'multipass-io.ps1')

function Invoke-CniMultipass {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & multipass @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "multipass $($Arguments -join ' ') failed (exit $LASTEXITCODE)."
    }
}

function Install-LabCni {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('calico', 'flannel')][string]$Provider,
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 600
    )
    if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
        throw 'Multipass is not installed.'
    }

    $first = 'k8s-master-1'
    $installer = Join-Path $PSScriptRoot 'install-cni.sh'
    $names = (Invoke-CniMultipass @('exec', $first, '--', 'kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[*].metadata.name}') | Out-String).Trim()
    $nodes = @($names -split '\s+' | Where-Object { $_ })
    if ($nodes.Count -eq 0) { throw 'No joined nodes found. Run init.ps1 first.' }

    # Check every VM before changing cluster resources, including stale host CNI files.
    foreach ($name in $nodes) {
        if ($name -notmatch '^k8s-(master|worker)-[1-6]$') {
            throw "Unexpected node '$name'. These installers target the Multipass lab only."
        }
        Write-Host "[$name] Checking existing CNI configuration."
        Send-LabFile -Source $installer -Node $name -Target '/home/ubuntu/install-cni.sh'
        Invoke-CniMultipass @('exec', $name, '--', 'bash', '/home/ubuntu/install-cni.sh', 'check', $Provider)
    }

    Write-Host "Installing $Provider. Image downloads and node readiness may take several minutes."
    Invoke-CniMultipass @('exec', $first, '--', 'bash', '/home/ubuntu/install-cni.sh', 'install', $Provider, "$TimeoutSeconds")
}
