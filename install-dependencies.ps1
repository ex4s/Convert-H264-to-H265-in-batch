<#
.SYNOPSIS
    Installe FFmpeg, MKVToolNix, et outils annexes pour le pipeline d'encodage.
.DESCRIPTION
    À exécuter UNE SEULE FOIS en tant qu'administrateur.
    N'installe pas via Chocolatey/Winget pour éviter les dépendances externes en prod.
    Télécharge directement les builds officiels.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\VideoEncoder",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # Sinon Invoke-WebRequest est 10x plus lent

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ce script doit être exécuté en tant qu'administrateur."
}

# --- Création de l'arborescence ---
$dirs = @(
    "$InstallRoot\bin",
    "$InstallRoot\scripts\modules",
    "$InstallRoot\state",
    "$InstallRoot\temp",
    "$InstallRoot\logs\main",
    "$InstallRoot\logs\jobs",
    "$InstallRoot\logs\ffmpeg",
    "$InstallRoot\logs\crashes",
    "$InstallRoot\reports\daily",
    "$InstallRoot\config"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "[+] Créé : $d" -ForegroundColor Green
    }
}

# --- FFmpeg (build BtbN, gpl-shared, inclut x265, NVENC, libsvtav1) ---
$ffmpegZip = "$env:TEMP\ffmpeg.zip"
$ffmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"

if ($Force -or -not (Test-Path "$InstallRoot\bin\ffmpeg.exe")) {
    Write-Host "[*] Téléchargement de FFmpeg..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ffmpegUrl -OutFile $ffmpegZip -UseBasicParsing
    Expand-Archive -Path $ffmpegZip -DestinationPath "$env:TEMP\ffmpeg_extract" -Force
    $ffmpegBin = Get-ChildItem "$env:TEMP\ffmpeg_extract" -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    Copy-Item "$($ffmpegBin.Directory.FullName)\*.exe" "$InstallRoot\bin\" -Force
    Remove-Item $ffmpegZip, "$env:TEMP\ffmpeg_extract" -Recurse -Force
    Write-Host "[+] FFmpeg installé." -ForegroundColor Green
}

# --- MKVToolNix (mkvmerge pour remux propre, mkvinfo pour debug) ---
$mkvUrl = "https://mkvtoolnix.download/windows/releases/latest/mkvtoolnix-64-bit-latest.7z"
# Note : installation manuelle conseillée car MKVToolNix change souvent ses URLs.
# Alternative : utiliser le portable depuis https://mkvtoolnix.download/downloads.html

# --- Vérifications ---
Write-Host "`n=== Vérifications ===" -ForegroundColor Yellow
& "$InstallRoot\bin\ffmpeg.exe" -version | Select-Object -First 2
& "$InstallRoot\bin\ffprobe.exe" -version | Select-Object -First 1

# Vérifier support x265 et NVENC
$encoders = & "$InstallRoot\bin\ffmpeg.exe" -hide_banner -encoders 2>&1
if ($encoders -match 'libx265')      { Write-Host "[OK] libx265 disponible"      -ForegroundColor Green }
if ($encoders -match 'hevc_nvenc')   { Write-Host "[OK] hevc_nvenc disponible"   -ForegroundColor Green }
if ($encoders -match 'hevc_qsv')     { Write-Host "[OK] hevc_qsv disponible"     -ForegroundColor Green }
if ($encoders -match 'hevc_amf')     { Write-Host "[OK] hevc_amf disponible"     -ForegroundColor Green }

# --- Détection GPU ---
$gpu = Get-CimInstance Win32_VideoController | Select-Object Name, AdapterRAM, DriverVersion
Write-Host "`n=== GPU détecté(s) ===" -ForegroundColor Yellow
$gpu | Format-Table -AutoSize

# --- Configuration par défaut ---
$defaultConfig = @{
    SourceRoot          = "Y:\"
    TempRoot            = "$InstallRoot\temp"
    StateRoot           = "$InstallRoot\state"
    LogRoot             = "$InstallRoot\logs"
    FFmpegPath          = "$InstallRoot\bin\ffmpeg.exe"
    FFprobePath         = "$InstallRoot\bin\ffprobe.exe"
    Encoder             = "libx265"          # "libx265" | "hevc_nvenc" | "hevc_qsv"
    CRF                 = 18
    Preset              = "medium"
    Extensions          = @(".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov")
    ParallelJobs        = 1                  # 1 pour CPU x265, 2-4 pour NVENC
    MinFreeSpaceGB      = 50
    SafeMode            = $true              # NE JAMAIS METTRE À FALSE EN PRODUCTION
    DryRun              = $false
    DeleteOriginal      = $false             # Active manuellement après tests
    KeepIfLarger        = $true              # Si réencodage gonfle le fichier, on garde l'original
    MaxFileSizeGB       = 50                 # Skip fichiers > 50 Go (probable corruption)
    MinFileSizeMB       = 10                 # Skip fichiers < 10 Mo (probable sample/corrompu)
    SkipPatterns        = @("*sample*", "*trailer*", "*.partial.*")
} | ConvertTo-Json -Depth 4

$cfgPath = "$InstallRoot\config\encoder.config.json"
if (-not (Test-Path $cfgPath) -or $Force) {
    Set-Content -Path $cfgPath -Value $defaultConfig -Encoding UTF8
    Write-Host "[+] Configuration par défaut écrite : $cfgPath" -ForegroundColor Green
}

Write-Host "`n=== Installation terminée ===" -ForegroundColor Green
Write-Host "Edite $cfgPath avant de lancer." -ForegroundColor Yellow
