#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($file in Get-ChildItem -LiteralPath $repository -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]\.work[\\/]' }) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) "PowerShell syntax errors in $($file.Name): $errors"
}

# Exercise real SSH config parsing/key generation against an isolated fixture.
# No connections or writes to the user's .ssh directory are made.
. (Join-Path $repository 'scripts/host-access.ps1')
$fixture = Join-Path $repository ('.work/verify-' + [guid]::NewGuid().ToString('N'))
$script:fixtureSshDirectory = Join-Path $fixture '.ssh/multipass-k8s-lab'
function Get-LabSshDirectory { return $script:fixtureSshDirectory }
New-Item -ItemType Directory -Path (Split-Path $script:fixtureSshDirectory -Parent) -Force | Out-Null
try {
    $config = Join-Path $fixture '.ssh/config'
    $original = "ServerAliveInterval 17`r`nHost personal`r`n    HostName example.invalid`r`n    User personal`r`nHost *`r`n    ConnectTimeout 5`r`n"
    [IO.File]::WriteAllText($config, $original)
    $unrelated = Join-Path $fixture '.ssh/personal-key'
    [IO.File]::WriteAllText($unrelated, 'untouched')
    $publicKey = Initialize-LabHostKey
    Assert-True ($publicKey -match '^ssh-ed25519 ') 'SSH public key was not generated.'
    $nodes = @(
        [pscustomobject]@{ Name = 'k8s-master-1'; IP = '192.168.35.200' },
        [pscustomobject]@{ Name = 'k8s-worker-1'; IP = '192.168.35.201' }
    )
    Set-LabHostSshConfig -Nodes $nodes
    $once = [IO.File]::ReadAllText($config)
    Set-LabHostSshConfig -Nodes $nodes
    Assert-True ([IO.File]::ReadAllText($config) -ceq $once) 'SSH config update is not idempotent.'
    foreach ($node in $nodes) {
        $effective = & ssh -F $config -G $node.Name 2>$null
        Assert-True ($LASTEXITCODE -eq 0) 'ssh -G rejected the generated config.'
        Assert-True ($effective -contains "hostname $($node.IP)") 'Incorrect SSH hostname mapping.'
        Assert-True ($effective -contains 'user ubuntu') 'SSH username is not ubuntu.'
        Assert-True ($effective -contains 'stricthostkeychecking accept-new') 'Host-key policy changed.'
    }
    $personal = & ssh -F $config -G personal 2>$null
    Assert-True ($personal -contains 'user personal') 'Existing SSH Host configuration was overwritten.'
    Assert-True ($personal -contains 'serveraliveinterval 17') 'Existing global options lost their scope.'
    Remove-LabHostAccess
    Assert-True ([IO.File]::ReadAllText($config) -ceq $original) 'SSH cleanup changed unrelated config text.'
    Assert-True (Test-Path -LiteralPath $unrelated) 'SSH cleanup removed an unrelated key.'
    Assert-True (-not (Test-Path -LiteralPath $script:fixtureSshDirectory)) 'Lab key directory remains after cleanup.'
    New-Item -ItemType Directory -Path $script:fixtureSshDirectory | Out-Null
    $refused = $false
    try { Remove-LabHostAccess } catch { $refused = $true }
    Assert-True $refused 'SSH cleanup accepted an unmarked directory.'
    Write-Host 'PowerShell syntax and isolated SSH configuration/key lifecycle checks passed.'
}
finally {
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $repository '.work')) + [IO.Path]::DirectorySeparatorChar
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
