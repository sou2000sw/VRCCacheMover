<#
  VRC Cache Mover
  VRChat 公式の config.json の cache_directory / picture_output_folder を書き換えるだけのツール。
  ジャンクションやシンボリックリンクは作らない・消さない。
  公式: https://docs.vrchat.com/docs/configuration-file
  License: MIT（LICENSE を参照）
#>
param(
    [string] $VrcDir = (Join-Path $env:USERPROFILE 'AppData\LocalLow\VRChat\VRChat'),
    [string] $PictureDefaultDir = (Join-Path ([Environment]::GetFolderPath('MyPictures')) 'VRChat'),
    [switch] $NoGui
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:AppName = 'VRC Cache Mover'
$script:Version = '1.0.1'
$script:ConfigPath = Join-Path $VrcDir 'config.json'
$script:MinCacheGB = 30   # 公式: 既定値より小さくはできない

# ---------- config.json の読み書き ----------

function Read-VrcConfig {
    # 壊れた JSON は例外にする（読めないまま上書きすると、ユーザーの他の設定が消えるため）
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return [pscustomobject]@{ Data = [pscustomobject]@{}; Exists = $false }
    }
    $text = [IO.File]::ReadAllText($script:ConfigPath, [Text.Encoding]::UTF8)
    if ($text.Trim() -eq '') { return [pscustomobject]@{ Data = [pscustomobject]@{}; Exists = $true } }
    try { $parsed = $text | ConvertFrom-Json }
    catch { throw "config.json を JSON として読めません。手で直すか、別名に退避してから再実行してください。`n$($_.Exception.Message)" }
    if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'config.json の中身が { } で囲まれた形になっていません。'
    }
    return [pscustomobject]@{ Data = $parsed; Exists = $true }
}

