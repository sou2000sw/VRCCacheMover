# VRC Cache Mover — Project Development Rules & Knowledge Integration

VRChat の公式 `config.json`（`cache_directory` / `picture_output_folder`）を GUI で書き換える Windows 用ツール。
BOOTH（無料＋支援枠）と GitHub で MIT ライセンス配布する。

## 設計の不変条件（崩さないこと）
- **公式設定を書くだけ。** ジャンクション／シンボリックリンクは作らない・消さない（検知して表示するだけ）。
- ログの移動は対象外（公式手段がない）。入れるなら「古いログの退避」で、リンク方式は採らない。
- 既存の `config.json` は読み込んでから対象キーだけ差し替える。読めない JSON は上書きしない。書く前に `.bak-日時` を残す。
- `config.json` は **BOM なし** UTF-8 で書く。`.ps1` は **BOM 付き** UTF-8 で保存する（5.1 が cp932 で読んで日本語が壊れるため）。
- VRChat 起動中は適用しない。古いキャッシュは自動で消さない。
- 配布物のファイル名は ASCII のみ（zip 展開時の文字化け対策）。

## Local Knowledge Base Access
Central knowledge is stored in `E:\Obsidian\Antigravity\`.
- **Project note**: [`00_概要_VRCCacheMover.md`](file:///E:/Obsidian/Antigravity/01_Projects/VRCCacheMover/00_概要_VRCCacheMover.md)
- **PowerShell & Encoding Invariants**: [`PowerShell_and_CommandLine_Best_Practices.md`](file:///E:/Obsidian/Antigravity/02_Resources/PowerShell_and_CommandLine_Best_Practices.md)

## Incremental Knowledge Feedback
- When you discover new insights or resolve tricky Windows/environment bugs, **append the findings to the relevant resource note in `E:\Obsidian\Antigravity\02_Resources\`**.
  1. Append under `## 🐛 落とし穴・トラブルシューティング` or add `### YYYY-MM-DD 追記: {要点}`.
  2. **Never overwrite or delete existing sections**.
  3. Update `updated: YYYY-MM-DD` in frontmatter.

## Build and Test Commands
- **Test**: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Logic.ps1`（偽の VRChat フォルダで検証。実際の config.json には触れない）
- **Build**: `powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1`（BOM・構文・テストを確認してから `dist\VRCCacheMover_v<版>.zip` を作る）
- **Run**: `VRCCacheMover.bat`（GUI）
- 版番号は `VRCCacheMover.ps1` の `$script:Version` が唯一の正。

## Security & Privacy Invariants
- ユーザーのパスや設定をどこにも送信しない（ネットワーク通信を持たない）。
