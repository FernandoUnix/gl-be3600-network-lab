#!/bin/sh
# setup_guest_network.sh
# Creates an isolated Guest Wi-Fi network on OpenWrt / GL.iNet GL-BE3600
# Supports 2.4 GHz and 5 GHz independently -- both can coexist
# Safe to re-run -- scans for the selected band's config and asks before wiping
#
# Policy: Internet only. No access to LAN, Lab, White-Hat, or any internal network.

set -e

# -- Timestamp (used in SSID name) ------------------------------------
DATE_TAG=$(date '+%d%m%Y-%H%M')

# -- ANSI colours (safe for busybox ash) ------------------------------
R='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
BLUE='\033[34m'
MAGENTA='\033[35m'
WHITE='\033[97m'
GRAY='\033[90m'

# -- Output helpers ---------------------------------------------------
ok()      { printf "  ${GREEN}[OK]${R}  %b\n" "$*"; }
info()    { printf "  ${CYAN}->${R}  ${GRAY}%b${R}\n" "$*"; }
warn()    { printf "  ${YELLOW}[!]${R}  ${YELLOW}%b${R}\n" "$*"; }
err()     { printf "  ${RED}[!!]${R}  ${RED}%b${R}\n" "$*"; }
fail()    { printf "\n  ${RED}${BOLD}FATAL:${R} %b\n\n" "$*"; exit 1; }
deleted() { printf "  ${GRAY}  [-]  %b${R}\n" "$*"; }

section() {
    printf "\n${BOLD}${BLUE}+----------------------------------------------------------+${R}\n"
    printf "${BOLD}${BLUE}|${R}  ${BOLD}${WHITE}%-56s${R}${BOLD}${BLUE}|${R}\n" "$*"
    printf "${BOLD}${BLUE}+----------------------------------------------------------+${R}\n"
}

divider() { printf "${GRAY}  ----------------------------------------------------------${R}\n"; }

# -- Banner -----------------------------------------------------------
clear
printf "\n"
printf "${BOLD}${CYAN}  +=========================================================+${R}\n"
printf "${BOLD}${CYAN}  |${R}                                                          ${BOLD}${CYAN}|${R}\n"
printf "${BOLD}${CYAN}  |${R}   ${BOLD}${WHITE}Guest Network Setup${R}  .  GL.iNet GL-BE3600            ${BOLD}${CYAN}|${R}\n"
printf "${BOLD}${CYAN}  |${R}   ${GRAY}Internet only  .  No LAN  .  No Lab  .  No White-Hat${R}   ${BOLD}${CYAN}|${R}\n"
printf "${BOLD}${CYAN}  |${R}                                                          ${BOLD}${CYAN}|${R}\n"
printf "${BOLD}${CYAN}  +=========================================================+${R}\n"
printf "\n"

# ---------------------------------------------------------------------
# Band selection
# ---------------------------------------------------------------------
section "Band Selection"
printf "\n"
printf "  ${BOLD}${WHITE}Choose which Guest band to configure:${R}\n\n"
printf "  ${CYAN}1${R}  ${BOLD}2.4 GHz${R}\n"
printf "     ${GRAY}SSID   :${R}  amarof-Guest-2G-${DATE_TAG}\n"
printf "     ${GRAY}Subnet :${R}  192.168.30.0/24\n"
printf "     ${GRAY}Radio  :${R}  wifi0\n"
printf "\n"
printf "  ${CYAN}2${R}  ${BOLD}5 GHz${R}\n"
printf "     ${GRAY}SSID   :${R}  amarof-Guest-5G-${DATE_TAG}\n"
printf "     ${GRAY}Subnet :${R}  192.168.31.0/24\n"
printf "     ${GRAY}Radio  :${R}  wifi1\n"
printf "\n"

