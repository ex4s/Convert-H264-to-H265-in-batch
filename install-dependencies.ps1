<#
.SYNOPSIS
    Installe FFmpeg, FFprobe et configure l'arborescence du pipeline d'encodage.

.DESCRIPTION
    Script à exécuter UNE SEULE FOIS en tant qu'administrateur.
    - Crée l'arborescence sous $InstallRoot
    - Télécharge le build FFmpeg de BtbN (master, GPL, inclut x265 / NVENC / QSV / AMF)
    - Détecte les GPU disponibles
    - Écrit une configuration par défaut

    Ne pollue pas le PATH système : les binaires restent isolés dans $InstallRoot\bin.

.PARAMETER InstallRoot
    Racine d'installation. Défaut : C:\VideoEncoder

.PARAMETER Force
    Force le re-téléchargement même si FFmpeg est déjà présent.

.EXAMPLE
    .\Install-Dependencies.ps1 -InstallRoot "D:\VideoEncoder"

.NOTES
    Requiert : PowerShell 5.1+, droits administrateur, accès internet sortant.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\VideoEncoder",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # Sinon Invoke-WebRequest est ~10x plus lent

# --- Vérification droits admin ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Ce script doit être exécuté en tant qu'administrateur."
}

Write-Host "=== Windows Video Encoder — Installation ===" -ForegroundColor Cyan
Write-Host "Install root : $InstallRoot`n" -ForegroundColor Cyan

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
    } else {
        Write-Host "[=] Existe : $d" -ForegroundColor DarkGray
    }
}

# --- FFmpeg ---
$ffmpegExe  = "$InstallRoot\bin\ffmpeg.exe"
$ffmpegZip  = "$env:TEMP\ffmpeg_btbn.zip"
$ffmpegUrl  = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
$extractDir = "$env:TEMP\ffmpeg_btbn_extract"

if ($Force -or -not (Test-Path $ffmpegExe)) {
    Write-Host "`n[*] Téléchargement de FFmpeg (BtbN, latest master)..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $ffmpegUrl -OutFile $ffmpegZip -UseBasicParsing
    } catch {
        throw "Échec téléchargement FFmpeg : $($_.Exception.Message)"
    }

    Write-Host "[*] Extraction..." -ForegroundColor Cyan
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $ffmpegZip -DestinationPath $extractDir -Force

    $ffmpegBin = Get-ChildItem $extractDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    if (-not $ffmpegBin) {
        throw "ffmpeg.exe introuvable dans l'archive téléchargée."
    }

    Copy-Item "$($ffmpegBin.Directory.FullName)\*.exe" "$InstallRoot\bin\" -Force
    Remove-Item $ffmpegZip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[+] FFmpeg installé dans $InstallRoot\bin\" -ForegroundColor Green
} else {
    Write-Host "`n[=] FFmpeg déjà présent. Utilise -Force pour réinstaller." -ForegroundColor DarkGray
}

# --- Vérifications ---
Write-Host "`n=== Vérifications ===" -ForegroundColor Yellow
$ffmpegVersion = & "$InstallRoot\bin\ffmpeg.exe" -version 2>&1 | Select-Object -First 1
Write-Host "FFmpeg : $ffmpegVersion" -ForegroundColor White

$ffprobeVersion = & "$InstallRoot\bin\ffprobe.exe" -version 2>&1 | Select-Object -First 1
Write-Host "FFprobe : $ffprobeVersion" -ForegroundColor White

# Vérifier support des encodeurs HEVC
Write-Host "`n=== Encodeurs HEVC disponibles ===" -ForegroundColor Yellow
$encoders = & "$InstallRoot\bin\ffmpeg.exe" -hide_banner -encoders 2>&1
$hevcEncoders = @{
    'libx265'    = 'CPU x265 (qualité max)'
    'hevc_nvenc' = 'NVIDIA NVENC (rapide)'
    'hevc_qsv'   = 'Intel QuickSync'
    'hevc_amf'   = 'AMD AMF'
}
foreach ($enc in $hevcEncoders.Keys) {
    if ($encoders -match "\b$enc\b") {
        Write-Host "  [OK] $enc — $($hevcEncoders[$enc])" -ForegroundColor Green
    } else {
        Write-Host "  [--] $enc — non disponible" -ForegroundColor DarkGray
    }
}

# --- Détection GPU ---
Write-Host "`n=== GPU détecté(s) ===" -ForegroundColor Yellow
try {
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Select-Object Name, DriverVersion, @{N='AdapterRAM_GB';E={[math]::Round($_.AdapterRAM / 1GB, 2)}}
    $gpus | Format-Table -AutoSize
} catch {
    Write-Host "[!] Impossible de détecter les GPU." -ForegroundColor Yellow
}

# --- Configuration par défaut ---
$cfgPath = "$InstallRoot\config\encoder.config.json"
if (-not (Test-Path $cfgPath) -or $Force) {
    $defaultConfig = [ordered]@{
        SourceRoot      = "Y:\"
        TempRoot        = "$InstallRoot\temp"
        StateRoot       = "$InstallRoot\state"
        LogRoot         = "$InstallRoot\logs"
        ReportRoot      = "$InstallRoot\reports"
        FFmpegPath      = "$InstallRoot\bin\ffmpeg.exe"
        FFprobePath     = "$InstallRoot\bin\ffprobe.exe"
        Encoder         = "libx265"
        CRF             = 20
        Preset          = "medium"
        Extensions      = @(".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov")
        ParallelJobs    = 1
        MinFreeSpaceGB  = 50
        SafeMode        = $true
        DryRun          = $false
        DeleteOriginal  = $false
        KeepIfLarger    = $true
        MaxFileSizeGB   = 50
        MinFileSizeMB   = 10
        SkipPatterns    = @("*sample*", "*trailer*", "*.partial.*")
        TimeoutHours    = 24
    }

    $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content -Path $cfgPath -Encoding UTF8
    Write-Host "`n[+] Configuration par défaut écrite : $cfgPath" -ForegroundColor Green
} else {
    Write-Host "`n[=] Configuration existante préservée : $cfgPath" -ForegroundColor DarkGray
}

Write-Host "`n=== Installation terminée ===" -ForegroundColor Green
Write-Host @"

Prochaines étapes :
  1. Copier les scripts du repo vers $InstallRoot\scripts\
       Copy-Item -Recurse .\scripts\* $InstallRoot\scripts\
  2. Éditer la config :
       notepad $cfgPath
  3. Premier dry-run :
       $InstallRoot\scripts\Invoke-VideoEncoder.ps1 -DryRun -MaxFiles 10
  4. Test réel limité :
       $InstallRoot\scripts\Invoke-VideoEncoder.ps1 -MaxFiles 5
  5. Enregistrer la tâche planifiée :
       $InstallRoot\scripts\Register-EncoderTask.ps1

"@ -ForegroundColor Cyan
