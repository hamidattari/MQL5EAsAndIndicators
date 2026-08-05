# TradeCopier – Complete Setup Guide

## What was built

| File                                         | Purpose                                           |
|----------------------------------------------|---------------------------------------------------|
| `TradeCopierServer/Program.cs`               | ASP.NET Core 8 relay server                       |
| `TradeCopierServer/appsettings.json`         | Port + auth token config                          |
| `TradeCopierServer/TradeCopierServer.csproj` | .NET project file                                 |
| `TradeCopierServer/deploy.ps1`               | One-shot build + install + firewall script        |
| `CopierMaster.mq5`                           | MT5 Master EA (pushes trades to server)           |
| `CopierSlave.mq5`                            | MT5 Slave EA (long-polls server, executes copies) |

---

## How it works

```
MT5 MASTER  ──POST /trade──►  TradeCopierServer  ──GET /poll──►  MT5 SLAVE
 (any broker)                  (VPS :5000)                        (copy broker)
```

1. **Master EA** watches positions every 1 second, POSTs a JSON command to the server when anything changes (OPEN / MODIFY / PARTIAL_CLOSE / CLOSE).
2. **Server** queues the command in memory. `/poll` is a *long-poll* endpoint: the Slave's HTTP call blocks on the server for up to 25 seconds until a command arrives (or the timeout expires and `{}` is returned so the Slave can re-issue the call).
3. **Slave EA** fires its OnTimer every 1 second, issues `GET /poll`. Because WebRequest waits 28 seconds for a response, the slave effectively reacts within ~50 ms of the master posting a trade.

No Telegram. No external services. No polling delay. Pure HTTP.

---

## Step 1 – Deploy the server on your VPS

### Prerequisites (run on VPS)

```powershell
# Install .NET 8 SDK (if not already present)
winget install Microsoft.DotNet.SDK.8
```

### Copy files & run deploy script

1. Copy the entire `TradeCopierServer\` folder to `C:\TradeCopierServer\` on the VPS.
2. Open **PowerShell as Administrator**.
3. Edit `appsettings.json` first:
   - Change `"AuthToken"` to a long random string (e.g. from `[System.Guid]::NewGuid().ToString("N") + [System.Guid]::NewGuid().ToString("N")`).
   - Change `"Port"` if 5000 is taken.
4. Run:

```powershell
cd C:\TradeCopierServer
.\deploy.ps1 -SrcDir C:\TradeCopierServer -Port 5000
```

This will:
- Compile a self-contained `TradeCopierServer.exe`
- Open port 5000 in Windows Firewall
- Install and start a Windows Service that auto-starts on boot
- Run a health check: should print `{"status":"ok","utc":"..."}`

---

## Step 2 – Whitelist the server URL in MT5

On **both** Master and Slave MT5 terminals:

1. **Tools → Options → Expert Advisors**
2. Tick **"Allow WebRequest for listed URL"**
3. Add: `http://<YOUR_VPS_IP>:5000`

> Replace `<YOUR_VPS_IP>` with the actual public IP or hostname of your VPS.

---

## Step 3 – Configure Master EA

Attach `CopierMaster.mq5` to **any chart** on the Master terminal.

| Input           | Value                                       |
|-----------------|---------------------------------------------|
| `ServerUrl`     | `http://<YOUR_VPS_IP>:5000`                 |
| `AuthToken`     | *(same string you put in appsettings.json)* |
| `EnableCopying` | `true`                                      |

---

## Step 4 – Configure Slave EA

Attach `CopierSlave.mq5` to **any chart** on the Slave terminal.

| Input               | Value                                                                        |
|---------------------|------------------------------------------------------------------------------|
| `ServerUrl`         | `http://<YOUR_VPS_IP>:5000`                                                  |
| `AuthToken`         | *(same string)*                                                              |
| `EnableCopying`     | `true`                                                                       |
| `LotMultiplier`     | e.g. `1.0` (copy same size) or `0.5` (half size)                             |
| `FixedLotMode`      | `false` (proportional) or `true` (always FixedLotSize)                       |
| `SymbolMappingList` | e.g. `XAUUSD=XAUUSD.ec,EURUSD=EURUSD.a` or leave blank if symbol names match |

---

## Step 5 – Test

1. Open a trade on the Master account.
2. Watch the Master EA Journal: should print `Master: OPEN sent tkt=XXXXXXXXX`.
3. Watch the Slave EA Journal: should print `Slave: GET /poll response: {...}` then `Slave: OPEN placed slaveTkt=XXXXXXXXX`.

### Useful Journal lines

| What you see                   | Meaning                                    |
|--------------------------------|--------------------------------------------|
| `GET /poll response: {}`       | Long-poll timed out, no commands – healthy |
| `Master: OPEN sent`            | Master successfully posted to server       |
| `Slave: Received command:`     | Slave got the JSON from server             |
| `Slave: OPEN placed slaveTkt=` | Order placed successfully                  |
| `Slave: OPEN failed retcode=`  | Broker rejected the order – check retcode  |
| `GET /poll failed HTTP=401 `   | Wrong AuthToken                            |
| `GET /poll failed HTTP=0`      | Server unreachable / firewall / wrong IP   |

---

## Multiple Slaves

Run `CopierSlave.mq5` on as many accounts as you like — they all poll the same `/poll` endpoint. The server uses a **single queue**, so the first slave to respond gets each command. If you need each slave to receive every command independently, contact me and I'll extend the server with per-slave named queues.

---

## Security Notes

- The `AuthToken` is sent as an HTTP Bearer token in every request.
- For production, consider putting the server behind an **nginx reverse proxy with TLS** (HTTPS) so the token is encrypted in transit.
- Do not share the `AuthToken`.

---

## Windows Service management

```powershell
Start-Service   TradeCopierServer
Stop-Service    TradeCopierServer
Restart-Service TradeCopierServer
Get-Service     TradeCopierServer   # check status
```

Logs go to the Windows Event Log (Application). View with:
```powershell
Get-EventLog -LogName Application -Source TradeCopierServer -Newest 20
```
