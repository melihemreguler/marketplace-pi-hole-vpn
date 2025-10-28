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

name_len=${#peer_name}
if [ $name_len -lt 1 ] || [ $name_len -gt 50 ]; then
    echo "Error: peer_name length must be 1-50 characters. Given: $name_len"
    exit 1
fi

if ! echo "$peer_name" | grep -Eq '^[a-zA-Z0-9_-]+$'; then
    echo "Error: peer_name must only contain [a-zA-Z0-9_-] characters (no spaces, no special characters)."
    exit 1
fi

###############################################################################
# 1. Find record in PEER_DB
###############################################################################
if [ ! -f "$PEER_DB" ]; then
    echo "Error: peer database (${PEER_DB}) not found. No record to delete."
    exit 1
fi

# CSV format:
# name,public_key,ip
# melih-macbook-m1,T09q...,10.2.53.2
record_line="$(grep -E "^${peer_name}," "$PEER_DB" || true)"

if [ -z "${record_line}" ]; then
    echo "Error: peer named '${peer_name}' not found (not in ${PEER_DB})."
    exit 1
fi

peer_pubkey="$(echo "$record_line" | awk -F',' '{print $2}')"
peer_ip="$(echo "$record_line" | awk -F',' '{print $3}')"

###############################################################################
# 2. Try to remove peer from live wg0 interface
###############################################################################
if wg show wg0 >/dev/null 2>&1; then
    if wg set wg0 peer "${peer_pubkey}" remove 2>/dev/null; then
        echo "Peer removed from live wg0 interface (${peer_name})."
    else
        echo "WARNING: wg set wg0 peer ... remove command failed but continuing."
    fi
else
    echo "WARNING: wg0 does not appear to be active, skipping removal from live interface."
fi

###############################################################################
# 3. Delete this peer block from /etc/wireguard/wg0.conf
###############################################################################
if [ ! -f "$WG_CONF" ]; then
    echo "WARNING: ${WG_CONF} not found, could not remove from config."
else
    tmp_conf="$(mktemp)"

    awk -v target_name="$peer_name" '
        BEGIN {
            # skip_mode anlamı:
            # 0 = normal yaz
            # 1 = "# peer_name=target_name" görüldü, bu peeri SKIP etmeye başla
            # 2 = AllowedIPs satırına kadar hala SKIPteyiz
            # 3 = AllowedIPs satırı da yutuldu, bir sonraki muhtemel boş satırı da yut
        }
        {
            if ($0 ~ "^# peer_name=" target_name "$") {
                skip_mode = 1
                next
            }

            if (skip_mode == 1) {
                # bu bloktaki satırları AllowedIPs satırına kadar yut
                if ($0 ~ /^AllowedIPs[[:space:]]*=/) {
                    skip_mode = 3
                } else {
                    skip_mode = 2
                }
                next
            }

            if (skip_mode == 2) {
                # AllowedIPs henüz gelmedi, hâlâ yutuyoruz
                if ($0 ~ /^AllowedIPs[[:space:]]*=/) {
                    skip_mode = 3
                }
                next
            }

            if (skip_mode == 3) {
                # AllowedIPs satırını da yuttuk.
                # Bu aşamada genelde boş satır geliyor; onu da yut, sonra normale dön.
                if ($0 ~ /^[[:space:]]*$/) {
                    # boş satırı da yut
                    skip_mode = 0
                    next
                } else {
                    # boş satır yokmuş, direkt normale dön
                    skip_mode = 0
                    # IMPORTANT: bu satırı işlemeye devam edeceğiz
                }
            }

            # normal moda geri döndüysek yazdır
            print $0
        }
    ' "$WG_CONF" > "$tmp_conf"

    mv "$tmp_conf" "$WG_CONF"
    chmod 600 "$WG_CONF"

    echo "Peer block '${peer_name}' removed from ${WG_CONF}."
fi

###############################################################################
# 4. Delete this record from PEER_DB and update file
#
# Here we write with awk so that:
# - header (first line) stays the same
# - matching peer_name line is dropped
###############################################################################
tmp_db="$(mktemp)"

awk -F',' -v target_name="$peer_name" 'NR==1 { print $0; next } $1 != target_name { print $0 }' "$PEER_DB" > "$tmp_db"

mv "$tmp_db" "$PEER_DB"
chmod 600 "$PEER_DB"

echo "Record '${peer_name}' removed from ${PEER_DB}."

###############################################################################
# 5. Summary + new status
###############################################################################
echo
echo "Peer removed ✅"
echo "  Name      : ${peer_name}"
echo "  PublicKey : ${peer_pubkey}"
echo "  IP        : ${peer_ip}"
echo
echo "Current peer list (${PEER_DB}):"
cat "$PEER_DB" || true
echo
echo "Note:"
echo "- wg0.conf has been updated."
echo "- The CSV above has been updated."
echo "- If you want to restart the wg0 service:"
echo "    systemctl restart wg-quick@wg0"
