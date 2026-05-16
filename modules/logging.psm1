<#
.SYNOPSIS
    Système de logs structuré, rotatif, thread-safe.
#>

$script:LogLock = [System.Threading.Mutex]::new($false, "Global\VideoEncoderLogMutex")

function Write-EncoderLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','CRITICAL')][string]$Level = 'INFO',
        [string]$LogFile,
        [string]$JobId,
        [hashtable]$Context
    )

    $ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $entry = [PSCustomObject]@{
        timestamp = $ts
        level     = $Level
        job_id    = $JobId
        pid       = $PID
        message   = $Message
        context   = $Context
    }
    $json = $entry | ConvertTo-Json -Compress -Depth 5

    # Console couleur
    $color = switch ($Level) {
        'DEBUG'    { 'DarkGray' }
        'INFO'     { 'White'    }
        'WARN'     { 'Yellow'   }
        'ERROR'    { 'Red'      }
        'CRITICAL' { 'Magenta'  }
    }
    Write-Host "[$ts][$Level]$(if($JobId){"[$JobId]"}) $Message" -ForegroundColor $color

    # Fichier (thread-safe via mutex global)
    if ($LogFile) {
        try {
            $null = $script:LogLock.WaitOne(5000)
            Add-Content -Path $LogFile -Value $json -Encoding UTF8
        } finally {
            $script:LogLock.ReleaseMutex()
        }
    }
}

function Initialize-LogRotation {
    param(
        [string]$LogDir,
        [int]$MaxSizeMB = 100,
        [int]$KeepFiles = 30
    )
    Get-ChildItem $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt ($MaxSizeMB * 1MB) } |
        ForEach-Object {
            $rotated = "$($_.FullName).$(Get-Date -Format 'yyyyMMddHHmmss').gz"
            # Compression via .NET (PowerShell n'a pas de gzip natif simple)
            $in  = [System.IO.File]::OpenRead($_.FullName)
            $out = [System.IO.File]::Create($rotated)
            $gz  = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
            $in.CopyTo($gz)
            $gz.Close(); $out.Close(); $in.Close()
            Remove-Item $_.FullName -Force
        }
    # Cleanup old
    Get-ChildItem $LogDir -Filter "*.gz" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepFiles |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Write-EncoderLog, Initialize-LogRotation
