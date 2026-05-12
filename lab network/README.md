# Lab Network Setup — OpenWrt / GL.iNet GL-BE3600

Interactive shell script that builds an isolated **Lab Wi-Fi network** on an OpenWrt-based router. The Lab network is designed for safe experimentation: devices can reach the **internet** and the **trusted LAN** (where Docker hosts, VMs, and internal tools typically live), and **Lab devices can communicate with each other** so they can run mixed multi-node tests. Lab cannot reach Guest or White-Hat.

The script is **safe to re-run**: it scans for any prior Lab configuration on the chosen band and asks before wiping and rebuilding. It only manages its own UCI sections (prefix `lab2g_*` / `lab5g_*`), so it never touches the Guest or White-Hat scripts' configuration.

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
| LAN access | **YES** (reach Docker/VMs/internal tools on `lan`) |
| Lab → Guest | **NO** |
| Lab → White-Hat | **NO** |
| Client isolation | **NO** (lab devices CAN talk to each other) |
| IPv6 | **disabled** |
| DNS | router only (forced via firewall) |

> Note: White-Hat is **allowed to reach Lab** (configured by the White-Hat script). Lab is **not** allowed to reach White-Hat — the link is one-way.

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
                                  |   forwarding:
                                  |     LabxG -> wan
                                  |     LabxG -> lan
                                  |
       +==========================+==========================+
       |                  GL.iNet GL-BE3600                  |
       |                                                     |
       |   +----------- Firewall zone: LabxG -----------+    |
       |   |  input=REJECT  output=ACCEPT  forward=REJ  |    |
       |   |  rules: Allow-DHCP (udp/67)                |    |
       |   |         Allow-DNS  (tcp+udp/53)            |    |
       |   |         Block-IPv6 (REJECT family=ipv6)    |    |
       |   +--------------------------------------------+    |
       |                       |                             |
       |              +-----------------+         <-----+    |
       |              | Interface       |   static     |     |
       |              |  LabxG          |  192.168.4x.1|     |
       |              +-----------------+              |     |
       |                       |                       |     |
       |              +-----------------+              |     |
       |              |  Bridge         |              |     |
       |              |  br-lab-Xg      | (no phys)    |     |
       |              +-----------------+              |     |
       |                       |                       |     |
       |              +-----------------+              |     |
       |              |  Radio wifiX    | WPA2-PSK     |     |
       |              |  amarof-Lab-    | isolate=0    |     |
       |              |  XG-DDMM...     |              |     |
       |              +-----------------+              |     |
       +======================|=======================+|=====+
                              |  ((( Wi-Fi )))         |
              _______________ | _______________        |
             /                |                \       |  one-way
        +-------+         +-------+         +-------+  |  forwarding
        | Lab#1 |<------->| Lab#2 |<------->| Lab#3 |  | (White-Hat
        +-------+         +-------+         +-------+  |  -> Lab)
         (lab devices CAN talk to each other)          |
         (CAN reach LAN  192.168.8.x)                  |
         (CANNOT reach Guest 192.168.30/31.x)          |
         (CANNOT reach White-Hat 192.168.50/51.x) -----+
