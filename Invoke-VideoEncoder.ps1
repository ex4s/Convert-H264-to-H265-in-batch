<#
.SYNOPSIS
    Pipeline complet de réencodage H.264 → HEVC à grande échelle.

.DESCRIPTION
    - Analyse récursive du SourceRoot configuré
    - Détection H.264 / AVC, skip HEVC / AV1 / Dolby Vision
    - Réencodage x265 / NVENC / QSV / AMF selon config
    - Validation d'intégrité avant suppression
    - Reprise après crash via state JSON
    - Logs structurés JSON par job
    - Anti double-exécution via lock file

.PARAMETER ConfigPath
    Chemin du fichier de configuration JSON.

.PARAMETER DryRun
    Force le mode dry-run (override la config).

.PARAMETER MaxFiles
    Limite le nombre de fichiers traités (utile pour tests).
    0 = illimité.

.PARAMETER ResumeOnly
    Ne re-scanne pas le SourceRoot. Reprend uniquement les fichiers
    déjà découverts mais non traités.

.PARAMETER SourceRootOverride
    Override le SourceRoot de la config (utile pour tests sur un sous-dossier).

.EXAMPLE
    # Premier dry-run pour voir ce qui serait fait
    .\Invoke-VideoEncoder.ps1 -DryRun -MaxFiles 100

.EXAMPLE
    # Test réel sur 5 fichiers
    .\Invoke-VideoEncoder.ps1 -MaxFiles 5

.EXAMPLE
    # Production
    .\Invoke-VideoEncoder.ps1

.NOTES
    Conçu pour fonctionner en boucle via une tâche planifiée.
    Le verrou empêche les double-exécutions.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\VideoEncoder\config\encoder.config.json",
    [switch]$DryRun,
    [int]$MaxFiles = 0,
    [switch]$ResumeOnly,
    [string]$SourceRootOverride
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
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration introuvable : $ConfigPath. Lance Install-Dependencies.ps1 d'abord."
}
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if ($DryRun)            { $Config.DryRun = $true }
if ($SourceRootOverride) { $Config.SourceRoot = $SourceRootOverride }

# Validation basique de la config
if (-not (Test-Path $Config.FFmpegPath))  { throw "FFmpeg introuvable : $($Config.FFmpegPath)" }
if (-not (Test-Path $Config.FFprobePath)) { throw "FFprobe introuvable : $($Config.FFprobePath)" }
if (-not (Test-Path $Config.SourceRoot))  { throw "SourceRoot introuvable : $($Config.SourceRoot)" }

$mainLog = Join-Path $Config.LogRoot "main\encoder_$(Get-Date -Format 'yyyyMMdd').log"

# --- Verrou anti double-exécution ---
if (-not (Test-ProcessLock -StateRoot $Config.StateRoot)) {
    Write-EncoderLog -Level CRITICAL -Message "Une autre instance tourne déjà. Abandon." -LogFile $mainLog
    exit 1
}

