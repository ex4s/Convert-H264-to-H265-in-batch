<#
.SYNOPSIS
    Gestion d'état persistant : queue, processed, failed, skipped.

.DESCRIPTION
    Stockage JSON avec mutex global pour la concurrence.
    Pour 31k fichiers, JSON est viable. Au-delà de 100k, envisager SQLite.

    Chaque fichier traité est identifié par un hash SHA256 court (16 chars)
    de son chemin lowercase. Ça évite les problèmes de chemins longs / caractères
    spéciaux dans les clés JSON.
#>

function Initialize-StateStore {
    <#
    .SYNOPSIS
        Crée les fichiers JSON s'ils n'existent pas, retourne leur table de chemins.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    if (-not (Test-Path $StateRoot)) {
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    }

    $files = @{
        Queue     = Join-Path $StateRoot "queue.json"
        Processed = Join-Path $StateRoot "processed.json"
        Failed    = Join-Path $StateRoot "failed.json"
        Skipped   = Join-Path $StateRoot "skipped.json"
    }
    foreach ($f in $files.Values) {
        if (-not (Test-Path $f)) {
            '{}' | Set-Content -Path $f -Encoding UTF8
        }
    }
    return $files
}

function Get-PathHash {
    <#
    .SYNOPSIS
        Hash SHA256 court d'un chemin (clé d'index dans les stores).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $hash  = $sha.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-','').Substring(0,16).ToLower()
    } finally {
        $sha.Dispose()
    }
}

function Read-StateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return @{} }
    try {
        $content = Get-Content $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) { return @{} }
        $obj = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($null -eq $obj) { return @{} }
        return $obj
    } catch {
        # Fichier corrompu : backup et repartir vide
        $backup = "$Path.corrupt.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item $Path $backup -Force -ErrorAction SilentlyContinue
        return @{}
    }
}

function Test-AlreadyProcessed {
    <#
    .SYNOPSIS
        Vérifie si un chemin est déjà connu (processed, skipped ou failed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][hashtable]$StateFiles
    )

    $key = Get-PathHash $FilePath
    foreach ($store in @('Processed','Skipped','Failed')) {
        $data = Read-StateFile -Path $StateFiles[$store]
        if ($data.ContainsKey($key)) {
            return $true
        }
    }
    return $false
}

function Add-StateEntry {
    <#
    .SYNOPSIS
        Ajoute une entrée dans un store JSON. Thread-safe via mutex.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Processed','Failed','Skipped','Queue')][string]$Store,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][hashtable]$StateFiles,
        [hashtable]$Data
    )

    $key  = Get-PathHash $FilePath
    $file = $StateFiles[$Store]
    $mutex = [System.Threading.Mutex]::new($false, "Global\WindowsVideoEncoder_State_$Store")
    $acquired = $false

    try {
        $acquired = $mutex.WaitOne(15000)
        if (-not $acquired) {
            throw "Timeout d'acquisition du mutex pour le store '$Store'"
        }

        $current = Read-StateFile -Path $file
        $entry = @{
            path      = $FilePath
            timestamp = [DateTime]::UtcNow.ToString("o")
        }
        if ($Data) {
            foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
        }
        $current[$key] = $entry

        # Écriture atomique : tmp + rename
        $tmp = "$file.tmp"
        $current | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $file -Force
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-StateStats {
    <#
    .SYNOPSIS
        Statistiques agrégées sur tous les stores.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$StateFiles)

    $stats = [ordered]@{
        Processed     = 0
        Failed        = 0
        Skipped       = 0
        TotalSavedGB  = 0.0
        TotalOriginalGB = 0.0
        TotalNewGB    = 0.0
    }

    $processed = Read-StateFile -Path $StateFiles.Processed
    $stats.Processed = $processed.Count
    foreach ($entry in $processed.Values) {
        if ($entry.saved_bytes)    { $stats.TotalSavedGB    += [double]$entry.saved_bytes    / 1GB }
        if ($entry.original_size)  { $stats.TotalOriginalGB += [double]$entry.original_size  / 1GB }
        if ($entry.new_size)       { $stats.TotalNewGB      += [double]$entry.new_size       / 1GB }
    }
    $stats.TotalSavedGB    = [math]::Round($stats.TotalSavedGB, 2)
    $stats.TotalOriginalGB = [math]::Round($stats.TotalOriginalGB, 2)
    $stats.TotalNewGB      = [math]::Round($stats.TotalNewGB, 2)

    $failed  = Read-StateFile -Path $StateFiles.Failed
    $stats.Failed  = $failed.Count

    $skipped = Read-StateFile -Path $StateFiles.Skipped
    $stats.Skipped = $skipped.Count

    return [PSCustomObject]$stats
}

function Test-ProcessLock {
    <#
    .SYNOPSIS
        Pose un verrou anti double-exécution.

    .OUTPUTS
        $true si le verrou est obtenu, $false si une autre instance tourne déjà.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    $lockFile = Join-Path $StateRoot "lock.pid"

    if (Test-Path $lockFile) {
        $oldPidContent = Get-Content $lockFile -ErrorAction SilentlyContinue
        $oldPid = $null
        if ($oldPidContent -and [int]::TryParse($oldPidContent.Trim(), [ref]$oldPid)) {
            $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match 'powershell|pwsh') {
                return $false
            }
        }
        # Verrou stale : on le supprime
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    }

    $PID | Set-Content -Path $lockFile -Encoding UTF8
    return $true
}

function Remove-ProcessLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    $lockFile = Join-Path $StateRoot "lock.pid"
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Initialize-StateStore, Test-AlreadyProcessed, Add-StateEntry, Get-PathHash, Test-ProcessLock, Remove-ProcessLock, Get-StateStats, Read-StateFile