```

---

## Per-band parameters

```
+---------+--------------------------+-----------------+----------+-----------+----------+
| Band    | SSID (DDMMYYYY-HHMM)     | Subnet          | Radio    | Bridge    | FW zone  |
+---------+--------------------------+-----------------+----------+-----------+----------+
| 2.4 GHz | amarof-Lab-2G-<date>     | 192.168.40.0/24 | wifi0    | br-lab-2g | Lab2G    |
| 5 GHz   | amarof-Lab-5G-<date>     | 192.168.41.0/24 | wifi1    | br-lab-5g | Lab5G    |
+---------+--------------------------+-----------------+----------+-----------+----------+
```

---

## Requirements

- **Hardware**: OpenWrt-compatible router (developed on **GL.iNet GL-BE3600**).
- **Shell**: BusyBox `ash` (script targets `/bin/sh`).
- **Tools** (stock OpenWrt): `uci`, `ifstatus`, `ip`, `brctl`, `bridge`, `wifi`, `ping`, `jsonfilter` (optional).
- **Root access** on the router (SSH as `root`).
- A working `lan` firewall zone (default on OpenWrt) — the script forwards Lab traffic to it.

---

## How to execute

```powershell
scp ".\lab network\setup_lab_network.sh" root@192.168.8.1:/root/
ssh root@192.168.8.1
```

On the router:

```sh
chmod +x /root/setup_lab_network.sh
/root/setup_lab_network.sh
```

Prompts (in order):

| Prompt | Expected input |
|--------|---------------|
| `Select band [1 or 2]` | `1` for 2.4 GHz, `2` for 5 GHz |
| `Password` | 8–63 chars (WPA2-PSK) |
| `Confirm` | retype the password |
| `Your choice [1 or 2]` *(only if existing config found)* | `1` wipe & recreate, `2` exit |

To create both bands, run the script twice.

---

## What gets created (per band)

`<pfx>` is `lab2g` or `lab5g`.

| Config file | Section | Purpose |
|-------------|---------|---------|
| `network`   | `network.<pfx>_bridge` (device)    | Empty bridge `br-lab-2g` / `br-lab-5g` |
| `network`   | `network.LabxG` (interface)        | Static IP `192.168.4x.1/24`, IPv6 off |
| `wireless`  | `wireless.<pfx>_wifi` (wifi-iface) | AP on `wifiX`, WPA2-PSK, **isolate=0** |
| `dhcp`      | `dhcp.LabxG` (dhcp)                | Range `.100`–`.249`, 12h, RA/DHCPv6 off |
| `firewall`  | `firewall.<pfx>_zone` (zone)       | `input=REJECT output=ACCEPT forward=REJECT` |
| `firewall`  | `firewall.<pfx>_to_wan` (forwarding) | Lab zone → `wan` |
| `firewall`  | `firewall.<pfx>_to_lan` (forwarding) | Lab zone → `lan` (Docker/VMs reachable) |
| `firewall`  | `firewall.<pfx>_allow_dhcp` (rule) | Accept UDP/67 from Lab zone |
| `firewall`  | `firewall.<pfx>_allow_dns`  (rule) | Accept TCP+UDP/53 from Lab zone |
| `firewall`  | `firewall.<pfx>_block_ipv6` (rule) | REJECT all IPv6 from Lab zone |

---

## Security model

- **`input=REJECT`** — Lab clients cannot reach router services unless DHCP/DNS is explicitly allowed.
- **`forward=REJECT`** — Lab zone cannot route to any other zone unless an explicit forwarding rule allows it. Only `wan` and `lan` are allowed; Guest and White-Hat are NOT reachable.
- **Lab → LAN allowed** — by design: lab devices need to reach Docker hosts and internal services on `192.168.8.x`.
- **Client isolation OFF** — by design: multi-node lab tests need devices to see each other.
- **IPv6 fully off** — prevents the "IPv6 bypasses the IPv4 firewall" failure mode.
- **DNS forced to router** — clients cannot bypass the resolver via the firewall.

If you want stricter isolation later (e.g. Lab cannot reach LAN), remove the `<pfx>_to_lan` forwarding:

```sh
uci delete firewall.lab2g_to_lan      # or lab5g_to_lan
uci commit firewall
/etc/init.d/firewall restart
```

---

## Validation checks

| Group | What it verifies |
|-------|------------------|
| **A. Interface status** | `ifstatus LabxG` reports `up=true` and `device=br-lab-Xg` |
| **B. Bridge**           | `brctl show` lists the bridge |
| **C. DHCP leases**      | `/tmp/dhcp.leases` entries in the Lab subnet; APIPA flagged |
| **D. Config completeness** | Every UCI section exists; **isolation leak check**: no forwarding from `LabxG` to any `Guest*` or `WhiteHat*` zone; `isolate=0` expected |
| **E. Internet**         | `ping -c2 8.8.8.8` from router (up to 3 tries, 30s apart) |

Check D's leak detection is the key requirement enforcer — it confirms Lab cannot reach Guest or White-Hat by scanning every firewall forwarding section.

---

## Re-running / cleanup

Re-running detects every existing UCI section for the selected band and the kernel bridge, then asks **1) wipe & recreate** or **2) exit**. Choosing `1` deletes **only Lab** sections for that band; the other band's Lab network and the Guest / White-Hat / IoT scripts are untouched.

---

## Independence from other scripts

This script only reads, writes, and deletes UCI sections whose names start with `lab2g_*` or `lab5g_*`, plus the firewall zone named `Lab2G` or `Lab5G`. It pattern-matches wireless SSIDs by the prefix `amarof-Lab-2G` / `amarof-Lab-5G` only.

The White-Hat script's `WhiteHatxG -> Lab2G/Lab5G` forwardings reference Lab zones by name. If Lab is later deleted, those rules remain but become inactive (no matching destination zone). Re-running this Lab script restores them automatically once the zones exist again.

---

## Troubleshooting

**`FATAL: Radio wifiX does not exist on this device`**
Run `uci show wireless | grep '=wifi-device'`. Adjust `NET_RADIO` in the script if your radios are `radio0` / `radio1`.

**Lab clients can't reach Docker on the LAN host**
Check that:
- The Docker host is on the `lan` zone (default).
- `uci show firewall | grep src=\'Lab2G\'` lists `lab2g_to_lan` with `dest='lan'`.
- The container is published on the host (`-p 192.168.8.x:port:port`) — Docker bridge networks are not exposed to other LANs by default.

**Lab devices in 2.4 GHz can't ping Lab devices in 5 GHz**
This is expected — each band is its own VLAN/zone (`Lab2G` and `Lab5G` are separate zones). If you want cross-band Lab communication, add forwardings:
```sh
uci set firewall.lab2g_to_lab5g=forwarding
uci set firewall.lab2g_to_lab5g.src='Lab2G'
uci set firewall.lab2g_to_lab5g.dest='Lab5G'
uci set firewall.lab5g_to_lab2g=forwarding
uci set firewall.lab5g_to_lab2g.src='Lab5G'
uci set firewall.lab5g_to_lab2g.dest='Lab2G'
uci commit firewall && /etc/init.d/firewall restart
```
(Note: this is a manual step — the script intentionally keeps the bands isolated by default so each script remains independent.)

**Validation check D fails with "ISOLATION LEAK"**
Someone (or a previous script run) created a forwarding from `LabxG` to `Guest*` or `WhiteHat*`. List forwardings and delete the offending one:
```sh
uci show firewall | grep forwarding
uci delete firewall.<section>
uci commit firewall && /etc/init.d/firewall restart
```
