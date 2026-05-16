<#
.SYNOPSIS
    Construction de la commande FFmpeg et exécution avec gestion timeout/erreurs.
#>

function Build-FFmpegArgs {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$MediaInfo,
        [Parameter(Mandatory)]$AnalysisResult
    )

    $args = @(
        '-hide_banner',
        '-y',                                # Overwrite (la sortie est en temp/, contrôlé)
        '-nostdin',
        '-fflags', '+genpts+igndts',         # Robustesse sur fichiers TS/AVI mal muxés
        '-err_detect', 'ignore_err',
        '-i', $InputPath,
        '-map', '0',                         # Garde TOUS les flux
        '-map_metadata', '0',                # Métadonnées globales
        '-map_chapters', '0'                 # Chapitres
    )

    # --- Encodeur vidéo ---
    switch ($Config.Encoder) {
        'libx265' {
            $args += @(
                '-c:v', 'libx265',
                '-preset', $Config.Preset,
                '-crf', $Config.CRF
            )
            # Paramètres x265 personnalisés (HDR, etc.)
            $x265Params = @()
            if ($AnalysisResult.IsHDR) {
                $hdrParams = Get-HDRMetadata -MediaInfo $MediaInfo
                $x265Params += $hdrParams
                $x265Params += 'hdr10=1'
            }
            $x265Params += "log-level=error"
            if ($x265Params.Count -gt 0) {
                $args += '-x265-params'
                $args += ($x265Params -join ':')
            }
            # Profile selon bit depth source
            $vs = $MediaInfo.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
            if ($vs.pix_fmt -match '10le') {
                $args += @('-pix_fmt', 'yuv420p10le')
            } else {
                $args += @('-pix_fmt', 'yuv420p')
            }
        }
        'hevc_nvenc' {
            $args += @(
                '-c:v', 'hevc_nvenc',
                '-preset', 'p6',             # p1=fastest, p7=slowest/best
                '-rc', 'vbr',
                '-cq', $Config.CRF,
                '-b:v', '0',                 # Pure CQ mode
                '-spatial_aq', '1',
                '-temporal_aq', '1'
            )
            if ($AnalysisResult.IsHDR) {
                $args += @('-pix_fmt', 'p010le')
            }
        }
        'hevc_qsv' {
            $args += @(
                '-c:v', 'hevc_qsv',
                '-preset', 'slow',
                '-global_quality', $Config.CRF,
                '-look_ahead', '1'
            )
        }
    }

    # --- Audio : copie intégrale ---
    $args += @('-c:a', 'copy')

    # --- Sous-titres : copie, sauf incompat MP4 ---
    $outExt = [System.IO.Path]::GetExtension($OutputPath).ToLower()
    if ($outExt -eq '.mp4') {
        # MP4 ne supporte pas les sous-titres SRT/PGS, on convertit ou skip
        $args += @('-c:s', 'mov_text')
    } else {
        $args += @('-c:s', 'copy')
    }

    # --- Data/Attachments ---
    $args += @('-c:d', 'copy', '-c:t', 'copy')

    # --- Garder les tags de langue et titres ---
    $args += @('-map_metadata:s:a', '0:s:a', '-map_metadata:s:s', '0:s:s')

    # --- Timestamps / sync ---
    $args += @('-avoid_negative_ts', 'make_zero')

    # --- Sortie ---
    $args += @('-max_muxing_queue_size', '4096')
    $args += $OutputPath

    return $args
}

function Invoke-FFmpegEncode {
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

    # Capture asynchrone des sorties (sinon deadlock sur gros buffers)
    $stderr = New-Object System.Text.StringBuilder
    $stdout = New-Object System.Text.StringBuilder
    $proc.add_ErrorDataReceived({  param($s,$e) if ($e.Data) { [void]$stderr.AppendLine($e.Data) } })
    $proc.add_OutputDataReceived({ param($s,$e) if ($e.Data) { [void]$stdout.AppendLine($e.Data) } })

    [void]$proc.Start()
    $proc.BeginErrorReadLine()
    $proc.BeginOutputReadLine()

    $timeoutMs = $TimeoutHours * 3600 * 1000
    if (-not $proc.WaitForExit($timeoutMs)) {
        $proc.Kill($true)
        throw "FFmpeg timeout après $TimeoutHours h"
    }

    # Vidage final
    $proc.WaitForExit()

    $allOutput = $stderr.ToString() + "`n" + $stdout.ToString()
    Set-Content -Path $LogPath -Value $allOutput -Encoding UTF8

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = $allOutput
    }
}

Export-ModuleMember -Function Build-FFmpegArgs, Invoke-FFmpegEncode