while true; do
    printf "  ${BOLD}Select band [1 or 2]:${R} "
    read -r _band_choice
    case "$_band_choice" in
        1)
            BAND="2.4 GHz"
            NET_SSID_BASE="amarof-Guest-2G"
            NET_SSID="amarof-Guest-2G-${DATE_TAG}"
            NET_RADIO="wifi0"
            NET_IP="192.168.30.1"
            NET_BRIDGE="br-guest-2g"
            NET_IFACE="Guest2G"
            FW_ZONE="Guest2G"
            UCI_PFX="guest2g"
            break
            ;;
        2)
            BAND="5 GHz"
            NET_SSID_BASE="amarof-Guest-5G"
            NET_SSID="amarof-Guest-5G-${DATE_TAG}"
            NET_RADIO="wifi1"
            NET_IP="192.168.31.1"
            NET_BRIDGE="br-guest-5g"
            NET_IFACE="Guest5G"
            FW_ZONE="Guest5G"
            UCI_PFX="guest5g"
            break
            ;;
        *)
            warn "Invalid input -- please enter 1 or 2"
            ;;
    esac
done

NET_NETMASK="255.255.255.0"
DHCP_START=100
DHCP_LIMIT=150
DHCP_LEASETIME="12h"
_subnet_base=$(echo "$NET_IP" | cut -d'.' -f1-3)

# -- Radio existence check --------------------------------------------
if ! uci show wireless."$NET_RADIO" > /dev/null 2>&1; then
    printf "\n"
    fail "Radio ${BOLD}$NET_RADIO${R} does not exist on this device -- cannot continue.\n       Run ${CYAN}uci show wireless | grep '=wifi-device'${R} to see available radios."
fi

printf "\n"
divider
printf "  ${BOLD}${GREEN}Selected configuration${R}\n"
divider
printf "  ${GRAY}Band   :${R}  ${BOLD}$BAND${R}\n"
printf "  ${GRAY}SSID   :${R}  ${BOLD}$NET_SSID${R}\n"
printf "  ${GRAY}Radio  :${R}  $NET_RADIO\n"
printf "  ${GRAY}IP     :${R}  $NET_IP / $NET_NETMASK\n"
printf "  ${GRAY}Bridge :${R}  $NET_BRIDGE\n"
printf "  ${GRAY}DHCP   :${R}  ${_subnet_base}.${DHCP_START} - ${_subnet_base}.$((DHCP_START + DHCP_LIMIT - 1))\n"
printf "  ${GRAY}Policy :${R}  Internet only (wan)\n"
divider

# ---------------------------------------------------------------------
# Wi-Fi password prompt
# ---------------------------------------------------------------------
section "Wi-Fi Password -- $NET_SSID"
printf "\n"
printf "  ${GRAY}Password must be 8-63 characters.${R}\n\n"

