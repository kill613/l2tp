#!/usr/bin/env bash
# Ubuntu 22.04/24.04 L2TP/IPsec installer for iKuai.
# Original repository: https://github.com/kill613/l2tp
set -Eeuo pipefail
export LC_ALL=C
umask 077

CONFIG_DIR=/etc/l2tp-installer
CONFIG_FILE=$CONFIG_DIR/config
RUNTIME=/usr/local/libexec/l2tp-installer
RECONFIGURE=0
WORK_DIR=
BACKUP_DIR=
CHANGED=0
COMMITTED=0
POLICY_CREATED=0
LEGACY=0
OLD_PORT=
OLD_BACKEND=
STEP=初始化
KEYS=(VPN_USER VPN_PASS IPSEC_PSK L2TP_PORT VPN_LOCAL_IP VPN_CIDR VPN_IP_RANGE FIREWALL_BACKEND)

log() { printf '%s\n' "$*" >&2; }
die() { log "错误：$*"; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT ERR INT TERM
    if (( POLICY_CREATED )); then rm -f -- /usr/sbin/policy-rc.d; fi
    if (( rc != 0 )); then
        log "失败步骤：$STEP（退出码 $rc）。未宣告安装成功。"
        if (( CHANGED && ! COMMITTED )) && [[ -n $BACKUP_DIR ]]; then
            log "正在恢复修改前的配置：$BACKUP_DIR"
            while IFS= read -r path; do
                if [[ -e $BACKUP_DIR/files$path ]]; then
                    cp -a -- "$BACKUP_DIR/files$path" "$path" || log "恢复失败：$path"
                else
                    rm -f -- "$path"
                fi
            done < "$BACKUP_DIR/manifest"
            systemctl daemon-reload || true
            # Restore only our chains, never flush the host's firewall.
            if [[ -f $CONFIG_FILE && -x $RUNTIME ]]; then
                "$RUNTIME" --apply-firewall || log '旧防火墙恢复失败，请检查备份。'
            elif [[ ${FIREWALL_BACKEND:-} == iptables ]]; then
                remove_owned_firewall || true
            fi
            if [[ ${FIREWALL_BACKEND:-} == ufw ]]; then ufw reload || true; fi
            if [[ -f $BACKUP_DIR/services ]]; then
                while read -r unit enabled active; do
                    if [[ $enabled == enabled ]]; then
                        systemctl enable "$unit" || true
                    else
                        systemctl disable "$unit" || true
                    fi
                    if [[ $active == active ]]; then
                        systemctl restart "$unit" || true
                    else
                        systemctl stop "$unit" || true
                    fi
                done < "$BACKUP_DIR/services"
            fi
            # Restore the three live sysctl values as well as their config file.
            if [[ -f $BACKUP_DIR/sysctl ]]; then
                while read -r key value; do sysctl -w "$key=$value" >/dev/null || true; done < "$BACKUP_DIR/sysctl"
            fi
        fi
        [[ -z $BACKUP_DIR ]] || log "备份目录：$BACKUP_DIR（含凭据，仅 root 可读）"
    fi
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
    exit "$rc"
}

