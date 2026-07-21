# HealthReport.ps1 — shared verdict + report layer for the diagnostics toolkit.
# Dot-source this, call Add-Finding as you collect data, then render:
#   Write-TerminalVerdict            -> color-coded summary of problems
#   Write-TextReport  -Path <file>   -> raw text archive
#   Write-HtmlReport  -Title -Path   -> self-contained HTML (returns path to open)
#
# A "finding" = one check with a Severity (OK/WARN/CRIT), a Value, an optional
# recommended Action, and optional raw Detail text. All judgment/presentation
# lives here so both scripts get an identical look from one place.

$script:Findings = [System.Collections.Generic.List[object]]::new()
$script:Explanation = $null

function Reset-Findings {
    $script:Findings = [System.Collections.Generic.List[object]]::new()
    $script:Explanation = $null
}

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Section,
        [ValidateSet('OK','WARN','CRIT')][string]$Severity = 'OK',
        [string]$Value  = '',
        [string]$Action = '',
        [string]$Detail = ''
    )
    $script:Findings.Add([pscustomobject]@{
        Section  = $Section
        Severity = $Severity
        Value    = $Value
        Action   = $Action
        Detail   = $Detail
    })
}

function Get-OverallStatus {
    $sevs = @($script:Findings | ForEach-Object { $_.Severity })
    if ($sevs -contains 'CRIT') { return 'RED' }
    if ($sevs -contains 'WARN') { return 'YELLOW' }
    return 'GREEN'
}

# Exit code for automation/monitoring: 0 = GREEN, 1 = YELLOW, 2 = RED.
function Get-ExitCode {
    switch (Get-OverallStatus) { 'RED' { 2 } 'YELLOW' { 1 } default { 0 } }
}

# Machine-readable output for piping into SIEM/monitoring/dashboards.
function Get-FindingsJson {
    ([pscustomobject]@{
        overall     = Get-OverallStatus
        generated   = (Get-Date).ToString('s')
        host        = $env:COMPUTERNAME
        findings    = @($script:Findings)
        explanation = $script:Explanation
    }) | ConvertTo-Json -Depth 6
}

# Model-agnostic AI explanation via ANY OpenAI-compatible chat endpoint
# (Ollama, OpenAI, Gemini's openai endpoint, OpenRouter, LM Studio, vLLM, ...).
# $Config: { baseUrl, model, apiKeyEnv } - apiKeyEnv is the NAME of an env var
# holding the key (omit/empty for keyless local). Returns the text, or $null
# if not configured. Never hardcodes an endpoint, model, or secret.
function Invoke-Explain {
    param([object]$Config)
    if (-not $Config -or -not $Config.baseUrl -or -not $Config.model) { return $null }

    # Only send real problems (WARN/CRIT) so the model can't invent issues from
    # healthy checks. A clean run short-circuits without an LLM call.
    $problems = @($script:Findings | Where-Object { $_.Severity -ne 'OK' })
    if ($problems.Count -eq 0) {
        $script:Explanation = 'All checks passed - no problems to explain.'
        return $script:Explanation
    }
    $digest = ($problems | ForEach-Object {
        $line = "[$($_.Severity)] $($_.Section): $($_.Value)"
        if ($_.Action) { $line += " (suggested: $($_.Action))" }
        $line
    }) -join "`n"

    $key = if ($Config.apiKeyEnv) { [Environment]::GetEnvironmentVariable($Config.apiKeyEnv) } else { $null }

    $sys = 'You are a Windows systems-diagnostics assistant. You are given ONLY the problem findings (WARN/CRIT) from a health check. For each finding write one short bullet: a brief plain-English cause, then tell the user exactly WHAT TO DO to fix it - a clear imperative action or command (e.g. "Close X", "Run Y", "Change Z to..."). Rank CRIT first, lead with the action. Strict rules: address ONLY the findings in the list; never invent, infer, or mention any problem not explicitly listed.'
    $body = @{
        model       = $Config.model
        temperature = 0.1
        messages    = @(
            @{ role = 'system'; content = $sys },
            @{ role = 'user';   content = "Problem findings:`n$digest" }
        )
    }
    if ($Config.max_tokens) { $body.max_tokens = [int]$Config.max_tokens }

    $headers = @{ 'Content-Type' = 'application/json' }
    if ($key) { $headers['Authorization'] = "Bearer $key" }
    $url = $Config.baseUrl.TrimEnd('/') + '/chat/completions'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 6) -TimeoutSec 120
        $text = $resp.choices[0].message.content
        if ($text) { $script:Explanation = ([string]$text).Trim() }
    } catch {
        $script:Explanation = "AI explanation unavailable: $($_.Exception.Message)"
    }
    return $script:Explanation
}

function ConvertTo-HtmlSafe {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $s = $s -replace '&','&amp;'
    $s = $s -replace '<','&lt;'
    $s = $s -replace '>','&gt;'
    return $s
}

