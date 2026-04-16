param(
    [string]$Root = ".",
    [string]$Entry = "logger.lua",
    [string]$Out = "dist/logger.bundle.lua",
    [int]$DebounceMs = 250,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$bundleScript = Join-Path $PSScriptRoot "bundle-lua.ps1"
if (-not (Test-Path -Path $bundleScript)) {
    throw "[watch-bundle] Missing bundler script: $bundleScript"
}

$resolvedRoot = (Resolve-Path -Path $Root).Path
$modulesDir = Join-Path $resolvedRoot "modules"

if (-not (Test-Path -Path (Join-Path $resolvedRoot $Entry))) {
    throw "[watch-bundle] Entry file not found: $(Join-Path $resolvedRoot $Entry)"
}

if (-not (Test-Path -Path $modulesDir)) {
    throw "[watch-bundle] Modules directory not found: $modulesDir"
}

function Invoke-BundleBuild {
    & $bundleScript -Root $resolvedRoot -Entry $Entry -Out $Out
}

Invoke-BundleBuild
if ($Once) {
    exit 0
}

$watchers = New-Object System.Collections.Generic.List[System.IO.FileSystemWatcher]
$sourceIds = New-Object System.Collections.Generic.List[string]

# Watch entry file in root
$rootWatcher = New-Object System.IO.FileSystemWatcher($resolvedRoot, (Split-Path -Leaf $Entry))
$rootWatcher.IncludeSubdirectories = $false
$rootWatcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'
$rootWatcher.EnableRaisingEvents = $true
$watchers.Add($rootWatcher)

# Watch all Lua modules
$moduleWatcher = New-Object System.IO.FileSystemWatcher($modulesDir, "*.lua")
$moduleWatcher.IncludeSubdirectories = $true
$moduleWatcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime, DirectoryName'
$moduleWatcher.EnableRaisingEvents = $true
$watchers.Add($moduleWatcher)

$counter = 0
foreach ($watcher in $watchers) {
    foreach ($evtName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
        $counter += 1
        $id = "bundle-watch-$counter"
        Register-ObjectEvent -InputObject $watcher -EventName $evtName -SourceIdentifier $id | Out-Null
        $sourceIds.Add($id)
    }
}

Write-Host "[watch-bundle] Watching logger/modules for changes..."
Write-Host "[watch-bundle] Press Ctrl+C to stop."

$lastRun = Get-Date
try {
    while ($true) {
        $evt = Wait-Event -Timeout 2
        if (-not $evt) {
            continue
        }

        Remove-Event -EventIdentifier $evt.EventIdentifier | Out-Null

        $now = Get-Date
        $elapsedMs = ($now - $lastRun).TotalMilliseconds
        if ($elapsedMs -lt $DebounceMs) {
            continue
        }

        $lastRun = $now
        Write-Host "[watch-bundle] Change detected. Rebuilding..."
        try {
            Invoke-BundleBuild
            Write-Host "[watch-bundle] Rebuild complete."
        }
        catch {
            Write-Host "[watch-bundle] Rebuild failed: $($_.Exception.Message)"
        }
    }
}
finally {
    foreach ($id in $sourceIds) {
        Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
        Remove-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
    }

    foreach ($watcher in $watchers) {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
    }
}
