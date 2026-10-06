#requires -Version 7.2
param([switch]$Extended)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'scripts/network.ps1')
. (Join-Path $repository 'scripts/cluster-check.ps1')
$masters = if ($Extended) { 3 } else { 1 }
$workers = if ($Extended) { 6 } else { 2 }
$names = @(1..$masters | ForEach-Object { "k8s-master-$_" }) + @(1..$workers | ForEach-Object { "k8s-worker-$_" })
Test-LabCluster -ExpectedNodes $names
