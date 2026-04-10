#Requires -RunAsAdministrator
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

# ─── Configuration ────────────────────────────────────────────────────────────
$CombatBoxHost   = "srs.combatbox.net"
$IPHeaderOverhead = 28          # 20 bytes IP + 8 bytes ICMP
$PingTimeout      = 2000        # ms per ping attempt
$StartSize        = 1472        # = MTU 1500 minus header overhead
$StepDown         = 10          # decrease payload by this many bytes each try
$MinSize          = 1200        # don't go below MTU 1228 — something else is wrong

# ─── Helper: coloured output ──────────────────────────────────────────────────
function Write-Step  { param($Msg) Write-Host "`n>> $Msg" -ForegroundColor Cyan }
function Write-OK    { param($Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Info  { param($Msg) Write-Host "   $Msg" -ForegroundColor Gray }
function Write-Warn  { param($Msg) Write-Host "   [!] $Msg" -ForegroundColor Yellow }
function Write-Fail  { param($Msg) Write-Host "   [X] $Msg" -ForegroundColor Red }

# ─── Banner ───────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host "   CBNetOptimizer" -ForegroundColor White
Write-Host "   Server: $CombatBoxHost" -ForegroundColor Gray
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host ""

# ─── 1. Resolve the Combat Box server ────────────────────────────────────────
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

# ─── 2. Select network adapter ───────────────────────────────────────────────
Write-Step "Finding active network adapters..."

$adapters = @(Get-NetAdapter |
    Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "VirtualBox|VMware|Hyper-V|Loopback|Xbox" } |
    Sort-Object -Property LinkSpeed -Descending)

if ($adapters.Count -eq 0) {
    Write-Warn "No adapters found after filtering. Showing ALL active adapters..."
    $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Sort-Object -Property LinkSpeed -Descending)
}

if ($adapters.Count -eq 0) {
    Write-Fail "No active network adapters found at all."
    Read-Host "Press Enter to exit"
    exit 1
}

if ($adapters.Count -eq 1) {
    $adapter = $adapters[0]
    Write-OK "Found: $($adapter.Name) ($($adapter.InterfaceDescription))"
}
else {
    Write-Host ""
    Write-Host "   Multiple active adapters found. Select your INTERNET connection:" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $a = $adapters[$i]
        Write-Host "     [$($i + 1)] $($a.Name)  —  $($a.InterfaceDescription)  ($($a.LinkSpeed))" -ForegroundColor White
    }
    Write-Host ""
    do {
        $choice = Read-Host "   Enter number (1-$($adapters.Count))"
        $choiceNum = [int]$choice - 1
    } while ($choiceNum -lt 0 -or $choiceNum -ge $adapters.Count)

    $adapter = $adapters[$choiceNum]
    Write-OK "Selected: $($adapter.Name) ($($adapter.InterfaceDescription))"
}

$adapterName  = $adapter.Name
$adapterIndex = $adapter.ifIndex
$adapterDesc  = $adapter.InterfaceDescription

# Read current MTU via netsh — the most reliable method across all adapter types
$currentMTU = $null
$subInterfaces = netsh interface ipv4 show subinterfaces
foreach ($line in $subInterfaces) {
    if ($line -match $adapterName) {
        if ($line -match "^\s*(\d+)") {
            $currentMTU = [int]$Matches[1]
        }
        break
    }
}
if (-not $currentMTU) {
    $currentMTU = 1500
    Write-Warn "Could not read current MTU — assuming default 1500."
}

Write-OK "Adapter:     $adapterName ($adapterDesc)"
Write-Info "Current MTU: $currentMTU"

# ─── 3. Path MTU Discovery ───────────────────────────────────────────────────
Write-Step "Finding optimal MTU to $serverIP (this takes a moment)..."
Write-Info "Sending pings with Don't Fragment flag, working down from $StartSize bytes..."

$optimalPayload = $null
$testSize = $StartSize

