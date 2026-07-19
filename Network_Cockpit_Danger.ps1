<#
Network_Cockpit_Danger.ps1
Unified Danger Mode with section-scoped progress bars
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$LogRoot = "$env:USERPROFILE\Desktop\Network_Cockpit_Logs",
  [switch]$DangerMode,
  [switch]$AutoFix,
  [switch]$WifiAnalyze,
  [int]$MonitorMinutes = 0,
  [int]$RssiSampleSeconds = 60,
  [string]$Iperf3Path = "",
  [switch]$Report,
  [switch]$Json,
  [switch]$Quiet
)

function Banner {
    param([string]$Title,[string]$Desc)
    $line = "==============================================="
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("=== {0} ===" -f $Title) -ForegroundColor Cyan
    Write-Host $Desc -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor Cyan
    Write-Log "=== $Title === | $Desc"
}

function Show-SectionProgress {
    param([string]$Section,[int]$Step,[int]$Total)
    $percent = [math]::Round(($Step / $Total) * 100, 0)
    Write-Progress -Activity $Section -Status "$percent% complete" -PercentComplete $percent
}

function Ensure-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
  if (-not $isAdmin) { Write-Host "Note: Admin rights unlock full repairs." -ForegroundColor Yellow }
}

function New-LogScope {
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $global:SessionDir = Join-Path $LogRoot "Run_$ts"
  New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null
  $global:Log = Join-Path $SessionDir "Cockpit-$ts.txt"
  $global:Csv = Join-Path $SessionDir "Monitoring-$ts.csv"
  $global:ReportMd = Join-Path $SessionDir "Report-$ts.md"
  "Log start $(Get-Date)" | Out-File -FilePath $Log -Encoding UTF8
}

function Write-Log {
  param([string]$Text)
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text
  $line | Tee-Object -FilePath $Log -Append | Out-String | Out-Null
}

function Run-Cmd {
  param([string]$Cmd,[string]$OutName)
  $outFile = Join-Path $SessionDir ("{0}.txt" -f $OutName)
  cmd.exe /c "$Cmd" | Out-File -FilePath $outFile -Encoding UTF8
}

function Run-PS {
  param([scriptblock]$Script,[string]$OutName)
  $outFile = Join-Path $SessionDir ("{0}.txt" -f $OutName)
  & $Script | Out-File -FilePath $outFile -Encoding UTF8
}

. "$PSScriptRoot\HealthReport.ps1"
Reset-Findings

Ensure-Admin
New-LogScope
if ($DangerMode) {
  $WifiAnalyze = $true
  $MonitorMinutes = [Math]::Max($MonitorMinutes, 10)
  $AutoFix = $true
  $Report = $true
}

# === Baseline Sweep ===
Banner "Baseline Sweep" "Captures system and adapter config, IPs, DNS, routes, ARP, and active connections."
$baselineCmds = @(
    @{Cmd="ipconfig /all"; Name="ipconfig_all"},
    @{Cmd="route print"; Name="route_print"},
    @{Cmd="arp -a"; Name="arp"},
    @{Cmd="netstat -ano"; Name="netstat_ano"},
    @{Cmd="nbtstat -n"; Name="nbtstat_n"},
    @{Cmd="nbtstat -r"; Name="nbtstat_r"}
)
for ($i=0; $i -lt $baselineCmds.Count; $i++) {
    Run-Cmd $baselineCmds[$i].Cmd $baselineCmds[$i].Name
    Show-SectionProgress -Section "Baseline Sweep" -Step ($i+1) -Total $baselineCmds.Count
}

# === Connectivity Tests ===
Banner "Connectivity Tests" "Ping/traceroute to gateway and public endpoints to separate local vs upstream instability."
$gwRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
$gw = $gwRoute.NextHop
$targets = @($gw,"8.8.8.8","1.1.1.1")
for ($i=0; $i -lt $targets.Count; $i++) {
    Run-Cmd "ping -n 10 $($targets[$i])" "ping_$($targets[$i])"
    Run-Cmd "tracert -d $($targets[$i])" "tracert_$($targets[$i])"
    Show-SectionProgress -Section "Connectivity Tests" -Step ($i+1) -Total $targets.Count
}

# --- findings: read back each ping log and judge packet loss ---
for ($i=0; $i -lt $targets.Count; $i++) {
    $t  = $targets[$i]
    $pf = Join-Path $SessionDir ("ping_{0}.txt" -f $t)
    if (-not (Test-Path $pf)) { continue }
    $txt = Get-Content $pf -Raw
    $label = if ($t -eq $gw) { "Gateway $t" } else { "$t" }
    if ($txt -match '\((\d+)% loss\)') {
        $loss = [int]$Matches[1]
        if ($loss -eq 100) {
            $act = if ($t -eq $gw) { "Local link/router down" } else { "Upstream/ISP unreachable" }
            Add-Finding -Section "Ping $label" -Severity CRIT -Value "100% packet loss" -Action $act -Detail $txt
        } elseif ($loss -gt 0) {
            Add-Finding -Section "Ping $label" -Severity WARN -Value "$loss% packet loss" -Action "Intermittent connectivity" -Detail $txt
        } else {
            Add-Finding -Section "Ping $label" -Severity OK -Value "0% loss" -Detail $txt
        }
    } else {
        Add-Finding -Section "Ping $label" -Severity WARN -Value "No reply parsed" -Detail $txt
    }
}

