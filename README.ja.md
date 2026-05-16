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

<img width="1322" height="800" alt="hot take" src="https://github.com/user-attachments/assets/25d62f5c-e2b2-40c7-b3df-50a81746eed3" />


---
