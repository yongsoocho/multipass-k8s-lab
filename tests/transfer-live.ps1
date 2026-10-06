#requires -Version 7.2
param([string]$Node = 'k8s-master-1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts/multipass-io.ps1')
$id = [guid]::NewGuid().ToString('N')
$fixture = Join-Path $repository ".work/transfer-$id"
$remote = "/tmp/multipass-k8s-transfer-$id"
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    & multipass exec $Node -- mkdir -m 700 -- $remote
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create guest test directory.' }
    # All byte values catch stdin text conversion, CR/LF changes, and truncation.
    $binary = Join-Path $fixture '한글 공백 [파일].bin'
    [IO.File]::WriteAllBytes($binary, [byte[]](0..255))
    Send-LabFile -Source $binary -Node $Node -Target "$remote/bytes.bin"
    $empty = Join-Path $fixture '빈 파일.txt'
    [IO.File]::WriteAllBytes($empty, [byte[]]@())
    Send-LabFile -Source $empty -Node $Node -Target "$remote/empty"
    foreach ($file in Get-ChildItem (Join-Path $repository 'scripts') -Filter '*.sh') {
        Send-LabFile -Source $file.FullName -Node $Node -Target "$remote/$($file.Name)"
        & multipass exec $Node -- bash -n "$remote/$($file.Name)"
        if ($LASTEXITCODE -ne 0) { throw "Guest bash syntax failure: $($file.Name)" }
    }
    $failed = $false
    try { Send-LabFile -Source $binary -Node $Node -Target "$remote/missing/subdirectory/file" } catch { $failed = $true }
    if (-not $failed) { throw 'Transfer to a missing parent did not fail.' }
    Write-Host 'Live Unicode/space/bracket path, binary/empty file, all shell scripts, SHA256, and failed-transfer checks passed.'
}
finally {
    if ($remote -notmatch '^/tmp/multipass-k8s-transfer-[a-f0-9]{32}$') { throw 'Unsafe guest cleanup path.' }
    & multipass exec $Node -- rm -rf -- $remote
    $allowed = [IO.Path]::GetFullPath((Join-Path $repository '.work')) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
