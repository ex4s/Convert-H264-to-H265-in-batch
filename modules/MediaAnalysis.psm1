<#
.SYNOPSIS
    Analyse FFprobe : codec, HDR, Dolby Vision, audio, sous-titres, chapitres.

.DESCRIPTION
    Wrappe ffprobe et applique une logique de décision pour savoir si un fichier
    doit être réencodé. Détecte les pièges classiques :
    - HEVC/AV1 déjà encodés (skip)
    - Dolby Vision (skip — workflow dovi_tool nécessaire)
    - Fichiers sans flux vidéo
    - Cover art / attached pic (à ignorer)
#>

function Get-MediaInfo {
    <#
    .SYNOPSIS
        Retourne les métadonnées FFprobe d'un fichier sous forme d'objet.

    .OUTPUTS
        PSCustomObject ou $null si ffprobe a échoué.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FFprobePath
    )

    $ffprobeArgs = @(
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        '-show_chapters',
        '--', $Path
    )

    try {
        $raw = & $FFprobePath @ffprobeArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            return $null
        }
        $json = $raw -join "`n"
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-ShouldEncode {
    <#
    .SYNOPSIS
        Décide si un fichier doit être réencodé.

    .OUTPUTS
        PSCustomObject avec ShouldEncode, Reason, et métadonnées techniques.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, AllowNull = $true)]$MediaInfo
    )

    $result = [PSCustomObject]@{
        ShouldEncode  = $false
        Reason        = ""
        VideoCodec    = $null
        IsHDR         = $false
        IsDolbyVision = $false
        Width         = 0
        Height        = 0
        PixelFormat   = $null
        Duration      = 0.0
        BitrateKbps   = 0
    }

    if (-not $MediaInfo) {
        $result.Reason = "FFprobe a échoué (fichier corrompu, vide, ou format non reconnu)"
        return $result
    }

    # Filtrer cover art / attached pictures (disposition.attached_pic = 1)
    $videoStreams = @($MediaInfo.streams | Where-Object {
        $_.codec_type -eq 'video' -and (-not $_.disposition -or $_.disposition.attached_pic -ne 1)
    })

    if ($videoStreams.Count -eq 0) {
        $result.Reason = "Aucun flux vidéo principal détecté"
        return $result
    }

    $vs = $videoStreams[0]
    $result.VideoCodec  = $vs.codec_name
    $result.PixelFormat = $vs.pix_fmt
    $result.Width       = [int]($vs.width  | ForEach-Object { if ($_) { $_ } else { 0 } })
    $result.Height      = [int]($vs.height | ForEach-Object { if ($_) { $_ } else { 0 } })

    if ($MediaInfo.format.duration) {
        $result.Duration = [double]$MediaInfo.format.duration
    }
    if ($MediaInfo.format.bit_rate) {
        $result.BitrateKbps = [int]([long]$MediaInfo.format.bit_rate / 1000)
    }

    # --- Détection HDR ---
    $hdrTransfer  = @('smpte2084', 'arib-std-b67', 'smpte428')
    $hdrPrimaries = @('bt2020')
    $hdrSpace     = @('bt2020nc', 'bt2020c')

    if (($vs.color_transfer  -and $hdrTransfer  -contains $vs.color_transfer)  -or
        ($vs.color_primaries -and $hdrPrimaries -contains $vs.color_primaries) -or
        ($vs.color_space     -and $hdrSpace     -contains $vs.color_space)) {
        $result.IsHDR = $true
    }

    # --- Détection Dolby Vision ---
    if ($vs.side_data_list) {
        foreach ($sd in $vs.side_data_list) {
            $sdType = "$($sd.side_data_type)"
            if ($sdType -match 'Dolby Vision' -or $sd.dv_profile -ne $null) {
                $result.IsDolbyVision = $true
                break
            }
        }
    }

    # --- Décision sur le codec ---
    $skipCodecs = @('hevc', 'h265', 'vp9', 'av1', 'libaom-av1', 'libsvtav1')
    if ($skipCodecs -contains $vs.codec_name) {
        $result.Reason = "Déjà encodé en $($vs.codec_name)"
        return $result
    }

    $encodeCodecs = @('h264', 'avc', 'x264', 'mpeg4', 'mpeg2video', 'vc1', 'wmv3', 'msmpeg4v3')
    if ($encodeCodecs -contains $vs.codec_name) {
        # Garde-fou Dolby Vision
        if ($result.IsDolbyVision) {
            $result.Reason = "Dolby Vision détecté — skip pour préserver l'intégrité du DV"
            return $result
        }
        $result.ShouldEncode = $true
        $result.Reason = "Source $($vs.codec_name) éligible pour réencodage HEVC"
        return $result
    }

    $result.Reason = "Codec non géré : $($vs.codec_name)"
    return $result
}

