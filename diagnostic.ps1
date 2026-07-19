# diagnostic.ps1 - Windows system health check (RAM / processes / services).
# PowerShell 7+ compatible. Read-only: observes state, changes nothing.
# Emits a color-coded verdict + HTML report via HealthReport.ps1.
#
#   -Json        Emit machine-readable JSON to stdout (implies -Quiet).
#   -Quiet       Do not auto-open the HTML report in a browser.
#   -ConfigPath  Service-check config (default: config.local.json beside this script).
# Exit code: 0 = GREEN, 1 = YELLOW, 2 = RED (for scheduled tasks / monitoring).

param(
    [switch]$Json,
    [switch]$Quiet,
    [string]$ConfigPath
)

. "$PSScriptRoot\HealthReport.ps1"
Reset-Findings

$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
$txtPath  = "$env:TEMP\system_diagnostic_$ts.txt"
$htmlPath = "$env:TEMP\health_report_$ts.html"

# --- optional service-check config (personal config.local.json is gitignored) ---
$services = @()
$cfgCandidates = @()
if ($ConfigPath) { $cfgCandidates += $ConfigPath }
$cfgCandidates += "$PSScriptRoot\config.local.json"
foreach ($p in $cfgCandidates) {
    if ($p -and (Test-Path $p)) {
        try { $cfg = Get-Content $p -Raw | ConvertFrom-Json; if ($cfg.services) { $services = $cfg.services } } catch { }
        break
    }
}

# --- collect top processes first (used by the memory verdict) ---
$topProcesses = Get-Process | Sort-Object -Property WorkingSet -Descending | Select-Object -First 10
$procDetail = ($topProcesses | ForEach-Object {
    "{0,-22} PID {1,-8} {2,10} MB" -f $_.ProcessName, $_.Id, [math]::Round($_.WorkingSet / 1MB, 1)
}) -join "`n"

# 1. System Information
try {
    $osInfo  = Get-CimInstance Win32_OperatingSystem
    $sysInfo = Get-CimInstance Win32_ComputerSystem
    Add-Finding -Section "System Info" -Severity OK -Value "$($sysInfo.Name) - $($osInfo.Caption)" -Detail @"
Architecture: $($osInfo.OSArchitecture)
Installed RAM: $([math]::Round($sysInfo.TotalPhysicalMemory / 1GB, 2)) GB
Last Boot: $($osInfo.LastBootUpTime)
"@
} catch {
    Add-Finding -Section "System Info" -Severity WARN -Value "Query failed" -Detail "$_"
}

# 2. Memory State  (the headline check)
try {
    $mem = Get-CimInstance Win32_OperatingSystem
    $totalMem = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 2)
    $freeMem  = [math]::Round($mem.FreePhysicalMemory / 1MB, 2)
    $usedMem  = $totalMem - $freeMem
    $usedPct  = [math]::Round(($usedMem / $totalMem) * 100, 1)

    $topName = $topProcesses[0].ProcessName
    $topGB   = [math]::Round($topProcesses[0].WorkingSet / 1GB, 1)

    if ($usedPct -gt 90) {
        $sev = 'CRIT'; $act = "RAM exhaustion - close top offenders (e.g. $topName ~${topGB}GB)"
    } elseif ($usedPct -gt 75) {
        $sev = 'WARN'; $act = "Getting tight - watch $topName (~${topGB}GB)"
    } else {
        $sev = 'OK';   $act = ''
    }
    Add-Finding -Section "Memory" -Severity $sev -Value "${usedPct}% used (${usedMem}GB of ${totalMem}GB, ${freeMem}GB free)" -Action $act
} catch {
    Add-Finding -Section "Memory" -Severity WARN -Value "Query failed" -Detail "$_"
}

# 3. Top 10 Processes by Memory (pre-sorted table)
$biggestGB = [math]::Round($topProcesses[0].WorkingSet / 1GB, 2)
if ($biggestGB -ge 2) {
    Add-Finding -Section "Top Processes" -Severity WARN -Value "$($topProcesses[0].ProcessName) alone is using ${biggestGB}GB" -Action "Consider closing/restarting it" -Detail $procDetail
} else {
    Add-Finding -Section "Top Processes" -Severity OK -Value "Largest: $($topProcesses[0].ProcessName) (${biggestGB}GB)" -Detail $procDetail
}

