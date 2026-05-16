<#
.SYNOPSIS
    Construction et exécution des commandes FFmpeg.

.DESCRIPTION
    Sépare la construction des arguments (testable) de l'exécution (effets de bord).
    Gère la lecture asynchrone de stdout/stderr pour éviter les deadlocks sur les
    gros buffers (FFmpeg peut produire >100 Mo de logs sur un encodage long).
#>

function Build-FFmpegArgs {
    <#
    .SYNOPSIS
        Construit les arguments FFmpeg pour un job d'encodage HEVC.

    .DESCRIPTION
        Map tous les flux, préserve métadonnées, chapitres, langues.
        Applique HDR si détecté.

    .OUTPUTS
        Array de strings (arguments FFmpeg).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$MediaInfo,
        [Parameter(Mandatory)]$AnalysisResult
    )

    $ffArgs = New-Object System.Collections.Generic.List[string]

    # --- Préfixe global ---
    $null = $ffArgs.Add('-hide_banner')
    $null = $ffArgs.Add('-y')                # Overwrite (sortie en temp/, contrôlé)
    $null = $ffArgs.Add('-nostdin')
    $null = $ffArgs.Add('-fflags')
    $null = $ffArgs.Add('+genpts+igndts')    # Robustesse TS/AVI mal muxés
    $null = $ffArgs.Add('-err_detect')
    $null = $ffArgs.Add('ignore_err')
    $null = $ffArgs.Add('-i')
    $null = $ffArgs.Add($InputPath)

    # --- Mapping : tous les flux + chapitres + métadonnées globales ---
    $null = $ffArgs.Add('-map'); $null = $ffArgs.Add('0')
    $null = $ffArgs.Add('-map_metadata'); $null = $ffArgs.Add('0')
    $null = $ffArgs.Add('-map_chapters'); $null = $ffArgs.Add('0')

    # --- Encodeur vidéo ---
    switch ($Config.Encoder) {
        'libx265' {
            $null = $ffArgs.Add('-c:v'); $null = $ffArgs.Add('libx265')
            $null = $ffArgs.Add('-preset'); $null = $ffArgs.Add([string]$Config.Preset)
            $null = $ffArgs.Add('-crf'); $null = $ffArgs.Add([string]$Config.CRF)

            $x265Params = New-Object System.Collections.Generic.List[string]

            if ($AnalysisResult.IsHDR) {
                $hdrParams = Get-HDRMetadata -MediaInfo $MediaInfo
                foreach ($p in $hdrParams) { $x265Params.Add($p) }
            }
            $x265Params.Add("log-level=error")

            if ($x265Params.Count -gt 0) {
                $null = $ffArgs.Add('-x265-params')
                $null = $ffArgs.Add(($x265Params -join ':'))
            }

            # Pixel format selon source
            $pix = if ($AnalysisResult.PixelFormat -match '10le|10be|p010') { 'yuv420p10le' } else { 'yuv420p' }
            $null = $ffArgs.Add('-pix_fmt'); $null = $ffArgs.Add($pix)
        }

        'hevc_nvenc' {
            $null = $ffArgs.Add('-c:v'); $null = $ffArgs.Add('hevc_nvenc')
            $null = $ffArgs.Add('-preset'); $null = $ffArgs.Add('p6')         # qualité/vitesse équilibré
            $null = $ffArgs.Add('-rc'); $null = $ffArgs.Add('vbr')
            $null = $ffArgs.Add('-cq'); $null = $ffArgs.Add([string]$Config.CRF)
            $null = $ffArgs.Add('-b:v'); $null = $ffArgs.Add('0')
            $null = $ffArgs.Add('-spatial_aq'); $null = $ffArgs.Add('1')
            $null = $ffArgs.Add('-temporal_aq'); $null = $ffArgs.Add('1')
            $null = $ffArgs.Add('-rc-lookahead'); $null = $ffArgs.Add('32')

            if ($AnalysisResult.PixelFormat -match '10le|10be|p010') {
                $null = $ffArgs.Add('-pix_fmt'); $null = $ffArgs.Add('p010le')
                $null = $ffArgs.Add('-profile:v'); $null = $ffArgs.Add('main10')
            }
        }

        'hevc_qsv' {
            $null = $ffArgs.Add('-c:v'); $null = $ffArgs.Add('hevc_qsv')
            $null = $ffArgs.Add('-preset'); $null = $ffArgs.Add('slow')
            $null = $ffArgs.Add('-global_quality'); $null = $ffArgs.Add([string]$Config.CRF)
            $null = $ffArgs.Add('-look_ahead'); $null = $ffArgs.Add('1')
        }

        'hevc_amf' {
            $null = $ffArgs.Add('-c:v'); $null = $ffArgs.Add('hevc_amf')
            $null = $ffArgs.Add('-quality'); $null = $ffArgs.Add('quality')
            $null = $ffArgs.Add('-rc'); $null = $ffArgs.Add('cqp')
            $null = $ffArgs.Add('-qp_i'); $null = $ffArgs.Add([string]$Config.CRF)
            $null = $ffArgs.Add('-qp_p'); $null = $ffArgs.Add([string]$Config.CRF)
        }

        default {
            throw "Encoder non supporté : $($Config.Encoder)"
        }
    }

    # --- Audio : copie intégrale ---
    $null = $ffArgs.Add('-c:a'); $null = $ffArgs.Add('copy')

    # --- Sous-titres : selon container de sortie ---
    $outExt = [System.IO.Path]::GetExtension($OutputPath).ToLower()
    if ($outExt -eq '.mp4') {
        $null = $ffArgs.Add('-c:s'); $null = $ffArgs.Add('mov_text')
    } else {
        $null = $ffArgs.Add('-c:s'); $null = $ffArgs.Add('copy')
    }

    # --- Data et attachments ---
    $null = $ffArgs.Add('-c:d'); $null = $ffArgs.Add('copy')
    $null = $ffArgs.Add('-c:t'); $null = $ffArgs.Add('copy')

    # --- Sync timestamps ---
    $null = $ffArgs.Add('-avoid_negative_ts'); $null = $ffArgs.Add('make_zero')
    $null = $ffArgs.Add('-max_muxing_queue_size'); $null = $ffArgs.Add('4096')

    # --- Sortie ---
    $null = $ffArgs.Add($OutputPath)

    return $ffArgs.ToArray()
}

