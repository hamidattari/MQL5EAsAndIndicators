# TradeCopierServer – Windows Deployment Guide
# Run this script in an ELEVATED PowerShell on the VPS.
# It builds, installs, and starts the Windows Service.

param(
    [string]$SrcDir  = "C:\TradeCopierServer",   # where you copied the project files
    [string]$SvcDir  = "C:\TradeCopierService",   # where the compiled exe will live
    [string]$SvcName = "TradeCopierServer",
    [int]   $Port    = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 1. Build self-contained single-file exe ───────────────────────────────────
Write-Host "`n[1/5] Building TradeCopierServer..." -ForegroundColor Cyan
dotnet publish "$SrcDir\TradeCopierServer.csproj" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -o "$SvcDir"

# ── 2. Open Windows Firewall port ────────────────────────────────────────────
Write-Host "`n[2/5] Opening firewall port $Port..." -ForegroundColor Cyan
$ruleName = "TradeCopierServer_$Port"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port
    Write-Host "  Firewall rule '$ruleName' created."
} else {
    Write-Host "  Firewall rule '$ruleName' already exists."
}

# ── 3. Install as Windows Service ────────────────────────────────────────────
Write-Host "`n[3/5] Installing Windows Service '$SvcName'..." -ForegroundColor Cyan
$exePath = Join-Path $SvcDir "TradeCopierServer.exe"
if (Get-Service -Name $SvcName -ErrorAction SilentlyContinue) {
    Write-Host "  Service exists – stopping and deleting old version..."
    Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $SvcName | Out-Null
    Start-Sleep -Seconds 2
}
sc.exe create $SvcName binPath= "`"$exePath`"" start= auto | Out-Null
sc.exe description $SvcName "TradeCopier relay server" | Out-Null
Write-Host "  Service registered."

# ── 4. Start the service ──────────────────────────────────────────────────────
Write-Host "`n[4/5] Starting service..." -ForegroundColor Cyan
Start-Service -Name $SvcName
Start-Sleep -Seconds 3
$svc = Get-Service -Name $SvcName
Write-Host "  Status: $($svc.Status)"

# ── 5. Health check ───────────────────────────────────────────────────────────
Write-Host "`n[5/5] Health check on http://localhost:$Port/health ..." -ForegroundColor Cyan
try {
    $r = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 5
    Write-Host "  Server says: $($r | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    Write-Warning "  Health check failed: $_"
    Write-Warning "  Check logs with: Get-EventLog -LogName Application -Source $SvcName -Newest 10"
}

Write-Host "`nDone!  Server is running on port $Port." -ForegroundColor Green
Write-Host "Manage with:  Start-Service $SvcName  |  Stop-Service $SvcName  |  Restart-Service $SvcName"
