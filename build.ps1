<#
  配布用 zip を dist\ に作る。テストが通らなければ作らない。
  実行: powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# .ps1 は BOM 付き UTF-8 でないと、Windows PowerShell 5.1 が日本語を cp932 として読んで壊す
foreach ($f in Get-ChildItem $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\(dist|tests\\_work)\\' }) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "BOM がありません: $($f.FullName)"
    }
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) { throw "構文エラー: $($f.FullName)`n$($errs -join "`n")" }
}

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-Logic.ps1')
if ($LASTEXITCODE -ne 0) { throw 'テストが失敗したので zip を作りません' }

$version = ([regex]::Match((Get-Content (Join-Path $root 'VRCCacheMover.ps1') -Raw -Encoding UTF8), "\`$script:Version = '([^']+)'")).Groups[1].Value
if (-not $version) { throw '版番号を読めません' }

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "VRCCacheMover_v$version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage -Force | Out-Null
Copy-Item (Join-Path $root 'VRCCacheMover.ps1') $stage
Copy-Item (Join-Path $root 'VRCCacheMover.bat') $stage
Copy-Item (Join-Path $root 'README.md') (Join-Path $stage 'README.txt')
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt')

$zip = Join-Path $dist "VRCCacheMover_v$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
Write-Host "built: $zip"