function Get-HDRMetadata {
    <#
    .SYNOPSIS
        Construit les paramètres x265 pour préserver les métadonnées HDR.

    .OUTPUTS
        Array de strings type "colorprim=bt2020" à passer à -x265-params.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$MediaInfo)

    $vs = $MediaInfo.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    if (-not $vs) { return @() }

    $params = New-Object System.Collections.Generic.List[string]

    if ($vs.color_primaries) { $params.Add("colorprim=$($vs.color_primaries)")  }
    if ($vs.color_transfer)  { $params.Add("transfer=$($vs.color_transfer)")    }
    if ($vs.color_space)     { $params.Add("colormatrix=$($vs.color_space)")    }
    if ($vs.chroma_location) { $params.Add("chromaloc=$($vs.chroma_location)")  }

    if ($vs.color_range -eq 'tv')   { $params.Add("range=limited") }
    if ($vs.color_range -eq 'pc')   { $params.Add("range=full")    }

    # master-display et max-cll depuis side_data_list
    if ($vs.side_data_list) {
        foreach ($sd in $vs.side_data_list) {
            if ($sd.side_data_type -eq 'Mastering display metadata') {
                # Format x265 : G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)
                # FFprobe expose red_x, red_y, green_x, green_y, blue_x, blue_y,
                # white_point_x, white_point_y, min_luminance, max_luminance (en str rationnel)
                try {
                    function ConvertTo-Coord($val) {
                        if ($val -match '(\d+)/(\d+)') {
                            return [math]::Round(([double]$Matches[1] / [double]$Matches[2]) * 50000)
                        }
                        return [math]::Round([double]$val * 50000)
                    }
                    function ConvertTo-Lum($val) {
                        if ($val -match '(\d+)/(\d+)') {
                            return [math]::Round([double]$Matches[1] / [double]$Matches[2])
                        }
                        return [math]::Round([double]$val)
                    }

                    $gx = ConvertTo-Coord $sd.green_x
                    $gy = ConvertTo-Coord $sd.green_y
                    $bx = ConvertTo-Coord $sd.blue_x
                    $by = ConvertTo-Coord $sd.blue_y
                    $rx = ConvertTo-Coord $sd.red_x
                    $ry = ConvertTo-Coord $sd.red_y
                    $wx = ConvertTo-Coord $sd.white_point_x
                    $wy = ConvertTo-Coord $sd.white_point_y
                    $lmin = ConvertTo-Lum $sd.min_luminance
                    $lmax = ConvertTo-Lum $sd.max_luminance

                    $md = "G($gx,$gy)B($bx,$by)R($rx,$ry)WP($wx,$wy)L($lmax,$lmin)"
                    $params.Add("master-display=$md")
                } catch {
                    # Si parsing échoue, on continue sans master-display
                }
            }
            if ($sd.side_data_type -eq 'Content light level metadata') {
                $maxCll  = if ($sd.max_content) { $sd.max_content } else { 0 }
                $maxFall = if ($sd.max_average) { $sd.max_average } else { 0 }
                $params.Add("max-cll=$maxCll,$maxFall")
            }
        }
    }

    # Signaler que le contenu est HDR10
    $params.Add("hdr10=1")
    $params.Add("hdr10-opt=1")
    $params.Add("repeat-headers=1")

    return $params.ToArray()
}

function Test-FileLock {
    <#
    .SYNOPSIS
        Détecte si un fichier est verrouillé (en cours d'écriture par une autre app).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $true }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
        $fs.Dispose()
        return $false
    } catch {
        return $true
    }
}

Export-ModuleMember -Function Get-MediaInfo, Test-ShouldEncode, Get-HDRMetadata, Test-FileLock
