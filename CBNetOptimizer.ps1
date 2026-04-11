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
        Write-Host "Cannot determine script path for elevation." -ForegroundColor Red
        Write-Host "Right-click the file and choose 'Run with PowerShell'." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
    try {
        # Pass the full argument string as a single value so that spaces in $scriptPath
        # are preserved correctly — array-style ArgumentList does not quote entries.
        $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argString -ErrorAction Stop
    }
    catch {
        Write-Host "Elevation failed: $_" -ForegroundColor Red
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
$ConsistencyPings = 20

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

# --- 4. Consistency test -----------------------------------------------------
$testPayload   = $optimalMTU - $IPHeaderOverhead
$progressWidth = 30
Write-Step "Consistency test: $ConsistencyPings pings at optimal payload ($testPayload bytes)..."
Write-Host ""

$rtts = @()
$lost = 0

for ($p = 1; $p -le $ConsistencyPings; $p++) {
    $pingLine  = ping -n 1 -f -l $testPayload -w $PingTimeout $serverIP 2>&1
    $replyLine = $pingLine | Where-Object { $_ -match "Reply from" }
    if ($replyLine -and $replyLine -match "time[=<](\d+)ms") {
        $rtts += [int]$Matches[1]
    } else {
        $lost++
    }

    $filled = [int][Math]::Round(($p / $ConsistencyPings) * $progressWidth)
    $bar = if ($filled -ge $progressWidth) {
        "[" + ("=" * $progressWidth) + "]"
    } else {
        "[" + ("=" * [Math]::Max(0, $filled - 1)) + ">" + (" " * ($progressWidth - $filled)) + "]"
    }
    Write-Host "`r   $bar $p / $ConsistencyPings" -NoNewline
}
Write-Host ""

# Compute stats from collected replies
$packetLossPct = [Math]::Round(($lost / $ConsistencyPings) * 100)
$minRTT = $avgRTT = $maxRTT = $jitter = $null
if ($rtts.Count -gt 0) {
    $stats  = $rtts | Measure-Object -Minimum -Maximum -Average
    $minRTT = [int]$stats.Minimum
    $maxRTT = [int]$stats.Maximum
    $avgRTT = [int][Math]::Round($stats.Average)
}
if ($rtts.Count -ge 2) {
    $diffs  = for ($i = 1; $i -lt $rtts.Count; $i++) { [Math]::Abs($rtts[$i] - $rtts[$i-1]) }
    $jitter = [Math]::Round(($diffs | Measure-Object -Average).Average, 1)
}

# Display — colour-coded thresholds
$lossColor = if ($packetLossPct -eq 0) { "Green" } elseif ($packetLossPct -le 5) { "Yellow" } else { "Red" }
Write-Host "   Packet loss:  $packetLossPct%" -ForegroundColor $lossColor

if ($null -ne $avgRTT) {
    $rttColor = if ($avgRTT -lt 50) { "Green" } elseif ($avgRTT -lt 100) { "Yellow" } else { "Red" }
    Write-Host "   Latency:      min ${minRTT}ms  avg ${avgRTT}ms  max ${maxRTT}ms" -ForegroundColor $rttColor
}
if ($null -ne $jitter) {
    $jitterColor = if ($jitter -lt 5) { "Green" } elseif ($jitter -lt 20) { "Yellow" } else { "Red" }
    Write-Host "   Jitter:       ${jitter}ms (mean deviation between replies)" -ForegroundColor $jitterColor
}

if ($packetLossPct -gt 5) {
    Write-Warn "High packet loss detected. Connection may be unstable regardless of MTU."
}
if ($null -ne $jitter -and $jitter -ge 20) {
    Write-Warn "High jitter detected. Consider checking for BufferBloat (waveform.com/tools/bufferbloat)."
}

# --- 5. Apply MTU  -----------------------------------------------------------
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

# --- 6. Disable TCP Auto-Tuning ----------------------------------------------
Write-Step "Disabling TCP Auto-Tuning..."
$autoTuning = (netsh interface tcp show global) | Select-String "Receive Window Auto-Tuning Level"
Write-Info "Current: $($autoTuning.ToString().Trim())"
netsh interface tcp set global autotuninglevel=disabled | Out-Null
Write-OK "TCP Auto-Tuning disabled."

# --- 7. DNS ------------------------------------------------------------------
Write-Step "DNS optimisation"
$dnsOutput = netsh interface ip show dns "$adapterName"
Write-Info "Current DNS config:"
foreach ($dnsLine in $dnsOutput) {
    $trimmed = $dnsLine.Trim()
    if ($trimmed) { Write-Info "  $trimmed" }
}

$currentDnsIPs = @()
foreach ($line in $dnsOutput) {
    if ($line -match "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})") {
        $currentDnsIPs += $Matches[1]
    }
}
$alreadyOptimal = ($currentDnsIPs.Count -ge 2 -and $currentDnsIPs[0] -eq "1.1.1.1" -and $currentDnsIPs -contains "8.8.8.8")

if ($alreadyOptimal) {
    Write-OK "DNS is already set to Cloudflare (1.1.1.1) + Google (8.8.8.8) - no change needed."
}
else {
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
}

# --- 8. Summary --------------------------------------------------------------
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
