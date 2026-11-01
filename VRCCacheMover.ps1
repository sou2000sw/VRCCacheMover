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
$script:Version = '1.1.0'
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
    # 'C:' のままだと GetFullPath がそのドライブのカレントフォルダを返す。ドライブ直下は 'C:\' で表す
    $p = $Path.Trim() -replace '/', '\'
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    $full = [IO.Path]::GetFullPath($p)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
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
    $toNative = $to -replace '/', '\'
    if ((Test-Path -LiteralPath $toNative) -and (Get-Item -LiteralPath $toNative -Force).LinkType) { return $null }   # 移す先がリンクなら実体は同じかもしれない
    # 空の月別フォルダや desktop.ini（隠しファイル）しか無いなら、移す写真は無い
    if (-not (Get-ChildItem -LiteralPath $fromNative -Recurse -File | Where-Object { $_.Name -ne 'desktop.ini' } | Select-Object -First 1)) { return $null }
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
    if ($full.Length -le 3) { $warns.Add('ドライブ直下は他のファイルと混ざります。フォルダを作って指定するのがおすすめです') }
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

    $move = $(if ($errs.Count -eq 0) { Get-PictureMove $oldPic $PictureDir } else { $null })
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

# ---------- 古いキャッシュの削除（ユーザーが確認したときだけ） ----------

$script:OldCacheNames = @('Cache-WindowsPlayer', 'TextureDiskCache-WindowsPlayer')

function Measure-Folder([string] $Path) {
    # Get-ChildItem -Recurse は 5.1 でジャンクションの先までたどるので、自前で歩いてリンクは数えるだけにする
    $bytes = [long]0; $files = 0; $links = 0
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object System.IO.DirectoryInfo $Path))
    while ($stack.Count -gt 0) {
        foreach ($e in $stack.Pop().EnumerateFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links++; continue }
            if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e) } else { $bytes += $e.Length; $files++ }
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Links = $links }
}

function Clear-ReadOnly([string] $Path) {
    # 読み取り専用が1つでもあると Directory.Delete が途中で止まる。リンクの中には入らない
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object System.IO.DirectoryInfo $Path))
    while ($stack.Count -gt 0) {
        foreach ($e in $stack.Pop().EnumerateFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.Attributes -band [IO.FileAttributes]::ReadOnly) { $e.Attributes = $e.Attributes -bxor [IO.FileAttributes]::ReadOnly }
            if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e) }
        }
    }
}