NET_WIFI_KEY=""
while true; do
    printf "  ${BOLD}Password :${R} "
    read -rs _pass1
    printf "\n"

    if [ ${#_pass1} -lt 8 ]; then
        warn "Too short -- minimum 8 characters, try again"
        printf "\n"
        continue
    fi

    printf "  ${BOLD}Confirm  :${R} "
    read -rs _pass2
    printf "\n\n"

    if [ "$_pass1" = "$_pass2" ]; then
        NET_WIFI_KEY="$_pass1"
        ok "Password confirmed"
        break
    else
        warn "Passwords do not match -- try again"
        printf "\n"
    fi
done

# ---------------------------------------------------------------------
# STEP 0  Scan for existing config for this band
# ---------------------------------------------------------------------
section "Scanning for existing $BAND Guest configuration"
printf "\n"

FOUND_COUNT=0

add_finding() {
    FOUND_COUNT=$((FOUND_COUNT + 1))
    printf "  ${YELLOW}%-14s${R}  %s\n" "$1" "$2"
}

if uci show network."$NET_IFACE" > /dev/null 2>&1; then
    _ip=$(uci get network."$NET_IFACE".ipaddr 2>/dev/null || echo "?")
    _dev=$(uci get network."$NET_IFACE".device 2>/dev/null || echo "?")
    add_finding "[network]" "network.$NET_IFACE   ip=$_ip   device=$_dev"
fi

if uci show network."${UCI_PFX}_bridge" > /dev/null 2>&1; then
    add_finding "[device]" "network.${UCI_PFX}_bridge   bridge=$NET_BRIDGE"
fi

if ip link show "$NET_BRIDGE" > /dev/null 2>&1; then
    add_finding "[kernel]" "$NET_BRIDGE   bridge exists in OS"
fi

for _s in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
    _ssid=$(uci get wireless."$_s".ssid 2>/dev/null || true)
    case "$_ssid" in "${NET_SSID_BASE}"*)
        _radio=$(uci get wireless."$_s".device 2>/dev/null || echo "?")
        _net=$(uci get wireless."$_s".network 2>/dev/null || echo "?")
        add_finding "[wireless]" "wireless.$_s   ssid=$_ssid   radio=$_radio   network=$_net"
        ;;
    esac
done

if uci show dhcp."$NET_IFACE" > /dev/null 2>&1; then
    _start=$(uci get dhcp."$NET_IFACE".start 2>/dev/null || echo "?")
    _limit=$(uci get dhcp."$NET_IFACE".limit 2>/dev/null || echo "?")
    _lease=$(uci get dhcp."$NET_IFACE".leasetime 2>/dev/null || echo "?")
    add_finding "[dhcp]" "dhcp.$NET_IFACE   start=$_start   limit=$_limit   lease=$_lease"
fi

for _s in $(uci show firewall | grep "=zone" | cut -d'.' -f2 | cut -d'=' -f1); do
    _zn=$(uci get firewall."$_s".name 2>/dev/null || true)
    if [ "$_zn" = "$FW_ZONE" ]; then
        _in=$(uci get firewall."$_s".input 2>/dev/null || echo "?")
        _fwd=$(uci get firewall."$_s".forward 2>/dev/null || echo "?")
        add_finding "[fw zone]" "firewall.$_s ($FW_ZONE)   input=$_in   forward=$_fwd"
    fi
done

for _s in $(uci show firewall | grep "=forwarding" | cut -d'.' -f2 | cut -d'=' -f1); do
    _src=$(uci get firewall."$_s".src 2>/dev/null || true)
    _dst=$(uci get firewall."$_s".dest 2>/dev/null || true)
    if [ "$_src" = "$FW_ZONE" ]; then
        add_finding "[fw fwd]" "firewall.$_s   $_src -> $_dst"
    fi
done

for _s in $(uci show firewall | grep "=rule" | cut -d'.' -f2 | cut -d'=' -f1); do
    _rname=$(uci get firewall."$_s".name 2>/dev/null || true)
    case "$_rname" in
        "Allow-DHCP-$FW_ZONE"|"Allow-DNS-$FW_ZONE")
            _proto=$(uci get firewall."$_s".proto 2>/dev/null || echo "?")
            _port=$(uci get firewall."$_s".dest_port 2>/dev/null || echo "?")
            add_finding "[fw rule]" "firewall.$_s ($_rname)   proto=$_proto   port=$_port"
            ;;
        "Block-IPv6-$FW_ZONE")
            add_finding "[fw rule]" "firewall.$_s ($_rname)   family=ipv6   target=REJECT"
            ;;
    esac
done

# -- Decision ---------------------------------------------------------
if [ "$FOUND_COUNT" -gt 0 ]; then
    printf "\n"
    printf "  ${YELLOW}${BOLD}%d existing item(s) found for %s band.${R}\n\n" "$FOUND_COUNT" "$BAND"
    printf "  ${CYAN}1${R}  Delete everything above and recreate from scratch\n"
    printf "  ${CYAN}2${R}  Exit -- leave current configuration untouched\n\n"

    while true; do
        printf "  ${BOLD}Your choice [1 or 2]:${R} "
        read -r CHOICE
        case "$CHOICE" in
            1)
                printf "\n"
                info "Recreating $BAND Guest network from scratch ..."
                break
                ;;
            2)
                printf "\n"
                info "Exiting -- no changes made"
                printf "\n"
                exit 0
                ;;
            *)
                warn "Invalid input -- please enter 1 or 2"
                ;;
        esac
    done
else
    ok "No existing $BAND configuration found -- proceeding with fresh install"
