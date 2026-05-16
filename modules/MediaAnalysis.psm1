<#
.SYNOPSIS
    Analyse FFprobe : codec, HDR, Dolby Vision, audio, sous-titres, chapitres.
#>

function Get-MediaInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FFprobePath
    )

    $args = @(
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        '-show_chapters',
        '--', $Path
    )

    try {
        $raw = & $FFprobePath @args 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            return $null
        }
        return ($raw -join "`n") | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-ShouldEncode {
    <#
    Retourne un objet avec :
      - ShouldEncode : bool
      - Reason       : string
      - VideoCodec   : string
      - IsHDR        : bool
      - IsDolbyVision: bool
    #>
    param([Parameter(Mandatory)]$MediaInfo)

    $result = [PSCustomObject]@{
        ShouldEncode  = $false
        Reason        = ""
        VideoCodec    = $null
        IsHDR         = $false
        IsDolbyVision = $false
        Width         = 0
        Height        = 0
        Duration      = 0
        BitrateKbps   = 0
    }

    if (-not $MediaInfo) {
        $result.Reason = "FFprobe a échoué (fichier corrompu ou format non reconnu)"
        return $result
    }

    $videoStreams = @($MediaInfo.streams | Where-Object { $_.codec_type -eq 'video' -and $_.disposition.attached_pic -ne 1 })
    if ($videoStreams.Count -eq 0) {
        $result.Reason = "Aucun flux vidéo détecté"
        return $result
    }

    $vs = $videoStreams[0]
    $result.VideoCodec = $vs.codec_name
    $result.Width      = [int]$vs.width
    $result.Height     = [int]$vs.height
    if ($MediaInfo.format.duration) {
        $result.Duration = [double]$MediaInfo.format.duration
    }
    if ($MediaInfo.format.bit_rate) {
        $result.BitrateKbps = [int]([long]$MediaInfo.format.bit_rate / 1000)
    }

    # Détection HDR (HDR10, HDR10+, HLG)
    if ($vs.color_transfer -in @('smpte2084','arib-std-b67') -or
        $vs.color_primaries -eq 'bt2020' -or
        $vs.color_space -eq 'bt2020nc' -or $vs.color_space -eq 'bt2020c') {
        $result.IsHDR = $true
    }

    # Détection Dolby Vision (side_data_list)
    if ($vs.side_data_list) {
        foreach ($sd in $vs.side_data_list) {
            if ($sd.side_data_type -match 'Dolby Vision' -or $sd.dv_profile) {
                $result.IsDolbyVision = $true
                break
            }
        }
    }

    # Codecs à ignorer (déjà encodés efficacement)
    $skipCodecs = @('hevc','h265','vp9','av1','libaom-av1')
    if ($skipCodecs -contains $vs.codec_name) {
        $result.Reason = "Déjà encodé en $($vs.codec_name)"
        return $result
    }

    # Codecs à réencoder
    $encodeCodecs = @('h264','avc','x264','mpeg4','mpeg2video','vc1','wmv3')
    if ($encodeCodecs -contains $vs.codec_name) {
        # Garde-fou Dolby Vision
        if ($result.IsDolbyVision) {
            $result.Reason = "Dolby Vision détecté — skip pour éviter la perte du DV"
            return $result
        }
        $result.ShouldEncode = $true
        $result.Reason = "Source $($vs.codec_name) → réencodage HEVC"
        return $result
    }

    $result.Reason = "Codec non géré : $($vs.codec_name)"
    return $result
}

function Get-HDRMetadata {
    <#
    Extrait les métadonnées HDR à passer à x265 via -x265-params.
    #>
    param([Parameter(Mandatory)]$MediaInfo)

    $vs = $MediaInfo.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $params = @()

    if ($vs.color_primaries) { $params += "colorprim=$($vs.color_primaries)" }
    if ($vs.color_transfer)  { $params += "transfer=$($vs.color_transfer)" }
    if ($vs.color_space)     { $params += "colormatrix=$($vs.color_space)" }
    if ($vs.chroma_location) { $params += "chromaloc=$($vs.chroma_location)" }

    # master-display et max-cll via side_data
    if ($vs.side_data_list) {
        foreach ($sd in $vs.side_data_list) {
            if ($sd.side_data_type -eq 'Mastering display metadata') {
                # Format à reconstruire pour x265
                # Voir doc x265 : G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)
                # Données dans red_x, red_y, green_x, etc.
                # (Implémentation complète à ajouter selon tes besoins)
            }
            if ($sd.side_data_type -eq 'Content light level metadata') {
                $params += "max-cll=$($sd.max_content),$($sd.max_average)"
            }
        }
    }

    if ($vs.color_range -eq 'tv')   { $params += "range=limited" }
    if ($vs.color_range -eq 'pc')   { $params += "range=full" }

    return $params
}

Export-ModuleMember -Function Get-MediaInfo, Test-ShouldEncode, Get-HDRMetadata