function Test-ReparsePoint([string] $Path) {
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-OldCache {
    # 消してよいのは、保存先を移した後の既定の場所にある決まった名前のフォルダだけ
    $blocked = { param($Reason) [pscustomobject]@{ Blocked = $Reason; Targets = @(); Bytes = [long]0; Files = 0; NewHasData = $false } }
    if (Test-VrcRunning) { return & $blocked 'VRChat が起動中です。終了してから削除してください' }
    $cacheDir = [string](Get-ConfigValue (Read-VrcConfig).Data 'cache_directory')
    # 手で書いた config.json で空白だけ・VRChat のフォルダそのものを指している場合も、今使っているキャッシュなので消さない
    $notMoved = (-not $cacheDir.Trim())
    if (-not $notMoved) { try { $notMoved = Test-SamePath $cacheDir $VrcDir } catch { $notMoved = $true } }
    if ($notMoved) { return & $blocked 'キャッシュの保存先が既定のままです。先に保存先を移して適用してください' }
    if (-not (Test-Path -LiteralPath $VrcDir)) { return & $blocked "VRChat のフォルダがありません（$VrcDir）" }
    if (Test-ReparsePoint $VrcDir) { return & $blocked "VRChat のフォルダがリンクになっているため、削除しません（$VrcDir）" }
    $targets = New-Object System.Collections.Generic.List[string]
    $bytes = [long]0; $files = 0
    foreach ($name in $script:OldCacheNames) {
        $p = Join-Path $VrcDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        if (Test-ReparsePoint $p) { return & $blocked "古いキャッシュのフォルダがリンクになっているため、削除しません（$p）" }
        $m = Measure-Folder $p
        if ($m.Links -gt 0) { return & $blocked "古いキャッシュの中にリンクがあるため、削除しません（$p）" }
        $targets.Add($p); $bytes += $m.Bytes; $files += $m.Files
    }
    if ($targets.Count -eq 0) { return & $blocked '元の場所に古いキャッシュはありません' }
    $newFull = Get-NativeFullPath $cacheDir
    foreach ($t in $targets) {
        # 手で書いた保存先が消す対象の中を指していたら、それは使用中のキャッシュ
        if ($newFull -ieq $t -or $newFull.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return & $blocked "キャッシュの保存先が古いキャッシュのフォルダの中を指しているため、削除しません（$newFull）"
        }
    }
    # VRChat は保存先の中に元と同じ名前のフォルダを作る。それがあれば新しい場所が使われている
    $newHasData = [bool](@($script:OldCacheNames | Where-Object { Test-Path -LiteralPath (Join-Path $newFull $_) -PathType Container }).Count)
    return [pscustomobject]@{ Blocked = $null; Targets = @($targets); Bytes = $bytes; Files = $files; NewHasData = $newHasData }
}

function Remove-OldCache($Info) {
    if ($Info.Blocked) { throw $Info.Blocked }
    if (Test-VrcRunning) { throw 'VRChat が起動中です。終了してから削除してください' }
    foreach ($p in $Info.Targets) {
        # 調べてから消すまでの間にリンクへ差し替わっていないか、消す直前にもう一度見る
        if (Test-ReparsePoint $p) { throw "リンクになっているため、削除を中止しました（$p）" }
        try { Clear-ReadOnly $p; [IO.Directory]::Delete($p, $true) }
        catch { throw "削除できないファイルがありました（$p）。途中まで削除されています。`n$($_.Exception.Message)" }
    }
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
$btnDeleteOld = New-UiButton '古いキャッシュを削除...' 440 74 170
$grpCache.Controls.AddRange(@($txtCache, $btnCacheBrowse, $btnCacheReset, $numSize, $btnDeleteOld))
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

$lblNote = New-UiLabel 'フォルダが無ければ適用時に作ります。古いキャッシュは自動では消さず、「古いキャッシュを削除」で消せます。' 12 340 620
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
    try {
        $dirs = $(if ($script:PictureMove) { @($script:PictureMove.From, $script:PictureMove.To) } else { @($PictureDefaultDir, $txtPic.Text) })
        $seen = @{}
        foreach ($d in $dirs) {
            if (-not $d.Trim()) { continue }
            $full = Get-NativeFullPath $d
            if ($seen.ContainsKey($full.ToLowerInvariant()) -or -not (Test-Path -LiteralPath $full)) { continue }
            $seen[$full.ToLowerInvariant()] = $true
            Start-Process explorer.exe ('"{0}"' -f $full)
        }
    } catch {
        Show-Message $_.Exception.Message 'Error'
    }
})
$btnDeleteOld.Add_Click({
    try {
        $info = Get-OldCache
        if ($info.Blocked) { Show-Message $info.Blocked; return }
        $msg = "元の場所にある古いキャッシュを削除します。`n`n" + ($info.Targets -join "`n")
        $msg += "`n`n合計 {0:N1} GB（{1:N0} ファイル）" -f ($info.Bytes / 1GB), $info.Files
        $msg += "`n`nごみ箱には入りません。削除したワールドやアバターは、次に必要になったときに VRChat が再ダウンロードします。"
        if (-not $info.NewHasData) { $msg += "`n`n※ 新しい保存先にはまだキャッシュがありません。VRChat を一度起動して、新しい場所が使われているのを確かめてから削除するのがおすすめです。" }
        $msg += "`n`n削除しますか？"
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'YesNo', 'Warning', 'Button2')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Remove-OldCache $info
        Show-Message ("削除しました。{0} の空きが約 {1:N1} GB 増えました。" -f $VrcDir.Substring(0, 2), ($info.Bytes / 1GB))
    } catch {
        Show-Message $_.Exception.Message 'Error'
    }
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