fi

# ---------------------------------------------------------------------
# STEP 0b  Teardown
# ---------------------------------------------------------------------
section "Removing existing $BAND Guest configuration"
printf "\n"

if uci show network."$NET_IFACE" > /dev/null 2>&1; then
    uci delete network."$NET_IFACE"
    deleted "network.$NET_IFACE"
fi

if uci show network."${UCI_PFX}_bridge" > /dev/null 2>&1; then
    uci delete network."${UCI_PFX}_bridge"
    deleted "network.${UCI_PFX}_bridge"
fi

for _s in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
    _ssid=$(uci get wireless."$_s".ssid 2>/dev/null || true)
    case "$_ssid" in "${NET_SSID_BASE}"*)
        uci delete wireless."$_s"
        deleted "wireless.$_s  (ssid: $_ssid)"
        ;;
    esac
done

if uci show dhcp."$NET_IFACE" > /dev/null 2>&1; then
    uci delete dhcp."$NET_IFACE"
    deleted "dhcp.$NET_IFACE"
fi

for _s in $(uci show firewall | grep "=zone" | cut -d'.' -f2 | cut -d'=' -f1); do
    _zn=$(uci get firewall."$_s".name 2>/dev/null || true)
    if [ "$_zn" = "$FW_ZONE" ]; then
        uci delete firewall."$_s"
        deleted "firewall zone $_s  (name=$FW_ZONE)"
    fi
done

for _s in $(uci show firewall | grep "=forwarding" | cut -d'.' -f2 | cut -d'=' -f1); do
    _src=$(uci get firewall."$_s".src 2>/dev/null || true)
    if [ "$_src" = "$FW_ZONE" ]; then
        _dst=$(uci get firewall."$_s".dest 2>/dev/null || true)
        uci delete firewall."$_s"
        deleted "firewall forwarding $_s  ($FW_ZONE -> $_dst)"
    fi
done

for _s in $(uci show firewall | grep "=rule" | cut -d'.' -f2 | cut -d'=' -f1); do
    _rname=$(uci get firewall."$_s".name 2>/dev/null || true)
    _rsrc=$(uci get firewall."$_s".src 2>/dev/null || true)
    if [ "$_rsrc" = "$FW_ZONE" ] || \
       [ "$_rname" = "Allow-DHCP-$FW_ZONE" ] || \
       [ "$_rname" = "Allow-DNS-$FW_ZONE" ]; then
        uci delete firewall."$_s"
        deleted "firewall rule $_s  (name=$_rname)"
    fi
done

uci commit network
uci commit wireless
uci commit dhcp
uci commit firewall

if ip link show "$NET_BRIDGE" > /dev/null 2>&1; then
    ip link set "$NET_BRIDGE" down 2>/dev/null || true
    ip link delete "$NET_BRIDGE" 2>/dev/null || true
    deleted "kernel bridge $NET_BRIDGE"
fi

printf "\n"
ok "Teardown complete"

# ---------------------------------------------------------------------
# STEP 1  Bridge device
# ---------------------------------------------------------------------
section "Step 1 of 5 -- Bridge Device"
printf "\n"

uci set network."${UCI_PFX}_bridge"=device
uci set network."${UCI_PFX}_bridge".name="$NET_BRIDGE"
uci set network."${UCI_PFX}_bridge".type='bridge'
uci set network."${UCI_PFX}_bridge".bridge_empty='1'

ok "Created bridge  ${BOLD}$NET_BRIDGE${R}  (no physical ports attached)"

# ---------------------------------------------------------------------
# STEP 2  Network interface
# ---------------------------------------------------------------------
section "Step 2 of 5 -- Network Interface"
printf "\n"

uci set network."$NET_IFACE"=interface
uci set network."$NET_IFACE".proto='static'
uci set network."$NET_IFACE".device="$NET_BRIDGE"
uci set network."$NET_IFACE".ipaddr="$NET_IP"
uci set network."$NET_IFACE".netmask="$NET_NETMASK"
uci set network."$NET_IFACE".delegate='0'

