# Convert-H264-to-H265-in-batch

> PowerShell バッチビデオエンコーダー：H.264 → H.265/HEVC への自動変換、クラッシュ復旧、整合性検証、詳細ログ機能付き。

## 📋 主な機能

- **再帰的スキャン** : ディレクトリツリーの自動走査（Y:\ またはカスタムパス）
- **スマートコーデック検出** : 既に最適化された HEVC、AV1、Dolby Vision をスキップ
- **デュアルエンコーダ対応** : libx265（CPU）または NVIDIA NVENC（GPU 加速）
- **クラッシュ復旧** : JSON 状態永続化と再開機能
- **整合性検証** : 削除前の FFprobe チェックでデータ損失を防止
- **アトミックファイル置換** : 最終置換前のバックアップシステム
- **構造化ログ** : ジョブごとの JSON ログ + ローテーション可能なメインログ
- **ディスク空き容量監視** : 事前チェックで temp/source ドライブを確認
- **ドライラン機能** : 実際のエンコーディングを実行せずテスト
- **カスタマイズ可能な安全性** : SafeMode で元ファイルを `.bak` として保持

---

## 🚀 クイックスタート

### 前提条件
- **PowerShell 7.0+** （Windows、Linux、macOS）
- **FFmpeg** libx265 または NVIDIA NVENC サポート付き
- **FFprobe** （通常は FFmpeg にバンドルされています）

### インストール

1. **リポジトリをクローン**
   ```powershell
   git clone https://github.com/ex4s/Convert-H264-to-H265-in-batch.git
   cd Convert-H264-to-H265-in-batch
   ```

2. **依存関係をインストール**
   ```powershell
   .\install-dependencies.ps1
   ```

3. **設定ファイルを作成**
   ```powershell
   Copy-Item config/encoder.config.json.template config/encoder.config.json
   # パスとエンコーダ設定を編集してください
   ```

---

## 💻 使用方法

### 基本的なエンコーディング
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath C:\VideoEncoder\config\encoder.config.json
```

### ドライラン（テストモード）
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath config.json -DryRun
```

### クラッシュ後の再開
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath config.json -ResumeOnly
```

### ファイル数を制限（テスト用）
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath config.json -MaxFiles 5
```

---

## ⚙️ 設定

`encoder.config.json` を編集：

```json
{
  "SourceRoot": "Y:\\Videos",
  "TempRoot": "C:\\VideoEncoder\\temp",
  "LogRoot": "C:\\VideoEncoder\\logs",
  "StateRoot": "C:\\VideoEncoder\\state",
  
  "FFmpegPath": "C:\\VideoEncoder\\bin\\ffmpeg.exe",
  "FFprobePath": "C:\\VideoEncoder\\bin\\ffprobe.exe",
  
  "Encoder": "libx265",
  "CRF": 23,
  "Preset": "medium",
  
  "Extensions": [".mp4", ".mkv", ".avi", ".mov"],
  "MinFileSizeMB": 100,
  "MaxFileSizeGB": 500,
  
  "SafeMode": true,
  "DeleteOriginal": false,
  "KeepIfLarger": true,
  "DryRun": false
}
```

### 主要パラメータ

| パラメータ | 説明 |
|-----------|------|
| `SourceRoot` | スキャンする対象ディレクトリ（再帰処理） |
| `Encoder` | `libx265`（CPU）または `hevc_nvenc`（NVIDIA GPU） |
| `CRF` | 品質（0-51、低いほど高品質、デフォルト 23） |
| `Preset` | 速度（ultrafast...slow、デフォルト medium） |
| `SafeMode` | true の場合、元ファイルを `.bak` として保持 |
| `DeleteOriginal` | SafeMode=false の場合のみ `.bak` を削除 |

---

## 📁 ディレクトリ構造

