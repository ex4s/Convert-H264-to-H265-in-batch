<#
.SYNOPSIS
    Pipeline complet de réencodage H.264 → HEVC à grande échelle.
.DESCRIPTION
    - Analyse récursive de Y:\
    - Détection H.264, skip HEVC/AV1/Dolby Vision
    - Réencodage x265 ou NVENC selon config
    - Validation d'intégrité avant suppression
    - Reprise après crash via state JSON
    - Logs structurés JSON par job
.PARAMETER ConfigPath
    Chemin du fichier de configuration JSON.
.PARAMETER DryRun
    Force le mode dry-run, override la config.
.PARAMETER MaxFiles
    Limite le nombre de fichiers traités (utile pour tests).
.PARAMETER ResumeOnly
    Ne scanne pas, reprend uniquement la file existante.
.EXAMPLE
    .\Invoke-VideoEncoder.ps1 -ConfigPath C:\VideoEncoder\config\encoder.config.json -MaxFiles 10
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\VideoEncoder\config\encoder.config.json",
    [switch]$DryRun,
    [int]$MaxFiles = 0,
    [switch]$ResumeOnly
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

# --- Import modules ---
Import-Module "$scriptRoot\modules\Logging.psm1"       -Force
Import-Module "$scriptRoot\modules\MediaAnalysis.psm1" -Force
Import-Module "$scriptRoot\modules\StateManager.psm1"  -Force
Import-Module "$scriptRoot\modules\Validation.psm1"    -Force
Import-Module "$scriptRoot\modules\Encoding.psm1"      -Force

# --- Chargement configuration ---
if (-not (Test-Path $ConfigPath)) { throw "Config introuvable : $ConfigPath" }
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($DryRun) { $Config.DryRun = $true }

$mainLog = "$($Config.LogRoot)\main\encoder_$(Get-Date -Format 'yyyyMMdd').log"

# --- Verrou anti double-exécution ---
if (-not (Test-ProcessLock -StateRoot $Config.StateRoot)) {
    Write-EncoderLog -Level CRITICAL -Message "Une autre instance tourne déjà. Abandon." -LogFile $mainLog
    exit 1
}

