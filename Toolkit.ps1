# Pickle Diagnostics Toolkit — menu launcher
# Run:  powershell -File "$HOME\Documents\pickleproject\scripts\Toolkit.ps1"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "==== Pickle Diagnostics Toolkit ====" -ForegroundColor Cyan
Write-Host "1) System / RAM / service health check  (diagnostic.ps1, read-only)"
Write-Host "2) Network diagnostics - SAFE            (read-only sweep + ping/tracert)"
Write-Host "3) Network diagnostics - DANGER MODE     (auto-fix + 10min monitor + report)"
Write-Host "4) Open last report                      (newest HTML report)"
Write-Host "Q) Quit"
Write-Host ""
$choice = Read-Host "Select"

switch ($choice.ToUpper()) {
    '1' { & "$here\diagnostic.ps1" }
    '2' { & "$here\Network_Cockpit_Danger.ps1" }
    '3' { & "$here\Network_Cockpit_Danger.ps1" -DangerMode }
    '4' {
        $candidates = @()
        $candidates += Get-ChildItem "$env:TEMP\health_report_*.html" -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem "$env:USERPROFILE\Desktop\Network_Cockpit_Logs\Run_*\NetworkReport.html" -Recurse -ErrorAction SilentlyContinue
        $latest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { Write-Host "Opening $($latest.FullName)" -ForegroundColor Green; Start-Process $latest.FullName }
        else { Write-Host "No reports found yet - run 1, 2, or 3 first." -ForegroundColor Yellow }
    }
    'Q' { Write-Host "Bye." -ForegroundColor DarkGray }
    default { Write-Host "No valid choice - nothing run." -ForegroundColor Yellow }
}
