#!/bin/bash
# Ubuntu L2TP/IPsec 一键安装脚本（兼容18.04+）
# 作者：技术工具库
# 依赖：xl2tpd + libreswan + ppp

# ==================== 自定义配置（请根据需求修改）====================
VPN_USER="vpnuser"          # VPN登录用户名
VPN_PASS="YourStrongPass123!"  # VPN登录密码（建议8位以上，含大小写+数字）
VPN_LOCAL_IP="192.168.18.1"  # VPN服务器内网IP
VPN_CIDR="192.168.18.0/24"   # VPN客户端分配IP段
IPSEC_PSK="YourPSKKey123!"   # IPsec预共享密钥（客户端需一致）
# ===================================================================

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用root用户运行（sudo -i 切换）"
    exit 1
fi

# 检查Ubuntu版本
UBUNTU_VERSION=$(lsb_release -r | awk '{print $2}')
if [[ ! $UBUNTU_VERSION =~ ^(18.04|20.04|22.04)$ ]]; then
    echo "错误：仅支持Ubuntu 18.04/20.04/22.04 LTS版本"
    exit 1
fi

echo "===== 开始安装L2TP/IPsec VPN ====="
echo "系统版本：Ubuntu $UBUNTU_VERSION"
echo "VPN配置：用户=$VPN_USER，IP段=$VPN_CIDR，PSK=$IPSEC_PSK"

# 1. 更新系统并安装依赖
echo -e "\n1. 安装依赖包..."
apt update -y && apt install -y xl2tpd xmlto libnss3-dev libnss3-tools \
libnspr4-dev libpam0g-dev libcap-ng-dev libcap-ng-utils libunbound-dev \
libevent-dev libcurl4-nss-dev libsystemd-dev ppp flex bison gcc make python3

# 2. 编译安装最新版libreswan（使用清华大学镜像源，替换原官方源）
echo -e "\n2. 安装libreswan（IPsec核心）..."
# 清华大学镜像源地址：https://mirrors.tuna.tsinghua.edu.cn/libreswan/
wget -q https://mirrors.tuna.tsinghua.edu.cn/libreswan/libreswan-4.12.tar.gz -O /tmp/libreswan.tar.gz
tar -zxf /tmp/libreswan.tar.gz -C /tmp
cd /tmp/libreswan-* || exit 1
./configure --prefix=/usr/local --sysconfdir=/etc --with-systemd
make -j$(nproc) && make install
cd - && rm -rf /tmp/libreswan*

# 3. 配置IPsec
echo -e "\n3. 配置IPsec..."
cat > /etc/ipsec.conf << EOF
version 2.0
config setup
    protostack=netkey
    interfaces=%defaultroute
    uniqueids=no
    virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12
    nat_traversal=yes
    keep_alive=60
    dpddelay=30
    dpdtimeout=120

conn L2TP-PSK-NAT
    rightsubnet=0.0.0.0/0
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    authby=secret
    pfs=no
    auto=add
    type=transport
    forceencaps=yes
    ike=aes256-sha1;modp1024
    phase2alg=aes256-sha1;modp1024
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
EOF

# 配置IPsec预共享密钥
cat > /etc/ipsec.secrets << EOF
: PSK "$IPSEC_PSK"
EOF
chmod 600 /etc/ipsec.secrets

# 4. 配置xl2tpd
echo -e "\n4. 配置xl2tpd..."
cat > /etc/xl2tpd/xl2tpd.conf << EOF
[global]
ipsec saref = yes
listen-addr = 0.0.0.0

[lns default]
ip range = $VPN_CIDR
local ip = $VPN_LOCAL_IP
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP-VPN-Server
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# 配置PPP选项
cat > /etc/ppp/options.xl2tpd << EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 1.1.1.1
noccp
auth
crtscts
idle 1800
mtu 1410
mru 1410
nodefaultroute
debug
lock
proxyarp
connect-delay 5000
EOF

# 添加VPN用户（chap-secrets）
cat > /etc/ppp/chap-secrets << EOF
$VPN_USER * $VPN_PASS *
EOF
chmod 600 /etc/ppp/chap-secrets

# 5. 配置系统转发和防火墙
echo -e "\n5. 配置网络转发和防火墙..."
# 开启IP转发
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
sysctl -p

# 开放VPN端口（UDP 500/4500/1701）
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 1701/udp
ufw reload

# 配置iptables转发规则
SERVER_IP=$(curl -s icanhazip.com)  # 自动获取服务器公网IP
iptables -t nat -A POSTROUTING -s $VPN_CIDR -o eth0 -j SNAT --to-source $SERVER_IP
iptables -A FORWARD -s $VPN_CIDR -j ACCEPT
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# 保存iptables规则（重启生效）
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-save > /etc/iptables/rules.v4
else
    mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4
fi

# 6. 设置服务自启动并启动
echo -e "\n6. 启动服务并设置自启..."
systemctl daemon-reload
systemctl enable ipsec xl2tpd
systemctl restart ipsec xl2tpd

# 7. 验证安装结果
echo -e "\n===== 安装完成！====="
echo "VPN连接信息："
echo "服务器地址：$SERVER_IP"
echo "IPsec预共享密钥（PSK）：$IPSEC_PSK"
echo "VPN用户名：$VPN_USER"
echo "VPN密码：$VPN_PASS"
echo "客户端配置：选择L2TP/IPsec模式，填入上述信息即可"
echo -e "\n测试命令（服务器端）："
echo "systemctl status ipsec xl2tpd  # 查看服务状态"
echo "journalctl -xe | grep xl2tpd  # 查看连接日志"