while ($testSize -ge $MinSize) {
    $result = ping -n 1 -f -l $testSize -w $PingTimeout $serverIP 2>&1

    # Check if the ping succeeded (Reply from...)
    $success = $result | Select-String -Pattern "Reply from" -Quiet

    if ($success) {
        $optimalPayload = $testSize
        Write-OK "Payload $testSize bytes — OK (MTU = $($testSize + $IPHeaderOverhead))"
        break
    }
    else {
        Write-Info "Payload $testSize bytes — fragmented or timed out"
        $testSize -= $StepDown
    }
}

if (-not $optimalPayload) {
    Write-Fail "Could not determine path MTU. The server may be blocking ICMP."
    Write-Warn "Falling back to the Combat Box recommended value of MTU 1300."
    $optimalMTU = 1300
}
else {
    # Fine-tune: step back up in increments of 1 to find exact boundary
    Write-Info ""
    Write-Info "Fine-tuning (stepping up by 1 byte to find the exact limit)..."

    $fineSize = $optimalPayload + $StepDown  # go back to the last failing size
    $bestPayload = $optimalPayload

    for ($s = $optimalPayload + 1; $s -le $fineSize; $s++) {
        $result = ping -n 1 -f -l $s -w $PingTimeout $serverIP 2>&1
        $success = $result | Select-String -Pattern "Reply from" -Quiet

        if ($success) {
            $bestPayload = $s
        }
        else {
            break
        }
    }

    $optimalMTU = $bestPayload + $IPHeaderOverhead
    Write-OK "Optimal MTU: $optimalMTU (largest payload: $bestPayload + $IPHeaderOverhead header)"
}

# ─── 4. Apply MTU ────────────────────────────────────────────────────────────
Write-Step "Applying MTU $optimalMTU to adapter '$adapterName'..."

if ($currentMTU -eq $optimalMTU) {
    Write-OK "MTU is already set to $optimalMTU — no change needed."
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

# ─── 5. Disable TCP Auto-Tuning ─────────────────────────────────────────────
Write-Step "Disabling TCP Auto-Tuning (reduces latency spikes in games)..."

$autoTuning = (netsh interface tcp show global) | Select-String "Receive Window Auto-Tuning Level"
Write-Info "Current: $($autoTuning.ToString().Trim())"

netsh interface tcp set global autotuninglevel=disabled | Out-Null
Write-OK "TCP Auto-Tuning disabled."

# ─── 6. Offer DNS change ────────────────────────────────────────────────────
Write-Step "DNS optimisation"

$dnsOutput = netsh interface ip show dns "$adapterName"
Write-Info "Current DNS config:"
foreach ($dnsLine in $dnsOutput) {
    $trimmed = $dnsLine.Trim()
    if ($trimmed) { Write-Info "  $trimmed" }
}

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

# ─── 7. Summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  =============================================" -ForegroundColor Green
Write-Host "   Done! Summary:" -ForegroundColor White
Write-Host "  =============================================" -ForegroundColor Green
Write-Host ""
Write-Host "   Server:          $CombatBoxHost ($serverIP)" -ForegroundColor White
Write-Host "   Adapter:         $adapterName" -ForegroundColor White
Write-Host "   MTU:             $currentMTU -> $optimalMTU" -ForegroundColor White
Write-Host "   Auto-Tuning:     Disabled" -ForegroundColor White
$finalDNS = netsh interface ip show dns "$adapterName" | Select-String "\d+\.\d+\.\d+\.\d+"
$dnsDisplay = if ($finalDNS) { ($finalDNS -replace '.*?(\d+\.\d+\.\d+\.\d+).*','$1') -join ', ' } else { "(unchanged)" }
Write-Host "   DNS:             $dnsDisplay" -ForegroundColor White
Write-Host ""
Write-Warn "No reboot required. Changes take effect immediately."
Write-Warn "To revert MTU to default later: netsh interface ipv4 set subinterface `"$adapterName`" mtu=1500 store=persistent"
Write-Host ""
Read-Host "Press Enter to exit"