# === Repairs ===
Banner "Repairs" "Flush DNS, reset Winsock/TCP/IP, renew DHCP to clear stale state."
if ($AutoFix) {
    $repairCmds = @(
        @{Cmd="ipconfig /flushdns"; Name="flushdns"},
        @{Cmd="netsh winsock reset"; Name="winsock_reset"},
        @{Cmd="netsh int ip reset"; Name="tcpip_reset"}
    )
    for ($i=0; $i -lt $repairCmds.Count; $i++) {
        if ($PSCmdlet.ShouldProcess($repairCmds[$i].Cmd, "run network repair (may briefly drop the connection)")) {
            Run-Cmd $repairCmds[$i].Cmd $repairCmds[$i].Name
        }
        Show-SectionProgress -Section "Repairs" -Step ($i+1) -Total $repairCmds.Count
    }
}

# === Power Stabilization ===
Banner "Power Stabilization" "Disable USB suspend, set Wi-Fi to max performance to prevent radio resets."
if ($AutoFix) {
    # Get active power scheme GUID
    $activeScheme = (powercfg -GETACTIVESCHEME | Select-String -Pattern '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b').Matches[0].Value
    Write-Log "Active power scheme: $activeScheme"

    if ($PSCmdlet.ShouldProcess("active power scheme $activeScheme", "apply power stabilization (disable USB suspend, Wi-Fi max performance)")) {
        # Disable USB selective suspend
        $outFile = Join-Path $SessionDir "usb_suspend_off.txt"
        & powercfg -SETACVALUEINDEX $activeScheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 *>&1 | Out-File -FilePath $outFile -Encoding UTF8
        Show-SectionProgress -Section "Power Stabilization" -Step 1 -Total 3

        # Force Wi-Fi adapter to maximum performance
        $outFile = Join-Path $SessionDir "wifi_maxperf.txt"
        & powercfg -SETACVALUEINDEX $activeScheme 4f971e89-eebd-4455-a8de-9e59040e7347 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 *>&1 | Out-File -FilePath $outFile -Encoding UTF8
        Show-SectionProgress -Section "Power Stabilization" -Step 2 -Total 3

        # Apply scheme
        $outFile = Join-Path $SessionDir "power_apply.txt"
        & powercfg -SETACTIVE $activeScheme *>&1 | Out-File -FilePath $outFile -Encoding UTF8
        Show-SectionProgress -Section "Power Stabilization" -Step 3 -Total 3
    }
}

# === Event Correlation ===
Banner "Event Correlation" "Collect System + WLAN AutoConfig logs to detect resets, driver instability, roaming events."
Run-PS {
  Get-WinEvent -LogName System -MaxEvents 200 | Where-Object { $_.ProviderName -match 'Tcpip|WLAN|NDIS|Kernel-PnP' }
} "system_events"
Show-SectionProgress -Section "Event Correlation" -Step 1 -Total 1

# === Wi-Fi Holistic Analysis ===
Banner "Wi-Fi Holistic Analysis" "Parse SSID, PHY, band, signal, congestion, roaming, stability dips."
if ($WifiAnalyze) {
    $wifiCmds = @(
        @{Cmd="netsh wlan show interfaces"; Name="wlan_interfaces"},
        @{Cmd="netsh wlan show networks mode=bssid"; Name="wlan_scan"}
    )
    for ($i=0; $i -lt $wifiCmds.Count; $i++) {
        Run-Cmd $wifiCmds[$i].Cmd $wifiCmds[$i].Name
        Show-SectionProgress -Section "Wi-Fi Holistic Analysis" -Step ($i+1) -Total $wifiCmds.Count
    }
    Run-PS { Get-WinEvent -LogName Microsoft-Windows-WLAN-AutoConfig/Operational -MaxEvents 200 } "wlan_autoconfig"
    Show-SectionProgress -Section "Wi-Fi Holistic Analysis" -Step ($wifiCmds.Count+1) -Total ($wifiCmds.Count+1)

    # --- finding: Wi-Fi signal strength from the interface dump ---
    $iface = Get-Content (Join-Path $SessionDir "wlan_interfaces.txt") -Raw
    if ($iface -match 'Signal\s*:\s*(\d+)%') {
        $sig = [int]$Matches[1]
        if ($sig -lt 50) {
            Add-Finding -Section "Wi-Fi Signal" -Severity WARN -Value "$sig% (weak)" -Action "Move closer to the AP or check for interference" -Detail $iface
        } else {
            Add-Finding -Section "Wi-Fi Signal" -Severity OK -Value "$sig%" -Detail $iface
        }
    } elseif ($iface -match 'location permission|Location services') {
        Add-Finding -Section "Wi-Fi Signal" -Severity OK -Value "Signal not measured (Location services off - by design)" -Action "Only if you want Wi-Fi signal/SSID: temporarily enable Location (Privacy & security > Location)" -Detail $iface
    } elseif ($iface -match 'no wireless interface|There is 0 interface') {
        Add-Finding -Section "Wi-Fi Signal" -Severity OK -Value "No wireless interface (wired connection)" -Detail $iface
    } else {
        Add-Finding -Section "Wi-Fi Signal" -Severity OK -Value "Signal not parsed - see raw detail" -Detail $iface
    }
}

