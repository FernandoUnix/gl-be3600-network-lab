# Guest Network Setup — OpenWrt / GL.iNet GL-BE3600

Interactive shell script that builds a fully isolated **Guest Wi-Fi network** on an OpenWrt-based router. Guests get **internet only** — they cannot reach LAN, Lab, White-Hat, or any internal network on the router.

The script is **safe to re-run**: it scans for any prior Guest configuration on the chosen band, reports exactly what it finds, and asks before wiping and rebuilding. It only manages its own UCI sections (prefix `guest2g_*` / `guest5g_*`), so it never touches the Lab or White-Hat scripts' configuration.

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
| LAN access | **NO** |
| Lab access | **NO** |
| White-Hat access | **NO** |
| Client isolation | **YES** (guests can't see each other) |
| IPv6 | **disabled** (delegation off, RA off, DHCPv6 off, fw REJECT) |
| DNS | router only (forced via firewall) |

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
                                  | forwarding rule:
                                  |   GuestxG -> wan (ONLY)
                                  |
       +==========================+==========================+
       |                  GL.iNet GL-BE3600                  |
       |                                                     |
       |   +----------- Firewall zone: GuestxG ----------+   |
       |   |  input=REJECT  output=ACCEPT  forward=REJ   |   |
       |   |  rules: Allow-DHCP (udp/67)                 |   |
       |   |         Allow-DNS  (tcp+udp/53)             |   |
       |   |         Block-IPv6 (REJECT family=ipv6)     |   |
       |   +---------------------------------------------+   |
       |                       |                             |
       |              +-----------------+                    |
       |              | Interface       |  static            |
       |              |  GuestxG        |  192.168.3x.1      |
       |              +-----------------+                    |
       |                       |                             |
       |              +-----------------+                    |
       |              |  Bridge         |                    |
       |              |  br-guest-Xg    |  (no phys ports)   |
       |              +-----------------+                    |
       |                       |                             |
       |              +-----------------+                    |
       |              |  Radio wifiX    |  AP, WPA2-PSK      |
       |              |  amarof-Guest-  |  isolate=1         |
       |              |  XG-DDMM...     |                    |
       |              +-----------------+                    |
       +======================|==============================+
                              |  ((( Wi-Fi )))
              _______________ | _______________
             /                |                \
        +-------+         +-------+         +-------+
        | G #1  |  X--X   | G #2  |  X--X   | G #3  |
        +-------+         +-------+         +-------+
         (clients cannot talk to each other -- isolate=1)
         (cannot reach LAN  192.168.8.x)
         (cannot reach Lab  192.168.40/41.x)
         (cannot reach W-H  192.168.50/51.x)
```

---

## Per-band parameters

```
+---------+-----------------------------+-----------------+----------+-------------+----------+
| Band    | SSID (DDMMYYYY-HHMM)        | Subnet          | Radio    | Bridge      | FW zone  |
+---------+-----------------------------+-----------------+----------+-------------+----------+
| 2.4 GHz | amarof-Guest-2G-<date>      | 192.168.30.0/24 | wifi0    | br-guest-2g | Guest2G  |
| 5 GHz   | amarof-Guest-5G-<date>      | 192.168.31.0/24 | wifi1    | br-guest-5g | Guest5G  |
+---------+-----------------------------+-----------------+----------+-------------+----------+
```

---

## Requirements

- **Hardware**: OpenWrt-compatible router (developed on **GL.iNet GL-BE3600**).
- **Shell**: BusyBox `ash` (script targets `/bin/sh`).
- **Tools** (stock OpenWrt): `uci`, `ifstatus`, `ip`, `brctl`, `bridge`, `wifi`, `ping`, `jsonfilter` (optional).
- **Root access** on the router (SSH as `root`).
- No OpenVPN required — Guest traffic exits via plain `wan`.

---

## How to execute

```powershell
scp ".\guest network\setup_guest_network.sh" root@192.168.8.1:/root/
ssh root@192.168.8.1
```

On the router:

```sh
chmod +x /root/setup_guest_network.sh
/root/setup_guest_network.sh
```

Prompts (in order):

| Prompt | Expected input |
|--------|---------------|
| `Select band [1 or 2]` | `1` for 2.4 GHz, `2` for 5 GHz |
| `Password` | 8–63 chars (WPA2-PSK) |
| `Confirm` | retype the password |
| `Your choice [1 or 2]` *(only if existing config found)* | `1` wipe & recreate, `2` exit |

To create both bands, run the script twice (once with `1`, once with `2`). Each band is fully independent.

---

## What gets created (per band)

`<pfx>` is `guest2g` or `guest5g`.

| Config file | Section | Purpose |
|-------------|---------|---------|
| `network`   | `network.<pfx>_bridge` (device)    | Empty bridge `br-guest-2g` / `br-guest-5g` |
| `network`   | `network.GuestxG` (interface)      | Static IP `192.168.3x.1/24`, IPv6 off |
| `wireless`  | `wireless.<pfx>_wifi` (wifi-iface) | AP on `wifiX`, WPA2-PSK, **isolate=1** |
| `dhcp`      | `dhcp.GuestxG` (dhcp)              | Range `.100`–`.249`, 12h, RA/DHCPv6 off |
| `firewall`  | `firewall.<pfx>_zone` (zone)       | `input=REJECT output=ACCEPT forward=REJECT` |
| `firewall`  | `firewall.<pfx>_to_wan` (forwarding) | Guest zone → `wan`  (**only forwarding**) |
| `firewall`  | `firewall.<pfx>_allow_dhcp` (rule) | Accept UDP/67 from Guest zone |
| `firewall`  | `firewall.<pfx>_allow_dns`  (rule) | Accept TCP+UDP/53 from Guest zone |
| `firewall`  | `firewall.<pfx>_block_ipv6` (rule) | REJECT all IPv6 from Guest zone |

---

## Security model

- **`input=REJECT`** — Guests cannot reach router services (LuCI, SSH). Only DHCP and DNS are explicitly allowed.
- **`forward=REJECT`** — Guest zone cannot route to any other zone unless an explicit forwarding rule allows it; only `wan` is allowed.
- **No path to LAN, Lab, or White-Hat** — there are no `GuestxG -> lan`, `-> Lab2G`, `-> Lab5G`, `-> WhiteHat2G`, or `-> WhiteHat5G` forwardings.
- **Client isolation (`isolate=1`)** — guests cannot talk to each other over Wi-Fi.
- **IPv6 fully off** — prevents the "IPv6 bypasses the IPv4 firewall" failure mode.
- **DNS forced to router** — `Allow-DNS-Guest2G/5G` accepts traffic only to UDP/TCP 53 destined to the router; clients cannot exfiltrate via custom DNS without it being intercepted by the resolver.

---

## Validation checks

After applying config the script runs:

| Group | What it verifies |
|-------|------------------|
| **A. Interface status** | `ifstatus GuestxG` reports `up=true` and `device=br-guest-Xg` |
| **B. Bridge**           | `brctl show` lists the bridge |
| **C. DHCP leases**      | `/tmp/dhcp.leases` entries in the Guest subnet; APIPA (169.x) flagged |
| **D. Config completeness** | Every UCI section exists; **isolation leak check**: no forwarding from `GuestxG` exists except `-> wan`; client isolation = 1 |
| **E. Internet**         | `ping -c2 8.8.8.8` from router (up to 3 tries, 30s apart) |

Check D is the key requirement enforcer — if anything ever adds a `GuestxG -> lan/Lab/WhiteHat` forwarding, the validator will catch it.

---

## Re-running / cleanup

Re-running detects every existing UCI section for the selected band (network/wireless/dhcp/firewall) and the kernel bridge, then asks **1) wipe & recreate** or **2) exit**.

Choosing `1` deletes **only Guest** sections for that band. The other band's Guest network and the Lab / White-Hat / IoT scripts are untouched.

---

## Independence from other scripts

This script only reads, writes, and deletes UCI sections whose names start with `guest2g_*` or `guest5g_*`, plus the firewall zone named `Guest2G` or `Guest5G`. It pattern-matches wireless SSIDs by the prefix `amarof-Guest-2G` / `amarof-Guest-5G` only.

Running the Lab or White-Hat scripts (or the original IoT script) will **not** affect Guest configuration in any way.

---

## Troubleshooting

**`FATAL: Radio wifiX does not exist on this device`**
Run `uci show wireless | grep '=wifi-device'` on the router. On some builds the radios are `radio0` / `radio1`. Edit `NET_RADIO` assignments in the script to match.

**Guest can reach LAN — they shouldn't**
Run `uci show firewall | grep "src='Guest"` on the router and check the destination. The only acceptable destination is `wan`. Delete anything else:
```sh
uci show firewall | grep forwarding   # find the bad section name
uci delete firewall.<section>
uci commit firewall && /etc/init.d/firewall restart
```

**Client gets a `169.254.x.x` (APIPA) address**
DHCP isn't reaching the client. Check `wifi status`, `bridge link`, and `/etc/init.d/dnsmasq status`.

**Internet check (E) fails but everything else passes**
The router's WAN may still be reconnecting after the `network`/`wifi` restarts. Wait a minute and re-run `ping 8.8.8.8` from the router.
