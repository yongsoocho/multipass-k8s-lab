# Loaded by init.ps1 and destroy.ps1; no changes occur until a function is called.
function Get-LabSshDirectory {
    $profileDirectory = [Environment]::GetFolderPath('UserProfile')
    if (-not $profileDirectory) { throw 'Cannot locate the current user profile.' }
    return Join-Path $profileDirectory '.ssh/multipass-k8s-lab'
}

function Set-LabManagedBlock {
    param([string]$Path, [string]$Content)
    $begin = '# BEGIN MULTIPASS-K8S-LAB'
    $end = '# END MULTIPASS-K8S-LAB'
    $existing = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $pattern = '(?ms)^' + [regex]::Escape($begin) + '\r?\n.*?^' + [regex]::Escape($end) + '(?:\r?\n|$)'
    if (($existing.Contains($begin) -or $existing.Contains($end)) -and -not [regex]::IsMatch($existing, $pattern)) {
        throw "Incomplete lab block in $Path; repair it before continuing."
    }
    $remaining = [regex]::Replace($existing, $pattern, '')
    $updated = if ($Content) { "$begin`n$($Content.TrimEnd())`nHost *`n$end`n$remaining" } else { $remaining }
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Initialize-LabHostKey {
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { throw 'Install the Windows OpenSSH Client optional feature (ssh and ssh-keygen).' }
    $directory = Get-LabSshDirectory
    $marker = Join-Path $directory '.managed-by-multipass-k8s-lab'
    if (Test-Path -LiteralPath $directory) {
        if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker).Trim() -ne 'multipass-k8s-lab/v1') {
            throw "Refusing to reuse an unmarked SSH directory: $directory"
        }
    } else {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText($marker, 'multipass-k8s-lab/v1')
    }
    $key = Join-Path $directory 'id_ed25519'
    if (-not (Test-Path -LiteralPath $key)) {
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command ssh-keygen).Source)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        foreach ($argument in @('-q', '-t', 'ed25519', '-N', '', '-C', 'multipass-k8s-host', '-f', $key)) {
            $start.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($start)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Failed to generate the dedicated lab SSH key.' }
        $process.Dispose()
    }
    if (-not (Test-Path -LiteralPath "$key.pub")) { throw "Missing public key: $key.pub" }
    return [IO.File]::ReadAllText("$key.pub").Trim()
}

function Set-LabHostSshConfig {
    param([object[]]$Nodes)
    $directory = Get-LabSshDirectory
    $key = (Join-Path $directory 'id_ed25519').Replace('\', '/')
    $knownHosts = (Join-Path $directory 'known_hosts').Replace('\', '/')
    $lines = foreach ($node in $Nodes) {
        "Host $($node.Name)"
        "    HostName $($node.IP)"
        '    User ubuntu'
        "    IdentityFile `"$key`""
        '    IdentitiesOnly yes'
        "    UserKnownHostsFile `"$knownHosts`""
        '    StrictHostKeyChecking accept-new'
        ''
    }
    Set-LabManagedBlock -Path (Join-Path (Split-Path $directory -Parent) 'config') -Content ($lines -join "`n")
}

function Remove-LabHostAccess {
    $directory = [IO.Path]::GetFullPath((Get-LabSshDirectory))
    $sshDirectory = [IO.Path]::GetFullPath((Split-Path $directory -Parent))
    $expected = [IO.Path]::GetFullPath((Join-Path $sshDirectory 'multipass-k8s-lab'))
    if ($directory -ne $expected -or -not $directory.StartsWith($sshDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SSH cleanup path is outside the expected directory.'
    }
    if (Test-Path -LiteralPath $directory) {
        $item = Get-Item -LiteralPath $directory
        $marker = Join-Path $directory '.managed-by-multipass-k8s-lab'
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker).Trim() -ne 'multipass-k8s-lab/v1') {
            throw "Refusing to delete an unmarked or linked SSH directory: $directory"
        }
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    $config = Join-Path $sshDirectory 'config'
    if (Test-Path -LiteralPath $config) { Set-LabManagedBlock -Path $config -Content '' }
}
