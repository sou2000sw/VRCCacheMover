<#
  VRCCacheMover.ps1 のロジック回帰テスト（GUI は起動しない）
  実行: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Logic.ps1
  偽の VRChat フォルダを tests\_work に作って試す。実際の config.json には触れない。
  失敗が1件でもあれば exit 1。
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $PSScriptRoot '_work'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$vrc = Join-Path $work 'vrc'
New-Item -ItemType Directory $vrc -Force | Out-Null
$cfgPath = Join-Path $vrc 'config.json'
$noBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($cfgPath, '{"betas":["particle_system_limiter"],"camera_res_height":1080}', $noBom)

# 手動リンク済みの写真フォルダを再現する（ジャンクションは管理者権限なしで作れる）
$picDef = Join-Path $work 'pic_default'
$picReal = Join-Path $work 'pic_real'
New-Item -ItemType Directory $picReal -Force | Out-Null
cmd /c mklink /J "$picDef" "$picReal" | Out-Null

. (Join-Path $root 'VRCCacheMover.ps1') -VrcDir $vrc -PictureDefaultDir $picDef -NoGui
function Test-VrcRunning { $false }   # 実機の VRChat の起動状態に左右されないよう差し替える

$script:failures = 0
function Assert-True([string] $Label, [bool] $Ok) {
    if ($Ok) { Write-Host "PASS $Label" } else { Write-Host "FAIL $Label"; $script:failures++ }
}
function Read-TestConfig { [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }

try {
    # 1. 既存設定を残してキャッシュを追加（日本語パス）
    $plan = New-ChangePlan -CacheDir (Join-Path $work 'キャッシュ') -CacheSizeGB 40 -PictureDir '' -SplitByDate $true
    Assert-True '1 no errors' ($plan.Errors.Count -eq 0)
    $bak = Invoke-ChangePlan $plan
    $out = Read-TestConfig
    Assert-True '1 no BOM' ([IO.File]::ReadAllBytes($cfgPath)[0] -ne 0xEF)
    Assert-True '1 backup made' ([bool]$bak -and (Test-Path $bak))
    Assert-True '1 betas still array' ($out.betas -is [array] -and $out.betas[0] -eq 'particle_system_limiter')
    Assert-True '1 camera kept' ($out.camera_res_height -eq 1080)
    Assert-True '1 cache_size 40' ($out.cache_size -eq 40)
    Assert-True '1 kana path with slashes' ($out.cache_directory -match 'キャッシュ$' -and $out.cache_directory -notmatch '\\')
    Assert-True '1 folder created' (Test-Path (Join-Path $work 'キャッシュ'))

    # 2. 写真: リンク先と違う場所は警告、同じ場所は警告なし、月別オフは false を書く
    $p2 = New-ChangePlan -CacheDir $out.cache_directory -CacheSizeGB 40 -PictureDir (Join-Path $work 'pic_other') -SplitByDate $false
    Assert-True '2 link warning' (@($p2.Warnings | Where-Object { $_ -match 'リンク済み' }).Count -eq 1)
    $p3 = New-ChangePlan -CacheDir $out.cache_directory -CacheSizeGB 40 -PictureDir $picReal -SplitByDate $false
    Assert-True '2 same target, no link warning' (@($p3.Warnings | Where-Object { $_ -match 'リンク済み' }).Count -eq 0)
    [void](Invoke-ChangePlan $p3)
    Assert-True '2 split false written' ((Read-TestConfig).picture_output_split_by_date -eq $false)

    # 3. 入力エラー
    $p4 = New-ChangePlan -CacheDir (Join-Path $vrc 'sub') -CacheSizeGB 30 -PictureDir 'relative\x' -SplitByDate $true
    Assert-True '3 inside vrc + relative = 2 errors' ($p4.Errors.Count -eq 2)
    $p5 = New-ChangePlan -CacheDir '' -CacheSizeGB 29 -PictureDir '' -SplitByDate $true
    Assert-True '3 size below 30 is error' ($p5.Errors.Count -eq 1)

    # 4. すべて既定に戻しても他の設定は残る
    [void](Invoke-ChangePlan (New-ChangePlan -CacheDir '' -CacheSizeGB 30 -PictureDir '' -SplitByDate $true))
    $out = Read-TestConfig
    Assert-True '4 keys removed, others kept' (-not $out.PSObject.Properties['cache_directory'] -and -not $out.PSObject.Properties['cache_size'] -and $out.camera_res_height -eq 1080)

    # 5. 何も残らなければ config.json を消す
    [IO.File]::WriteAllText($cfgPath, '{"cache_directory":"F:/x"}', $noBom)
    [void](Invoke-ChangePlan (New-ChangePlan -CacheDir '' -CacheSizeGB 30 -PictureDir '' -SplitByDate $true))
    Assert-True '5 empty config deleted' (-not (Test-Path $cfgPath))

    # 6. 壊れた JSON は例外にして、ファイルには触れない
    [IO.File]::WriteAllText($cfgPath, '{broken', $noBom)
    $threw = $false
    try { [void](New-ChangePlan -CacheDir '' -CacheSizeGB 30 -PictureDir '' -SplitByDate $true) } catch { $threw = $true }
    Assert-True '6 broken json throws' $threw
    Assert-True '6 file untouched' ([IO.File]::ReadAllText($cfgPath) -eq '{broken')

    # 7. 参照ボタン用の専用フォルダ付与
    Assert-True '7 drive root gets subfolder' ((Join-AutoSubfolder 'H:\' 'VRCCache') -eq 'H:\VRCCache')
    Assert-True '7 no double subfolder' ((Join-AutoSubfolder 'H:\VRCCache' 'VRCCache') -eq 'H:\VRCCache')

    # 8. 写真の移動案内（移す元と先を示すだけで、ファイルは動かさない）
    $picOld = Join-Path $work 'pic_old'
    $picNew = Join-Path $work 'pic_new'
    $picEmpty = Join-Path $work 'pic_empty'
    New-Item -ItemType Directory (Join-Path $picOld '2025-04') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $picOld '2025-04\a.png'), 'x')
    New-Item -ItemType Directory $picEmpty -Force | Out-Null
    $m = Get-PictureMove ($picOld -replace '\\', '/') $picNew
    Assert-True '8 move found' ($m -and $m.From -ieq $picOld -and $m.To -ieq $picNew)
    Assert-True '8 same folder no move' ($null -eq (Get-PictureMove ($picOld -replace '\\', '/') $picOld))
    Assert-True '8 empty folder no move' ($null -eq (Get-PictureMove $picEmpty $picNew))
    Assert-True '8 missing folder no move' ($null -eq (Get-PictureMove (Join-Path $work 'nothing') $picNew))
    Assert-True '8 linked default no move' ($null -eq (Get-PictureMove '' $picNew))
    $savedOd = $env:OneDrive
    try {
        $env:OneDrive = $work
        Assert-True '8 onedrive detected' ((Get-PictureMove $picOld $picNew).OnOneDrive)
        $env:OneDrive = Join-Path $work 'pic_ol'   # 名前の前方一致だけでは OneDrive 扱いしない
        Assert-True '8 onedrive prefix only' (-not (Get-PictureMove $picOld $picNew).OnOneDrive)
    } finally { $env:OneDrive = $savedOd }
    [IO.File]::WriteAllText($cfgPath, ('{"picture_output_folder":"' + ($picOld -replace '\\', '/') + '"}'), $noBom)
    $p8 = New-ChangePlan -CacheDir '' -CacheSizeGB 30 -PictureDir $picNew -SplitByDate $true
    Assert-True '8 plan has move' ($p8.PictureMove -and $p8.PictureMove.From -ieq $picOld)
    Assert-True '8 photo untouched' (Test-Path (Join-Path $picOld '2025-04\a.png'))
} finally {
    if (Test-Path $picDef) { cmd /c rmdir "$picDef" | Out-Null }
}

if ($script:failures -gt 0) { Write-Host "$($script:failures) failed"; exit 1 }
Write-Host 'all passed'
exit 0
