#requires -Version 7.2
param(
    [ValidateRange(60, 3600)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'scripts/cni-common.ps1')
Install-LabCni -Provider calico -TimeoutSeconds $TimeoutSeconds