# Wrapper pour s'assurer du nettoyage du lock
try {
    $StateFiles = Initialize-StateStore -StateRoot $Config.StateRoot
    Initialize-LogRotation -LogDir (Join-Path $Config.LogRoot "main") -MaxSizeMB 100 -KeepFiles 30

    Write-EncoderLog -Level INFO -Message "=== Démarrage encodeur ===" -LogFile $mainLog -Context @{
        host    = $env:COMPUTERNAME
        config  = $ConfigPath
        encoder = $Config.Encoder
        crf     = $Config.CRF
        dryrun  = [bool]$Config.DryRun
        safe    = [bool]$Config.SafeMode
    }

    # ====================================================================
    # PHASE 1 : DÉCOUVERTE
    # ====================================================================
    $toEncode = New-Object System.Collections.Generic.List[hashtable]

    if (-not $ResumeOnly) {
        Write-EncoderLog -Level INFO -Message "Scan récursif de $($Config.SourceRoot)..." -LogFile $mainLog

        $extensions  = $Config.Extensions
        $minBytes    = [long]$Config.MinFileSizeMB * 1MB
        $maxBytes    = [long]$Config.MaxFileSizeGB * 1GB
        $skipPats    = $Config.SkipPatterns

        # Get-ChildItem avec filtrage (extensions, taille, patterns)
        $allFiles = Get-ChildItem -Path $Config.SourceRoot -Recurse -File -ErrorAction Continue |
            Where-Object {
                $ext = $_.Extension.ToLower()
                if ($extensions -notcontains $ext) { return $false }
                if ($_.Length -lt $minBytes)       { return $false }
                if ($_.Length -gt $maxBytes)       { return $false }
                # BUG-FIX : on capture le fichier dans une variable nommée
                $candidateName = $_.Name
                foreach ($pattern in $skipPats) {
                    if ($candidateName -like $pattern) { return $false }
                }
                return $true
            }

        Write-EncoderLog -Level INFO -Message "Fichiers candidats : $($allFiles.Count)" -LogFile $mainLog

        # ====================================================================
        # PHASE 2 : ANALYSE & FILTRAGE
        # ====================================================================
        $analyzed = 0
        $skippedAlreadyKnown = 0
        $totalCandidates = $allFiles.Count

        foreach ($file in $allFiles) {
            $analyzed++

            if ($analyzed % 250 -eq 0) {
                Write-EncoderLog -Level INFO -LogFile $mainLog `
                    -Message "Analyse : $analyzed / $totalCandidates ($($toEncode.Count) à encoder, $skippedAlreadyKnown déjà connus)"
            }

            # Skip si déjà connu (processed/skipped/failed)
            if (Test-AlreadyProcessed -FilePath $file.FullName -StateFiles $StateFiles) {
                $skippedAlreadyKnown++
                continue
            }

            # Skip si verrouillé par autre process
            if (Test-FileLock -Path $file.FullName) {
                Write-EncoderLog -Level WARN -LogFile $mainLog `
                    -Message "Fichier verrouillé, skip : $($file.FullName)"
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

            if ($MaxFiles -gt 0 -and $toEncode.Count -ge $MaxFiles) {
                Write-EncoderLog -Level INFO -Message "MaxFiles ($MaxFiles) atteint, arrêt du scan." -LogFile $mainLog
                break
            }
        }

        Write-EncoderLog -Level INFO -Message "Phase d'analyse terminée." -LogFile $mainLog -Context @{
            analyzed   = $analyzed
            to_encode  = $toEncode.Count
            previously_known = $skippedAlreadyKnown
        }
    }

    if ($toEncode.Count -eq 0) {
        Write-EncoderLog -Level INFO -Message "Aucun fichier à encoder. Fin." -LogFile $mainLog
        return
    }

    # ====================================================================
    # PHASE 3 : ENCODAGE
    # ====================================================================
    $jobIndex = 0
    $totalSavedBytes = 0L
    $totalEncodingSeconds = 0.0

    foreach ($job in $toEncode) {
        $jobIndex++
        $jobId     = Get-PathHash $job.Path
        $jobLog    = Join-Path $Config.LogRoot "jobs\$jobId.log"
        $ffmpegLog = Join-Path $Config.LogRoot "ffmpeg\$jobId.log"
        $tempDir   = Join-Path $Config.TempRoot $jobId

        Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog `
            -Message "[$jobIndex/$($toEncode.Count)] Début" -Context @{
                path       = $job.Path
                size_gb    = [math]::Round($job.Size / 1GB, 2)
                codec      = $job.Analysis.VideoCodec
                resolution = "$($job.Analysis.Width)x$($job.Analysis.Height)"
                hdr        = $job.Analysis.IsHDR
                duration_min = [math]::Round($job.Analysis.Duration / 60, 1)
            }

        try {
            # --- Vérif espace disque temp ---
            $requiredSpace = [long]($job.Size * 1.5)  # Marge 50% pour le worst case
            if (-not (Test-DiskSpace -Path $Config.TempRoot -RequiredBytes $requiredSpace)) {
                throw "Espace insuffisant sur TempRoot (besoin ~$([math]::Round($requiredSpace/1GB,1)) Go)"
            }

            # --- Vérif espace source (pour le .bak temporaire) ---
            $sourcePathRoot = [System.IO.Path]::GetPathRoot($job.Path)
            if ($sourcePathRoot -match '^[A-Za-z]:') {
                $sourceLetter = $sourcePathRoot.Substring(0,1)
                $sourceDrive = Get-PSDrive -Name $sourceLetter -ErrorAction SilentlyContinue
                if ($sourceDrive -and $sourceDrive.Free -lt ($Config.MinFreeSpaceGB * 1GB)) {
                    throw "Espace source insuffisant : $([math]::Round($sourceDrive.Free/1GB,1)) Go libre, minimum requis : $($Config.MinFreeSpaceGB) Go"
                }
            }

            # --- Préparation temp ---
            if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $tempOutput = Join-Path $tempDir "output.mkv"

            # --- Construction commande ---
            $ffArgs = Build-FFmpegArgs `
                -InputPath $job.Path `
                -OutputPath $tempOutput `
                -Config $Config `
                -MediaInfo $job.Info `
                -AnalysisResult $job.Analysis

            Write-EncoderLog -Level DEBUG -JobId $jobId -LogFile $jobLog `
                -Message "Commande FFmpeg construite" -Context @{
                    arg_count = $ffArgs.Count
                    output    = $tempOutput
                }

            # --- DRY RUN ---
            if ($Config.DryRun) {
                Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog `
                    -Message "[DRY-RUN] Encodage simulé, aucune action réelle"
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }

            # --- Encodage réel ---
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-FFmpegEncode `
                -FFmpegPath $Config.FFmpegPath `
                -Arguments $ffArgs `
                -LogPath $ffmpegLog `
                -TimeoutHours $Config.TimeoutHours
            $sw.Stop()
            $totalEncodingSeconds += $sw.Elapsed.TotalSeconds

            if ($result.ExitCode -ne 0) {
                $tailSample = ($result.Output -split "`n" | Select-Object -Last 10) -join " | "
                throw "FFmpeg exit code $($result.ExitCode). Tail : $tailSample"
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

            $newSize    = (Get-Item $tempOutput).Length
            $savedBytes = $job.Size - $newSize
            $savedPct   = [math]::Round(($savedBytes / $job.Size) * 100, 1)

            # --- Décision : garder le nouveau ou l'original ? ---
            if ($Config.KeepIfLarger -and $newSize -ge $job.Size) {
                $growthPct = [math]::Round(($newSize - $job.Size) / $job.Size * 100, 1)
                Write-EncoderLog -Level WARN -JobId $jobId -LogFile $mainLog `
                    -Message "Encodage plus gros (+${growthPct}%), original conservé"
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                Add-StateEntry -Store Skipped -FilePath $job.Path -StateFiles $StateFiles -Data @{
                    reason        = "encoded_file_larger_than_original"
                    original_size = $job.Size
                    new_size      = $newSize
                    growth_pct    = $growthPct
                }
                continue
            }

            # --- Remplacement atomique ---
            $finalPath  = [System.IO.Path]::ChangeExtension($job.Path, ".mkv")
            $backupPath = "$($job.Path).bak"

            # 1. Renommer l'original en .bak (atomique, NTFS)
            Rename-Item -Path $job.Path -NewName ([System.IO.Path]::GetFileName($backupPath)) -Force

            # 2. Déplacer le nouveau à l'emplacement final
            Move-Item -Path $tempOutput -Destination $finalPath -Force

            # 3. Si pas en SafeMode et DeleteOriginal=true, supprimer le .bak
            if ((-not $Config.SafeMode) -and $Config.DeleteOriginal) {
                Remove-Item $backupPath -Force
                Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog -Message "Original .bak supprimé"
            } else {
                Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog `
                    -Message "Original conservé en .bak (SafeMode actif ou DeleteOriginal=false)"
            }

            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

            # --- État ---
            $totalSavedBytes += $savedBytes
            Add-StateEntry -Store Processed -FilePath $job.Path -StateFiles $StateFiles -Data @{
                original_size = $job.Size
                new_size      = $newSize
                saved_bytes   = $savedBytes
                saved_pct     = $savedPct
                duration_sec  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                final_path    = $finalPath
                backup_path   = $backupPath
                encoder       = $Config.Encoder
                crf           = $Config.CRF
                preset        = $Config.Preset
                was_hdr       = $job.Analysis.IsHDR
            }

            Write-EncoderLog -Level INFO -JobId $jobId -LogFile $mainLog -Message "Succès" -Context @{
                saved_gb  = [math]::Round($savedBytes / 1GB, 2)
                saved_pct = $savedPct
                time_min  = [math]::Round($sw.Elapsed.TotalMinutes, 1)
                speed     = if ($job.Analysis.Duration -gt 0) {
                    [math]::Round($job.Analysis.Duration / $sw.Elapsed.TotalSeconds, 2)
                } else { 0 }
            }

        } catch {
            $errMsg = $_.Exception.Message
            Write-EncoderLog -Level ERROR -JobId $jobId -LogFile $mainLog `
                -Message "Échec : $errMsg" -Context @{
                    stack = $_.ScriptStackTrace
                    path  = $job.Path
                }
            Add-StateEntry -Store Failed -FilePath $job.Path -StateFiles $StateFiles -Data @{
                error = $errMsg
            }
            # Nettoyage temp
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ====================================================================
    # RAPPORT FINAL
    # ====================================================================
    Write-EncoderLog -Level INFO -Message "=== Fin de batch ===" -LogFile $mainLog -Context @{
        jobs_processed       = $jobIndex
        total_saved_gb       = [math]::Round($totalSavedBytes / 1GB, 2)
        total_encoding_hours = [math]::Round($totalEncodingSeconds / 3600, 2)
    }

} catch {
    Write-EncoderLog -Level CRITICAL -Message "Erreur fatale : $($_.Exception.Message)" -LogFile $mainLog -Context @{
        stack = $_.ScriptStackTrace
    }
    # Dump du crash
    $crashFile = Join-Path $Config.LogRoot "crashes\crash_$(Get-Date -Format 'yyyyMMddHHmmss').log"
    $crashDir = Split-Path $crashFile -Parent
    if (-not (Test-Path $crashDir)) { New-Item -ItemType Directory -Path $crashDir -Force | Out-Null }
    $_ | Out-File $crashFile -Encoding UTF8
    exit 2
} finally {
    Remove-ProcessLock -StateRoot $Config.StateRoot
}