ok "Interface  ${BOLD}$NET_IFACE${R}  ->  $NET_IP / $NET_NETMASK  on $NET_BRIDGE"
ok "IPv6 prefix delegation ${BOLD}disabled${R}  ${GRAY}(no global IPv6 assigned)${R}"

# ---------------------------------------------------------------------
# STEP 3  Wi-Fi SSID
# ---------------------------------------------------------------------
section "Step 3 of 5 -- Wi-Fi SSID"
printf "\n"

uci set wireless."${UCI_PFX}_wifi"=wifi-iface
uci set wireless."${UCI_PFX}_wifi".device="$NET_RADIO"
uci set wireless."${UCI_PFX}_wifi".mode='ap'
uci set wireless."${UCI_PFX}_wifi".ssid="$NET_SSID"
uci set wireless."${UCI_PFX}_wifi".network="$NET_IFACE"
uci set wireless."${UCI_PFX}_wifi".encryption='psk2'
uci set wireless."${UCI_PFX}_wifi".key="$NET_WIFI_KEY"
uci set wireless."${UCI_PFX}_wifi".disabled='0'
uci set wireless."${UCI_PFX}_wifi".isolate='1'

ok "SSID  ${BOLD}$NET_SSID${R}  on radio ${BOLD}$NET_RADIO${R}  ($BAND)  ->  network $NET_IFACE"
ok "Client isolation ${BOLD}enabled${R}  ${GRAY}(guests cannot see each other)${R}"

# ---------------------------------------------------------------------
# STEP 4  DHCP
# ---------------------------------------------------------------------
section "Step 4 of 5 -- DHCP Server"
printf "\n"

uci set dhcp."$NET_IFACE"=dhcp
uci set dhcp."$NET_IFACE".interface="$NET_IFACE"
uci set dhcp."$NET_IFACE".start="$DHCP_START"
uci set dhcp."$NET_IFACE".limit="$DHCP_LIMIT"
uci set dhcp."$NET_IFACE".leasetime="$DHCP_LEASETIME"
uci set dhcp."$NET_IFACE".ra='disabled'
uci set dhcp."$NET_IFACE".dhcpv6='disabled'

ok "DHCP range  ${_subnet_base}.${DHCP_START} - ${_subnet_base}.$((DHCP_START + DHCP_LIMIT - 1))  lease $DHCP_LEASETIME"
ok "DHCPv6 and Router Advertisements ${BOLD}disabled${R}"

# ---------------------------------------------------------------------
# STEP 5  Firewall
# ---------------------------------------------------------------------
section "Step 5 of 5 -- Firewall"
printf "\n"

uci set firewall."${UCI_PFX}_zone"=zone
uci set firewall."${UCI_PFX}_zone".name="$FW_ZONE"
uci set firewall."${UCI_PFX}_zone".network="$NET_IFACE"
uci set firewall."${UCI_PFX}_zone".input='REJECT'
uci set firewall."${UCI_PFX}_zone".output='ACCEPT'
uci set firewall."${UCI_PFX}_zone".forward='REJECT'
ok "Zone  ${BOLD}$FW_ZONE${R}  --  input=REJECT  output=ACCEPT  forward=REJECT"

uci set firewall."${UCI_PFX}_to_wan"=forwarding
uci set firewall."${UCI_PFX}_to_wan".src="$FW_ZONE"
uci set firewall."${UCI_PFX}_to_wan".dest='wan'
ok "Forward  $FW_ZONE  ->  wan  ${GRAY}(internet only)${R}"

uci set firewall."${UCI_PFX}_allow_dhcp"=rule
uci set firewall."${UCI_PFX}_allow_dhcp".name="Allow-DHCP-$FW_ZONE"
uci set firewall."${UCI_PFX}_allow_dhcp".src="$FW_ZONE"
uci set firewall."${UCI_PFX}_allow_dhcp".proto='udp'
uci set firewall."${UCI_PFX}_allow_dhcp".dest_port='67'
uci set firewall."${UCI_PFX}_allow_dhcp".target='ACCEPT'
ok "Rule  Allow DHCP  ${GRAY}(UDP/67)${R}"