function Invoke-FFmpegEncode {
    <#
    .SYNOPSIS
        Lance FFmpeg avec lecture async des sorties et timeout dur.

    .OUTPUTS
        PSCustomObject avec ExitCode (int) et Output (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FFmpegPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$LogPath,
        [int]$TimeoutHours = 24
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FFmpegPath
    foreach ($a in $Arguments) { $null = $startInfo.ArgumentList.Add($a) }
    $startInfo.RedirectStandardError  = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $startInfo

    # Capture asynchrone (sinon deadlock sur buffers pleins)
    $stderr = [System.Text.StringBuilder]::new()
    $stdout = [System.Text.StringBuilder]::new()

    $errHandler = {
        if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    }
    $outHandler = {
        if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    }

    $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $errHandler -MessageData $stderr
    $outEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outHandler -MessageData $stdout

    try {
        [void]$proc.Start()
        $proc.BeginErrorReadLine()
        $proc.BeginOutputReadLine()

        $timeoutMs = $TimeoutHours * 3600 * 1000
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill($true) } catch { }
            throw "FFmpeg timeout après $TimeoutHours h"
        }
        $proc.WaitForExit()  # Vide les buffers async restants

        # Petit délai pour laisser les handlers traiter les derniers événements
        Start-Sleep -Milliseconds 200

        $allOutput = $stderr.ToString() + "`n--- STDOUT ---`n" + $stdout.ToString()

        # S'assurer que le répertoire de log existe
        $logDir = Split-Path $LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Set-Content -Path $LogPath -Value $allOutput -Encoding UTF8

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Output   = $allOutput
        }
    } finally {
        Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue
        Remove-Job -Job $errEvent -Force -ErrorAction SilentlyContinue
        Remove-Job -Job $outEvent -Force -ErrorAction SilentlyContinue
        $proc.Dispose()
    }
}

Export-ModuleMember -Function Build-FFmpegArgs, Invoke-FFmpegEncode
