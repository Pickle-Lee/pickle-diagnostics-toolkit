#!/usr/bin/env bash
# Reproduces the real diagnostic.ps1 terminal verdict (genuine output + colors)
sleep 0.5
printf '\n'
printf '\033[91m===== HEALTH VERDICT: RED =====\033[0m\n'
printf '\033[91m[CRIT] Memory: 95.3%% used (14.52GB of 15.23GB, 0.71GB free)  ->  RAM exhaustion - close top offenders (e.g. vmmemWSL ~1.5GB)\033[0m\n'
printf '\033[93m[WARN] Service: Local web: url http://localhost:8080/health unreachable  ->  Check Local web\033[0m\n'
printf '\033[90m9 other checks OK\033[0m\n'
printf '\033[92mFull report: C:\\Users\\you\\AppData\\Local\\Temp\\health_report_20260719.html\033[0m\n'
sleep 0.2
