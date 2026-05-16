<#
.SYNOPSIS
    Gestion d'état persistant via SQLite (System.Data.SQLite optionnel) ou JSON.
    Cette implémentation utilise JSON + fichier de lock pour rester sans dépendance.
    Pour 31k fichiers, c'est viable. Au-delà de 100k, passer à SQLite.
#>

function Initialize-StateStore {
    param([Parameter(Mandatory)][string]$StateRoot)

    $files = @{
        Queue     = "$StateRoot\queue.json"
        Processed = "$StateRoot\processed.json"
        Failed    = "$StateRoot\failed.json"
        Skipped   = "$StateRoot\skipped.json"
    }
    foreach ($f in $files.Values) {
        if (-not (Test-Path $f)) { '{}' | Set-Content -Path $f -Encoding UTF8 }
    }
    return $files
}

function Test-AlreadyProcessed {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][hashtable]$StateFiles
    )
    # Hash du chemin pour clé courte
    $key = Get-PathHash $FilePath
    foreach ($f in @($StateFiles.Processed, $StateFiles.Skipped, $StateFiles.Failed)) {
        $data = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable
        if ($data.ContainsKey($key)) { return $true }
    }
    return $false
}

function Add-StateEntry {
    param(
        [Parameter(Mandatory)][ValidateSet('Processed','Failed','Skipped','Queue')][string]$Store,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][hashtable]$StateFiles,
        [hashtable]$Data
    )
    $key = Get-PathHash $FilePath
    $file = $StateFiles.$Store
    $mutex = [System.Threading.Mutex]::new($false, "Global\VideoEncoderState_$Store")
    try {
        $null = $mutex.WaitOne(10000)
        $current = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
        if (-not $current) { $current = @{} }
        $entry = @{
            path      = $FilePath
            timestamp = [DateTime]::UtcNow.ToString("o")
        }
        if ($Data) { $entry += $Data }
        $current[$key] = $entry
        $current | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
    } finally {
        $mutex.ReleaseMutex()
    }
}

function Get-PathHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,16)
}

function Test-ProcessLock {
    param([string]$StateRoot)
    $lockFile = "$StateRoot\lock.pid"
    if (Test-Path $lockFile) {
        $oldPid = Get-Content $lockFile -ErrorAction SilentlyContinue
        if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
            return $false  # Une autre instance tourne
        }
    }
    $PID | Set-Content -Path $lockFile
    return $true
}

function Remove-ProcessLock {
    param([string]$StateRoot)
    Remove-Item "$StateRoot\lock.pid" -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Initialize-StateStore, Test-AlreadyProcessed, Add-StateEntry, Get-PathHash, Test-ProcessLock, Remove-ProcessLock