# === Monitoring ===
Banner "Monitoring" "Continuous RTT/loss sampling with event hints to correlate dropouts with system events."
if ($MonitorMinutes -gt 0) {
    "# Monitoring CSV`n# timestamp,target,rtt_ms,loss,event_hint" | Out-File -FilePath $Csv -Encoding UTF8
    $endTime = (Get-Date).AddMinutes($MonitorMinutes)
    $totalSeconds = $MonitorMinutes * 60
    $elapsed = 0
    while ((Get-Date) -lt $endTime) {
        foreach ($t in @($gw,"8.8.8.8")) {
            $p = (ping -n 1 $t | Out-String)
            if ($p -match "time=(\d+)ms") { $rtt = [int]$Matches[1] } else { $rtt = "" }
            if ($p -match "Request timed out") { $lost = 1 } else { $lost = 0 }
            # event_hint: fill the promised 5th column instead of leaving it blank
            $hint = if ($lost) { "timeout" }
                    elseif ($rtt -ne "" -and $rtt -gt 150) { "high_latency" }
                    else { "" }
            "$((Get-Date).ToString('s')),$t,$rtt,$lost,$hint" | Add-Content -Path $Csv -Encoding UTF8
        }
        $elapsed += 2
        Show-SectionProgress -Section "Monitoring" -Step $elapsed -Total $totalSeconds
        Start-Sleep -Seconds 2
    }

    # --- finding: count dropouts recorded during monitoring ---
    $rows = Get-Content $Csv | Where-Object { $_ -notmatch '^#' }
    $drops = @($rows | Where-Object { ($_ -split ',')[3] -eq '1' }).Count
    if ($drops -gt 5) {
        Add-Finding -Section "Monitoring Dropouts" -Severity WARN -Value "$drops timeouts over $MonitorMinutes min" -Action "Unstable link - see Monitoring-*.csv for timing"
    } else {
        Add-Finding -Section "Monitoring Dropouts" -Severity OK -Value "$drops timeouts over $MonitorMinutes min"
    }
}   # <-- closes the if block

# === Report ===
if ($Report) {
    Banner "Report" "Generate Markdown summary of findings and actions."
    $reportLines = @()
    $reportLines += "# Network Cockpit Report"
    $reportLines += "Run time: $(Get-Date)"
    $reportLines += ""
    $reportLines += "## Baseline Sweep"
    $reportLines += "See ipconfig_all.txt, route_print.txt, arp.txt, netstat_ano.txt, nbtstat_n.txt, nbtstat_r.txt"
    $reportLines += ""
    $reportLines += "## Connectivity Tests"
    $reportLines += "Ping/tracert logs: ping_*.txt, tracert_*.txt"
    $reportLines += ""
    $reportLines += "## Repairs"
    $reportLines += "DNS flush, Winsock reset, TCP/IP reset applied if AutoFix enabled."
    $reportLines += ""
    $reportLines += "## Power Stabilization"
    $reportLines += "USB suspend disabled, Wi-Fi max performance enforced."
    $reportLines += ""
    $reportLines += "## Event Correlation"
    $reportLines += "System and WLAN events captured."
    $reportLines += ""
    $reportLines += "## Wi-Fi Holistic Analysis"
    $reportLines += "Interface and BSSID scan logs, AutoConfig events."
    $reportLines += ""
    $reportLines += "## Monitoring"
    $reportLines += "CSV log: Monitoring-*.csv"
    $reportLines | Out-File -FilePath $ReportMd -Encoding UTF8
}

# === Verdict + HTML report ===
if ($Json) {
    Get-FindingsJson
} else {
    Write-TerminalVerdict
    $htmlPath = Join-Path $SessionDir "NetworkReport.html"
    [void](Write-HtmlReport -Title "Network Health - $env:COMPUTERNAME" -Path $htmlPath)
    Write-Host "Full report: $htmlPath" -ForegroundColor Green
    if (-not $Quiet) { Start-Process $htmlPath }
}

exit (Get-ExitCode)
