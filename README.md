# CBNetOptimizer

A PowerShell script that automatically finds and applies the optimal MTU for your connection to the [Combat Box](https://combatbox.net) IL-2 Sturmovik multiplayer server.

## What It Does

Instead of blindly setting your MTU to a fixed value (like the commonly recommended 1300), this script measures the actual path MTU between your PC and the Combat Box server using ICMP Path MTU Discovery, then sets the precise optimal value.

The script:

1. Resolves `srs.combatbox.net` and pings it with the "Don't Fragment" flag
2. Steps down from MTU 1500 to find the largest packet that passes without fragmentation
3. Fine-tunes to the exact byte boundary
4. Runs a 20-ping consistency test at the optimal MTU, reporting latency, jitter, and packet loss
5. Applies the optimal MTU to your network adapter via `netsh`
6. Disables TCP Auto-Tuning (reduces latency spikes in games)
7. Optionally sets DNS to Cloudflare (1.1.1.1) + Google (8.8.8.8)

## Requirements

- Windows 10 or 11
- No installs required — uses only built-in Windows tools

## Usage

1. Download `CBNetOptimizer.ps1`
2. Right-click it and choose **"Run with PowerShell"**
3. Accept the Windows UAC prompt when asked

If Windows blocks the script because it was downloaded from the internet, unblock it first:
right-click `CBNetOptimizer.ps1` → **Properties** → tick **Unblock** → OK.

## What to Expect

```
  =============================================
   Combat Box - Network Optimizer
   Server: srs.combatbox.net
  =============================================

>> Resolving srs.combatbox.net...
   [OK] Server IP: x.x.x.x

>> Finding active network adapters...
   [OK] Found: Ethernet (Intel I225-V)

>> Finding optimal MTU to x.x.x.x (this takes a moment)...
   Payload 1472 bytes - OK (MTU = 1500)
   Fine-tuning (stepping up by 1 byte to find the exact limit)...
   [OK] Optimal MTU: 1500 (largest payload: 1472 + 28 header)

>> Applying MTU 1500 to adapter 'Ethernet'...
   [OK] MTU is already set to 1500 - no change needed.
```

If multiple network adapters are active, the script will list them and let you pick.

## Reverting Changes

To reset MTU back to the Windows default:

```powershell
netsh interface ipv4 set subinterface "YOUR_ADAPTER_NAME" mtu=1500 store=persistent
```

To re-enable TCP Auto-Tuning:

```powershell
netsh interface tcp set global autotuninglevel=normal
```

## Adapter Filtering

The script automatically filters out non-internet adapters (VirtualBox, VMware, Hyper-V, Loopback, Xbox Wireless). If your internet adapter gets filtered out, it falls back to showing all active adapters for manual selection.

## License

[MIT](LICENSE)
