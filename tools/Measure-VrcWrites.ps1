<#
  VRChat を遊んでいる間の、ドライブ別の書き込み量を計測する（配布物には含めない作者用ツール）
  実行: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Measure-VrcWrites.ps1
  終了: Ctrl+C（-Hours 24 なら24時間で、-StopWhenVrcExits なら VRChat の終了で止まる）。結果は measure\<開始日時>\ に出る

  見ているもの（どれも管理者権限なしで取れる）
  - ドライブ別の書き込み量: Win32_PerfRawData_PerfDisk_LogicalDisk の累積値の差分。他のアプリの分も含む
  - VRChat プロセスの書き込み量: Win32_Process.WriteTransferCount。全ドライブ合計で、ファイル以外の I/O も含む
  - フォルダ別: 開始時と終了時のファイル一覧（サイズ・更新日時）の差。同じファイルへの上書きは最後の大きさで
    1回分しか数えないので、実際の書き込み量より少なく出る（下限値）
#>
param(
    [int]$IntervalSec = 60,
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'measure'),
    [string]$VrcDir = (Join-Path $env:USERPROFILE 'AppData\LocalLow\VRChat\VRChat'),
    [switch]$StopWhenVrcExits,
    [double]$Hours = 0          # 0 は無制限。例: 24 で丸1日計測して止まる
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# --- 対象フォルダ（config.json に従う） ---
$cacheDir = $VrcDir
$pictureDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'VRChat'
$configPath = Join-Path $VrcDir 'config.json'
if (Test-Path -LiteralPath $configPath) {
    $cfg = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $names = @($cfg.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -contains 'cache_directory' -and $cfg.cache_directory) { $cacheDir = $cfg.cache_directory -replace '/', '\' }
    if ($names -contains 'picture_output_folder' -and $cfg.picture_output_folder) { $pictureDir = $cfg.picture_output_folder -replace '/', '\' }
}
$folders = [ordered]@{}
$folders['VRChat フォルダ'] = $VrcDir
if (-not ($cacheDir.TrimEnd('\') -ieq $VrcDir.TrimEnd('\'))) { $folders['キャッシュの保存先'] = $cacheDir }
$folders['写真の保存先'] = $pictureDir

$volumes = @('C:') + @($folders.Values | ForEach-Object { ([IO.Path]::GetPathRoot($_)).TrimEnd('\').ToUpper() }) |
    Where-Object { $_ -match '^[A-Z]:$' } | Select-Object -Unique

# --- 計測の部品 ---
function Get-VolumeWriteBytes {
    $h = @{}
    foreach ($d in Get-CimInstance Win32_PerfRawData_PerfDisk_LogicalDisk) { $h[$d.Name] = [uint64]$d.DiskWriteBytesPersec }
    $h
}

function Get-FileSnapshot([string]$Root) {
    $h = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $h }
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $h[$f.FullName] = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks
    }
    $h
}

# 新規・更新されたファイルの合計を、直下のフォルダごとにまとめる
function Compare-FileSnapshot([string]$Root, [hashtable]$Before) {
    $groups = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $groups }
    $rootFull = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\') + '\'
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $sig = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks
        if ($Before.ContainsKey($f.FullName) -and $Before[$f.FullName] -eq $sig) { continue }
        $rel = if ($f.FullName.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $f.FullName.Substring($rootFull.Length) } else { $f.Name }
        $key = if ($rel.Contains('\')) { $rel.Split('\')[0] } else { '(直下のファイル)' }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ Bytes = [int64]0; Files = 0 } }
        $groups[$key].Bytes += $f.Length
        $groups[$key].Files++
    }
    $groups
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    '{0:N1} MB' -f ($Bytes / 1MB)
}

# --- 開始時の状態 ---
$start = Get-Date
$runDir = Join-Path $OutDir $start.ToString('yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$csvPath = Join-Path $runDir 'samples.csv'
$summaryPath = Join-Path $runDir 'summary.txt'

Write-Host "ファイル一覧を記録しています..."
$snapshots = @{}
foreach ($k in $folders.Keys) { $snapshots[$k] = Get-FileSnapshot $folders[$k] }

$prev = Get-VolumeWriteBytes
$total = @{}; $whileRunning = @{}
foreach ($v in $volumes) { $total[$v] = [double]0; $whileRunning[$v] = [double]0 }
$procMax = @{}          # PID ごとの WriteTransferCount の最大値（終了したプロセスの分も残す）
$runningSec = 0
$seenVrc = $false
$tick = 0
'time,vrchat_running,' + (($volumes | ForEach-Object { "${_}_write_MB" }) -join ',') + ',vrchat_total_write_MB' |
    Set-Content -LiteralPath $csvPath -Encoding UTF8

function Write-Summary([bool]$WithFiles) {
    $now = Get-Date
    $elapsedH = ($now - $start).TotalHours
    $runH = $runningSec / 3600
    $idleH = [math]::Max($elapsedH - $runH, 0)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("計測期間: $($start.ToString('yyyy-MM-dd HH:mm')) - $($now.ToString('yyyy-MM-dd HH:mm'))（{0:N1} 時間）" -f $elapsedH)
    $lines.Add("VRChat が起動していた時間: {0:N1} 時間" -f $runH)
    $lines.Add('')
    $lines.Add('[ドライブ別の書き込み量]（Windows の性能カウンタ。他のアプリの分も含む）')
    foreach ($v in $volumes) {
        $idle = $total[$v] - $whileRunning[$v]
        $rateRun = if ($runH -gt 0) { Format-Size ($whileRunning[$v] / $runH) } else { '-' }
        $rateIdle = if ($idleH -gt 0) { Format-Size ($idle / $idleH) } else { '-' }
        $lines.Add("  ${v} 合計 $(Format-Size $total[$v])（VRChat 起動中 $(Format-Size $whileRunning[$v]) / 起動していない間 $(Format-Size $idle)）")
        $lines.Add("      1時間あたり: VRChat 起動中 $rateRun / 起動していない間 $rateIdle")
    }
    $vrcBytes = [double]0
    foreach ($p in $procMax.Values) { $vrcBytes += $p }
    $lines.Add('')
    $lines.Add("[VRChat プロセスの書き込み量]（全ドライブ合計。ファイル以外の I/O も含む参考値） $(Format-Size $vrcBytes)")
    if ($WithFiles) {
        $lines.Add('')
        $lines.Add('[フォルダ別: 新規・更新されたファイルの合計]（同じファイルへの上書きは1回分しか数えない下限値）')
        foreach ($k in $folders.Keys) {
            $g = Compare-FileSnapshot $folders[$k] $snapshots[$k]
            $sum = [int64]0; foreach ($x in $g.Values) { $sum += $x.Bytes }
            $lines.Add("  $k $($folders[$k]): $(Format-Size $sum)")
            foreach ($name in ($g.Keys | Sort-Object { $g[$_].Bytes } -Descending)) {
                $lines.Add("      $name $(Format-Size $g[$name].Bytes)（$($g[$name].Files) ファイル）")
            }
        }
    } else {
        $lines.Add('')
        $lines.Add('（フォルダ別の集計は 10 回ごとと終了時に更新）')
    }
    [IO.File]::WriteAllLines($summaryPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
    $lines
}

Write-Host "計測を開始しました（$IntervalSec 秒ごと）。対象ドライブ: $($volumes -join ', ')"
Write-Host "結果: $runDir"
Write-Host "終了するときは Ctrl+C を押してください。ウィンドウを閉じると最後の集計が残りません。"

try {
    while ($true) {
        Start-Sleep -Seconds $IntervalSec
        $tick++
        $cur = Get-VolumeWriteBytes
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='VRChat.exe'")
        $running = $procs.Count -gt 0
        foreach ($p in $procs) {
            $id = [string]$p.ProcessId
            $w = [double]$p.WriteTransferCount
            if (-not $procMax.ContainsKey($id) -or $procMax[$id] -lt $w) { $procMax[$id] = $w }
        }
        if ($running) { $runningSec += $IntervalSec; $seenVrc = $true }

        $cells = foreach ($v in $volumes) {
            $a = if ($prev.ContainsKey($v)) { $prev[$v] } else { [uint64]0 }
            $b = if ($cur.ContainsKey($v)) { $cur[$v] } else { $a }
            # 再起動などで累積値が戻ったときは、今の値をそのまま差分とみなす
            $delta = if ($b -ge $a) { [double]($b - $a) } else { [double]$b }
            $total[$v] += $delta
            if ($running) { $whileRunning[$v] += $delta }
            '{0:F1}' -f ($delta / 1MB)
        }
        $vrcNow = [double]0; foreach ($x in $procMax.Values) { $vrcNow += $x }
        ('{0},{1},{2},{3:F1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), [int]$running, ($cells -join ','), ($vrcNow / 1MB)) |
            Add-Content -LiteralPath $csvPath -Encoding UTF8
        $prev = $cur

        Write-Summary ($tick % 10 -eq 0) | Out-Null
        if ($StopWhenVrcExits -and $seenVrc -and -not $running) { break }
        if ($Hours -gt 0 -and ((Get-Date) - $start).TotalHours -ge $Hours) { break }
    }
} finally {
    Write-Host ''
    Write-Host '集計しています...'
    Write-Summary $true | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "保存しました: $summaryPath"
}
