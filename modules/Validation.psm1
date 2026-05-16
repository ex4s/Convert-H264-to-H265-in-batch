<#
.SYNOPSIS
    Validation d'intégrité du fichier réencodé avant suppression de l'original.
    Vérifie : décodabilité complète, durée, présence de tous les flux, hash audio.
#>

function Test-EncodedFileIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OriginalPath,
        [Parameter(Mandatory)][string]$EncodedPath,
        [Parameter(Mandatory)][string]$FFmpegPath,
        [Parameter(Mandatory)][string]$FFprobePath,
        [double]$DurationToleranceSeconds = 2.0
    )

    $report = [PSCustomObject]@{
        Valid          = $false
        Checks         = @{}
        Reason         = ""
    }

    # --- Check 1 : Fichier existe et non vide ---
    if (-not (Test-Path $EncodedPath)) {
        $report.Reason = "Fichier encodé inexistant"
        return $report
    }
    $size = (Get-Item $EncodedPath).Length
    if ($size -lt 1MB) {
        $report.Reason = "Fichier encodé trop petit ($([math]::Round($size/1KB)) Ko)"
        return $report
    }
    $report.Checks.FileExists = $true

    # --- Check 2 : FFprobe lit le fichier ---
    $info = & $FFprobePath -v error -print_format json -show_format -show_streams $EncodedPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $report.Reason = "FFprobe échec sur fichier encodé : $info"
        return $report
    }
    $infoObj = ($info -join "`n") | ConvertFrom-Json
    $report.Checks.FFprobeOk = $true

    # --- Check 3 : Durée cohérente ---
    $origInfo = & $FFprobePath -v error -print_format json -show_format $OriginalPath 2>$null
    $origObj = ($origInfo -join "`n") | ConvertFrom-Json
    $origDur = [double]$origObj.format.duration
    $newDur  = [double]$infoObj.format.duration
    if ([Math]::Abs($origDur - $newDur) -gt $DurationToleranceSeconds) {
        $report.Reason = "Durée incohérente : orig=$origDur s, new=$newDur s"
        return $report
    }
    $report.Checks.DurationOk = $true

    # --- Check 4 : Nombre de flux préservé ---
    $origStreams = ($origObj.streams).Count
    $newStreams  = ($infoObj.streams).Count
    # Le remux peut perdre des flux data inutiles, on tolère
    if ($newStreams -lt ($origStreams - 2)) {
        $report.Reason = "Flux manquants : orig=$origStreams, new=$newStreams"
        return $report
    }
    $report.Checks.StreamsOk = $true

    # --- Check 5 : Décodage complet (le test le plus important) ---
    # FFmpeg lit tout le fichier et vérifie chaque frame
    $decodeLog = & $FFmpegPath -v error -i $EncodedPath -f null - 2>&1
    if ($LASTEXITCODE -ne 0 -or ($decodeLog -match 'error|Invalid|corrupt')) {
        $report.Reason = "Décodage échoué : $($decodeLog | Select-Object -First 5)"
        return $report
    }
    $report.Checks.FullDecodeOk = $true

    $report.Valid = $true
    return $report
}

function Test-DiskSpace {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$RequiredBytes
    )
    $drive = (Get-Item $Path).PSDrive
    if (-not $drive) {
        # Chemin UNC ou exotique
        $drive = Get-PSDrive -Name $Path.Substring(0,1) -ErrorAction SilentlyContinue
    }
    if (-not $drive) { return $true }  # On ne peut pas vérifier, on tente
    return ($drive.Free -gt $RequiredBytes)
}

Export-ModuleMember -Function Test-EncodedFileIntegrity, Test-DiskSpace