# 4. Service checks (config-driven; each: name + optional process/url/port)
if (@($services).Count -eq 0) {
    Add-Finding -Section "Service Checks" -Severity OK -Value "None configured" -Action "Add a config.local.json (see config.example.json) to watch processes/URLs/ports"
} else {
    foreach ($svc in $services) {
        $name = if ($svc.name) { $svc.name } else { "service" }
        $problems = @(); $details = @()
        if ($svc.process) {
            $p = Get-Process -Name $svc.process -ErrorAction SilentlyContinue
            if ($p) { $details += "process '$($svc.process)' running (PID $((@($p).Id) -join ','))" }
            else    { $problems += "process '$($svc.process)' not running" }
        }
        if ($svc.url) {
            try {
                $r = Invoke-WebRequest -Uri $svc.url -UseBasicParsing -TimeoutSec 5
                $details += "url $($svc.url) -> HTTP $($r.StatusCode)"
            } catch { $problems += "url $($svc.url) unreachable" }
        }
        if ($svc.port) {
            $c = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $svc.port -or $_.RemotePort -eq $svc.port }
            $details += "port $($svc.port): $(@($c).Count) connection(s)"
        }
        if ($problems.Count) {
            Add-Finding -Section "Service: $name" -Severity WARN -Value ($problems -join '; ') -Action "Check $name" -Detail ($details -join "`n")
        } else {
            Add-Finding -Section "Service: $name" -Severity OK -Value "healthy" -Detail ($details -join "`n")
        }
    }
}

# 5. Running PowerShell Scripts
try {
    $psScripts = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '\.ps1' }
    if ($psScripts) {
        $detail = ($psScripts | ForEach-Object { "$($_.Name) - $($_.CommandLine)" }) -join "`n"
        Add-Finding -Section "Running PS Scripts" -Severity OK -Value "$(@($psScripts).Count) detected" -Detail $detail
    } else {
        Add-Finding -Section "Running PS Scripts" -Severity OK -Value "None detected"
    }
} catch {
    Add-Finding -Section "Running PS Scripts" -Severity OK -Value "Query failed" -Detail "$_"
}

# 6. Running Scheduled Tasks
try {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }
    if ($tasks) {
        $detail = ($tasks | ForEach-Object { $_.TaskName }) -join "`n"
        Add-Finding -Section "Running Scheduled Tasks" -Severity OK -Value "$(@($tasks).Count) running" -Detail $detail
    } else {
        Add-Finding -Section "Running Scheduled Tasks" -Severity OK -Value "None"
    }
} catch {
    Add-Finding -Section "Running Scheduled Tasks" -Severity OK -Value "Query failed" -Detail "$_"
}

# 7. Startup Items
try {
    $startupPaths = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    )
    $startupItems = @()
    foreach ($path in $startupPaths) {
        if (Test-Path $path) {
            $startupItems += Get-ChildItem $path -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
        }
    }
    if ($startupItems) {
        Add-Finding -Section "Startup Items" -Severity OK -Value "$($startupItems.Count) found" -Detail ($startupItems -join "`n")
    } else {
        Add-Finding -Section "Startup Items" -Severity OK -Value "None found"
    }
} catch {
    Add-Finding -Section "Startup Items" -Severity OK -Value "Query failed" -Detail "$_"
}

# 8. Key Environment Variables
Add-Finding -Section "Key Environment Variables" -Severity OK -Value "captured" -Detail @"
PYTHONPATH: $env:PYTHONPATH
NODE_OPTIONS: $env:NODE_OPTIONS
PATH entries: $(@($env:PATH -split ';' | Where-Object { $_ }).Count)
"@

# 9. Recently Modified Files in TEMP
try {
    $recent = Get-ChildItem -Path $env:TEMP -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 10
    $detail = ($recent | ForEach-Object { "$($_.Name) - $($_.LastWriteTime)" }) -join "`n"
    Add-Finding -Section "10 Most Recent TEMP Files" -Severity OK -Value "listed" -Detail $detail
} catch {
    Add-Finding -Section "10 Most Recent TEMP Files" -Severity OK -Value "Query failed" -Detail "$_"
}

# --- Render ---
if ($Json) {
    Get-FindingsJson
} else {
    Write-TerminalVerdict
    [void](Write-TextReport -Path $txtPath)
    [void](Write-HtmlReport -Title "System Health - $env:COMPUTERNAME" -Path $htmlPath)
    Write-Host "Full report: $htmlPath" -ForegroundColor Green
    Write-Host "Text archive: $txtPath" -ForegroundColor DarkGray
    if (-not $Quiet) { Start-Process $htmlPath }
}

exit (Get-ExitCode)