```
C:\VideoEncoder\
├── bin\                          # FFmpeg、FFprobe バイナリ
├── scripts\
│   ├── Invoke-VideoEncoder.ps1   # メインエンコーダスクリプト
│   ├── install-dependencies.ps1
│   └── modules\
│       ├── Logging.psm1
│       ├── MediaAnalysis.psm1
│       ├── Encoding.psm1
│       ├── Validation.psm1
│       └── StateManager.psm1
├── state\
│   ├── queue.json                # 永続的なキュー
│   ├── processed.db              # SQLite 履歴
│   ├── failed.json               # 失敗ファイル
│   ├── skipped.json              # スキップされたファイル
│   └── lock.pid                  # プロセスロック
├── temp\                         # エンコーディング進行中
├── logs\
│   ├── main\                     # メインローテーションログ
│   ├── jobs\                     # ファイルごとのログ
│   ├── ffmpeg\                   # FFmpeg 出力
│   └── crashes\                  # エラーダンプ
├── reports\
│   └── daily\                    # 日次レポート（節約容量、ETA）
└── config\
    └── encoder.config.json       # 中央設定ファイル
```

---

## 📊 結果とモニタリング

### 状態ファイル
- **processed.db** : エンコーディング履歴を記録した SQLite データベース
- **queue.json** : 現在保留中のジョブ
- **failed.json** : エンコーディングに失敗したファイル（エラー詳細付き）
- **skipped.json** : エンコーディングされなかったファイル（既に HEVC、サイズ不適切など）

### ログ
- **main/encoder_YYYYMMDD.log** : 高レベルのバッチログ
- **jobs/{jobid}.log** : ファイル単位の詳細ログ
- **ffmpeg/{jobid}.log** : FFmpeg 生出力
- **daily/report_YYYYMMDD.txt** : サマリー（節約容量、処理時間、ETA）

### ログ出力例
```
2026-05-16T19:15:42 [INFO] [Job:abc123def] [1/150] 開始 : Y:\Videos\movie.mp4
2026-05-16T19:45:22 [INFO] [Job:abc123def] 成功 (saved_gb: 2.4, saved_pct: 32.1%, time_min: 29.7)
```

---

## 🔄 スケジュール実行（Windows）

1. スケジュール済みタスクを作成
2. アクション：PowerShell スクリプトを実行
3. スクリプト：`Start-EncoderService.ps1`
4. スケジュール：毎日午前 2:00（例）
5. 条件：アイドル時のみ、AC 電源時のみ

---

## 🛡️ 安全性機能

✅ **二重実行防止** : プロセスロックで同時実行を防止
✅ **ディスク容量チェック** : 事前チェックで検証
✅ **バックアップシステム** : 置換前に元ファイルを `.bak` として保持
✅ **整合性検証** : 削除前に FFprobe でチェック
✅ **クラッシュ復旧** : JSON 状態で中断からの再開が可能
✅ **選別的エンコーディング** : 既に最適化されたコーデック（HEVC、AV1、DV）をスキップ

---

## 📝 ライセンス

MIT ライセンス - 詳細は LICENSE ファイルを参照

---

## 🤝 貢献

貢献を歓迎します。Issue や Pull Request を開いてください。

---

## ❓ トラブルシューティング

### "FFmpeg exit code 1"
→ `logs/ffmpeg/{jobid}.log` で FFmpeg エラーを確認
→ FFmpeg が入力コーデックをサポートしていることを確認
→ 手動エンコーディングをテスト：`ffmpeg -i input.mp4 -c:v libx265 -crf 23 output.mkv`

### "Espace temp insuffisant"（temp 容量不足）
→ temp ドライブのサイズを増やすか、設定で大きいディスクを指定
→ `MaxFileSizeGB` パラメータを削減

### "Une autre instance tourne déjà"（別のインスタンスが実行中）
→ プロセスロックを確認：古い場合は `state/lock.pid` を削除
→ 他の PowerShell インスタンスが実行していないことを確認

### "Validation échouée"（検証失敗）
→ エンコードされたファイルが破損している可能性
→ ディスク状態と FFmpeg バージョンを確認
→ 別のプリセット（遅いほうが安定）で再試行

---

**最終更新:** 2026-05-16  
**作成者:** ex4s  
**状態:** 開発中 ✨
