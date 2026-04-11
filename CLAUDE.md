# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CBNetOptimizer is a Windows PowerShell utility that automatically discovers and applies the optimal MTU (Maximum Transmission Unit) for connections to the Combat Box IL-2 Sturmovik multiplayer server (`srs.combatbox.net`). It also optionally applies TCP and DNS optimizations.

## Running the Script

There is no build step — this is a pure PowerShell scripting project.

**Recommended — right-click `CBNetOptimizer.ps1` → "Run with PowerShell".** The script self-elevates via UAC; no pre-existing admin shell is needed.

```powershell
# From a non-admin PowerShell terminal (script self-elevates)
powershell -ExecutionPolicy Bypass -File CBNetOptimizer.ps1
```

If Windows execution policy blocks the script on first run (downloaded file), unblock it first:
```powershell
Unblock-File -Path .\CBNetOptimizer.ps1
```

## Architecture

- **`CBNetOptimizer.ps1`** — Main script. Self-elevates via `Start-Process powershell.exe -Verb RunAs` if not already admin. Executes a sequential pipeline:

1. **DNS Resolution** — Resolves `srs.combatbox.net` to IP
2. **Adapter Selection** — Enumerates active adapters, filters virtual/hypervisor adapters (VirtualBox, VMware, Hyper-V, Xbox Wireless, Loopback), prompts user if multiple remain
3. **MTU Discovery** — ICMP Path MTU Discovery using `ping.exe` with the Don't Fragment flag:
   - Steps down from `$StartSize` (1472) by `$StepDown` (10) bytes until a payload succeeds
   - Fine-tunes upward 1 byte at a time to find the exact boundary
   - Falls back to Combat Box recommended MTU (1300) if ICMP is blocked
4. **Consistency Test** — `$ConsistencyPings` (20) individual pings at the optimal payload; shows animated progress bar and reports packet loss, min/avg/max latency, and jitter
5. **MTU Application** — Applies via `netsh interface ipv4 set subinterface`
6. **TCP Tuning** — Disables TCP Auto-Tuning (`netsh int tcp set global autotuninglevel=disabled`)
7. **DNS Configuration** — Optionally sets DNS to Cloudflare (1.1.1.1) + Google (8.8.8.8) via `netsh`
8. **Summary** — Displays applied settings and revert commands

## Key Configuration (CBNetOptimizer.ps1, lines ~38–45)

```powershell
$CombatBoxHost    = "srs.combatbox.net"
$IPHeaderOverhead = 28      # TCP/IP header bytes added to payload size
$PingTimeout      = 2000    # ms
$StartSize        = 1472    # Starting payload for MTU discovery
$StepDown         = 10      # Step-down increment when payload fails
$MinSize          = 1200    # Minimum payload to test before giving up
$ConsistencyPings = 20      # Number of pings in the post-discovery consistency test
```

## Output Helpers

Five functions provide consistent color-coded output: `Write-Step` (cyan), `Write-OK` (green), `Write-Info` (gray), `Write-Warn` (yellow), `Write-Fail` (red).

## External Dependencies

None beyond built-in Windows tools: `Resolve-DnsName`, `Get-NetAdapter`, `ping.exe`, `netsh`. No package manager or external downloads.
