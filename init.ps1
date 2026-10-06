#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PowerShell does not reliably parse GNU-style --extend as a switch parameter.
$extended = $false
$resume = $false
foreach ($argument in $args) {
    switch ($argument) {
        { $_ -in @('-e', '--extend') } { $extended = $true }
        { $_ -in @('-Resume', '--resume') } { $resume = $true }
        default { throw 'Usage: .\init.ps1 [-e|--extend] [-Resume]' }
    }
}

$root = Split-Path -Parent $PSCommandPath
. (Join-Path $root 'scripts/host-access.ps1')
. (Join-Path $root 'scripts/network.ps1')
$switchName = 'MultipassK8s'
$vip = '192.168.35.209'
$k8sMinor = 'v1.37'
$nodes = [System.Collections.Generic.List[object]]::new()
$masterCount = if ($extended) { 3 } else { 1 }
$workerCount = if ($extended) { 6 } else { 2 }
for ($i = 1; $i -le $masterCount; $i++) {
    $nodes.Add([pscustomobject]@{ Name = "k8s-master-$i"; IP = "192.168.35.$(199 + $i)"; Mac = ('02:35:00:00:00:{0:x2}' -f (199 + $i)); Cpu = 2; Memory = '2G'; Disk = '20G'; Role = 'master'; Index = $i })
}
for ($i = 1; $i -le $workerCount; $i++) {
    $lastOctet = 199 + $masterCount + $i
    $nodes.Add([pscustomobject]@{ Name = "k8s-worker-$i"; IP = "192.168.35.$lastOctet"; Mac = ('02:35:00:00:00:{0:x2}' -f $lastOctet); Cpu = 1; Memory = '2G'; Disk = '15G'; Role = 'worker'; Index = $i })
}

function Invoke-Mp {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $recent = [Collections.Generic.Queue[string]]::new()
    & multipass @Arguments 2>&1 | ForEach-Object {
        $recent.Enqueue([string]$_)
        if ($recent.Count -gt 40) { $null = $recent.Dequeue() }
        $_
    }
    if ($LASTEXITCODE -ne 0) { throw "multipass $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($recent.ToArray() -join [Environment]::NewLine)" }
}

function Send-File {
    param([string]$Source, [string]$Node, [string]$Target)
    Invoke-Mp @('transfer', $Source, "${Node}:$Target") | Out-Null
}

function Run-Node {
    param([string]$Node, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Command)
    Write-Host "[$Node] $($Command -join ' ')"
    Invoke-Mp (@('exec', $Node, '--') + $Command)
}

