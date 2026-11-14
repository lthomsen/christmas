# Bygger JuleHygge.exe med den C#-compiler der følger med Windows (.NET Framework 4.x)
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$out = Join-Path $PSScriptRoot 'JuleHygge.exe'
& $csc /nologo /codepage:65001 /target:winexe /optimize+ /unsafe /platform:anycpu /out:$out `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    (Join-Path $PSScriptRoot 'src\JuleHygge.cs')
if ($LASTEXITCODE -eq 0) { Write-Host "Bygget: $out" }