uci set firewall."${UCI_PFX}_allow_dns"=rule
uci set firewall."${UCI_PFX}_allow_dns".name="Allow-DNS-$FW_ZONE"
uci set firewall."${UCI_PFX}_allow_dns".src="$FW_ZONE"
uci set firewall."${UCI_PFX}_allow_dns".proto='tcp udp'
uci set firewall."${UCI_PFX}_allow_dns".dest_port='53'
uci set firewall."${UCI_PFX}_allow_dns".target='ACCEPT'
ok "Rule  Allow DNS   ${GRAY}(TCP+UDP/53 -- router as resolver)${R}"

uci set firewall."${UCI_PFX}_block_ipv6"=rule
uci set firewall."${UCI_PFX}_block_ipv6".name="Block-IPv6-$FW_ZONE"
uci set firewall."${UCI_PFX}_block_ipv6".src="$FW_ZONE"
uci set firewall."${UCI_PFX}_block_ipv6".family='ipv6'
uci set firewall."${UCI_PFX}_block_ipv6".target='REJECT'
ok "Rule  Block all IPv6  ${GRAY}(prevents firewall bypass via IPv6)${R}"

# ---------------------------------------------------------------------
# Commit
# ---------------------------------------------------------------------
printf "\n"
divider
printf "  ${BOLD}Saving configuration ...${R}\n"
divider

uci commit network   && ok "network   saved"
uci commit wireless  && ok "wireless  saved"
uci commit dhcp      && ok "dhcp      saved"
uci commit firewall  && ok "firewall  saved"

# ---------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------
section "Restarting Services"
printf "\n"

printf "  ${CYAN}->${R}  Restarting network  "
/etc/init.d/network restart > /dev/null 2>&1 && printf "${GREEN}done${R}\n" || printf "${RED}error${R}\n"

printf "  ${CYAN}->${R}  Restarting firewall "
/etc/init.d/firewall restart > /dev/null 2>&1 && printf "${GREEN}done${R}\n" || printf "${RED}error${R}\n"

printf "  ${CYAN}->${R}  Restarting wifi     "
wifi down > /dev/null 2>&1
sleep 2
wifi up > /dev/null 2>&1
sleep 5
printf "${GREEN}done${R}\n"

printf "\n"
ok "All services restarted"

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------
section "Validation Checks"
FAILURES=0

# A. Interface
printf "\n  ${BOLD}A)  Interface status${R}\n\n"
if ifstatus "$NET_IFACE" > /tmp/guest_status.json 2>&1; then
    UP=$(jsonfilter -i /tmp/guest_status.json -e '@["up"]' 2>/dev/null \
         || grep -o '"up":true' /tmp/guest_status.json || true)
    DEV=$(jsonfilter -i /tmp/guest_status.json -e '@["device"]' 2>/dev/null \
          || grep -o "\"device\":\"$NET_BRIDGE\"" /tmp/guest_status.json || true)

    if echo "$UP" | grep -qi 'true'; then
        ok "Interface ${BOLD}$NET_IFACE${R} is UP"
    else
        err "Interface $NET_IFACE is NOT up"
        FAILURES=$((FAILURES + 1))
    fi

    if echo "$DEV" | grep -q "$NET_BRIDGE"; then
        ok "Device is ${BOLD}$NET_BRIDGE${R}"
    else
        err "Device is not $NET_BRIDGE"
        FAILURES=$((FAILURES + 1))
    fi
else
    err "ifstatus $NET_IFACE failed -- interface may not exist"
    FAILURES=$((FAILURES + 1))
fi

# B. Bridge
printf "\n  ${BOLD}B)  Bridge${R}\n\n"
if brctl show | grep -q "$NET_BRIDGE"; then
    ok "Bridge ${BOLD}$NET_BRIDGE${R} exists"
else
    err "Bridge $NET_BRIDGE not found"
    FAILURES=$((FAILURES + 1))
fi

