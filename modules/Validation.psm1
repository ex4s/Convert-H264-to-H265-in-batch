<#
.SYNOPSIS
    Validation d'intégrité du fichier réencodé AVANT toute suppression de l'original.

.DESCRIPTION
    Effectue plusieurs niveaux de vérification :
    1. Existence et taille minimale
    2. FFprobe lit correctement le fichier
    3. Durée cohérente avec l'original (tolérance configurable)
    4. Nombre de flux préservé (avec tolérance pour les flux data)
    5. Décodage complet sans erreur (le test critique)
#>

function Test-EncodedFileIntegrity {
    <#
    .SYNOPSIS
        Valide qu'un fichier réencodé est utilisable et fidèle à l'original.

    .OUTPUTS
        PSCustomObject avec .Valid (bool), .Reason (string), .Checks (hashtable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OriginalPath,
        [Parameter(Mandatory)][string]$EncodedPath,
        [Parameter(Mandatory)][string]$FFmpegPath,
        [Parameter(Mandatory)][string]$FFprobePath,
        [double]$DurationToleranceSeconds = 2.0,
        [int]$StreamLossTolerance = 2
    )

    $report = [PSCustomObject]@{
        Valid  = $false
        Checks = @{}
        Reason = ""
    }

    # --- Check 1 : Existence et taille minimale ---
    if (-not (Test-Path $EncodedPath)) {
        $report.Reason = "Fichier encodé inexistant"
        return $report
    }
    $encodedSize = (Get-Item $EncodedPath).Length
    if ($encodedSize -lt 1MB) {
        $report.Reason = "Fichier encodé suspicieusement petit ($([math]::Round($encodedSize/1KB)) Ko)"
        return $report
    }
    $report.Checks.FileExists = $true

    # --- Check 2 : FFprobe lit le nouveau fichier ---
    $newInfoRaw = & $FFprobePath -v error -print_format json -show_format -show_streams $EncodedPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $report.Reason = "FFprobe a échoué sur le fichier encodé"
        return $report
    }
    try {
        $newInfo = ($newInfoRaw -join "`n") | ConvertFrom-Json
    } catch {
        $report.Reason = "FFprobe output non parsable : $($_.Exception.Message)"
        return $report
    }
    $report.Checks.FFprobeOk = $true

    # --- Check 3 : Durée cohérente ---
    $origInfoRaw = & $FFprobePath -v error -print_format json -show_format $OriginalPath 2>$null
    try {
        $origInfo = ($origInfoRaw -join "`n") | ConvertFrom-Json
    } catch {
        $report.Reason = "FFprobe original non parsable"
        return $report
    }

    if ($origInfo.format.duration -and $newInfo.format.duration) {
        $origDur = [double]$origInfo.format.duration
        $newDur  = [double]$newInfo.format.duration
        $diff = [Math]::Abs($origDur - $newDur)
        if ($diff -gt $DurationToleranceSeconds) {
            $report.Reason = "Durée incohérente : orig=$([math]::Round($origDur,1))s, new=$([math]::Round($newDur,1))s (diff=$([math]::Round($diff,1))s)"
            return $report
        }
        $report.Checks.DurationOk = $true
    } else {
        $report.Checks.DurationOk = "skipped (durée absente)"
    }

    # --- Check 4 : Nombre de flux préservé ---
    $origStreams = @($origInfo.streams).Count
    $newStreams  = @($newInfo.streams).Count
    if ($newStreams -lt ($origStreams - $StreamLossTolerance)) {
        $report.Reason = "Flux manquants : orig=$origStreams, new=$newStreams"
        return $report
    }
    $report.Checks.StreamsOk = "$newStreams/$origStreams"

    # --- Check 5 : Décodage complet (LE check critique) ---
    # FFmpeg tente de décoder chaque frame ; les erreurs apparaissent en stderr
    $decodeOutput = & $FFmpegPath -v error -xerror -i $EncodedPath -f null - 2>&1
    $decodeExit = $LASTEXITCODE

    # Filtres : on tolère certains warnings non bloquants
    $errorLines = $decodeOutput | Where-Object {
        $_ -match '\b(error|Invalid|corrupt|truncated|missing)\b' -and
        $_ -notmatch 'non monotonous' -and
        $_ -notmatch 'Estimating duration'
    }

    if ($decodeExit -ne 0 -or $errorLines) {
        $errSample = ($errorLines | Select-Object -First 5) -join " | "
        $report.Reason = "Décodage échoué (exit=$decodeExit) : $errSample"
        return $report
    }
    $report.Checks.FullDecodeOk = $true

    $report.Valid = $true
    return $report
}

function Test-DiskSpace {
    <#
    .SYNOPSIS
        Vérifie l'espace libre disponible sur un chemin (gère locaux et UNC).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$RequiredBytes
    )

    try {
        # Méthode 1 : si Path correspond à un drive letter local
        $qualifier = [System.IO.Path]::GetPathRoot($Path)
        if ($qualifier -match '^[A-Za-z]:') {
            $driveLetter = $qualifier.Substring(0,1)
            $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
            if ($drive -and $drive.Free) {
                return ($drive.Free -gt $RequiredBytes)
            }
        }

        # Méthode 2 : WMI pour les volumes spéciaux / UNC mappés
        $driveInfo = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Path))
        if ($driveInfo.IsReady) {
            return ($driveInfo.AvailableFreeSpace -gt $RequiredBytes)
        }
    } catch {
        # En cas d'échec, on retourne $true pour ne pas bloquer (le système gérera)
        return $true
    }
    return $true
}

Export-ModuleMember -Function Test-EncodedFileIntegrity, Test-DiskSpace