if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) { throw 'Multipass is not installed.' }
foreach ($command in @('ssh', 'sftp', 'ssh-keygen')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Windows OpenSSH Client is required ($command not found)." }
}
if (-not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell module is unavailable. Enable Hyper-V and restart Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator.' }

$existing = @((Invoke-Mp @('list', '--format', 'json') | Out-String | ConvertFrom-Json).list)
if (-not $resume -and @($existing | Where-Object { $_.name -like 'k8s-*' }).Count -gt 0) {
    throw 'Existing k8s-* instances found. For a provisioning failure before kubeadm init/join, rerun with -Resume (and -e for extended).'
}

$driver = (Invoke-Mp @('get', 'local.driver') | Out-String).Trim()
if ($driver -ne 'hyperv') {
    if ($existing.Count -gt 0) { throw "Current driver is '$driver' and has instances. Remove or migrate them before switching to hyperv." }
    Invoke-Mp @('set', 'local.driver=hyperv') | Out-Null
    $existing = @((Invoke-Mp @('list', '--format', 'json') | Out-String | ConvertFrom-Json).list)
    if ($existing.Count -gt 0) { throw 'The hyperv driver already has instances. Inspect them before building this cluster.' }
}

$expectedNames = @($nodes | ForEach-Object Name)
$existingNames = @($existing | ForEach-Object name)
if ($resume) {
    $unexpected = @($existingNames | Where-Object { $_ -like 'k8s-*' -and $_ -notin $expectedNames })
    if ($unexpected.Count) { throw "Existing nodes do not match this topology: $($unexpected -join ', '). Use the original -e setting." }
    foreach ($node in $nodes) {
        if ($node.Name -notin $existingNames) { continue }
        $instance = $existing | Where-Object name -eq $node.Name
        if ($instance.state -notin @('Running', 'Stopped')) { throw "Cannot resume $($node.Name) in state $($instance.state)." }
        if ($instance.state -eq 'Stopped') { Invoke-Mp @('start', $node.Name) | Out-Host }
        Send-File (Join-Path $root 'scripts/check-resume.sh') $node.Name '/home/ubuntu/multipass-k8s-check-resume.sh'
        Run-Node $node.Name @('bash', '/home/ubuntu/multipass-k8s-check-resume.sh', $node.Name, $node.Mac) | Out-Host
    }
}

$hostIps = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^192\.168\.35\.\d+$' -and $_.PrefixLength -eq 24 -and $_.InterfaceAlias -notlike 'vEthernet*' })
$switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if (-not $switch) {
    if ($hostIps.Count -ne 1) { throw 'Exactly one physical host adapter on 192.168.35.0/24 is required to create the external switch.' }
    $adapter = Get-NetAdapter -InterfaceIndex $hostIps[0].InterfaceIndex
    Write-Host "Creating external Hyper-V switch on $($adapter.Name). The host link may briefly reset."
    $switch = New-VMSwitch -Name $switchName -NetAdapterName $adapter.Name -AllowManagementOS $true
}
if ($switch.SwitchType -ne 'External') { throw "$switchName exists but is not an external switch." }
$networks = Invoke-Mp @('networks') | Out-String
if ($networks -notmatch "(?m)^$([regex]::Escape($switchName))\s+switch\s") { throw "$switchName is not visible to Multipass. Check the Hyper-V driver and switch." }

foreach ($node in $nodes) {
    if ($resume -and $node.Name -in $existingNames) { continue }
    if (Test-Connection -TargetName $node.IP -Count 1 -Quiet -TimeoutSeconds 1) { throw "IP $($node.IP) already responds on the LAN." }
}
if ($extended -and (Test-Connection -TargetName $vip -Count 1 -Quiet -TimeoutSeconds 1)) { throw "VIP $vip already responds on the LAN." }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('multipass-k8s-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $publicKeys = [System.Collections.Generic.List[string]]::new()
    $publicKeys.Add((Initialize-LabHostKey))
    $hostsFile = Join-Path $temporary 'lab-hosts'
    $hostsLines = @($nodes | ForEach-Object { "$($_.IP) $($_.Name)" })
    if ($extended) { $hostsLines += "$vip k8s-api" } else { $hostsLines += '192.168.35.200 k8s-api' }
    [IO.File]::WriteAllText($hostsFile, ($hostsLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    foreach ($node in $nodes) {
        if ($node.Name -notin $existingNames) {
            Write-Host "Launching $($node.Name) at $($node.IP)"
            $cloudInit = Join-Path $temporary "$($node.Name)-cloud-init.yaml"
            @'
#cloud-config
ssh_pwauth: true
chpasswd:
  users:
    - name: ubuntu
      password: test
      type: text
  expire: false
packages:
  - openssh-server
runcmd:
  - [systemctl, enable, --now, ssh]
'@ | Set-Content -LiteralPath $cloudInit -Encoding utf8
            Invoke-Mp @('launch', '24.04', '--name', $node.Name, '--cpus', "$($node.Cpu)", '--memory', $node.Memory, '--disk', $node.Disk, '--network', "name=$switchName,mode=manual,mac=$($node.Mac)", '--cloud-init', $cloudInit, '--timeout', '900') | Out-Host
        } else {
            Write-Host "Resuming provisioning of $($node.Name) at $($node.IP)"
        }
        Run-Node $node.Name @('cloud-init', 'status', '--wait') | Out-Null
        $netplan = Join-Path $temporary "$($node.Name)-netplan.yaml"
        @"
network:
  version: 2
  ethernets:
    k8s-lan:
      match:
        macaddress: '$($node.Mac)'
      dhcp4: false
      addresses: [$($node.IP)/24]
"@ | Set-Content -LiteralPath $netplan -Encoding ascii
        Send-File $netplan $node.Name '/home/ubuntu/10-k8s-lan.yaml'
        Run-Node $node.Name @('sudo', 'mv', '/home/ubuntu/10-k8s-lan.yaml', '/etc/netplan/10-k8s-lan.yaml') | Out-Null
        Run-Node $node.Name @('sudo', 'chmod', '600', '/etc/netplan/10-k8s-lan.yaml') | Out-Null
        Send-File (Join-Path $root 'scripts/apply-network.sh') $node.Name '/home/ubuntu/multipass-k8s-apply-network.sh'
        Run-Node $node.Name @('sudo', 'install', '-D', '-m', '755', '/home/ubuntu/multipass-k8s-apply-network.sh', '/usr/local/lib/multipass-k8s/apply-network.sh') | Out-Null
        Set-LabNodeNetwork -Node $node.Name -Address $node.IP -Mac $node.Mac
        Run-Node $node.Name @('bash', '-c', "ip -4 addr | grep -F '$($node.IP)/24'") | Out-Null
        Send-File (Join-Path $root 'scripts/setup-node.sh') $node.Name '/home/ubuntu/setup-node.sh'
        Run-Node $node.Name @('bash', '/home/ubuntu/setup-node.sh', $k8sMinor, $node.IP) | Out-Host
        Send-File $hostsFile $node.Name '/home/ubuntu/lab-hosts'
        Send-File (Join-Path $root 'scripts/setup-access.sh') $node.Name '/home/ubuntu/setup-access.sh'
        $nodePublicKey = (Run-Node $node.Name @('bash', '/home/ubuntu/setup-access.sh', 'prepare', '/home/ubuntu/lab-hosts') | Out-String).Trim()
        if ($nodePublicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3} [^\r\n]+$') { throw "Invalid public key returned by $($node.Name)." }
        $publicKeys.Add($nodePublicKey)
    }

    $publicKeysFile = Join-Path $temporary 'lab-authorized-keys'
    [IO.File]::WriteAllText($publicKeysFile, ($publicKeys -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    foreach ($node in $nodes) {
        Send-File $publicKeysFile $node.Name '/home/ubuntu/lab-authorized-keys'
        Run-Node $node.Name @('bash', '/home/ubuntu/setup-access.sh', 'authorize', '/home/ubuntu/lab-authorized-keys') | Out-Null
    }
    Set-LabHostSshConfig -Nodes $nodes.ToArray()
    $sftpBatch = Join-Path $temporary 'sftp-check.txt'
    [IO.File]::WriteAllText($sftpBatch, "pwd`nquit`n", [Text.UTF8Encoding]::new($false))
    foreach ($node in $nodes) {
        $remoteName = (& ssh -o BatchMode=yes -o ConnectTimeout=10 $node.Name hostname | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $remoteName -ne $node.Name) { throw "SSH by hostname failed for $($node.Name)." }
        & sftp -o ConnectTimeout=10 -b $sftpBatch $node.Name
        if ($LASTEXITCODE -ne 0) { throw "SFTP by hostname failed for $($node.Name)." }
        Run-Node $node.Name @('ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'k8s-master-1', 'hostname') | Out-Null
    }
    Write-Host 'SSH/SFTP by hostname and VM-to-master SSH checks passed.'

    if ($extended) {
        foreach ($node in @($nodes | Where-Object Role -eq 'master')) {
            # Match the configured address instead; interface names vary between Hyper-V versions.
            $iface = (Run-Node $node.Name @('bash', '-c', "ip -o -4 addr show | awk '/$($node.IP)\// {print `$2}'") | Out-String).Trim()
            if (-not $iface) { throw "Cannot find LAN interface on $($node.Name)." }
            Send-File (Join-Path $root 'scripts/setup-lb.sh') $node.Name '/home/ubuntu/setup-lb.sh'
            Run-Node $node.Name @('bash', '/home/ubuntu/setup-lb.sh', "$($node.Index)", $node.IP, $vip, $iface) | Out-Host
        }
    }

    $first = 'k8s-master-1'
    $endpoint = if ($extended) { "${vip}:16443" } else { '192.168.35.200:6443' }
    $kubernetesVersion = (Run-Node $first @('kubeadm', 'version', '-o', 'short') | Out-String).Trim()
    if ($kubernetesVersion -notmatch '^v1\.37\.\d+$') { throw "Unexpected kubeadm version: $kubernetesVersion" }
    $initArgs = @('sudo', 'kubeadm', 'init', "--kubernetes-version=$kubernetesVersion", '--apiserver-advertise-address=192.168.35.200', "--control-plane-endpoint=$endpoint", '--pod-network-cidr=10.244.0.0/16', '--upload-certs')
    Run-Node $first $initArgs | Out-Host
    Run-Node $first @('bash', '-c', 'mkdir -p /home/ubuntu/.kube && sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config') | Out-Null

    $workerJoin = (Run-Node $first @('sudo', 'kubeadm', 'token', 'create', '--print-join-command') | Out-String).Trim()
    if ($workerJoin -notmatch '^kubeadm join ') { throw 'Could not obtain worker join command.' }
    if ($extended) {
        $certOutput = Run-Node $first @('sudo', 'kubeadm', 'init', 'phase', 'upload-certs', '--upload-certs') | Out-String
        $certKey = ([regex]::Matches($certOutput, '(?m)^[a-f0-9]{64}$') | Select-Object -Last 1).Value
        if (-not $certKey) { throw 'Could not obtain control-plane certificate key.' }
        foreach ($node in @($nodes | Where-Object { $_.Role -eq 'master' -and $_.Index -gt 1 })) {
            Run-Node $node.Name @('bash', '-c', "sudo $workerJoin --control-plane --certificate-key $certKey --apiserver-advertise-address=$($node.IP)") | Out-Host
        }
    }
    foreach ($node in @($nodes | Where-Object Role -eq 'worker')) {
        Run-Node $node.Name @('bash', '-c', "sudo $workerJoin") | Out-Host
    }
    foreach ($node in @($nodes | Where-Object Role -eq 'master')) {
        Run-Node $node.Name @('bash', '-c', 'mkdir -p /home/ubuntu/.kube && sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config && chmod 600 /home/ubuntu/.kube/config && sudo install -d -m 700 /root/.kube && sudo install -m 600 /etc/kubernetes/admin.conf /root/.kube/config') | Out-Null
    }
    # Node registration does not require a CNI; Ready does.
    $expectedNodes = @($nodes | ForEach-Object Name)
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $registered = (Run-Node $first @('kubectl', 'get', 'nodes', '-o', 'json') | Out-String | ConvertFrom-Json).items
        $registeredNames = @($registered | ForEach-Object { $_.metadata.name })
        if (@($expectedNodes | Where-Object { $_ -notin $registeredNames }).Count -eq 0) { break }
        if ($attempt -eq 29) { throw 'Timed out waiting for all nodes to register.' }
        Start-Sleep -Seconds 2
    }
    Run-Node $first @('kubectl', 'get', '--raw=/readyz') | Out-Host
    Run-Node $first @('kubectl', 'get', 'nodes', '-o', 'wide') | Out-Host
    Write-Host 'Bootstrap complete. No CNI was installed: NotReady nodes and Pending CoreDNS are expected.'
    Write-Host 'Install one CNI manually, or run .\install-calico.ps1 OR .\install-flannel.ps1.'
    Write-Host 'SSH: ssh k8s-master-1 | SFTP: sftp k8s-master-1 | Ubuntu password fallback: test'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedTemporary = [IO.Path]::GetFullPath($temporary)
    if ($resolvedTemporary.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTemporary -Leaf) -like 'multipass-k8s-*') {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