_attached=$(bridge link 2>/dev/null | grep "master $NET_BRIDGE" | awk '{print $2}' | tr -d ':' || true)
if [ -n "$_attached" ]; then
    ok "Wireless interface attached  ->  ${BOLD}$_attached${R}"
else
    info "No wireless interface on $NET_BRIDGE yet  (normal until first client connects)"
fi

# C. DHCP leases
printf "\n  ${BOLD}C)  DHCP leases${R}\n\n"
if [ -f /tmp/dhcp.leases ]; then
    _good=$(grep " ${_subnet_base}\." /tmp/dhcp.leases || true)
    _bad=$(grep ' 169\.' /tmp/dhcp.leases || true)
    if [ -n "$_good" ]; then
        ok "Active Guest leases found:"
        echo "$_good" | while read -r _line; do
            printf "     ${GRAY}%s${R}\n" "$_line"
        done
    else
        info "No leases yet -- connect a device to test"
    fi
    if [ -n "$_bad" ]; then
        err "APIPA addresses detected (169.x.x.x) -- DHCP misconfigured"
        FAILURES=$((FAILURES + 1))
    fi
else
    info "No lease file yet  (dnsmasq may still be starting)"
fi

# D. Config completeness
printf "\n  ${BOLD}D)  Configuration completeness${R}\n\n"

