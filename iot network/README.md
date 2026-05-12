# IoT Network Setup — OpenWrt / GL.iNet GL-BE3600

Interactive shell script that builds a fully isolated IoT Wi-Fi network on an OpenWrt-based router (tested on the GL.iNet GL-BE3600). It creates an independent bridge, network interface, SSID, DHCP server and a strict firewall zone for IoT devices — and forces all IoT traffic out through the router's OpenVPN client (`ovpnclient1`).

The script is **safe to re-run**: it scans for any prior configuration on the chosen band, reports exactly what it finds, and asks for confirmation before wiping and rebuilding.

---

## Table of Contents

- [What the script does](#what-the-script-does)
- [Architecture diagram](#architecture-diagram)
- [Execution flow](#execution-flow)
- [Requirements](#requirements)
- [How to execute](#how-to-execute)
- [What gets created (per band)](#what-gets-created-per-band)
- [Security model](#security-model)
- [Validation checks](#validation-checks)
- [Re-running / cleanup](#re-running--cleanup)
- [Manual verification on a client device](#manual-verification-on-a-client-device)
- [Troubleshooting](#troubleshooting)

---

## What the script does

1. Prompts you to choose **2.4 GHz** or **5 GHz** (both can coexist — run the script twice).
2. Asks for a Wi-Fi password (8–63 chars, with confirmation).
3. Scans for any existing IoT config on the selected band (UCI sections + kernel bridge) and prints a finding list.
4. If anything is found, asks whether to **wipe and recreate** or **exit**.
5. Builds the IoT stack in 5 steps:
   - **Bridge device** (`br-iot-2g` or `br-iot-5g`)
   - **Network interface** with static IP (`192.168.20.1` or `192.168.21.1`)
   - **Wi-Fi SSID** with WPA2-PSK + client isolation
   - **DHCP server** (range `.100`–`.249`, 12h lease, IPv6 disabled)
   - **Firewall zone** with strict policy + rules + VPN-routed forwarding
6. Restarts `network`, `firewall`, and `wifi`.
7. Runs **5 categories of validation checks** (interface up, bridge present, DHCP, config completeness, internet reachability) and prints a pass/fail summary.

---

## Architecture diagram

```
                              INTERNET
                                  |
                          +---------------+
                          |  ISP / WAN    |
                          +---------------+
                                  |
                              [wan zone]
                                  |
                          +---------------+
                          |  OpenVPN      |   <-- ovpnclient1
                          |  client tun   |       (all IoT egress here)
                          +---------------+
                                  ^
                                  | forwarding rule:
                                  |   IoTxG -> ovpnclient1
                                  |   IoTxG -> wan (fallback)
                                  |
       +==========================+==========================+
       |                  GL.iNet GL-BE3600                  |
       |                                                     |
       |   +----------- Firewall zone: IoTxG -----------+    |
       |   |  input=REJECT  output=ACCEPT  forward=REJ  |    |
       |   |  rules: Allow-DHCP (udp/67)                |    |
       |   |         Allow-DNS  (tcp+udp/53)            |    |
       |   |         Block-IPv6 (REJECT family=ipv6)    |    |
       |   +--------------------------------------------+    |
       |                       |                             |
       |              +-----------------+                    |
       |              | Interface IoTxG |  static            |
       |              |  192.168.2x.1   |                    |
       |              +-----------------+                    |
       |                       |                             |
       |              +-----------------+                    |
       |              |  Bridge         |                    |
       |              |  br-iot-Xg      |  (no phys ports)   |
       |              +-----------------+                    |
       |                       |                             |
       |              +-----------------+                    |
       |              |  Radio wifiX    |  AP, WPA2-PSK      |
       |              |  SSID: amarof-  |  isolate=1         |
       |              |  IoT-XG-DDMM... |                    |
       |              +-----------------+                    |
       +======================|==============================+
                              |  ((( Wi-Fi )))
              _______________ | _______________
             /                |                \
        +--------+        +--------+        +--------+
        | IoT #1 |   X--X | IoT #2 |   X--X | IoT #3 |
        +--------+        +--------+        +--------+
         (clients cannot talk to each other -- isolate=1)
         (cannot reach LAN 192.168.8.x -- forward=REJECT)
         (no IPv6 at all -- delegation/RA/DHCPv6/fw all off)

Legend:
   --->   permitted flow
   X--X   blocked by client isolation
   [zone] OpenWrt firewall zone
```

### Per-band parameters

```
+---------+--------------------------+-----------------+----------+-----------+----------+
| Band    | SSID (DDMMYYYY-HHMM)     | Subnet          | Radio    | Bridge    | FW zone  |
+---------+--------------------------+-----------------+----------+-----------+----------+
| 2.4 GHz | amarof-IoT-2G-<date>     | 192.168.20.0/24 | wifi0    | br-iot-2g | IoT2G    |
| 5 GHz   | amarof-IoT-5G-<date>     | 192.168.21.0/24 | wifi1    | br-iot-5g | IoT5G    |
+---------+--------------------------+-----------------+----------+-----------+----------+
```

---

## Execution flow

```
   START
     |
     v
  +-------------------+
  | Banner + Band     |
  | selection (1/2)   |
  +-------------------+
     |
     v
  +-------------------+        radio exists?
  | Radio check       |--- NO ----------------> FATAL exit
  | uci show          |
  | wireless.wifiX    |
  +-------------------+
     |  YES
     v
  +-------------------+
  | Prompt password   |  (>=8 chars, confirm match)
  +-------------------+
     |
     v
  +-------------------+
  | STEP 0  Scan      |   look for: network.IoTxG, bridge device,
  | existing config   |              wireless SSIDs matching base,
  +-------------------+              dhcp.IoTxG, fw zone/forwarding/
     |                                rules, kernel bridge link
     v
   FOUND_COUNT > 0 ?
     |        |
    YES       NO
     |        |
     v        v
  +-------+   |
  | ask:  |   |
  | 1)wipe|   |
  | 2)exit|   |
  +-------+   |
     |        |
     v        v
  +----------------------+
  | STEP 0b  Teardown    | uci delete + commit on
  | (only if needed)     |  network/wireless/dhcp/firewall
  +----------------------+  + ip link delete bridge
     |
     v
  +----------------------+
  | STEP 1  Bridge       |  network.<pfx>_bridge = device (type=bridge)
  +----------------------+
     |
     v
  +----------------------+
  | STEP 2  Interface    |  network.IoTxG = interface (static + IP)
  |                      |  delegate=0  (no IPv6 prefix)
  +----------------------+
     |
     v
  +----------------------+
  | STEP 3  Wi-Fi SSID   |  wireless.<pfx>_wifi = wifi-iface
  |                      |  encryption=psk2, isolate=1
  +----------------------+
     |
     v
  +----------------------+
  | STEP 4  DHCP         |  dhcp.IoTxG  range 100-249, 12h
  |                      |  ra=disabled, dhcpv6=disabled
  +----------------------+
     |
     v
  +----------------------+
  | STEP 5  Firewall     |  zone IoTxG (input/forward = REJECT)
  |                      |  forwarding IoTxG -> wan
  |                      |  forwarding IoTxG -> ovpnclient1
  |                      |  Allow-DHCP, Allow-DNS, Block-IPv6
  +----------------------+
     |
     v
  +----------------------+
  | Commit all configs   |  network, wireless, dhcp, firewall
  +----------------------+
     |
     v
  +----------------------+
  | Restart services     |  /etc/init.d/network restart
  |                      |  /etc/init.d/firewall restart
  |                      |  wifi down/up
  +----------------------+
     |
     v
  +----------------------+
  | Validation (A..E)    |   A) ifstatus shows UP + device == bridge
  |                      |   B) brctl shows bridge
  |                      |   C) DHCP leases (or "no leases yet")
  |                      |   D) every UCI section is present
  |                      |   E) ping 8.8.8.8 (up to 3 tries)
  +----------------------+
     |
     v
   FAILURES == 0 ?
     |        |
    YES       NO
     |        |
     v        v
  ALL PASSED   REPORT FAILED CHECKS
     |        |
     +---+----+
         v
   Print final network summary
   + manual verification hints
         |
         v
        END
```

---

## Requirements

- **Hardware**: OpenWrt-compatible router with at least one `wifi-device` radio (developed on **GL.iNet GL-BE3600**, OpenWrt-based).
- **Shell**: BusyBox `ash` (the script targets `/bin/sh`, not bash).
- **Tools** (present in stock OpenWrt): `uci`, `ifstatus`, `ip`, `brctl`, `bridge`, `wifi`, `ping`, `jsonfilter` (optional, falls back to `grep`).
- **Pre-existing OpenVPN client interface named `ovpnclient1`** — the firewall forwarding rule points IoT traffic at this interface. If you don't use a VPN, see [Troubleshooting](#troubleshooting).
- **Root access** on the router (SSH as `root`).

---

## How to execute

### 1. Copy the script to the router

From your workstation (PowerShell example):

```powershell
scp ".\iot network\setup_iot_network.sh" root@192.168.8.1:/root/
```

(adjust the router IP if yours is different.)

### 2. SSH into the router

```powershell
ssh root@192.168.8.1
```

### 3. Make it executable and run it

```sh
chmod +x /root/setup_iot_network.sh
/root/setup_iot_network.sh
```

### 4. Follow the prompts

You will be asked, in order:

| Prompt | Expected input |
|--------|---------------|
| `Select band [1 or 2]` | `1` for 2.4 GHz, `2` for 5 GHz |
| `Password` | 8–63 chars (WPA2-PSK) |
| `Confirm` | retype the password |
| `Your choice [1 or 2]` *(only if existing config found)* | `1` to wipe and recreate, `2` to abort |

### 5. To create both bands

Just run the script twice — once choosing `1`, once choosing `2`. They are independent: each band has its own bridge, subnet, DHCP pool and firewall zone.

---

## What gets created (per band)

For each run, the following UCI sections are created (`<pfx>` is `iot2g` or `iot5g`):

| Config file | Section | Purpose |
|-------------|---------|---------|
| `network`   | `network.<pfx>_bridge` (device) | Empty bridge `br-iot-2g` / `br-iot-5g` |
| `network`   | `network.IoTxG` (interface)     | Static IP `192.168.2x.1/24`, IPv6 delegation off |
| `wireless`  | `wireless.<pfx>_wifi` (wifi-iface) | AP on `wifiX`, WPA2-PSK, client isolation |
| `dhcp`      | `dhcp.IoTxG` (dhcp)             | Range `.100`–`.249`, 12h lease, RA/DHCPv6 off |
| `firewall`  | `firewall.<pfx>_zone` (zone)    | `input=REJECT output=ACCEPT forward=REJECT` |
| `firewall`  | `firewall.<pfx>_to_wan` (forwarding)  | IoT zone → `wan` |
| `firewall`  | `firewall.<pfx>_to_ovpn` (forwarding) | IoT zone → `ovpnclient1` |
| `firewall`  | `firewall.<pfx>_allow_dhcp` (rule)    | Accept UDP/67 from IoT zone |
| `firewall`  | `firewall.<pfx>_allow_dns`  (rule)    | Accept TCP+UDP/53 from IoT zone |
| `firewall`  | `firewall.<pfx>_block_ipv6` (rule)    | REJECT all IPv6 from IoT zone |

---

## Security model

The IoT zone is **defensively configured**:

- **`input=REJECT`** — IoT clients cannot reach router services (LuCI, SSH, etc.) by default; only DHCP and DNS are explicitly allowed.
- **`forward=REJECT`** — IoT zone cannot route to any other zone unless an explicit forwarding rule allows it (only `wan` and `ovpnclient1` are allowed).
- **No path to LAN** — there is no `IoTxG -> lan` forwarding, so IoT devices cannot reach `192.168.8.x` (the trusted LAN).
- **Client isolation (`isolate=1`)** — IoT devices cannot talk to *each other* over Wi-Fi (Layer-2 isolation at the AP).
- **IPv6 fully off** — prefix delegation disabled on the interface, RA + DHCPv6 disabled in the DHCP section, and a firewall rule rejects any IPv6 traffic from the zone. This prevents the common "VPN leaks because IPv6 bypasses the IPv4 tunnel" failure mode.
- **Egress only via VPN** — the primary forwarding is `IoTxG -> ovpnclient1`. The `IoTxG -> wan` rule exists too; if you want strict VPN-only (kill-switch behavior), remove the `to_wan` forwarding manually after running the script.

---

## Validation checks

After applying config, the script runs 5 check groups and counts failures:

| Group | What it verifies |
|-------|------------------|
| **A. Interface status** | `ifstatus IoTxG` returns `up=true` and `device=br-iot-Xg` |
| **B. Bridge**           | `brctl show` lists the bridge; reports any wireless iface attached |
| **C. DHCP leases**      | Scans `/tmp/dhcp.leases` for entries in the IoT subnet; flags APIPA (169.x) |
| **D. Config completeness** | Every UCI section above exists; client isolation is `1` |
| **E. Internet**         | `ping -c2 8.8.8.8` (up to 3 tries, 30s apart) to confirm router egress |

If any check fails, the script prints a red banner with the failure count.

---

## Re-running / cleanup

The script is idempotent **per band**. Re-running it will:

1. Detect every existing UCI section for that band (network/wireless/dhcp/firewall) and the kernel bridge.
2. Print a finding list (yellow `[!]` lines).
3. Ask you to choose **1) wipe & recreate** or **2) exit**.

Choosing `1` deletes everything for that band only — the *other* band's IoT network is untouched.

---

## Manual verification on a client device

After the script finishes, on a phone or laptop:

1. Connect to `amarof-IoT-2G-<date>` (or `-5G-`).
2. Confirm the assigned IP is in `192.168.20.x` (or `192.168.21.x`).
3. Open a browser — internet should work (traffic exits via the VPN).
4. Try `ping 192.168.8.1` (the LAN gateway) — it should **fail** (LAN isolated).
5. Connect a second device to the same SSID — the two devices should **not** be able to ping each other (client isolation).

---

## Troubleshooting

**`FATAL: Radio wifiX does not exist on this device`**
Run `uci show wireless | grep '=wifi-device'` on the router to see your actual radio names. On some OpenWrt builds the radios are named `radio0` / `radio1` instead of `wifi0` / `wifi1`. Edit the `IOT_RADIO` assignments in the script to match.

**You don't use OpenVPN (no `ovpnclient1` interface)**
The forwarding rule `IoTxG -> ovpnclient1` will be created but inactive (no matching interface). IoT traffic will still exit via the `IoTxG -> wan` rule. To clean up, after running the script:

```sh
uci delete firewall.iot2g_to_ovpn      # or iot5g_to_ovpn
uci commit firewall
/etc/init.d/firewall restart
```

**Internet check (E) fails but everything else passed**
The router's WAN/VPN may still be reconnecting after the `network` and `wifi` restarts. Wait a minute and re-try `ping 8.8.8.8` from the router. The IoT clients depend on the router itself having internet.

**Client gets a `169.254.x.x` (APIPA) address**
DHCP isn't reaching the client. Check that:
- `wifi` is up: `wifi status`
- The wireless interface is attached to the bridge: `bridge link`
- `dnsmasq` is running: `/etc/init.d/dnsmasq status`

**Clients can reach the LAN (`192.168.8.x`) — they shouldn't**
Re-run validation check D, or list firewall forwardings: `uci show firewall | grep forwarding`. There should be **no** `IoTxG -> lan` rule. If there is one from a prior manual change, delete it.