function Write-TerminalVerdict {
    $status = Get-OverallStatus
    $color  = switch ($status) { 'RED' {'Red'} 'YELLOW' {'Yellow'} default {'Green'} }
    Write-Host ""
    Write-Host "===== HEALTH VERDICT: $status =====" -ForegroundColor $color

    $problems = @($script:Findings | Where-Object { $_.Severity -ne 'OK' } |
                  Sort-Object @{ Expression = { if ($_.Severity -eq 'CRIT') { 0 } else { 1 } } })
    foreach ($p in $problems) {
        $c   = if ($p.Severity -eq 'CRIT') { 'Red' } else { 'Yellow' }
        $line = "[{0}] {1}: {2}" -f $p.Severity, $p.Section, $p.Value
        if ($p.Action) { $line += "  ->  $($p.Action)" }
        Write-Host $line -ForegroundColor $c
    }
    if ($problems.Count -eq 0) { Write-Host "No problems detected." -ForegroundColor Green }

    $okCount = @($script:Findings | Where-Object { $_.Severity -eq 'OK' }).Count
    Write-Host "$okCount other checks OK" -ForegroundColor DarkGray
    Write-Host ""
}

function Write-TextReport {
    param([Parameter(Mandatory)][string]$Path)
    $lines = foreach ($f in $script:Findings) {
        "=== $($f.Section) [$($f.Severity)] ==="
        if ($f.Value)  { $f.Value }
        if ($f.Action) { "ACTION: $($f.Action)" }
        if ($f.Detail) { $f.Detail }
        ""
    }
    ($lines -join "`n") | Out-File -FilePath $Path -Encoding UTF8
    return $Path
}

function Write-HtmlReport {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Path
    )
    $status      = Get-OverallStatus
    $statusColor = @{ 'RED'='#e5484d'; 'YELLOW'='#f5a623'; 'GREEN'='#30a46c' }[$status]
    $sev2color   = @{ 'CRIT'='#e5484d'; 'WARN'='#f5a623'; 'OK'='#30a46c' }
    $generated   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $cardsHtml = ""
    foreach ($f in $script:Findings) {
        $c   = $sev2color[$f.Severity]
        $sec = ConvertTo-HtmlSafe $f.Section
        $val = ConvertTo-HtmlSafe $f.Value
        $actHtml = ''
        if ($f.Action) { $actHtml = "<div class='action'>&rarr; " + (ConvertTo-HtmlSafe $f.Action) + "</div>" }
        $detHtml = ''
        if ($f.Detail) { $detHtml = "<details><summary>raw detail</summary><pre>" + (ConvertTo-HtmlSafe $f.Detail) + "</pre></details>" }
        $cardsHtml += "<div class='card' style='border-left-color:$c'>"
        $cardsHtml += "<div class='cardhead'><span class='sev' style='background:$c'>$($f.Severity)</span><span class='sec'>$sec</span></div>"
        $cardsHtml += "<div class='val'>$val</div>$actHtml$detHtml</div>`n"
    }

    $explHtml = ''
    if ($script:Explanation) {
        $explHtml = "<div class='card' style='border-left-color:#6e56cf'><div class='cardhead'><span class='sev' style='background:#6e56cf'>AI</span><span class='sec'>Explanation</span></div><div class='val' style='white-space:pre-wrap'>" + (ConvertTo-HtmlSafe $script:Explanation) + "</div></div>"
    }

    $html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>$Title</title>
<style>
 body{font-family:'Segoe UI',system-ui,sans-serif;background:#16181d;color:#e6e6e6;margin:0;padding:24px;}
 .wrap{max-width:900px;margin:0 auto;}
 h1{font-size:20px;margin:0 0 4px;}
 .meta{color:#8a8f98;font-size:13px;margin-bottom:20px;}
 .banner{padding:14px 18px;border-radius:8px;font-weight:700;font-size:18px;color:#fff;margin-bottom:20px;background:$statusColor;}
 .card{background:#1e2128;border:1px solid #2a2e37;border-left:5px solid #30a46c;border-radius:8px;padding:12px 14px;margin-bottom:12px;}
 .cardhead{display:flex;align-items:center;gap:10px;margin-bottom:6px;}
 .sev{font-size:11px;font-weight:700;color:#fff;padding:2px 8px;border-radius:10px;letter-spacing:.5px;}
 .sec{font-weight:600;}
 .val{color:#c7ccd4;font-size:14px;white-space:pre-wrap;}
 .action{color:#f5a623;font-size:13px;margin-top:4px;}
 details{margin-top:8px;} summary{cursor:pointer;color:#8a8f98;font-size:12px;}
 pre{background:#0f1115;padding:10px;border-radius:6px;overflow-x:auto;font-size:12px;color:#b7bdc7;line-height:1.4;}
</style></head>
<body><div class="wrap">
 <h1>$Title</h1>
 <div class="meta">Generated $generated</div>
 <div class="banner">HEALTH VERDICT: $status</div>
 $explHtml
 $cardsHtml
</div></body></html>
"@
    $html | Out-File -FilePath $Path -Encoding UTF8
    return $Path
}