_check() {
    if eval "$1" > /dev/null 2>&1; then
        ok "$2"
    else
        err "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

_check "uci show firewall.${UCI_PFX}_to_wan"   \
    "Forwarding  $FW_ZONE -> wan"               \
    "Missing forwarding $FW_ZONE -> wan"

_check "uci show firewall.${UCI_PFX}_allow_dhcp" \
    "Rule  Allow-DHCP-$FW_ZONE"                  \
    "Missing Allow-DHCP-$FW_ZONE  (clients won't get IPs)"

_check "uci show firewall.${UCI_PFX}_allow_dns"  \
    "Rule  Allow-DNS-$FW_ZONE"                   \
    "Missing Allow-DNS-$FW_ZONE  (clients won't resolve hostnames)"

_check "uci show dhcp.$NET_IFACE"              \
    "DHCP section  $NET_IFACE"                 \
    "DHCP section $NET_IFACE missing"

_check "ip link show $NET_BRIDGE"              \
    "Kernel bridge  $NET_BRIDGE"               \
    "$NET_BRIDGE not found in kernel"

_check "uci show wireless.${UCI_PFX}_wifi"     \
    "Wireless section  ${UCI_PFX}_wifi"        \
    "Wireless section ${UCI_PFX}_wifi missing"

_check "uci show firewall.${UCI_PFX}_block_ipv6" \
    "Rule  Block-IPv6-$FW_ZONE"                  \
    "Missing Block-IPv6-$FW_ZONE  (IPv6 bypass risk)"

# Verify NO forwardings to internal zones (Guest must be internet-only)
_leak=$(uci show firewall | grep "=forwarding" | cut -d'.' -f2 | cut -d'=' -f1 | while read -r _s; do
    _src=$(uci get firewall."$_s".src 2>/dev/null || true)
    _dst=$(uci get firewall."$_s".dest 2>/dev/null || true)
    if [ "$_src" = "$FW_ZONE" ] && [ "$_dst" != "wan" ]; then
        echo "$_s ($_src -> $_dst)"
    fi
done)
if [ -z "$_leak" ]; then
    ok "Isolation verified  ${GRAY}(no forwarding from $FW_ZONE except -> wan)${R}"
else
    err "ISOLATION LEAK -- found forwarding(s) outside wan:"
    echo "$_leak" | while read -r _line; do printf "       ${RED}%s${R}\n" "$_line"; done
    FAILURES=$((FAILURES + 1))
fi

_iso=$(uci get wireless."${UCI_PFX}_wifi".isolate 2>/dev/null || echo "0")
if [ "$_iso" = "1" ]; then
    ok "Client isolation enabled  ${GRAY}(isolate=1)${R}"
else
    err "Client isolation NOT enabled"
    FAILURES=$((FAILURES + 1))
fi

# E. Internet connectivity
printf "\n  ${BOLD}E)  Internet connectivity${R}\n\n"
_ping_ok=0
_ping_try=0
info "Testing router internet (WAN may need time to recover after restart)"
while [ "$_ping_try" -lt 3 ]; do
    _ping_try=$((_ping_try + 1))
    printf "  ${CYAN}->${R}  Attempt $_ping_try/3 -- pinging 8.8.8.8 ... "
    if ping -c2 -W5 8.8.8.8 > /dev/null 2>&1; then
        printf "${GREEN}reachable${R}\n"
        _ping_ok=1
        break
    fi
    printf "${RED}unreachable${R}\n"
    if [ "$_ping_try" -lt 3 ]; then
        info "Waiting 30 seconds before next attempt ..."
        sleep 30
    fi
done
if [ "$_ping_ok" = "1" ]; then
    ok "Router internet is up -- Guest clients will have internet via $NET_BRIDGE"
else
    err "Router cannot reach internet after 3 attempts"
    info "Check WAN connection -- Guest internet depends on router having internet"
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------
printf "\n"
if [ "$FAILURES" -eq 0 ]; then
    printf "${BOLD}${GREEN}  +=========================================================+${R}\n"
    printf "${BOLD}${GREEN}  |${R}  ${BOLD}${WHITE}[OK] ALL CHECKS PASSED${R}                                   ${BOLD}${GREEN}|${R}\n"
    printf "${BOLD}${GREEN}  |${R}  ${GREEN}$BAND Guest network is live and ready to use${R}           ${BOLD}${GREEN}|${R}\n"
    printf "${BOLD}${GREEN}  +=========================================================+${R}\n"
else
    printf "${BOLD}${RED}  +=========================================================+${R}\n"
    printf "${BOLD}${RED}  |${R}  ${BOLD}${WHITE}[!!] %d CHECK(S) FAILED${R}  -- review errors above            ${BOLD}${RED}|${R}\n" "$FAILURES"
    printf "${BOLD}${RED}  +=========================================================+${R}\n"
fi

printf "\n"
divider
printf "  ${BOLD}Network summary${R}\n"
divider
printf "  ${GRAY}Band        :${R}  ${BOLD}$BAND${R}\n"
printf "  ${GRAY}SSID        :${R}  ${BOLD}$NET_SSID${R}\n"
printf "  ${GRAY}Subnet      :${R}  ${_subnet_base}.0/24\n"
printf "  ${GRAY}Gateway     :${R}  $NET_IP\n"
printf "  ${GRAY}DHCP range  :${R}  ${_subnet_base}.${DHCP_START} - ${_subnet_base}.$((DHCP_START + DHCP_LIMIT - 1))\n"
printf "  ${GRAY}Bridge      :${R}  $NET_BRIDGE\n"
printf "  ${GRAY}Firewall    :${R}  input=REJECT  output=ACCEPT  forward=REJECT\n"
printf "  ${GRAY}Forwarding  :${R}  $FW_ZONE -> wan  ${GRAY}(internet only)${R}\n"
printf "  ${GRAY}IPv6        :${R}  ${GREEN}disabled${R}\n"
printf "  ${GRAY}Isolation   :${R}  ${GREEN}enabled${R}\n"
printf "\n"
divider
printf "  ${BOLD}Verify on your device${R}\n"
divider
printf "  ${CYAN}1${R}  Connect to  ${BOLD}$NET_SSID${R}\n"
printf "  ${CYAN}2${R}  Check IP is in  ${BOLD}${_subnet_base}.x${R}  range\n"
printf "  ${CYAN}3${R}  Open a browser -- internet should work\n"
printf "  ${CYAN}4${R}  Try pinging  ${BOLD}192.168.8.1${R} (LAN)  -- should ${RED}fail${R}\n"
printf "  ${CYAN}5${R}  Try pinging  ${BOLD}192.168.40.1${R} (Lab)  -- should ${RED}fail${R}\n"
printf "  ${CYAN}6${R}  Connect two Guest devices -- they should ${RED}not${R} see each other\n"
printf "\n"