random_secret() {
    local length=$1 value
    # Read bounded blocks: no tr | head SIGPIPE under pipefail, no Bash $RANDOM.
    while :; do
        value=$(od -An -N256 -tu1 /dev/urandom | awk '
            {for(i=1;i<=NF;i++) if($i<248) printf "%s", substr("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",$i%62+1,1)}')
        value=${value:0:length}
        if [[ ${#value} == "$length" && $value == *[A-Z]* && $value == *[a-z]* && $value == *[0-9]* ]]; then
            printf '%s' "$value"
            return
        fi
    done
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 1 <= $1 && $1 <= 65535 )); }
port_busy() {
    # Both TCP and UDP are avoided; include non-listening bound UDP sockets.
    ss -H -anlut | awk -v port="$1" '$5 ~ (":" port "$") {found=1} END {exit !found}'
}
pick_port() {
    local low high n candidate
    read -r low high < "${1:-/proc/sys/net/ipv4/ip_local_port_range}"
    for ((n=0; n<1000; n++)); do
        candidate=$(od -An -N4 -tu4 /dev/urandom)
        candidate=$((10000 + candidate % 50001))
        (( candidate < low || candidate > high )) || continue
        [[ $candidate != "${OLD_PORT:-}" ]] || continue
        if ! port_busy "$candidate"; then printf '%s' "$candidate"; return; fi
    done
    die '无法找到空闲随机端口，请通过 L2TP_PORT 指定。'
}

quote_ppp() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

validate_values() {
    [[ ${VPN_USER:-} =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,63}$ ]] || die '账户须为 1–64 位英文、数字或 _.@-，首位为英文或数字。'
    local key value
    for key in VPN_PASS IPSEC_PSK; do
        value=${!key:-}
        [[ ${#value} -ge 8 && ${#value} -le 128 && $value != *[![:print:]]* ]] || die "$key 须为 8–128 位可打印 ASCII 字符。"
    done
    valid_port "${L2TP_PORT:-}" || die 'L2TP_PORT 须为 1–65535 的整数。'
    [[ $L2TP_PORT != 500 && $L2TP_PORT != 4500 ]] || die 'L2TP 端口不能与 IPsec 的 500/4500 冲突。'
}

save_config() {
    local target=$1 key
    {
        printf '# Managed by l2tp-installer; root only.\n'
        for key in "${KEYS[@]}"; do printf '%s=%q\n' "$key" "${!key}"; done
    } > "$target"
    chmod 600 "$target"
}

load_config() {
    local target=$1
    [[ -f $target && ! -L $target && $(stat -c %u "$target") == 0 ]] || die '配置必须是 root 拥有的普通文件。'
    (( (8#$(stat -c %a "$target") & 077) == 0 )) || die '配置权限须为 600。'
    # Only our root-owned, private, generated state is sourced; never user input.
    # shellcheck disable=SC1090
    source "$target"
    local key
    for key in "${KEYS[@]}"; do [[ -n ${!key:-} ]] || die "保存的配置缺少 $key。"; done
    validate_values
    [[ $FIREWALL_BACKEND == ufw || $FIREWALL_BACKEND == iptables ]] || die '未知防火墙后端。'
}

ask_settings() {
    local answer
    if [[ -t 0 && ${NONINTERACTIVE:-0} != 1 ]]; then
        if [[ -z ${VPN_USER:-} ]]; then read -r -p 'VPN 账户 [real]：' answer; VPN_USER=${answer:-real}; fi
        if [[ -z ${VPN_PASS:-} ]]; then read -r -s -p 'VPN 密码 [留空随机生成 18 位]：' answer; log ''; VPN_PASS=$answer; fi
        if [[ -z ${IPSEC_PSK:-} ]]; then read -r -s -p 'IPsec PSK [留空随机生成 32 位]：' answer; log ''; IPSEC_PSK=$answer; fi
    fi
    VPN_USER=${VPN_USER:-real}
    VPN_PASS=${VPN_PASS:-$(random_secret 18)}
    IPSEC_PSK=${IPSEC_PSK:-$(random_secret 32)}
    L2TP_PORT=${L2TP_PORT:-$(pick_port /proc/sys/net/ipv4/ip_local_port_range)}
    VPN_LOCAL_IP=${VPN_LOCAL_IP:-192.168.18.1}
    VPN_CIDR=${VPN_CIDR:-192.168.18.0/24}
    VPN_IP_RANGE=${VPN_IP_RANGE:-192.168.18.10-192.168.18.250}
    validate_values
}

detect_backend() {
    local rules
    if systemctl is-active --quiet firewalld || systemctl is-enabled --quiet firewalld 2>/dev/null; then
        die '检测到 firewalld，本脚本仅管理 UFW 或 iptables，未修改规则。'
    fi
    if command -v nft >/dev/null; then
        rules=$(nft list tables) || die '无法检查 nftables。'
        # iptables-nft compatibility tables are supported; native tables are not.
        if [[ -n $(printf '%s\n' "$rules" | grep -Ev '^table ip6? (filter|nat|mangle|raw|security)$|^$' || true) ]]; then
            die '检测到原生 nftables 表，请先明确规则管理方式，避免多套防火墙冲突。'
        fi
    fi
    if systemctl is-enabled --quiet nftables 2>/dev/null || systemctl is-active --quiet nftables; then
        die '检测到 nftables.service，请先明确规则管理方式。'
    fi
    FIREWALL_BACKEND=iptables
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then FIREWALL_BACKEND=ufw; fi
    [[ -z $OLD_BACKEND || $OLD_BACKEND == "$FIREWALL_BACKEND" ]] || die '防火墙管理方式已变化，请先迁移原有规则。'
}

preflight() {
    [[ $(id -u) == 0 ]] || die '请使用 root 或 sudo bash l2tp.sh 运行。'
    [[ -f /etc/os-release ]] || die '无法识别系统。'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == ubuntu && ($VERSION_ID == 22.04 || $VERSION_ID == 24.04) ]] || die '仅支持 Ubuntu 22.04/24.04。'
    CODENAME=$VERSION_CODENAME
    ARCH=$(dpkg --print-architecture)
    [[ $ARCH == amd64 || $ARCH == arm64 ]] || die '仅支持 amd64/arm64。'
    [[ -d /run/systemd/system ]] || die '需要运行 systemd 的完整 Ubuntu 系统。'
    [[ -f ${BASH_SOURCE[0]} ]] || die '请先下载脚本到文件后再运行。'
    local command_name
    for command_name in ip ss flock timeout gpgv; do command -v "$command_name" >/dev/null || die "缺少基础命令 $command_name。"; done
    [[ -x /usr/lib/apt/apt-helper && -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] || die '缺少 APT 下载组件或 Ubuntu 签名密钥。'
    exec 9>/run/lock/l2tp-installer.lock
    flock -n 9 || die '另一安装进程正在运行。'
    for command_name in strongswan-starter strongswan-charon charon-systemd; do
        if dpkg-query -W -f='${db:Status-Status}\n' "$command_name" 2>/dev/null | grep -qx installed; then
            die '检测到 strongSwan，安装 Libreswan 会替换其他 IPsec 组件，请先处理现有部署。'
        fi
    done
    if [[ -x /usr/local/sbin/ipsec || -x /usr/local/libexec/ipsec/pluto ]]; then
        die '检测到旧版源码安装的 IPsec。请先备份并卸载该源码版本，避免与系统软件包同时运行。'
    fi
    detect_backend
}

detect_existing() {
    local conns xlsections file
    conns=$(sed -nE 's/^[[:space:]]*conn[[:space:]]+([^[:space:]]+).*/\1/p' /etc/ipsec.conf 2>/dev/null || true)
    xlsections=$(grep -E '^\[' /etc/xl2tpd/xl2tpd.conf 2>/dev/null || true)
    for file in /etc/ipsec.d/*.conf; do
        [[ ! -f $file ]] || ! grep -qE '^[[:space:]]*conn[[:space:]]' "$file" || die "检测到其他 IPsec 配置：$file。"
    done
    if [[ -f $CONFIG_FILE ]]; then
        [[ $conns == l2tp-ikuai && $xlsections == $'[global]\n[lns default]' ]] || die '现有配置已被外部修改，请先检查后再运行。'
        return
    fi
    if [[ -z $conns && -z $xlsections ]]; then return; fi
    [[ $conns == L2TP-PSK-NAT && $xlsections == $'[global]\n[lns default]' ]] || die '发现无法明确识别的 VPN 配置，未覆盖。'
    LEGACY=1
}

import_legacy() {
    # Recognize only the original repository's single-account deployment.
    python3 - "$WORK_DIR/import" <<'PY'
import ipaddress, pathlib, re, shlex, sys
def read(p):
    return pathlib.Path(p).read_text()
def fail():
    sys.exit('旧配置无法安全识别；未覆盖。请检查单账户、PSK 和地址池。')
try:
    rows = [shlex.split(s, comments=True) for s in read('/etc/ppp/chap-secrets').splitlines()]
    rows = [r for r in rows if r]
    if len(rows) != 1 or len(rows[0]) != 4 or rows[0][1::2] != ['*', '*']: fail()
    secrets = [s.strip() for s in read('/etc/ipsec.secrets').splitlines() if s.strip() and not s.lstrip().startswith('#')]
    if len(secrets) != 1: fail()
    match = re.fullmatch(r':\s*PSK\s+"([^"\\]+)"', secrets[0])
    if not match: fail()
    xl = read('/etc/xl2tpd/xl2tpd.conf')
    def one(key):
        values = re.findall(r'^\s*' + key + r'\s*=\s*(\S+)\s*$', xl, re.M)
        if len(values) != 1: fail()
        return values[0]
    local = one('local ip')
    pool = one('ip range')
    if '/' in pool:
        network = ipaddress.IPv4Network(pool)
        if network.prefixlen != 24: fail()
        pool = f'{network.network_address + 10}-{network.network_address + 250}'
    else:
        network = ipaddress.IPv4Network(f'{local}/24', strict=False)
    ports = re.findall(r'^\s*port\s*=\s*(\d+)\s*$', xl, re.M)
    if len(ports) > 1: fail()
    values = dict(VPN_USER=rows[0][0], VPN_PASS=rows[0][2], IPSEC_PSK=match[1],
                  VPN_LOCAL_IP=local, VPN_CIDR=str(network), VPN_IP_RANGE=pool,
                  L2TP_PORT=ports[0] if ports else '1701')
    pathlib.Path(sys.argv[1]).write_text(''.join(f'{k}={shlex.quote(v)}\n' for k,v in values.items()))
except (ValueError, OSError):
    fail()
PY
    # shellcheck disable=SC1091
    source "$WORK_DIR/import"
    validate_values
    log '已导入旧版单账户配置；普通运行保留原端口与凭据。'
}

apt_options() {
    APT_OPTS=(-o "Dir::Etc::sourcelist=$WORK_DIR/sources.list" -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=$WORK_DIR/lists" -o APT::Get::List-Cleanup=0
        -o Acquire::Retries=0 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15
        -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any -o Dpkg::Options::=--force-confold)
}

write_sources() {
    local base=$1 security=$2
    cat > "$WORK_DIR/sources.list" <<EOF
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $base $CODENAME main universe
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $base $CODENAME-updates main universe
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $security $CODENAME-security main universe
EOF
}

try_mirror() {
    local base=$1 security=$2 attempt
    write_sources "$base" "$security"
    for attempt in 1 2 3; do
        log "软件源：$base（第 $attempt/3 次）"
        # A private list directory prevents using stale indexes from another mirror.
        rm -rf -- "$WORK_DIR/lists"
        mkdir -p "$WORK_DIR/lists/partial"
        chmod 755 "$WORK_DIR/lists" "$WORK_DIR/lists/partial"
        if timeout 300 apt-get "${APT_OPTS[@]}" update &&
            DEBIAN_FRONTEND=noninteractive timeout 900 apt-get "${APT_OPTS[@]}" install -y --no-remove --no-install-recommends \
                libreswan xl2tpd ppp iptables python3 curl ca-certificates; then
            return 0
        fi
        if ((attempt < 3)); then sleep "$((attempt * 2))"; fi
    done
    return 1
}

install_packages() {
    local suffix official security base started elapsed _elapsed
    local -a candidates
    if [[ $ARCH == amd64 ]]; then
        suffix=ubuntu
        official=http://archive.ubuntu.com/ubuntu
        security=http://security.ubuntu.com/ubuntu
    else
        suffix=ubuntu-ports
        official=http://ports.ubuntu.com/ubuntu-ports
        security=$official
    fi
    candidates=("https://mirrors.tuna.tsinghua.edu.cn/$suffix" "https://mirrors.ustc.edu.cn/$suffix" "https://mirrors.aliyun.com/$suffix")
    create_package_policy
    : > "$WORK_DIR/ranking"
    for base in "${candidates[@]}"; do
        started=$(date +%s%N)
        if probe_mirror "$base"; then
            elapsed=$(( ($(date +%s%N) - started) / 1000000 ))
            log "镜像探测：$base，签名有效，${elapsed}ms"
            printf '%s %s\n' "$elapsed" "$base" >> "$WORK_DIR/ranking"
        else
            log "镜像暂不可用：$base；保留为后续重试候选。"
            printf '999999 %s\n' "$base" >> "$WORK_DIR/ranking"
        fi
        rm -f -- "$WORK_DIR/probe"
    done
    apt_options
    while read -r _elapsed base; do
        if try_mirror "$base" "$base"; then finish_package_install; return; fi
    done < <(sort -sn -k1,1 "$WORK_DIR/ranking")
    if try_mirror "$official" "$security"; then finish_package_install; return; fi
    die '所有镜像及官方源均安装失败。请检查上方 APT 错误、DNS、网络和软件包锁。'
}

probe_mirror() {
    timeout 20 /usr/lib/apt/apt-helper -o Acquire::Retries=0 -o Acquire::https::Timeout=8 \
        download-file "$1/dists/$CODENAME/InRelease" "$WORK_DIR/probe" >/dev/null 2>&1 &&
        gpgv --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg "$WORK_DIR/probe" >/dev/null 2>&1
}

create_package_policy() {
    # Avoid exposing package defaults before the final protected configuration.
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        POLICY_CREATED=1
    fi
}

finish_package_install() {
    if (( POLICY_CREATED )); then rm -f -- /usr/sbin/policy-rc.d; POLICY_CREATED=0; fi
}

detect_egress() {
    EGRESS_IF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ $EGRESS_IF =~ ^[a-zA-Z0-9_.:-]+$ && $EGRESS_IF != lo ]] || die '无法识别 IPv4 出口网卡。'
}

validate_network() {
    ip -j -4 route show table all > "$WORK_DIR/routes.json"
    python3 - "$VPN_CIDR" "$VPN_LOCAL_IP" "$VPN_IP_RANGE" "$WORK_DIR/routes.json" <<'PY'
import ipaddress, json, sys
try:
    net = ipaddress.IPv4Network(sys.argv[1])
    local = ipaddress.IPv4Address(sys.argv[2])
    start, end = map(ipaddress.IPv4Address, sys.argv[3].split('-'))
    private = [ipaddress.IPv4Network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')]
    if not any(net.subnet_of(n) for n in private) or net.prefixlen < 16 or net.prefixlen > 29:
        raise ValueError('VPN_CIDR 应为 /16 至 /29 的私有 IPv4 网段')
    if not all(ip in net and ip not in (net.network_address, net.broadcast_address) for ip in (local,start,end)):
        raise ValueError('网关和地址池必须位于 VPN_CIDR 的可用地址内')
    if start > end or start <= local <= end: raise ValueError('地址池顺序错误或包含 VPN 网关')
    for route in json.load(open(sys.argv[4])):
        dst = route.get('dst','default')
        if dst == 'default': continue
        # Existing PPP sessions of this VPN are not a conflicting LAN.
        if route.get('dev','').startswith('ppp'): continue
        other = ipaddress.IPv4Network(dst, strict=False)
        if net.overlaps(other): raise ValueError(f'VPN 网段与已有路由 {dst} 冲突')
except ValueError as exc:
    sys.exit(str(exc))
PY
}

backup_files() {
    BACKUP_DIR=$CONFIG_DIR/backups/$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$BACKUP_DIR/files"
    chmod 700 "$CONFIG_DIR" "$CONFIG_DIR/backups" "$BACKUP_DIR"
    local path unit enabled active key
    for path in "$CONFIG_FILE" "$RUNTIME" /etc/ipsec.conf /etc/ipsec.secrets /etc/xl2tpd/xl2tpd.conf \
        /etc/ppp/options.xl2tpd /etc/ppp/chap-secrets /etc/ufw/before.rules \
        /etc/sysctl.d/99-l2tp-installer.conf /etc/systemd/system/l2tp-firewall.service \
        /etc/systemd/system/ipsec.service.d/l2tp-installer.conf /etc/systemd/system/xl2tpd.service.d/l2tp-installer.conf; do
        printf '%s\n' "$path" >> "$BACKUP_DIR/manifest"
        if [[ -e $path ]]; then
            mkdir -p "$BACKUP_DIR/files$(dirname "$path")"
            cp -a -- "$path" "$BACKUP_DIR/files$path"
        fi
    done
    for unit in ipsec xl2tpd l2tp-firewall; do
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        active=$(systemctl is-active "$unit" 2>/dev/null || true)
        printf '%s %s %s\n' "$unit" "${enabled:-disabled}" "${active:-inactive}" >> "$BACKUP_DIR/services"
    done
    for key in net.ipv4.ip_forward net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects; do
        printf '%s %s\n' "$key" "$(sysctl -n "$key")" >> "$BACKUP_DIR/sysctl"
    done
    iptables-save > "$BACKUP_DIR/iptables.v4"
    CHANGED=1
}

configure_ipsec_version() {
    local version
    version=$(dpkg-query -W -f='${Version}' libreswan)
    IKEV1_POLICY_LINE=''
    # Jammy ships 3.32 (no global IKEv1 switch); Noble ships 4.14.
    if dpkg --compare-versions "$version" ge 4.5; then IKEV1_POLICY_LINE='    ikev1-policy=accept'; fi
}

render_configs() {
    local dest=$1
    mkdir -p "$dest"
    cat > "$dest/ipsec.conf" <<EOF
# Managed by l2tp-installer
config setup
    uniqueids=no
${IKEV1_POLICY_LINE:-}
conn l2tp-ikuai
    authby=secret
    ikev2=never
    type=transport
    left=%defaultroute
    leftprotoport=17/$L2TP_PORT
    right=%any
    rightprotoport=17/%any
    encapsulation=yes
    pfs=no
    rekey=no
    ike=aes256-sha2_256;modp2048,aes128-sha2_256;modp2048,aes256-sha1;modp2048,aes128-sha1;modp2048
    esp=aes256-sha2_256,aes128-sha2_256,aes256-sha1,aes128-sha1
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
    auto=add
EOF
    # Hex encoding avoids quote/escape ambiguities in Libreswan PSK parsing.
    printf ': PSK 0x%s\n' "$(printf '%s' "$IPSEC_PSK" | od -An -tx1 | tr -d ' \n')" > "$dest/ipsec.secrets"
    cat > "$dest/xl2tpd.conf" <<EOF
[global]
port = $L2TP_PORT
listen-addr = 0.0.0.0

[lns default]
ip range = $VPN_IP_RANGE
local ip = $VPN_LOCAL_IP
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP-VPN-Server
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF
    cat > "$dest/options.xl2tpd" <<'EOF'
ipcp-accept-local
ipcp-accept-remote
ms-dns 223.5.5.5
ms-dns 1.1.1.1
noccp
auth
refuse-pap
refuse-eap
mtu 1400
mru 1400
nodefaultroute
lock
lcp-echo-interval 30
lcp-echo-failure 5
connect-delay 5000
EOF
    printf '%s * %s *\n' "$(quote_ppp "$VPN_USER")" "$(quote_ppp "$VPN_PASS")" > "$dest/chap-secrets"
}

install_configs() {
    local file
    ipsec addconn --config "$WORK_DIR/render/ipsec.conf" --checkconfig
    mkdir -p /etc/xl2tpd /etc/ppp /usr/local/libexec
    for file in ipsec.conf ipsec.secrets; do install -m 600 "$WORK_DIR/render/$file" "/etc/$file"; done
    install -m 600 "$WORK_DIR/render/xl2tpd.conf" /etc/xl2tpd/xl2tpd.conf
    for file in options.xl2tpd chap-secrets; do install -m 600 "$WORK_DIR/render/$file" "/etc/ppp/$file"; done
    # Keep credentials even if the first start fails; cleanup restores previous state.
    save_config "$CONFIG_FILE"
    if [[ $(readlink -f "${BASH_SOURCE[0]}") != "$RUNTIME" ]]; then install -m 755 "${BASH_SOURCE[0]}" "$RUNTIME"; fi
    cat > /etc/sysctl.d/99-l2tp-installer.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
    sysctl -p /etc/sysctl.d/99-l2tp-installer.conf >/dev/null
}

firewall_filter_rules() {
    local input=$1 forward=$2
    cat <<EOF
-A $input -p udp -m multiport --dports 500,4500 -j ACCEPT
-A $input -p esp -j ACCEPT
-A $input -p udp --dport $L2TP_PORT -m policy --dir in --pol ipsec -j ACCEPT
-A $input -p udp --dport $L2TP_PORT -j DROP
-A $forward -i ppp+ -s $VPN_CIDR -o $EGRESS_IF -j ACCEPT
-A $forward -i $EGRESS_IF -o ppp+ -d $VPN_CIDR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF
}

remove_owned_firewall() {
    local table parent chain
    while read -r table parent chain; do
        while iptables -w 10 -t "$table" -C "$parent" -j "$chain" 2>/dev/null; do
            iptables -w 10 -t "$table" -D "$parent" -j "$chain"
        done
        if iptables -w 10 -t "$table" -S "$chain" >/dev/null 2>&1; then
            iptables -w 10 -t "$table" -F "$chain"
            iptables -w 10 -t "$table" -X "$chain"
        fi
    done <<'EOF'
filter INPUT L2TP-IN
filter FORWARD L2TP-FWD
nat POSTROUTING L2TP-NAT
EOF
}

apply_iptables() {
    local table chain parent
    # Restore in a single transaction; flush only the installer-owned chains.
    for chain in L2TP-IN L2TP-FWD; do
        if ! iptables -w 10 -S "$chain" >/dev/null 2>&1; then iptables -w 10 -N "$chain"; fi
    done
    if ! iptables -w 10 -t nat -S L2TP-NAT >/dev/null 2>&1; then iptables -w 10 -t nat -N L2TP-NAT; fi
    {
        printf '*filter\n-F L2TP-IN\n-F L2TP-FWD\n'
        firewall_filter_rules L2TP-IN L2TP-FWD
        printf 'COMMIT\n*nat\n-F L2TP-NAT\n'
        printf '%s\n' '-A L2TP-NAT -m policy --dir out --pol ipsec -j RETURN'
        printf '%s\n' "-A L2TP-NAT -s $VPN_CIDR -o $EGRESS_IF -j MASQUERADE"
        printf 'COMMIT\n'
    } | iptables-restore --wait 10 --noflush
    while read -r table parent chain; do
        # Moving only our jump to the first position also handles an earlier DROP.
        while iptables -w 10 -t "$table" -C "$parent" -j "$chain" 2>/dev/null; do
            iptables -w 10 -t "$table" -D "$parent" -j "$chain"
        done
        iptables -w 10 -t "$table" -I "$parent" 1 -j "$chain"
    done <<'EOF'
filter INPUT L2TP-IN
filter FORWARD L2TP-FWD
nat POSTROUTING L2TP-NAT
EOF
}

render_ufw() {
    local source=$1 target=$2
    firewall_filter_rules L2TP-IN L2TP-FWD > "$WORK_DIR/filter.rules"
    python3 - "$source" "$target" "$WORK_DIR/filter.rules" "$VPN_CIDR" "$EGRESS_IF" <<'PY'
import pathlib, re, sys
src, dst, rules, cidr, iface = sys.argv[1:]
text = pathlib.Path(src).read_text()
text = re.sub(r'^# BEGIN L2TP-INSTALLER\n.*?^# END L2TP-INSTALLER\n', '', text, flags=re.M|re.S)
filt = (':L2TP-IN - [0:0]\n:L2TP-FWD - [0:0]\n'
        '-A ufw-before-input -j L2TP-IN\n-A ufw-before-forward -j L2TP-FWD\n' + pathlib.Path(rules).read_text())
nat = (':L2TP-NAT - [0:0]\n-A POSTROUTING -j L2TP-NAT\n'
       '-A L2TP-NAT -m policy --dir out --pol ipsec -j RETURN\n'
       f'-A L2TP-NAT -s {cidr} -o {iface} -j MASQUERADE\n')
def insert(table, block):
    global text
    match = re.search(r'^\*' + table + r'\n(.*?)^COMMIT\s*$', text, flags=re.M|re.S)
    if not match:
        if table == 'filter': sys.exit('无法识别 UFW before.rules 的 filter 表')
        text += '\n*' + table + '\nCOMMIT\n'
        match = re.search(r'^\*' + table + r'\n(.*?)^COMMIT\s*$', text, flags=re.M|re.S)
    body = match[1]
    first_rule = re.search(r'^-(?:A|I)\s', body, flags=re.M)
    offset = first_rule.start() if first_rule else len(body)
    # All chain declarations must precede commands in iptables-restore input.
    marked = '# BEGIN L2TP-INSTALLER\n' + block + '# END L2TP-INSTALLER\n'
    pos = match.start(1) + offset
    text = text[:pos] + marked + text[pos:]
insert('filter', filt)
insert('nat', nat)
pathlib.Path(dst).write_text(text)
PY
}

apply_firewall() {
    detect_backend
    detect_egress
    if [[ $FIREWALL_BACKEND == ufw ]]; then
        [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/l2tp-installer.XXXXXXXX)
        render_ufw /etc/ufw/before.rules "$WORK_DIR/before.rules"
        iptables-restore --test < "$WORK_DIR/before.rules"
        install -m 640 "$WORK_DIR/before.rules" /etc/ufw/before.rules
        ufw reload
    else
        apply_iptables
    fi
}

install_services() {
    mkdir -p /etc/systemd/system/{ipsec,xl2tpd}.service.d
    cat > /etc/systemd/system/l2tp-firewall.service <<EOF
[Unit]
Description=L2TP/IPsec forwarding and firewall rules
Wants=network-online.target
After=network-online.target ufw.service netfilter-persistent.service
Before=ipsec.service xl2tpd.service

[Service]
Type=oneshot
ExecStart=$RUNTIME --apply-firewall
ExecReload=$RUNTIME --apply-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    local unit
    for unit in ipsec xl2tpd; do
        cat > "/etc/systemd/system/$unit.service.d/l2tp-installer.conf" <<'EOF'
[Unit]
Requires=l2tp-firewall.service
After=l2tp-firewall.service network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
EOF
    done
    systemctl daemon-reload
    systemctl enable l2tp-firewall ipsec xl2tpd
    systemctl restart l2tp-firewall
    systemctl restart ipsec
    systemctl restart xl2tpd
    sleep 2
    systemctl is-active --quiet l2tp-firewall ipsec xl2tpd
    ipsec auto --status | grep '"l2tp-ikuai"' >/dev/null || die 'IPsec 未加载 l2tp-ikuai 连接。'
    ss -H -luntp | awk -v p="$L2TP_PORT" '$5 ~ (":" p "$") && /xl2tpd/ {ok=1} END {exit !ok}' || die 'xl2tpd 未监听预期端口。'
}

show_result() {
    local public_ip='' url
    for url in https://api.ipify.org https://ipv4.icanhazip.com; do
        public_ip=$(curl -4fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || true)
        if python3 -c 'import ipaddress,sys; assert ipaddress.IPv4Address(sys.argv[1]).is_global' "$public_ip" 2>/dev/null; then break; fi
        public_ip=
    done
    printf '\n===== 服务端安装及本机检查完成 =====\n'
    printf '爱快：网络设置 → VPN 客户端 → L2TP\n拨号名称：L2TP1\n'
    printf '服务器地址/域名：%s\n服务端口：%s（UDP）\n用户名：%s\n密码：%s\n预共享密钥：%s\n' \
        "${public_ip:-请填写服务器可达的公网 IP 或域名}" "$L2TP_PORT" "$VPN_USER" "$VPN_PASS" "$IPSEC_PSK"
    printf '本地标识/对方标识：留空\nMTU/MRU：1400\n'
    printf '云安全组/上游映射：UDP 500、4500；L2TP 数据使用端口 %s，服务器仅接受 IPsec 保护的数据。\n' "$L2TP_PORT"
    printf '已配置本机防火墙；未修改云安全组。IPsec 封装下，上游通常只需放行 UDP 500/4500。\n'
    printf '配置：%s（权限 600）\n备份：%s\n' "$CONFIG_FILE" "$BACKUP_DIR"
    printf '服务检查不代表爱快已经拨号成功；请确认爱快获得本地 IP 并测试上网。\n'
}

main() {
    local mode=install arg key
    # Preserve explicit environment overrides separately from stored state.
    declare -A overrides=()
    for key in "${KEYS[@]}"; do
        if [[ -v $key && $key != FIREWALL_BACKEND ]]; then overrides[$key]=${!key}; fi
    done
    for arg in "$@"; do
        case $arg in
            --reconfigure) RECONFIGURE=1 ;;
            --apply-firewall) mode=firewall ;;
            --help|-h)
                printf '用法：sudo bash l2tp.sh [--reconfigure]\n环境变量：VPN_USER VPN_PASS IPSEC_PSK L2TP_PORT VPN_LOCAL_IP VPN_CIDR VPN_IP_RANGE NONINTERACTIVE=1\n重复运行保留原配置；--reconfigure 重新输入账户并生成新的默认密码、PSK 和端口。\n'
                return ;;
            *) die "未知参数：$arg" ;;
        esac
    done
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $mode == firewall ]]; then
        [[ $(id -u) == 0 ]] || die '恢复规则需要 root。'
        load_config "$CONFIG_FILE"
        OLD_BACKEND=$FIREWALL_BACKEND
        exec 8>/run/lock/l2tp-firewall.lock
        flock -w 30 8 || die '防火墙配置正在使用。'
        STEP=恢复防火墙
        apply_firewall
        return
    fi
    STEP=安装前检查
    preflight
    detect_existing
    if [[ -f $CONFIG_FILE ]]; then
        load_config "$CONFIG_FILE"
        OLD_PORT=$L2TP_PORT
        OLD_BACKEND=$FIREWALL_BACKEND
        detect_backend
        if (( ! RECONFIGURE )); then log '保留已有账户、密钥、地址池与端口；环境变量不会覆盖现有配置。'; fi
    fi
    WORK_DIR=$(mktemp -d /tmp/l2tp-installer.XXXXXXXX)
    # _apt needs directory traversal, but generated credentials remain mode 600.
    chmod 711 "$WORK_DIR"
    STEP=优选软件源及安装依赖
    install_packages
    configure_ipsec_version
    if (( LEGACY )); then
        import_legacy
        OLD_PORT=$L2TP_PORT
        IPSEC_PSK=$(random_secret 32)
        log '按要求已为旧配置生成新的随机 PSK；安装完成后需要同步更新爱快。'
    fi
    if (( RECONFIGURE )); then
        for key in VPN_USER VPN_PASS IPSEC_PSK L2TP_PORT; do unset "$key"; done
        for key in "${!overrides[@]}"; do printf -v "$key" '%s' "${overrides[$key]}"; done
    fi
    if [[ ! -f $CONFIG_FILE ]] || (( RECONFIGURE )); then ask_settings; fi
    STEP=校验网络与配置
    validate_values
    detect_egress
    validate_network
    if [[ $L2TP_PORT != "${OLD_PORT:-}" ]] && port_busy "$L2TP_PORT"; then die '指定的 L2TP 端口已被占用。'; fi
    render_configs "$WORK_DIR/render"
    STEP=备份与安装配置
    backup_files
    install_configs
    STEP=配置防火墙及启动服务
    install_services
    COMMITTED=1
    STEP=输出连接信息
    show_result
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
