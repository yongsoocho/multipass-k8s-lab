# Multipass on Windows can misdecode non-ASCII local paths. Open files with .NET
# and feed bytes to stdin so Multipass never receives a host filesystem path.
function Invoke-LabMultipassInput {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Base64,
        [int]$TimeoutSeconds = 120
    )
    $inputFile = if ($Base64) {
        # Windows native stdin may treat Ctrl-Z as EOF or translate CR/LF.
        # An ASCII base64 envelope keeps arbitrary file contents intact.
        $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Source))
        [IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes($encoded))
    } else { [IO.File]::OpenRead($Source) }
    $process = $null
    try {
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command multipass -ErrorAction Stop).Source)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $copy = $inputFile.CopyToAsync($process.StandardInput.BaseStream)
        if (-not $copy.Wait($TimeoutSeconds * 1000)) { throw 'Multipass stdin upload timed out.' }
        $process.StandardInput.Close()
        $remaining = [Math]::Max(1, [int]($TimeoutSeconds * 1000 - $watch.ElapsedMilliseconds))
        if (-not $process.WaitForExit($remaining)) { throw "multipass $($Arguments[0]) timed out after $TimeoutSeconds seconds." }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "multipass $($Arguments -join ' ') failed (exit $($process.ExitCode)): $errorOutput $output"
        }
        if ($errorOutput.Trim()) { Write-Host $errorOutput.Trim() }
        if ($output.Trim()) { $output.Trim() }
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        $inputFile.Dispose()
    }
}

function Send-LabFile {
    param([string]$Source, [string]$Node, [string]$Target)
    $encodedTarget = "$Target.$([guid]::NewGuid().ToString('N')).b64"
    Invoke-LabMultipassInput -Source $Source -Base64 -Arguments @('transfer', '-', "${Node}:$encodedTarget") | Out-Null
    $decode = 'import base64,pathlib,sys; src=pathlib.Path(sys.argv[1]); data=base64.b64decode(src.read_bytes(),validate=True); pathlib.Path(sys.argv[2]).write_bytes(data); src.unlink()'
    & multipass exec $Node -- python3 -c $decode $encodedTarget $Target
    if ($LASTEXITCODE -ne 0) { throw "Cannot decode transferred file on ${Node}:$Target." }
    $expected = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $actual = & multipass exec $Node -- sha256sum -- $Target 2>&1
    if ($LASTEXITCODE -ne 0 -or ($actual | Out-String) -notmatch "^$expected\s") {
        throw "Transferred file checksum mismatch on ${Node}:$Target. $actual"
    }
}
