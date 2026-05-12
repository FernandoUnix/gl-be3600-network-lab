# White-Hat Network Setup — OpenWrt / GL.iNet GL-BE3600

> **Authorized security testing only.** This network is intended for controlled, in-scope penetration testing and offensive-security training in a home lab you own. Do not connect production assets to it.

Interactive shell script that builds a **White-Hat Wi-Fi network** on an OpenWrt-based router. The White-Hat network is designed to host pentest workstations (e.g. Kali, Parrot, custom rigs) that need broad **internal visibility**: internet + trusted LAN + the Lab network on both bands. White-Hat **cannot** reach the Guest network.

The script is **safe to re-run**: it scans for any prior White-Hat configuration on the chosen band and asks before wiping and rebuilding. It only manages its own UCI sections (prefix `wh2g_*` / `wh5g_*`), so it never touches the Guest or Lab scripts' configuration.

---

## Table of Contents

- [Policy summary](#policy-summary)
- [Architecture diagram](#architecture-diagram)
- [Per-band parameters](#per-band-parameters)
- [Requirements](#requirements)
- [How to execute](#how-to-execute)
- [What gets created (per band)](#what-gets-created-per-band)
- [Security model](#security-model)
- [Validation checks](#validation-checks)
- [Re-running / cleanup](#re-running--cleanup)
- [Independence from other scripts](#independence-from-other-scripts)
- [Troubleshooting](#troubleshooting)

---

## Policy summary

| Aspect | Setting |
|---|---|
| Internet access | **YES** (via `wan`) |
| LAN access | **YES** (pentest targets on the trusted LAN) |
| Lab 2G access | **YES** (forwarding to `Lab2G`) |
| Lab 5G access | **YES** (forwarding to `Lab5G`) |
| Guest access | **NO** (isolation enforced) |
| Client isolation | **NO** (pentest devices can scan each other) |
| IPv6 | **disabled** |
| DNS | router only (forced via firewall) |

The Lab forwardings (`-> Lab2G`, `-> Lab5G`) are created **even if Lab zones don't exist yet** — they sit idle and activate automatically the moment the Lab script creates the corresponding zones.

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
                                  ^
                                  |  forwarding:
                                  |    WhiteHatxG -> wan
                                  |    WhiteHatxG -> lan
                                  |    WhiteHatxG -> Lab2G
                                  |    WhiteHatxG -> Lab5G
                                  |    (NO -> Guest*)
                                  |
       +==========================+==========================+
       |                  GL.iNet GL-BE3600                  |
       |                                                     |
       |   +--------- Firewall zone: WhiteHatxG ---------+   |
       |   |  input=REJECT  output=ACCEPT  forward=REJ   |   |
       |   |  rules: Allow-DHCP (udp/67)                 |   |
       |   |         Allow-DNS  (tcp+udp/53)             |   |
       |   |         Block-IPv6 (REJECT family=ipv6)     |   |
       |   +---------------------------------------------+   |
       |                       |                             |
       |              +-----------------+                    |
       |              | Interface       |   static           |
       |              |  WhiteHatxG     |   192.168.5x.1     |
       |              +-----------------+                    |
       |                       |                             |
       |              +-----------------+                    |
       |              |  Bridge         |                    |
       |              |  br-wh-Xg       |  (no phys ports)   |
       |              +-----------------+                    |
       |                       |                             |
       |              +-----------------+                    |
       |              |  Radio wifiX    |   WPA2-PSK         |
       |              |  amarof-White-  |   isolate=0        |
       |              |  Hat-XG-DDMM... |                    |
       |              +-----------------+                    |
       +======================|==============================+
                              |  ((( Wi-Fi )))
              _______________ | _______________
             /                |                \
        +-------+         +-------+         +-------+
        | WH #1 |<------->| WH #2 |<------->| WH #3 |
        +-------+         +-------+         +-------+
         (pentest devices CAN see each other)
         (CAN reach LAN,  Lab 2G,  Lab 5G)
         (CANNOT reach Guest 192.168.30/31.x)
```

---

## Per-band parameters

```
+---------+--------------------------------+-----------------+----------+----------+-------------+
| Band    | SSID (DDMMYYYY-HHMM)           | Subnet          | Radio    | Bridge   | FW zone     |
+---------+--------------------------------+-----------------+----------+----------+-------------+
| 2.4 GHz | amarof-WhiteHat-2G-<date>     | 192.168.50.0/24 | wifi0    | br-wh-2g | WhiteHat2G  |
| 5 GHz   | amarof-WhiteHat-5G-<date>     | 192.168.51.0/24 | wifi1    | br-wh-5g | WhiteHat5G  |
+---------+--------------------------------+-----------------+----------+----------+-------------+
```

---

## Requirements

- **Hardware**: OpenWrt-compatible router (developed on **GL.iNet GL-BE3600**).
- **Shell**: BusyBox `ash` (script targets `/bin/sh`).
- **Tools** (stock OpenWrt): `uci`, `ifstatus`, `ip`, `brctl`, `bridge`, `wifi`, `ping`, `jsonfilter` (optional).
- **Root access** on the router (SSH as `root`).
- A working `lan` zone (default on OpenWrt).
- (Optional but recommended) the **Lab network** already set up via `setup_lab_network.sh` — otherwise the Lab forwardings exist but are dormant.

---

## How to execute

```powershell
scp ".\white-hat network\setup_white_hat_network.sh" root@192.168.8.1:/root/
ssh root@192.168.8.1
```

On the router:

```sh
chmod +x /root/setup_white_hat_network.sh
/root/setup_white_hat_network.sh
```

Prompts (in order):

| Prompt | Expected input |
|--------|---------------|
| `Select band [1 or 2]` | `1` for 2.4 GHz, `2` for 5 GHz |
| `Password` | 8–63 chars (WPA2-PSK) — pick a strong one, this network has broad access |
| `Confirm` | retype the password |
| `Your choice [1 or 2]` *(only if existing config found)* | `1` wipe & recreate, `2` exit |

To create both bands, run the script twice.

---

## What gets created (per band)

`<pfx>` is `wh2g` or `wh5g`.

| Config file | Section | Purpose |
|-------------|---------|---------|
| `network`   | `network.<pfx>_bridge` (device)    | Empty bridge `br-wh-2g` / `br-wh-5g` |
| `network`   | `network.WhiteHatxG` (interface)   | Static IP `192.168.5x.1/24`, IPv6 off |
| `wireless`  | `wireless.<pfx>_wifi` (wifi-iface) | AP on `wifiX`, WPA2-PSK, **isolate=0** |
| `dhcp`      | `dhcp.WhiteHatxG` (dhcp)           | Range `.100`–`.249`, 12h, RA/DHCPv6 off |
| `firewall`  | `firewall.<pfx>_zone` (zone)       | `input=REJECT output=ACCEPT forward=REJECT` |
| `firewall`  | `firewall.<pfx>_to_wan`   (forwarding) | White-Hat zone → `wan` |
| `firewall`  | `firewall.<pfx>_to_lan`   (forwarding) | White-Hat zone → `lan` (pentest targets) |
| `firewall`  | `firewall.<pfx>_to_lab2g` (forwarding) | White-Hat zone → `Lab2G` (active when Lab 2G exists) |
| `firewall`  | `firewall.<pfx>_to_lab5g` (forwarding) | White-Hat zone → `Lab5G` (active when Lab 5G exists) |
| `firewall`  | `firewall.<pfx>_allow_dhcp` (rule) | Accept UDP/67 from White-Hat zone |
| `firewall`  | `firewall.<pfx>_allow_dns`  (rule) | Accept TCP+UDP/53 from White-Hat zone |
| `firewall`  | `firewall.<pfx>_block_ipv6` (rule) | REJECT all IPv6 from White-Hat zone |

---

## Security model

- **`input=REJECT`** — White-Hat clients cannot reach router services unless DHCP/DNS is explicitly allowed. (You may want to also expose SSH/LuCI here for admin convenience — that's a manual change.)
- **`forward=REJECT`** — Default-deny on forwarding; only the four explicit forwardings (`wan`, `lan`, `Lab2G`, `Lab5G`) work.
- **No path to Guest** — by design: pentest traffic must never touch unrelated guest devices.
- **Client isolation OFF** — by design: pentesters need to scan and pivot between their own workstations.
- **IPv6 fully off** — prevents the "IPv6 bypasses the IPv4 firewall" failure mode and eliminates an entire class of unintended scan paths.
- **One-way trust to Lab** — White-Hat → Lab is allowed; Lab → White-Hat is NOT (the Lab script does not create the reverse forwarding). This means Lab devices are still protected from compromised pentest hosts unless you explicitly choose otherwise.
- **Strong passwords are essential** — anyone who joins this SSID gets LAN reach. Treat the WPA2 key like a privileged credential.

---

## Validation checks

| Group | What it verifies |
|-------|------------------|
| **A. Interface status** | `ifstatus WhiteHatxG` reports `up=true` and `device=br-wh-Xg` |
| **B. Bridge**           | `brctl show` lists the bridge |
| **C. DHCP leases**      | `/tmp/dhcp.leases` entries in the White-Hat subnet; APIPA flagged |
| **D. Config completeness** | Every UCI section exists; all four forwardings present; **isolation leak check**: no forwarding from `WhiteHatxG` to any `Guest*` zone; Lab zone presence reported (warning, not failure, if absent); `isolate=0` expected |
| **E. Internet**         | `ping -c2 8.8.8.8` from router (up to 3 tries, 30s apart) |

Check D's leak detection enforces the core requirement: White-Hat must never reach Guest. If the Lab zones are missing, the script prints a warning but doesn't fail — it's a valid state (Lab forwardings stay dormant until Lab is set up).

---

## Re-running / cleanup

Re-running detects every existing UCI section for the selected band and the kernel bridge, then asks **1) wipe & recreate** or **2) exit**. Choosing `1` deletes **only White-Hat** sections for that band; the other band's White-Hat network and the Guest / Lab / IoT scripts are untouched.

---

## Independence from other scripts

This script only reads, writes, and deletes UCI sections whose names start with `wh2g_*` or `wh5g_*`, plus the firewall zone named `WhiteHat2G` or `WhiteHat5G`. It pattern-matches wireless SSIDs by the prefix `amarof-WhiteHat-2G` / `amarof-WhiteHat-5G` only.

The Lab forwardings (`wh*_to_lab2g`, `wh*_to_lab5g`) reference the `Lab2G` and `Lab5G` zones **by name**. If Lab is set up later, the rules activate automatically. If Lab is deleted, the rules remain but become inactive. Re-running this script does **not** create or modify Lab in any way.

---

## Troubleshooting

**`FATAL: Radio wifiX does not exist on this device`**
Run `uci show wireless | grep '=wifi-device'`. Adjust `NET_RADIO` in the script if your radios are `radio0` / `radio1`.

**White-Hat can reach Guest — they shouldn't**
Validation check D should already have failed. List the offending forwardings:
```sh
uci show firewall | grep "src='WhiteHat" | grep -i guest
uci delete firewall.<section>
uci commit firewall && /etc/init.d/firewall restart
```

**White-Hat can reach LAN/Lab from 2.4 GHz but not 5 GHz (or vice versa)**
The two White-Hat bands are independent zones (`WhiteHat2G` and `WhiteHat5G`) with their own forwardings. If only one band has them, you most likely only ran the script for one band. Run it for the other band as well.

**Lab forwardings show as "inactive"**
The Lab zones (`Lab2G` / `Lab5G`) don't exist yet. Run `setup_lab_network.sh` from the `lab network/` folder. After Lab is up, restart firewall to make the dormant rules live:
```sh
/etc/init.d/firewall restart
```

**Lab is set up, but White-Hat can't reach Lab subnets**
Confirm the forwardings are in place and the Lab zones are recognised:
```sh
uci show firewall | grep "dest='Lab"
uci show firewall | grep "name='Lab"
```
You should see all four lab destinations on the White-Hat side and matching zones on the Lab side. If the zone names differ (e.g. `lab2g` vs `Lab2G`), the forwarding won't resolve — case matters.

**Validation check D warns "Lab2G/Lab5G zone not present"**
Informational only. White-Hat is up and routes to wan/lan correctly; the Lab forwardings are queued and will activate as soon as the Lab script runs.
