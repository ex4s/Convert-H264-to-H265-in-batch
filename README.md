# Convert-H264-to-H265-in-batch

> PowerShell batch video encoder: Intelligent H.264 → H.265/HEVC conversion with automatic recovery, integrity validation, and detailed logging.

## 📋 Features

- **Recursive scanning** of directory tree (Y:\ or custom path)
- **Smart codec detection** : Skip HEVC, AV1, Dolby Vision (already optimized)
- **Dual encoder support** : libx265 or NVIDIA NVENC (GPU acceleration)
- **Crash recovery** : JSON state persistence and resume capability
- **Integrity validation** : Pre-delete verification to prevent data loss
- **Atomic file replacement** : Backup system before final swap
- **Structured logging** : JSON logs per job + rotating main log
- **Disk space monitoring** : Pre-flight checks for temp + source drives
- **Dry-run mode** : Test without actual encoding
- **Configurable safety** : SafeMode keeps originals as `.bak` files

---

## 🚀 Quick Start

### Prerequisites
- **PowerShell 7.0+** (Windows, Linux, macOS)
- **FFmpeg** with libx265 or NVIDIA NVENC support
- **FFprobe** (usually bundled with FFmpeg)

### Installation

1. **Clone the repository**
   ```powershell
   git clone https://github.com/ex4s/Convert-H264-to-H265-in-batch.git
   cd Convert-H264-to-H265-in-batch
   ```

2. **Install dependencies**
   ```powershell
   .\install-dependencies.ps1
   ```

3. **Create configuration**
   ```powershell
   Copy-Item config/encoder.config.json.template config/encoder.config.json
   # Edit with your paths and encoder settings
   ```

---

## 💻 Usage

### Basic Encoding
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath C:\VideoEncoder\config\encoder.config.json
```

### Dry-Run (Test Mode)
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath config.json -DryRun
```

### Resume After Crash
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath config.json -ResumeOnly
```

### Limit Files (Testing)
```powershell
.\Invoke-VideoEncoder.ps1 -ConfigPath config.json -MaxFiles 5
```

---

## ⚙️ Configuration

Edit `encoder.config.json`:

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

### Key Parameters

| Parameter | Description |
|-----------|-------------|
| `SourceRoot` | Root directory to scan recursively |
| `Encoder` | `libx265` (CPU) or `hevc_nvenc` (NVIDIA GPU) |
| `CRF` | Quality (0-51, lower = better, default 23) |
| `Preset` | Speed (ultrafast...slow, default medium) |
| `SafeMode` | Keep originals as `.bak` if true |
| `DeleteOriginal` | Delete `.bak` only if SafeMode=false |

---

## 📁 Directory Structure

```
C:\VideoEncoder\
├── bin\                          # FFmpeg, FFprobe binaries
├── scripts\
│   ├── Invoke-VideoEncoder.ps1   # Main encoder script
│   ├── install-dependencies.ps1
│   └── modules\
│       ├── Logging.psm1
│       ├── MediaAnalysis.psm1
│       ├── Encoding.psm1
│       ├── Validation.psm1
│       └── StateManager.psm1
├── state\
│   ├── queue.json                # Persistent queue
│   ├── processed.db              # SQLite history
│   ├── failed.json               # Failed files
│   ├── skipped.json              # Skipped files
│   └── lock.pid                  # Process lock
├── temp\                         # Encoding in progress
├── logs\
│   ├── main\                     # Main rotating log
│   ├── jobs\                     # Per-file logs
│   ├── ffmpeg\                   # FFmpeg output
│   └── crashes\                  # Error dumps
├── reports\
│   └── daily\                    # Daily reports (savings, ETA)
└── config\
    └── encoder.config.json       # Central configuration
```

---

## 📊 Results & Monitoring

### State Files
- **processed.db** : SQLite database with complete encoding history
- **queue.json** : Current pending jobs
- **failed.json** : Files that failed encoding (with error details)
- **skipped.json** : Files not encoded (already HEVC, too small, etc.)

### Logs
- **main/encoder_YYYYMMDD.log** : High-level batch log
- **jobs/{jobid}.log** : Detailed per-file log
- **ffmpeg/{jobid}.log** : Raw FFmpeg output
- **daily/report_YYYYMMDD.txt** : Summary (disk saved, processing time, ETA)

### Example Log Output
```
2026-05-16T19:15:42 [INFO] [Job:abc123def] [1/150] Début : Y:\Videos\movie.mp4
2026-05-16T19:45:22 [INFO] [Job:abc123def] OK (saved_gb: 2.4, saved_pct: 32.1%, time_min: 29.7)
```

---

## 🔄 Scheduled Execution (Windows)

1. Create a Scheduled Task
2. Action: Run PowerShell script
3. Script: `Start-EncoderService.ps1`
4. Schedule: Daily at 2:00 AM (example)
5. Conditions: Only if idle, on AC power

---

## 🛡️ Safety Features

✅ **Anti-double-execution** : Process lock prevents concurrent runs
✅ **Disk space checks** : Pre-flight verification
✅ **Backup system** : Original files kept as `.bak` before replacement
✅ **Integrity validation** : FFprobe checks before deletion
✅ **Crash recovery** : JSON state allows resume from interruption
✅ **Selective encoding** : Skips already-optimized codecs (HEVC, AV1, DV)

---

## 📝 License

MIT License - See LICENSE file for details

---

## 🤝 Contributing

Contributions welcome! Please open an issue or pull request.

---

## ❓ Troubleshooting

### "FFmpeg exit code 1"
→ Check `logs/ffmpeg/{jobid}.log` for FFmpeg errors
→ Verify FFmpeg supports your input codec
→ Try manual encoding: `ffmpeg -i input.mp4 -c:v libx265 -crf 23 output.mkv`

### "Espace temp insuffisant"
→ Increase temp drive size or point to larger disk in config
→ Reduce `MaxFileSizeGB` parameter

### "Une autre instance tourne déjà"
→ Check process lock: Delete `state/lock.pid` if stale
→ Verify no other PowerShell instances are running

### "Validation échouée"
→ Encoded file may be corrupted
→ Check disk health and FFmpeg version
→ Retry with different preset (slower = more stable)

---

**Last Updated:** 2026-05-16  
**Author:** ex4s  
**Status:** Active Development ✨
