#!/bin/bash
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"
PEER_DB="/root/wg-peers-meta.csv"

###############################################################################
# 0. Get arguments & validate
###############################################################################
if [ $# -ne 1 ]; then
    echo "Usage: $0 <peer_name>"
    echo "peer_name: 1-50 characters, only [a-zA-Z0-9_-]"
    exit 1
fi

peer_name="$1"

# length check
name_len=${#peer_name}
if [ $name_len -lt 1 ] || [ $name_len -gt 50 ]; then
    echo "Error: peer_name length must be 1-50 characters. Given: $name_len"
    exit 1
fi

# character set check (only letters, numbers, underscore, dash)
if ! echo "$peer_name" | grep -Eq '^[a-zA-Z0-9_-]+$'; then
    echo "Error: peer_name must only contain [a-zA-Z0-9_-] characters (no spaces, no special characters)."
    exit 1
fi

# Check if the same name has been used before (prevent duplicate name)
if [ -f "$PEER_DB" ]; then
    if grep -E "^${peer_name}," "$PEER_DB" >/dev/null 2>&1; then
        echo "Error: '${peer_name}' name is already in use. Please choose a different name."
        exit 1
    fi
fi

###############################################################################
# helper: best-effort peer addition to wg0 interface
###############################################################################
best_effort_wg_set() {
    local pubkey="$1"
    local psk="$2"
    local next_ip="$3"

    if ! wg show wg0 >/dev/null 2>&1; then
        echo "WARNING: wg0 does not appear to be active. wg set could not be applied."
        echo "You can add it manually later:"
        echo "wg set wg0 peer ${pubkey} preshared-key <(echo \"${psk}\") allowed-ips \"10.2.53.${next_ip}/32, fc10:253::${next_ip}/128\""
        return 0
    fi

    if ! wg set wg0 peer "${pubkey}" \
        preshared-key <(echo "${psk}") \
        allowed-ips "10.2.53.${next_ip}/32, fc10:253::${next_ip}/128"; then
        echo "WARNING: wg set command failed but wg0.conf has been updated."
        echo "You can try again manually."
    fi
}

###############################################################################
# 1. Find server IP (keeping the logic to not prefer IPv6 if available)
###############################################################################
server_ip="$(ip -6 a s scope global eth0 | grep 'inet6 ' | awk -F'[ \t/]+' '{print $3}' || true)"
if [ -n "${server_ip:-}" ]; then
    server_ip="[${server_ip}]"
else
    server_ip="$(ip -4 a s scope global eth0 | grep 'inet ' | grep -v 'inet 10\.' | awk -F'[ \t/]+' '{print $3}')"
fi

###############################################################################
# 2. Find the next IP to use
###############################################################################
last_ip_raw="$(grep -E 'AllowedIPs = 10\.2\.53\.[0-9]+' "$WG_CONF" \
  | sed -E 's/.*10\.2\.53\.([0-9]+).*/\1/' \
  | sort -n \
  | tail -n1 || true)"

if [ -z "${last_ip_raw:-}" ]; then
    # If no peers exist, first client should be 10.2.53.2 (server is .1)
    last_ip=1
else
    last_ip="$last_ip_raw"
fi

next_ip=$(( last_ip + 1 ))

###############################################################################
# 3. Calculate server public key
###############################################################################
server_privkey="$(grep '^PrivateKey' "$WG_CONF" | awk '{print $3}')"
server_pubkey="$(echo "$server_privkey" | wg pubkey)"

###############################################################################
# 4. Generate new client keys
###############################################################################
client_privkey="$(wg genkey)"
client_pubkey="$(echo "$client_privkey" | wg pubkey)"
psk="$(wg genpsk)"

###############################################################################
# 5. Prepare client config templates
###############################################################################
conf_common="[Interface]
Address = 10.2.53.${next_ip}/32, fc10:253::${next_ip}/128
DNS = 10.2.53.1, fc10:253::1
PrivateKey = ${client_privkey}

[Peer]
Endpoint = ${server_ip}:51820
PersistentKeepalive = 25
PublicKey = ${server_pubkey}
PresharedKey = ${psk}"

dns_only="${conf_common}
AllowedIPs = 10.2.53.1/32, fc10:253::1/128"

full_vpn="${conf_common}
AllowedIPs = 0.0.0.0/0, ::/0"

# Associating file names with peer_name 💅
DNS_FILE="/root/${peer_name}-dns.conf"
FULL_FILE="/root/${peer_name}-full.conf"

echo "${dns_only}"  > "${DNS_FILE}"
echo "${full_vpn}" > "${FULL_FILE}"

chmod 600 "${DNS_FILE}" "${FULL_FILE}"

###############################################################################
# 6. Add new peer block to the end of wg0.conf
###############################################################################
cat <<EOF >> "${WG_CONF}"

# peer_name=${peer_name}
[Peer]
PublicKey = ${client_pubkey}
PresharedKey = ${psk}
AllowedIPs = 10.2.53.${next_ip}/32, fc10:253::${next_ip}/128
EOF

chmod 600 "${WG_CONF}"

###############################################################################
# 7. Save metadata (name -> pubkey -> ip)
#    Create CSV with header if it doesn't exist.
###############################################################################
if [ ! -f "$PEER_DB" ]; then
    echo "name,public_key,ip" > "$PEER_DB"
fi

echo "${peer_name},${client_pubkey},10.2.53.${next_ip}" >> "$PEER_DB"
chmod 600 "$PEER_DB"

###############################################################################
# 8. Try adding peer to live wg0 interface
###############################################################################
best_effort_wg_set "${client_pubkey}" "${psk}" "${next_ip}"

###############################################################################
# 9. Show results (QR + summary)
###############################################################################
echo
echo "=========== DNS ONLY (${peer_name}) ==========="
echo "${dns_only}" | qrencode -t utf8
echo "${dns_only}"
echo
echo "=========== FULL VPN (${peer_name}) ==========="
echo "${full_vpn}" | qrencode -t utf8
echo "${full_vpn}"
echo
echo "Saved:"
echo "  ${DNS_FILE}"
echo "  ${FULL_FILE}"
echo
echo "New peer:"
echo "  Name           : ${peer_name}"
echo "  PublicKey      : ${client_pubkey}"
echo "  IP (IPv4/IPv6) : 10.2.53.${next_ip}/32 , fc10:253::${next_ip}/128"
echo
echo "Server config added to /etc/wireguard/wg0.conf and PEER_DB updated:"
echo "  ${PEER_DB}"
echo
echo "If connection is not active:"
echo "  systemctl restart wg-quick@wg0"

