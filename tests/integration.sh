#!/usr/bin/env bash
# Run only in a disposable Linux environment with root + unshare privileges.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} != --namespace ]]; then
    exec unshare --net --mount bash tests/integration.sh --namespace
fi
mount --make-rprivate /
# shellcheck source=l2tp.sh
source ./l2tp.sh
WORK_DIR=$(mktemp -d)
daemon_pid=
pluto_pid=
client_ns=
finish() {
    if [[ -n $daemon_pid ]]; then kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; fi
    if [[ -n $pluto_pid ]]; then kill "$pluto_pid" 2>/dev/null || true; wait "$pluto_pid" 2>/dev/null || true; fi
    if [[ -n $client_ns ]]; then ip netns delete "$client_ns" || true; fi
    if [[ -f "$WORK_DIR/pluto.log" ]]; then cat "$WORK_DIR/pluto.log"; fi
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
configure_ipsec_version
render_configs "$WORK_DIR/render"
ipsec addconn --config "$WORK_DIR/render/ipsec.conf" --checkconfig

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

# Exercise a real enabled UFW and reload without touching the runner's /etc/ufw.
remove_owned_firewall
cp -a /etc/ufw "$WORK_DIR/ufw"
mount --bind "$WORK_DIR/ufw" /etc/ufw
ip address add 198.18.0.1/24 dev ens3
ip route add default via 198.18.0.254 dev ens3
ufw allow 22/tcp
ufw --force enable
OLD_BACKEND=ufw
sysctl -w net.ipv4.ip_forward=0
apply_firewall
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]
[[ $FIREWALL_BACKEND == ufw ]]
ufw reload
iptables -C L2TP-IN -p udp --dport 18563 -m policy --dir in --pol ipsec -j ACCEPT
iptables -C L2TP-IN -p udp --dport 18563 -j DROP
iptables -C ufw-user-input -p tcp --dport 22 -j ACCEPT
[[ $(iptables -S ufw-before-input | grep -c -- '-j L2TP-IN') == 1 ]]
[[ $(iptables -S L2TP-IN | grep -c -- '^-A ') == 4 ]]
echo 'IPsec/xl2tpd configuration and isolated iptables/active UFW checks passed.'

# Reproduce the captured iKuai zero-duration IKEv1 PSK offer.
client_ns=l2tp-zero-$$
ip netns add "$client_ns"
ip link add zero-server type veth peer name zero-client
ip link set zero-client netns "$client_ns"
ip address add 198.19.0.1/24 dev zero-server
ip link set zero-server up
# Keep the protocol test independent of the earlier synthetic INPUT DROP.
iptables -I INPUT 1 -i zero-server -p udp --dport 500 -j ACCEPT
ip netns exec "$client_ns" ip link set lo up
ip netns exec "$client_ns" ip address add 198.19.0.2/24 dev zero-client
ip netns exec "$client_ns" ip link set zero-client up
mkdir -p "$WORK_DIR/nss" "$WORK_DIR/pluto"
certutil -N -d "sql:$WORK_DIR/nss" --empty-password
cat > "$WORK_DIR/zero.conf" <<'EOF'
config setup
    ikev1-policy=accept
conn zero-test
    authby=secret
    ikev2=never
    type=transport
    left=198.19.0.1
    leftprotoport=17/18563
    right=%any
    rightprotoport=17/%any
    ike=aes128-sha2_256;modp3072
    esp=aes128-sha2_256
    pfs=no
    rekey=no
    ikelifetime=8h
    salifetime=1h
    auto=add
EOF
printf '%%any %%any : PSK "ZeroLifetimeTest123"\n' > "$WORK_DIR/zero.secrets"
"$LIBRESWAN_PREFIX/libexec/ipsec/pluto" --nofork --stderrlog \
    --config "$WORK_DIR/zero.conf" --secretsfile "$WORK_DIR/zero.secrets" \
    --nssdir "$WORK_DIR/nss" --rundir "$WORK_DIR/pluto" > "$WORK_DIR/pluto.log" 2>&1 &
pluto_pid=$!
for attempt in {1..50}; do
    [[ -S "$WORK_DIR/pluto/pluto.ctl" ]] && break
    sleep 0.2
done
"$LIBRESWAN_PREFIX/libexec/ipsec/addconn" --config "$WORK_DIR/zero.conf" --ctlsocket "$WORK_DIR/pluto/pluto.ctl" --autoall
ip netns exec "$client_ns" python3 tests/ike_zero_lifetime.py 198.19.0.1 198.19.0.2 ZeroLifetimeTest123
sleep 3
"$LIBRESWAN_PREFIX/libexec/ipsec/whack" --ctlsocket "$WORK_DIR/pluto/pluto.ctl" --status > "$WORK_DIR/zero-status"
grep -E '(ISAKMP|IKE) SA established' "$WORK_DIR/zero-status"
grep -F 'IPsec SA established' "$WORK_DIR/zero-status"
grep -F 'zero IKE lifetime normalized' "$WORK_DIR/pluto.log"
if grep -F 'IKE SA expired' "$WORK_DIR/pluto.log"; then exit 1; fi
echo 'PASS zero-lifetime IKE SA survives authentication'

# Nonzero lifetimes must retain their original negotiated value.
ip netns exec "$client_ns" python3 tests/ike_zero_lifetime.py 198.19.0.1 198.19.0.2 ZeroLifetimeTest123 120
