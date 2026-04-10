<#
.SYNOPSIS
    Optimizes your network connection for Combat Box (IL-2 Sturmovik).

.DESCRIPTION
    Automatically finds the optimal MTU for your path to the Combat Box server
    (srs.combatbox.net) using Path MTU Discovery, applies the setting to your
    active network adapter, and optionally sets fast DNS (Cloudflare + Google).

    Run this script as Administrator in PowerShell.

.NOTES
    Author:  Haluter
    Server:  srs.combatbox.net
    License: MIT
#>

# --- Self-elevation ----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) {
        Write-Host "Cannot determine script path. Please right-click and choose Run with PowerShell." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    try {
        Start-Process PowerShell -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath) -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to elevate: $_" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    exit
}

# --- Configuration -----------------------------------------------------------
$CombatBoxHost    = "srs.combatbox.net"
$IPHeaderOverhead = 28
$PingTimeout      = 2000
$StartSize        = 1472
$StepDown         = 10
$MinSize          = 1200

# --- Helper functions --------------------------------------------------------
function Write-Step { param($Msg) Write-Host "`n>> $Msg" -ForegroundColor Cyan }
function Write-OK   { param($Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Info { param($Msg) Write-Host "   $Msg" -ForegroundColor Gray }
function Write-Warn { param($Msg) Write-Host "   [!] $Msg" -ForegroundColor Yellow }
function Write-Fail { param($Msg) Write-Host "   [X] $Msg" -ForegroundColor Red }

# --- Banner ------------------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host "   CBNetOptimizer" -ForegroundColor White
Write-Host "   Server: $CombatBoxHost" -ForegroundColor Gray
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host ""

# --- 1. Resolve server -------------------------------------------------------
Write-Step "Resolving $CombatBoxHost..."
try {
    $dns = Resolve-DnsName -Name $CombatBoxHost -Type A -ErrorAction Stop
    $serverIP = ($dns | Where-Object { $_.QueryType -eq "A" } | Select-Object -First 1).IPAddress
    if (-not $serverIP) { throw "No A record found." }
    Write-OK "Server IP: $serverIP"
}
catch {
    Write-Fail "Could not resolve $CombatBoxHost. Check your internet connection."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# --- 2. Select network adapter -----------------------------------------------
Write-Step "Finding active network adapters..."

$adapters = @(Get-NetAdapter |
    Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "VirtualBox|VMware|Hyper-V|Loopback|Xbox" } |
    Sort-Object -Property LinkSpeed -Descending)

if ($adapters.Count -eq 0) {
    Write-Warn "No adapters found after filtering. Showing ALL active adapters..."
    $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Sort-Object -Property LinkSpeed -Descending)
}

if ($adapters.Count -eq 0) {
    Write-Fail "No active network adapters found."
    Read-Host "Press Enter to exit"
    exit 1
}

if ($adapters.Count -eq 1) {
    $adapter = $adapters[0]
    Write-OK "Found: $($adapter.Name) ($($adapter.InterfaceDescription))"
}
else {
    Write-Host ""
    Write-Host "   Multiple adapters found. Select your INTERNET connection:" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $a = $adapters[$i]
        Write-Host "     [$($i + 1)] $($a.Name) - $($a.InterfaceDescription) ($($a.LinkSpeed))" -ForegroundColor White
    }
    Write-Host ""
    do {
        $choice = Read-Host "   Enter number (1-$($adapters.Count))"
        $choiceNum = [int]$choice - 1
    } while ($choiceNum -lt 0 -or $choiceNum -ge $adapters.Count)
    $adapter = $adapters[$choiceNum]
    Write-OK "Selected: $($adapter.Name) ($($adapter.InterfaceDescription))"
}

$adapterName = $adapter.Name
$adapterDesc = $adapter.InterfaceDescription

# --- Read current MTU via netsh ----------------------------------------------
$currentMTU = $null
$subInterfaces = netsh interface ipv4 show subinterfaces
foreach ($line in $subInterfaces) {
    if ($line -match [regex]::Escape($adapterName)) {
        if ($line -match "^\s*(\d+)") {
            $currentMTU = [int]$Matches[1]
        }
        break
    }
}
if (-not $currentMTU) {
    $currentMTU = 1500
    Write-Warn "Could not read current MTU - assuming default 1500."
}

Write-OK "Adapter:     $adapterName ($adapterDesc)"
Write-Info "Current MTU: $currentMTU"

# --- 3. Path MTU Discovery ---------------------------------------------------
Write-Step "Finding optimal MTU to $serverIP (this takes a moment)..."
Write-Info "Pinging with Don't Fragment flag, stepping down from $StartSize bytes..."

$optimalPayload = $null
$testSize = $StartSize

while ($testSize -ge $MinSize) {
    $result = ping -n 1 -f -l $testSize -w $PingTimeout $serverIP 2>&1
    $success = $result | Select-String -Pattern "Reply from" -Quiet
    if ($success) {
        $optimalPayload = $testSize
        Write-OK "Payload $testSize bytes - OK (MTU = $($testSize + $IPHeaderOverhead))"
        break
    }
    else {
        Write-Info "Payload $testSize bytes - fragmented or timed out"
        $testSize -= $StepDown
    }
}