try {
    $StateFiles = Initialize-StateStore -StateRoot $Config.StateRoot
    Initialize-LogRotation -LogDir "$($Config.LogRoot)\main" -MaxSizeMB 100 -KeepFiles 30

    Write-EncoderLog -Level INFO -Message "=== Démarrage encodeur ===" -LogFile $mainLog -Context @{
        Config = $Config | ConvertTo-Json -Compress
        Host   = $env:COMPUTERNAME
    }

    # ====================================================================
    # PHASE 1 : DÉCOUVERTE
    # ====================================================================
    if (-not $ResumeOnly) {
        Write-EncoderLog -Level INFO -Message "Scan récursif de $($Config.SourceRoot)..." -LogFile $mainLog
        $allFiles = Get-ChildItem -Path $Config.SourceRoot -Recurse -File -ErrorAction Continue |
            Where-Object {
                $_.Extension.ToLower() -in $Config.Extensions -and
                $_.Length -gt ($Config.MinFileSizeMB * 1MB) -and
                $_.Length -lt ($Config.MaxFileSizeGB * 1GB) -and
                -not ($Config.SkipPatterns | Where-Object { $_.Name -like $_ })
            }

        Write-EncoderLog -Level INFO -Message "Fichiers candidats : $($allFiles.Count)" -LogFile $mainLog

        # ====================================================================
        # PHASE 2 : ANALYSE & FILTRAGE
        # ====================================================================
        $toEncode = New-Object System.Collections.Generic.List[hashtable]
        $analyzed = 0
        foreach ($file in $allFiles) {
            $analyzed++
            if ($analyzed % 100 -eq 0) {
                Write-EncoderLog -Level INFO -Message "Analyse : $analyzed / $($allFiles.Count)" -LogFile $mainLog
            }

            # Skip si déjà connu
            if (Test-AlreadyProcessed -FilePath $file.FullName -StateFiles $StateFiles) {
                continue
            }

            $info = Get-MediaInfo -Path $file.FullName -FFprobePath $Config.FFprobePath
            $analysis = Test-ShouldEncode -MediaInfo $info

            if (-not $analysis.ShouldEncode) {
                Add-StateEntry -Store Skipped -FilePath $file.FullName -StateFiles $StateFiles -Data @{
                    reason = $analysis.Reason
                    codec  = $analysis.VideoCodec
                }
                continue
            }

            $toEncode.Add(@{
                Path     = $file.FullName
                Size     = $file.Length
                Info     = $info
                Analysis = $analysis
            })

            if ($MaxFiles -gt 0 -and $toEncode.Count -ge $MaxFiles) { break }
        }

        Write-EncoderLog -Level INFO -Message "À encoder : $($toEncode.Count) fichiers" -LogFile $mainLog
    }

    # ====================================================================
    # PHASE 3 : ENCODAGE
    # ====================================================================
    $jobIndex = 0
    $totalSavedBytes = 0L

    foreach ($job in $toEncode) {
        $jobIndex++
        $jobId = Get-PathHash $job.Path
        $jobLog = "$($Config.LogRoot)\jobs\$jobId.log"
        $ffmpegLog = "$($Config.LogRoot)\ffmpeg\$jobId.log"
        $tempDir = "$($Config.TempRoot)\$jobId"

        Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog -Message "[$jobIndex/$($toEncode.Count)] Début : $($job.Path)"

        try {
            # --- Vérif espace disque ---
            $requiredSpace = [long]($job.Size * 1.2)  # Marge 20%
            if (-not (Test-DiskSpace -Path $Config.TempRoot -RequiredBytes $requiredSpace)) {
                throw "Espace temp insuffisant (besoin ~$([math]::Round($requiredSpace/1GB,1)) Go)"
            }
            $sourceDrive = Split-Path -Qualifier $job.Path
            $sourceFree = (Get-PSDrive ($sourceDrive[0]) -ErrorAction SilentlyContinue).Free
            if ($sourceFree -lt ($Config.MinFreeSpaceGB * 1GB)) {
                throw "Espace source insuffisant : $([math]::Round($sourceFree/1GB,1)) Go libre"
            }

            # --- Préparation temp ---
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $sourceExt = [System.IO.Path]::GetExtension($job.Path)
            # Toujours sortir en MKV (le plus permissif)
            $tempOutput = "$tempDir\output.mkv"

            # --- Construction commande ---
            $args = Build-FFmpegArgs `
                -InputPath $job.Path `
                -OutputPath $tempOutput `
                -Config $Config `
                -MediaInfo $job.Info `
                -AnalysisResult $job.Analysis

            Write-EncoderLog -Level DEBUG -JobId $jobId -LogFile $jobLog -Message "Commande FFmpeg" -Context @{ args = $args }

            # --- DRY RUN ---
            if ($Config.DryRun) {
                Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog -Message "[DRY-RUN] Skip encodage réel"
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }

            # --- Encodage ---
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-FFmpegEncode `
                -FFmpegPath $Config.FFmpegPath `
                -Arguments $args `
                -LogPath $ffmpegLog `
                -TimeoutHours 24
            $sw.Stop()

            if ($result.ExitCode -ne 0) {
                throw "FFmpeg exit code $($result.ExitCode). Voir $ffmpegLog"
            }

            # --- Validation ---
            Write-EncoderLog -Level INFO -JobId $jobId -LogFile $jobLog -Message "Validation en cours..."
            $validation = Test-EncodedFileIntegrity `
                -OriginalPath $job.Path `
                -EncodedPath $tempOutput `
                -FFmpegPath $Config.FFmpegPath `
                -FFprobePath $Config.FFprobePath

            if (-not $validation.Valid) {
                throw "Validation échouée : $($validation.Reason)"
            }

            $newSize = (Get-Item $tempOutput).Length
            $savedBytes = $job.Size - $newSize
            $savedPct = [math]::Round(($savedBytes / $job.Size) * 100, 1)

            # --- Décision : garder le nouveau ou l'original ---
            if ($Config.KeepIfLarger -and $newSize -gt $job.Size) {
                Write-EncoderLog -Level WARN -JobId $jobId -LogFile $mainLog `
                    -Message "Nouveau fichier plus gros (+$([math]::Round((-$savedPct),1))%). Original conservé."
                Remove-Item $tempDir -Recurse -Force
                Add-StateEntry -Store Skipped -FilePath $job.Path -StateFiles $StateFiles -Data @{
                    reason = "Encoded file larger than original"
                    original_size = $job.Size
                    new_size = $newSize
                }
                continue
            }

            # --- Remplacement atomique ---
            $finalPath = [System.IO.Path]::ChangeExtension($job.Path, ".mkv")
            $backupPath = "$($job.Path).bak"

            # 1. Renommer original en .bak
            Rename-Item -Path $job.Path -NewName $backupPath -Force
            # 2. Copier nouveau à l'emplacement final
            Move-Item -Path $tempOutput -Destination $finalPath -Force
            # 3. Si SafeMode = $false ET DeleteOriginal = $true, supprimer le .bak
            if ($Config.SafeMode -eq $false -and $Config.DeleteOriginal -eq $true) {
                Remove-Item $backupPath -Force
                Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog -Message "Original supprimé."
            } else {
                Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog `
                    -Message "Original conservé en .bak (SafeMode actif). À nettoyer manuellement."
            }

            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

            # --- État ---
            $totalSavedBytes += $savedBytes
            Add-StateEntry -Store Processed -FilePath $job.Path -StateFiles $StateFiles -Data @{
                original_size  = $job.Size
                new_size       = $newSize
                saved_bytes    = $savedBytes
                saved_pct      = $savedPct
                duration_sec   = $sw.Elapsed.TotalSeconds
                final_path     = $finalPath
                encoder        = $Config.Encoder
                crf            = $Config.CRF
            }

            Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog -Message "OK" -Context @{
                saved_gb = [math]::Round($savedBytes/1GB,2)
                saved_pct = $savedPct
                time_min = [math]::Round($sw.Elapsed.TotalMinutes,1)
            }

        } catch {
            Write-EncoderLog -Level ERROR -JobId $jobId -LogFile $mainLog -Message "Échec : $_" -Context @{
                exception = $_.Exception.Message
                stack = $_.ScriptStackTrace
            }
            Add-StateEntry -Store Failed -FilePath $job.Path -StateFiles $StateFiles -Data @{
                error = $_.Exception.Message
            }
            # Nettoyage temp
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ====================================================================
    # RAPPORT FINAL
    # ====================================================================
    Write-EncoderLog -Level INFO -Message "=== Fin de batch ===" -LogFile $mainLog -Context @{
        total_saved_gb = [math]::Round($totalSavedBytes/1GB,2)
        jobs_processed = $jobIndex
    }

} finally {
    Remove-ProcessLock -StateRoot $Config.StateRoot
}
