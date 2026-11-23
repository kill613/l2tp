#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $EUID == 0 ]] || { echo '请以 root 执行。' >&2; exit 1; }
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || {
    echo '此修复版已针对 Ubuntu 22.04 的发行版软件包编写。' >&2
    exit 1
}
exec 9>/run/lock/l2tp-deploy.lock
flock -n 9 || { echo '已有部署正在运行。' >&2; exit 1; }

if [[ -f /etc/l2tp-deploy/client.txt ]]; then
    systemctl is-active --quiet l2tp-network.service
    systemctl is-active --quiet ipsec.service
    systemctl is-active --quiet xl2tpd.service
    echo 'L2TP 已部署。连接资料在 /etc/l2tp-deploy/client.txt。'
    exit 0
fi

if systemctl is-active --quiet ipsec.service ||
   ip -o link show | grep -E ': ppp[0-9]+:' >/dev/null; then
    echo '检测到在用 IPsec 或 PPP，停止以免覆盖现有 VPN。' >&2
    exit 1
fi
if { command -v ufw >/dev/null && LC_ALL=C ufw status | grep -F 'Status: active' >/dev/null; } ||
   systemctl is-active --quiet firewalld.service ||
   systemctl is-active --quiet nftables.service ||
   [[ $(iptables -S INPUT | head -n 1) != '-P INPUT ACCEPT' ]] ||
   [[ $(iptables -S FORWARD | head -n 1) != '-P FORWARD ACCEPT' ]]; then
    echo '检测到需要单独集成的主机防火墙，未修改配置。' >&2
    exit 1
fi

public_ip=${VPN_PUBLIC_IP:-}
if [[ -z $public_ip ]]; then
    read -r -p '输入云控制台显示的公网 IPv4: ' public_ip </dev/tty
fi
route=$(ip -4 route get 1.1.1.1)
egress=$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$route")
[[ $egress =~ ^[[:alnum:]_.:-]+$ ]] || { echo '无法识别出网接口。' >&2; exit 1; }
python3 - "$public_ip" <<'PY'
import ipaddress
import json
import subprocess
import sys

public = ipaddress.IPv4Address(sys.argv[1])
if not public.is_global or public.is_multicast:
    sys.exit("请输入云控制台中绑定到服务器的公网 IPv4。")
pool = ipaddress.IPv4Network("192.168.18.0/24")
for route in json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "show", "table", "main"])):
    dst = route.get("dst", "default")
    if dst != "default" and ipaddress.IPv4Network(dst, strict=False).overlaps(pool):
        sys.exit(f"VPN 地址池和路由 {dst} 重叠，安装已停止。")
PY

# Use the system's signed APT sources, including its configured domestic mirror.
if ! dpkg-query -W -f='${db:Status-Status}\n' libreswan xl2tpd ppp openssl 2>/dev/null |
    awk '$0 == "installed" {n++} END {exit n != 4}'; then
    apt-get -o Acquire::Retries=2 update
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 install -y libreswan xl2tpd ppp openssl
fi