if (-not $optimalPayload) {
    Write-Fail "Could not determine path MTU. Server may be blocking ICMP."
    Write-Warn "Falling back to Combat Box recommended MTU of 1300."
    $optimalMTU = 1300
}
else {
    Write-Info ""
    Write-Info "Fine-tuning to exact byte boundary..."
    $fineSize    = $optimalPayload + $StepDown
    $bestPayload = $optimalPayload
    for ($s = $optimalPayload + 1; $s -le $fineSize; $s++) {
        $result  = ping -n 1 -f -l $s -w $PingTimeout $serverIP 2>&1
        $success = $result | Select-String -Pattern "Reply from" -Quiet
        if ($success) { $bestPayload = $s } else { break }
    }
    $optimalMTU = $bestPayload + $IPHeaderOverhead
    Write-OK "Optimal MTU: $optimalMTU (payload $bestPayload + $IPHeaderOverhead header bytes)"
}

# --- 4. Apply MTU ------------------------------------------------------------
Write-Step "Applying MTU $optimalMTU to adapter '$adapterName'..."
if ($currentMTU -eq $optimalMTU) {
    Write-OK "MTU is already $optimalMTU - no change needed."
}
else {
    try {
        netsh interface ipv4 set subinterface "$adapterName" mtu=$optimalMTU store=persistent | Out-Null
        Write-OK "MTU changed: $currentMTU -> $optimalMTU"
    }
    catch {
        Write-Fail "Failed to set MTU: $_"
    }
}

# --- 5. Disable TCP Auto-Tuning ----------------------------------------------
Write-Step "Disabling TCP Auto-Tuning..."
$autoTuning = (netsh interface tcp show global) | Select-String "Receive Window Auto-Tuning Level"
Write-Info "Current: $($autoTuning.ToString().Trim())"
netsh interface tcp set global autotuninglevel=disabled | Out-Null
Write-OK "TCP Auto-Tuning disabled."

# --- 6. DNS ------------------------------------------------------------------
Write-Step "DNS optimisation"
$dnsOutput = netsh interface ip show dns "$adapterName"
Write-Info "Current DNS config:"
foreach ($dnsLine in $dnsOutput) {
    $trimmed = $dnsLine.Trim()
    if ($trimmed) { Write-Info "  $trimmed" }
}

Write-Host ""
Write-Host "   Your DNS server is what translates website names into IP addresses." -ForegroundColor Gray
Write-Host "   Your current DNS is usually provided by your ISP and may be slow." -ForegroundColor Gray
Write-Host "   Cloudflare (1.1.1.1) and Google (8.8.8.8) are free, faster alternatives" -ForegroundColor Gray
Write-Host "   that can reduce connection delays when joining the Combat Box server." -ForegroundColor Gray
Write-Host "   This change is safe and can be undone at any time." -ForegroundColor Gray
Write-Host ""
$changeDNS = Read-Host "   Set DNS to Cloudflare (1.1.1.1) + Google (8.8.8.8)? [Y/n]"
if ($changeDNS -ne "n" -and $changeDNS -ne "N") {
    try {
        netsh interface ip set dns "$adapterName" static 1.1.1.1 | Out-Null
        netsh interface ip add dns "$adapterName" 8.8.8.8 index=2 | Out-Null
        Write-OK "DNS set to 1.1.1.1 (Cloudflare) + 8.8.8.8 (Google)."
    }
    catch {
        Write-Fail "Failed to set DNS: $_"
    }
}
else {
    Write-Info "DNS left unchanged."
}

# --- 7. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "  =============================================" -ForegroundColor Green
Write-Host "   Done! Summary:" -ForegroundColor White
Write-Host "  =============================================" -ForegroundColor Green
Write-Host ""
Write-Host "   Server:       $CombatBoxHost ($serverIP)" -ForegroundColor White
Write-Host "   Adapter:      $adapterName" -ForegroundColor White
Write-Host "   MTU:          $currentMTU -> $optimalMTU" -ForegroundColor White
Write-Host "   Auto-Tuning:  Disabled" -ForegroundColor White

$dnsIPs = @()
foreach ($line in (netsh interface ip show dns "$adapterName")) {
    if ($line -match "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})") {
        $dnsIPs += $Matches[1]
    }
}
$dnsDisplay = if ($dnsIPs.Count -gt 0) { $dnsIPs -join ", " } else { "unchanged" }
Write-Host "   DNS:          $dnsDisplay" -ForegroundColor White

Write-Host ""
Write-Warn "No reboot required. Changes take effect immediately."
Write-Warn "To revert MTU: netsh interface ipv4 set subinterface `"$adapterName`" mtu=1500 store=persistent"
Write-Host ""
Read-Host "Press Enter to exit"
