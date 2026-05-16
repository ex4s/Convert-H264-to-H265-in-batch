<#
.SYNOPSIS
    Logging structuré JSON, thread-safe, avec rotation.

.DESCRIPTION
    Chaque ligne de log est un objet JSON valide (NDJSON) — exploitable directement
    par jq, ELK, Splunk, etc. Le mutex global permet l'écriture concurrente depuis
    plusieurs runspaces PowerShell sans corruption.
#>

# Mutex partagé entre processus pour éviter les écritures concurrentes corrompues
$script:LogMutex = $null

function Get-LogMutex {
    if (-not $script:LogMutex) {
        $script:LogMutex = [System.Threading.Mutex]::new($false, "Global\WindowsVideoEncoder_LogMutex")
    }
    return $script:LogMutex
}

function Write-EncoderLog {
    <#
    .SYNOPSIS
        Écrit une entrée de log structurée (console + fichier).

    .PARAMETER Message
        Message principal.

    .PARAMETER Level
        DEBUG, INFO, WARN, ERROR, CRITICAL.

    .PARAMETER LogFile
        Chemin du fichier de log (optionnel — sinon console seulement).

    .PARAMETER JobId
        Identifiant court du job courant (pour corrélation).

    .PARAMETER Context
        Hashtable de données structurées additionnelles.

    .EXAMPLE
        Write-EncoderLog -Level INFO -Message "Démarrage" -LogFile "C:\logs\main.log" -Context @{ files = 31000 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','CRITICAL')][string]$Level = 'INFO',
        [string]$LogFile,
        [string]$JobId,
        [hashtable]$Context
    )

    $ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    $entry = [ordered]@{
        timestamp = $ts
        level     = $Level
        pid       = $PID
    }
    if ($JobId)   { $entry.job_id  = $JobId }
    $entry.message = $Message
    if ($Context) { $entry.context = $Context }

    $json = $entry | ConvertTo-Json -Compress -Depth 6

    # --- Console couleur ---
    $color = switch ($Level) {
        'DEBUG'    { 'DarkGray' }
        'INFO'     { 'White'    }
        'WARN'     { 'Yellow'   }
        'ERROR'    { 'Red'      }
        'CRITICAL' { 'Magenta'  }
        default    { 'White'    }
    }
    $jobTag = if ($JobId) { "[$JobId]" } else { "" }
    Write-Host "[$ts][$Level]$jobTag $Message" -ForegroundColor $color

    # --- Fichier (mutex global) ---
    if ($LogFile) {
        $mutex = Get-LogMutex
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne(5000)
            if ($acquired) {
                # S'assurer que le répertoire existe
                $dir = Split-Path $LogFile -Parent
                if ($dir -and -not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                Add-Content -Path $LogFile -Value $json -Encoding UTF8
            }
        } catch {
            # En cas d'échec d'écriture, ne JAMAIS planter le pipeline principal
            Write-Host "[LOGGING ERROR] $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            if ($acquired) { $mutex.ReleaseMutex() }
        }
    }
}

function Initialize-LogRotation {
    <#
    .SYNOPSIS
        Compresse les logs > MaxSizeMB, garde les KeepFiles plus récents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [int]$MaxSizeMB = 100,
        [int]$KeepFiles = 30
    )

    if (-not (Test-Path $LogDir)) { return }

    Get-ChildItem $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt ($MaxSizeMB * 1MB) } |
        ForEach-Object {
            $rotated = "$($_.FullName).$(Get-Date -Format 'yyyyMMddHHmmss').gz"
            try {
                $in  = [System.IO.File]::OpenRead($_.FullName)
                $out = [System.IO.File]::Create($rotated)
                $gz  = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
                $in.CopyTo($gz)
                $gz.Close(); $out.Close(); $in.Close()
                Remove-Item $_.FullName -Force
            } catch {
                Write-Host "[ROTATION ERROR] $($_.FullName) : $($_.Exception.Message)" -ForegroundColor Red
            }
        }

    # Cleanup des plus vieux .gz
    Get-ChildItem $LogDir -Filter "*.gz" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepFiles |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Write-EncoderLog, Initialize-LogRotation