backup=$(mktemp -d /root/l2tp-backup.XXXXXX)
stage=$(mktemp -d)
files=(
    /etc/ipsec.conf /etc/ipsec.secrets
    /etc/xl2tpd/xl2tpd.conf /etc/ppp/options.xl2tpd /etc/ppp/chap-secrets
    /usr/local/libexec/l2tp-network
    /etc/systemd/system/l2tp-network.service
    /etc/systemd/system/ipsec.service.d/80-l2tp-network.conf
    /etc/systemd/system/xl2tpd.service.d/80-l2tp-network.conf
    /etc/l2tp-deploy/client.txt
)
forward_before=$(sysctl -n net.ipv4.ip_forward)
systemctl is-active --quiet xl2tpd.service && xl2tpd_was_active=1 || xl2tpd_was_active=0
systemctl is-enabled --quiet ipsec.service && ipsec_was_enabled=1 || ipsec_was_enabled=0
systemctl is-enabled --quiet xl2tpd.service && xl2tpd_was_enabled=1 || xl2tpd_was_enabled=0
changed=0
cleanup() {
    local status=$?
    if (( status && changed )); then
        echo "部署失败，正在恢复配置。备份位于 $backup" >&2
        systemctl stop ipsec.service xl2tpd.service l2tp-network.service || true
        local file
        for file in "${files[@]}"; do
            if [[ -e "$backup$file" || -L "$backup$file" ]]; then
                cp -a --remove-destination "$backup$file" "$file" || echo "恢复失败：$file" >&2
            else
                rm -f -- "$file"
            fi
        done
        sysctl -w "net.ipv4.ip_forward=$forward_before" >/dev/null || true
        systemctl daemon-reload || true
        (( ipsec_was_enabled )) || systemctl disable ipsec.service || true
        (( xl2tpd_was_enabled )) || systemctl disable xl2tpd.service || true
        if (( xl2tpd_was_active )); then systemctl start xl2tpd.service || true; fi
    fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for file in "${files[@]}"; do
    if [[ -e $file || -L $file ]]; then cp -a --parents "$file" "$backup/"; fi
done
iptables-save > "$backup/iptables.rules"

psk=$(openssl rand -hex 24)
password=$(openssl rand -hex 16)
cat > "$stage/ipsec.conf" <<EOF_IPSEC
config setup

conn l2tp-psk
    auto=add
    type=transport
    authby=secret
    ikev2=never
    left=%defaultroute
    leftid=$public_ip
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    pfs=no
    rekey=no
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
EOF_IPSEC
ipsec addconn --config "$stage/ipsec.conf" --checkconfig
printf '%s %%any : PSK "%s"\n' "$public_ip" "$psk" > "$stage/ipsec.secrets"
cat > "$stage/xl2tpd.conf" <<'EOF_XL2TPD'
[global]
port = 1701

[lns default]
ip range = 192.168.18.10-192.168.18.100
local ip = 192.168.18.1
require authentication = yes
refuse pap = yes
pppoptfile = /etc/ppp/options.xl2tpd
EOF_XL2TPD
cat > "$stage/options.xl2tpd" <<'EOF_PPP'
name l2tpd
auth
require-mschap-v2
ms-dns 223.5.5.5
ms-dns 1.1.1.1
mtu 1400
mru 1400
EOF_PPP
if [[ -f /etc/ppp/chap-secrets ]]; then
    awk '!($1 == "vpnuser" && ($2 == "l2tpd" || $2 == "*"))' /etc/ppp/chap-secrets > "$stage/chap-secrets"
fi
printf 'vpnuser l2tpd "%s" *\n' "$password" >> "$stage/chap-secrets"
printf '服务器: %s\n用户名: vpnuser\n密码: %s\n预共享密钥: %s\n' "$public_ip" "$password" "$psk" > "$stage/client.txt"

cat > "$stage/l2tp-network" <<'EOF_NET'
#!/usr/bin/env bash
set -euo pipefail
guard=(-p udp --dport 1701 -m policy --dir in --pol none -m comment --comment l2tp-deploy -j DROP)
nat=(-s 192.168.18.0/24 -o "$2" -m comment --comment l2tp-deploy -j MASQUERADE)
remove_rules() {
    if iptables -w -C INPUT "${guard[@]}" 2>/dev/null; then iptables -w -D INPUT "${guard[@]}"; fi
    if iptables -w -t nat -C POSTROUTING "${nat[@]}" 2>/dev/null; then
        iptables -w -t nat -D POSTROUTING "${nat[@]}"
    fi
}
case $1 in
    start)
        trap 'remove_rules' ERR
        iptables -w -C INPUT "${guard[@]}" 2>/dev/null || iptables -w -I INPUT 1 "${guard[@]}"
        iptables -w -t nat -C POSTROUTING "${nat[@]}" 2>/dev/null ||
            iptables -w -t nat -A POSTROUTING "${nat[@]}"
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        ;;
    stop)
        remove_rules
        ;;
    *) exit 2 ;;
esac
EOF_NET
cat > "$stage/l2tp-network.service" <<EOF_UNIT
[Unit]
Description=L2TP IPsec firewall and IPv4 forwarding
Wants=network-online.target
After=network-online.target
Before=ipsec.service xl2tpd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/l2tp-network start $egress
ExecStop=/usr/local/libexec/l2tp-network stop $egress
EOF_UNIT
cat > "$stage/80-l2tp-network.conf" <<'EOF_DROPIN'
[Unit]
Requires=l2tp-network.service
After=l2tp-network.service
EOF_DROPIN

changed=1
install -d -m 700 /etc/l2tp-deploy
install -d -m 755 /usr/local/libexec /etc/systemd/system/ipsec.service.d /etc/systemd/system/xl2tpd.service.d
for file in "${files[@]}"; do
    [[ $file == /etc/l2tp-deploy/client.txt ]] && continue
    mode=644
    case $file in
        */ipsec.secrets|*/chap-secrets) mode=600 ;;
        /usr/local/libexec/l2tp-network) mode=755 ;;
    esac
    install -m "$mode" "$stage/${file##*/}" "$file"
done
systemctl daemon-reload
systemctl restart l2tp-network.service
systemctl restart ipsec.service xl2tpd.service
for unit in l2tp-network ipsec xl2tpd; do systemctl is-active --quiet "$unit.service"; done
state=$(ipsec status)
grep -F 'l2tp-psk' <<< "$state" >/dev/null
for port in 500 4500 1701; do
    for attempt in {1..50}; do
        [[ -n $(ss -H -lun "sport = :$port") ]] && break
        sleep 0.2
    done
    [[ -n $(ss -H -lun "sport = :$port") ]] || { echo "UDP $port 未监听。" >&2; exit 1; }
done
systemctl enable ipsec.service xl2tpd.service
install -m 600 "$stage/client.txt" /etc/l2tp-deploy/client.txt
changed=0

echo "部署完成。备份位于 $backup。"
echo '云安全组允许测试客户端的 UDP 500/4500，公网 UDP 1701 保持关闭。'
echo '仅在自己的终端运行 cat /etc/l2tp-deploy/client.txt 查看连接信息。'