function Get-ConfigValue($Data, [string] $Key) {
    $prop = $Data.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

function Set-ConfigValue($Data, [string] $Key, $Value) {
    # $null はキーを消す（＝VRChat の既定に戻る）
    if ($null -eq $Value) { $Data.PSObject.Properties.Remove($Key); return }
    $Data | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}

function Save-VrcConfig($Data) {
    $backup = $null
    if (Test-Path -LiteralPath $script:ConfigPath) {
        $backup = '{0}.bak-{1}' -f $script:ConfigPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $script:ConfigPath -Destination $backup
    }
    if (@($Data.PSObject.Properties).Count -eq 0) {
        # 書く項目が無い＝すべて既定。空のファイルは残さない（バックアップは残る）
        if (Test-Path -LiteralPath $script:ConfigPath) { Remove-Item -LiteralPath $script:ConfigPath }
    } else {
        $json = $Data | ConvertTo-Json -Depth 20
        # VRChat が BOM 付きを読めるかは未検証なので BOM なしで書く
        [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $backup
}

# ---------- パスの検査 ----------

function ConvertTo-ConfigPath([string] $Path) {
    # JSON の \ はエスケープ文字なので / に統一する（公式例も C:/VRCCache/ の形）
    $p = ($Path.Trim() -replace '\\', '/').TrimEnd('/')
    if ($p -match '^[A-Za-z]:$') { $p += '/' }
    return $p
}

function Get-NativeFullPath([string] $Path) {
    return [IO.Path]::GetFullPath(($Path.Trim() -replace '/', '\')).TrimEnd('\')
}

function Test-SamePath([string] $A, [string] $B) {
    if (-not $A -or -not $B) { return $false }
    return (Get-NativeFullPath $A) -ieq (Get-NativeFullPath $B)
}

function Test-VrcRunning {
    return [bool](Get-Process -Name 'VRChat' -ErrorAction SilentlyContinue)
}

function Get-PictureLinkInfo {
    # 既定の写真フォルダを手でリンクしている人がいる。検知だけして、触らない
    if (-not (Test-Path -LiteralPath $PictureDefaultDir)) { return $null }
    $item = Get-Item -LiteralPath $PictureDefaultDir -Force
    if (-not $item.LinkType) { return $null }
    return [pscustomobject]@{ LinkType = $item.LinkType; Target = (@($item.Target) -join ', ') }
}

function Test-UnderOneDrive([string] $Path) {
    # ピクチャを OneDrive に同期している人は多い。外へ移すとクラウド側からも消える
    $full = Get-NativeFullPath $Path
    foreach ($root in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if (-not $root) { continue }
        $r = $root.TrimEnd('\')
        if ($full -ieq $r -or $full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-PictureMove([string] $OldSetting, [string] $NewSetting) {
    # 保存先を変えても以前の写真は動かさない。移す元と先を示すだけ（移動はエクスプローラーで本人がする）
    $from = $(if ($OldSetting.Trim()) { $OldSetting } else { $PictureDefaultDir })
    $to = $(if ($NewSetting.Trim()) { $NewSetting } else { $PictureDefaultDir })
    if (Test-SamePath $from $to) { return $null }
    $fromNative = $from -replace '/', '\'
    if (-not (Test-Path -LiteralPath $fromNative)) { return $null }
    if ((Get-Item -LiteralPath $fromNative -Force).LinkType) { return $null }   # リンクは既存の警告に任せる
    if (-not (Get-ChildItem -LiteralPath $fromNative -Force | Select-Object -First 1)) { return $null }
    return [pscustomobject]@{ From = (Get-NativeFullPath $from); To = (Get-NativeFullPath $to); OnOneDrive = (Test-UnderOneDrive $from) }
}

function Test-TargetFolder([string] $Path, [int] $NeedGB) {
    $errs = New-Object System.Collections.Generic.List[string]
    $warns = New-Object System.Collections.Generic.List[string]
    $native = $Path.Trim() -replace '/', '\'
    if ($native -notmatch '^[A-Za-z]:\\?') {
        $errs.Add("ドライブ文字から始まるフルパスを指定してください: $Path")
        return [pscustomobject]@{ Errors = @($errs); Warnings = @($warns); FullPath = $null }
    }
    $full = Get-NativeFullPath $native
    $vrcFull = Get-NativeFullPath $VrcDir
    if ($full -ieq $vrcFull -or $full.StartsWith($vrcFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $errs.Add('VRChat 本体のフォルダの中は指定できません（既定に戻すなら空欄にしてください）')
    }
    $drive = $full.Substring(0, 2)
    if (-not (Test-Path -LiteralPath ($drive + '\'))) {
        $errs.Add("ドライブ $drive が見つかりません")
        return [pscustomobject]@{ Errors = @($errs); Warnings = @($warns); FullPath = $full }
    }
    if ($full.Length -le 2) { $warns.Add('ドライブ直下は他のファイルと混ざります。フォルダを作って指定するのがおすすめです') }
    if ($drive -ieq $env:SystemDrive) { $warns.Add("$drive はシステムドライブです（書き込みを減らす目的なら別ドライブへ）") }
    $di = New-Object System.IO.DriveInfo($drive)
    $freeGB = [math]::Floor($di.AvailableFreeSpace / 1GB)
    if ($freeGB -lt $NeedGB) { $warns.Add("$drive の空きが $freeGB GB です（目安 $NeedGB GB 以上）") }
    $isUsb = ($di.DriveType -eq [IO.DriveType]::Removable)
    if (-not $isUsb) {
        # 外付け HDD/SSD は Fixed と報告されるので、バスの種類も見る。取れない環境では諦める
        try { $isUsb = ((Get-Partition -DriveLetter $drive[0] -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType -eq 'USB') } catch { }
    }
    # 外れたときに VRChat がどう振る舞うかは未検証なので、断定しない
    if ($isUsb) { $warns.Add("$drive は USB 接続のドライブです。外れている・ドライブ文字が変わると、保存先が見つからなくなる可能性があります") }
    return [pscustomobject]@{ Errors = @($errs); Warnings = @($warns); FullPath = $full }
}

# ---------- 変更計画と適用（GUI から独立させてテストできるようにしている） ----------

function New-ChangePlan {
    param([string] $CacheDir, [int] $CacheSizeGB, [string] $PictureDir, [bool] $SplitByDate)
    $cfg = Read-VrcConfig
    $data = $cfg.Data
    $errs = New-Object System.Collections.Generic.List[string]
    $warns = New-Object System.Collections.Generic.List[string]
    $folders = New-Object System.Collections.Generic.List[string]
    $oldPic = [string](Get-ConfigValue $data 'picture_output_folder')

    if ($CacheDir.Trim()) {
        $check = Test-TargetFolder $CacheDir ($CacheSizeGB + 5)
        foreach ($e in $check.Errors) { $errs.Add("キャッシュ: $e") }
        foreach ($w in $check.Warnings) { $warns.Add("キャッシュ: $w") }
        if ($check.FullPath) { $folders.Add($check.FullPath) }
        Set-ConfigValue $data 'cache_directory' (ConvertTo-ConfigPath $CacheDir)
    } else {
        Set-ConfigValue $data 'cache_directory' $null
    }

    if ($CacheSizeGB -lt $script:MinCacheGB) { $errs.Add("キャッシュ: 容量上限は $($script:MinCacheGB) GB 以上にしてください") }
    elseif ($CacheSizeGB -eq $script:MinCacheGB) { Set-ConfigValue $data 'cache_size' $null }
    else { Set-ConfigValue $data 'cache_size' $CacheSizeGB }

    if ($PictureDir.Trim()) {
        $check = Test-TargetFolder $PictureDir 5
        foreach ($e in $check.Errors) { $errs.Add("写真: $e") }
        foreach ($w in $check.Warnings) { $warns.Add("写真: $w") }
        if ($check.FullPath) { $folders.Add($check.FullPath) }
        Set-ConfigValue $data 'picture_output_folder' (ConvertTo-ConfigPath $PictureDir)
        $link = Get-PictureLinkInfo
        if ($link -and -not (Test-SamePath $link.Target $PictureDir)) {
            $warns.Add("写真: 既定の写真フォルダは $($link.Target) へリンク済みです。別の場所を指定すると、以前の写真と新しい写真が2か所に分かれます")
        }
    } else {
        Set-ConfigValue $data 'picture_output_folder' $null
    }

    # 公式の既定は true。既定のときはキーを書かない
    if ($SplitByDate) { Set-ConfigValue $data 'picture_output_split_by_date' $null }
    else { Set-ConfigValue $data 'picture_output_split_by_date' $false }

    if (Test-VrcRunning) { $errs.Add('VRChat が起動中です。終了してから適用してください') }
    if (-not (Test-Path -LiteralPath $VrcDir)) { $errs.Add("VRChat のフォルダがありません（$VrcDir）。一度 VRChat を起動してから実行してください") }

    $move = Get-PictureMove $oldPic $PictureDir
    return [pscustomobject]@{ Data = $data; Errors = @($errs); Warnings = @($warns); Folders = @($folders); PictureMove = $move }
}

function Invoke-ChangePlan($Plan) {
    if ($Plan.Errors.Count -gt 0) { throw ($Plan.Errors -join "`n") }
    foreach ($f in $Plan.Folders) {
        New-Item -ItemType Directory -Path $f -Force | Out-Null
        $probe = Join-Path $f ('.write_test_' + [guid]::NewGuid().ToString('N'))
        try { [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe }
        catch { throw "このフォルダに書き込めません: $f" }
    }
    return Save-VrcConfig $Plan.Data
}

function Get-PlanPreview($Plan) {
    if (@($Plan.Data.PSObject.Properties).Count -eq 0) { return '（config.json を削除し、すべて VRChat の既定に戻します）' }
    $text = $Plan.Data | ConvertTo-Json -Depth 20
    $newFolders = @($Plan.Folders | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($newFolders.Count -gt 0) { $text += "`n`n新しく作るフォルダ:`n" + ($newFolders -join "`n") }
    return $text
}

function Join-AutoSubfolder([string] $Selected, [string] $SubName) {
    # 選んだ場所の中に専用フォルダを足す。すでにその名前のフォルダを選んでいれば二重にしない
    if ((Split-Path -Leaf $Selected) -ieq $SubName) { return $Selected }
    return (Join-Path $Selected $SubName)
}

if ($NoGui) { return }

# ---------- GUI ----------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-UiLabel([string] $Text, [int] $X, [int] $Y, [int] $W = 560) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 20)
    return $l
}

function New-UiButton([string] $Text, [int] $X, [int] $Y, [int] $W = 80) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, 26)
    return $b
}

function Select-Folder([string] $Current) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '保存先のフォルダを選んでください'
    if ($Current -and (Test-Path -LiteralPath ($Current -replace '/', '\'))) { $dlg.SelectedPath = $Current -replace '/', '\' }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Show-Message([string] $Text, [string] $Icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($Text, $script:AppName, 'OK', $Icon) | Out-Null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "$($script:AppName) v$($script:Version) - キャッシュ・写真の保存先変更"
$form.Size = New-Object System.Drawing.Size(660, 494)
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9)

$lblStatus = New-UiLabel '' 12 10 620
$form.Controls.Add($lblStatus)
$form.Controls.Add((New-UiLabel "設定ファイル: $($script:ConfigPath)" 12 32 620))

$grpCache = New-Object System.Windows.Forms.GroupBox
$grpCache.Text = 'キャッシュ'; $grpCache.Location = New-Object System.Drawing.Point(12, 58); $grpCache.Size = New-Object System.Drawing.Size(620, 110)
$grpCache.Controls.Add((New-UiLabel "保存先（空欄 = 既定: $VrcDir）" 10 20 600))
$txtCache = New-Object System.Windows.Forms.TextBox
$txtCache.Location = New-Object System.Drawing.Point(10, 44); $txtCache.Size = New-Object System.Drawing.Size(420, 24)
$btnCacheBrowse = New-UiButton '参照...' 440 42
$btnCacheReset = New-UiButton '既定に戻す' 526 42 84
$grpCache.Controls.Add((New-UiLabel '容量上限（GB、30 以上）' 10 78 160))
$numSize = New-Object System.Windows.Forms.NumericUpDown
$numSize.Location = New-Object System.Drawing.Point(170, 75); $numSize.Size = New-Object System.Drawing.Size(80, 24)
$numSize.Minimum = $script:MinCacheGB; $numSize.Maximum = 2000
$grpCache.Controls.AddRange(@($txtCache, $btnCacheBrowse, $btnCacheReset, $numSize))
$form.Controls.Add($grpCache)

$grpPic = New-Object System.Windows.Forms.GroupBox
$grpPic.Text = 'カメラ写真'; $grpPic.Location = New-Object System.Drawing.Point(12, 176); $grpPic.Size = New-Object System.Drawing.Size(620, 130)
$grpPic.Controls.Add((New-UiLabel "保存先（空欄 = 既定: $PictureDefaultDir）" 10 20 600))
$txtPic = New-Object System.Windows.Forms.TextBox
$txtPic.Location = New-Object System.Drawing.Point(10, 44); $txtPic.Size = New-Object System.Drawing.Size(420, 24)
$btnPicBrowse = New-UiButton '参照...' 440 42
$btnPicReset = New-UiButton '既定に戻す' 526 42 84
$chkSplit = New-Object System.Windows.Forms.CheckBox
$chkSplit.Text = '月ごとのフォルダ（YYYY-MM）に分ける'; $chkSplit.Location = New-Object System.Drawing.Point(10, 76); $chkSplit.Size = New-Object System.Drawing.Size(400, 22)
$lblLink = New-UiLabel '' 10 102 600
$lblLink.ForeColor = [System.Drawing.Color]::DarkOrange
$grpPic.Controls.AddRange(@($txtPic, $btnPicBrowse, $btnPicReset, $chkSplit, $lblLink))
$form.Controls.Add($grpPic)

$chkAutoSub = New-Object System.Windows.Forms.CheckBox
$chkAutoSub.Text = '「参照」で選んだ場所の中に専用フォルダ（VRCCache / VRChatPhotos）を自動で作る'
$chkAutoSub.Location = New-Object System.Drawing.Point(14, 312); $chkAutoSub.Size = New-Object System.Drawing.Size(620, 22)
$chkAutoSub.Checked = $true
$form.Controls.Add($chkAutoSub)

$lblNote = New-UiLabel '指定したフォルダが無ければ適用時に作ります。古いキャッシュは自動では消しません（確認後に手で削除できます）。' 12 340 620
$form.Controls.Add($lblNote)
$btnOpenOld = New-UiButton '元のキャッシュの場所を開く' 12 370 190
$btnOpenPics = New-UiButton '写真フォルダを開く' 210 370 140
$btnApply = New-UiButton '適用' 436 370 96
$btnClose = New-UiButton '閉じる' 540 370 92
$form.Controls.AddRange(@($btnOpenOld, $btnOpenPics, $btnApply, $btnClose))
$script:PictureMove = $null   # 直前の適用で写真の保存先が変わったときの移す元と先

function Update-FormFromConfig {
    $running = Test-VrcRunning
    $lblStatus.Text = $(if ($running) { '● VRChat が起動中です。終了してから適用してください' } else { '● VRChat は終了しています' })
    $lblStatus.ForeColor = $(if ($running) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::ForestGreen })
    $btnApply.Enabled = -not $running
    try { $data = (Read-VrcConfig).Data }
    catch { Show-Message $_.Exception.Message 'Error'; $btnApply.Enabled = $false; return }
    $txtCache.Text = [string](Get-ConfigValue $data 'cache_directory')
    $size = Get-ConfigValue $data 'cache_size'
    $numSize.Value = $(if ($size -and [int]$size -ge $script:MinCacheGB) { [int]$size } else { $script:MinCacheGB })
    $txtPic.Text = [string](Get-ConfigValue $data 'picture_output_folder')
    $chkSplit.Checked = ((Get-ConfigValue $data 'picture_output_split_by_date') -ne $false)
    $link = Get-PictureLinkInfo
    $lblLink.Text = $(if ($link) { "※ 既定の写真フォルダは手動で $($link.Target) へリンク済みです（このツールは触りません）" } else { '' })
}

$btnCacheBrowse.Add_Click({
    $p = Select-Folder $txtCache.Text
    if ($p) { $txtCache.Text = $(if ($chkAutoSub.Checked) { Join-AutoSubfolder $p 'VRCCache' } else { $p }) }
})
$btnCacheReset.Add_Click({ $txtCache.Text = ''; $numSize.Value = $script:MinCacheGB })
$btnPicBrowse.Add_Click({
    $p = Select-Folder $txtPic.Text
    if ($p) { $txtPic.Text = $(if ($chkAutoSub.Checked) { Join-AutoSubfolder $p 'VRChatPhotos' } else { $p }) }
})
$btnPicReset.Add_Click({ $txtPic.Text = ''; $chkSplit.Checked = $true })
$btnOpenOld.Add_Click({ if (Test-Path -LiteralPath $VrcDir) { Start-Process explorer.exe $VrcDir } })
$btnOpenPics.Add_Click({
    # 適用直後は移す元と先、それ以外は既定と指定先を開く
    $dirs = $(if ($script:PictureMove) { @($script:PictureMove.From, $script:PictureMove.To) } else { @($PictureDefaultDir, ($txtPic.Text.Trim() -replace '/', '\')) })
    foreach ($d in @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) { Start-Process explorer.exe ('"{0}"' -f $d) }
})
$btnClose.Add_Click({ $form.Close() })
$btnApply.Add_Click({
    try {
        $plan = New-ChangePlan -CacheDir $txtCache.Text -CacheSizeGB ([int]$numSize.Value) -PictureDir $txtPic.Text -SplitByDate $chkSplit.Checked
        if ($plan.Errors.Count -gt 0) { Show-Message ("適用できません:`n`n" + ($plan.Errors -join "`n")) 'Error'; return }
        $msg = "config.json を次の内容にします。`n`n" + (Get-PlanPreview $plan)
        if ($plan.Warnings.Count -gt 0) { $msg += "`n`n注意:`n" + ($plan.Warnings -join "`n") }
        if ($plan.PictureMove) { $msg += "`n`n以前の写真は $($plan.PictureMove.From) に残ります（このツールは移しません）" }
        $msg += "`n`n適用しますか？"
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'YesNo', 'Question')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $backup = Invoke-ChangePlan $plan
        $done = '適用しました。次に VRChat を起動したときから反映されます。'
        if ($backup) { $done += "`n`n元の設定のバックアップ:`n$backup" }
        $script:PictureMove = $plan.PictureMove
        if ($plan.PictureMove) {
            $done += "`n`n以前の写真は次の場所に残っています:`n$($plan.PictureMove.From)`n新しい写真の保存先:`n$($plan.PictureMove.To)"
            $done += "`n`n移したい場合は「写真フォルダを開く」で両方を開き、エクスプローラーで移してください。"
            if ($plan.PictureMove.OnOneDrive) { $done += "`n※ 以前の写真フォルダは OneDrive の中にあります。OneDrive の外へ移すと、OneDrive（クラウド）からも消えます。" }
        }
        Show-Message $done
        Update-FormFromConfig
    } catch {
        Show-Message $_.Exception.Message 'Error'
    }
})

Update-FormFromConfig
[void]$form.ShowDialog()
