#!/usr/bin/env bash
# Run only in a disposable Linux environment with root + unshare privileges.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} != --namespace ]]; then
    exec unshare --net bash tests/integration.sh --namespace
fi
# shellcheck source=l2tp.sh
source ./l2tp.sh
WORK_DIR=$(mktemp -d)
daemon_pid=
finish() {
    if [[ -n $daemon_pid ]]; then kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; fi
    rm -rf -- "$WORK_DIR"
}
trap finish EXIT
VPN_USER=real
VPN_PASS=Abcdefghijk12345678
IPSEC_PSK=Abcdefghijklmnopqrstuvwxyz1234567
L2TP_PORT=18562
VPN_LOCAL_IP=192.168.18.1
VPN_CIDR=192.168.18.0/24
VPN_IP_RANGE=192.168.18.10-192.168.18.250
EGRESS_IF=ens3
render_configs "$WORK_DIR/render"
/usr/libexec/ipsec/addconn --config "$WORK_DIR/render/ipsec.conf" --checkconfig

ip link set lo up
ip link add ens3 type dummy
ip link set ens3 up
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -j DROP
iptables -t nat -A POSTROUTING -s 10.73.0.0/24 -j MASQUERADE
apply_iptables
iptables-save > "$WORK_DIR/once"
apply_iptables
iptables-save > "$WORK_DIR/twice"
# Counters and iptables-save timestamps vary, rules must not.
diff <(grep -v '^#' "$WORK_DIR/once") <(grep -v '^#' "$WORK_DIR/twice")
iptables -C INPUT -p tcp --dport 22 -j ACCEPT
iptables -C INPUT -j DROP
iptables -t nat -C POSTROUTING -s 10.73.0.0/24 -j MASQUERADE
L2TP_PORT=18563
apply_iptables
if iptables -C L2TP-IN -p udp --dport 18562 -j DROP; then exit 1; fi
iptables -C L2TP-IN -p udp --dport 18563 -j DROP
printf 'plaintext-test' > /dev/udp/127.0.0.1/18563
iptables -nvx -L L2TP-IN | awk '$3 == "DROP" && $1 > 0 {ok=1} END {exit !ok}'

cat > "$WORK_DIR/before.rules" <<'EOF'
*filter
:ufw-before-input - [0:0]
:ufw-before-forward - [0:0]
-A ufw-before-input -p tcp --dport 22 -j ACCEPT
COMMIT
EOF
render_ufw "$WORK_DIR/before.rules" "$WORK_DIR/merged.rules"
iptables-restore --test < "$WORK_DIR/merged.rules"
render_ufw "$WORK_DIR/merged.rules" "$WORK_DIR/merged-twice.rules"
cmp "$WORK_DIR/merged.rules" "$WORK_DIR/merged-twice.rules"

# Check actual xl2tpd parser/bind without starting any host VPN service.
xl2tpd -D -c "$WORK_DIR/render/xl2tpd.conf" -p "$WORK_DIR/xl2tpd.pid" -C "$WORK_DIR/control" > "$WORK_DIR/xl2tpd.log" 2>&1 &
daemon_pid=$!
sleep 2
kill -0 "$daemon_pid" || { cat "$WORK_DIR/xl2tpd.log"; exit 1; }
ss -H -luntp | grep ':18562 ' >/dev/null
echo 'IPsec/xl2tpd configuration and isolated iptables/UFW checks passed.'
