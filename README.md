# Ubuntu L2TP/IPsec 一键安装

适用于 **Ubuntu 22.04 / 24.04，amd64 / arm64，systemd**，面向爱快路由器的 L2TP 客户端。以秋水逸冰的 [L2TP/IPSec 一键安装脚本](https://teddysun.com/448.html) 为二次开发基础，保留作者署名和 Apache-2.0 许可证。沿用其编译安装、IPsec/PPP 配置和完成后输出连接信息的流程，适配当前 Ubuntu。xl2tpd、PPP 和编译依赖通过 Ubuntu 软件源安装；Libreswan 4.15 在独立目录编译。

## 安装

在服务器上下载后执行，安装需要 root 和可访问的软件源：

```bash
curl -fL --connect-timeout 15 --max-time 120 --retry 3 \
  -H 'Accept: application/vnd.github.raw+json' \
  'https://api.github.com/repos/kill613/l2tp/contents/l2tp.sh?ref=main' \
  -o l2tp.sh && sudo bash l2tp.sh
```

仓库默认分支为 `main`，旧说明中的 `master` 下载地址应改为 `main`。下载脚本前尚未运行优选逻辑，若服务器无法访问 GitHub，请先在其他设备下载 `l2tp.sh`，上传后执行。Libreswan 源码先尝试公开加速渠道，随后回退官方 GitHub，两个渠道均须通过固定 SHA-256 校验。

首次安装会检测公网 IPv4，可回车采用或手动修改；可输入账户、密码、预共享密钥和 L2TP 端口，留空使用以下默认值：

| 配置 | 默认行为 |
| --- | --- |
| 公网 IPv4 | 自动检测，支持手动输入；可用 VPN_PUBLIC_IP 指定 |
| 账户 | `real` |
| 密码 | 安全随机生成 18 位，保证同时包含大小写字母和数字 |
| IPsec 预共享密钥（PSK） | 独立随机生成 32 位，包含大小写字母和数字，不再使用原脚本的固定密钥 |
| L2TP 端口 | 可交互输入，回车采用随机默认值；在 10000–60000 内随机选择，避开已占用端口、上次端口及系统临时端口范围 |
| IPsec 端口 | UDP 500、4500，保持标准端口 |
| VPN 网关 | `192.168.18.1` |
| 客户端地址池 | `192.168.18.10–192.168.18.250` |
| DNS | `223.5.5.5`、`1.1.1.1` |

手动账户支持英文、数字和 `_.@-`，首位为英文或数字；密码与 PSK 支持 8–128 位可打印 ASCII 字符。密码会正确转义，PSK 以十六进制写入 IPsec 配置。新生成的默认密码、PSK 不含特殊字符，方便在爱快中填写。

### 无需交互安装

```bash
sudo env NONINTERACTIVE=1 bash l2tp.sh
```

可选环境变量：`VPN_PUBLIC_IP`、`VPN_USER`、`VPN_PASS`、`IPSEC_PSK`、`L2TP_PORT`、`VPN_CIDR`、`VPN_LOCAL_IP`、`VPN_IP_RANGE`。例如指定账户与端口，其余使用随机默认值：

```bash
sudo env NONINTERACTIVE=1 VPN_USER=real L2TP_PORT=18562 bash l2tp.sh
```

若改变 VPN 网段，应同时设置三项地址参数，例如：

```bash
sudo env NONINTERACTIVE=1 VPN_CIDR=10.73.0.0/24 VPN_LOCAL_IP=10.73.0.1 \
  VPN_IP_RANGE=10.73.0.10-10.73.0.250 bash l2tp.sh
```

脚本会检测与服务器路由的重叠；也应避免与爱快 LAN、对端网络重叠。安装器不能从服务器自动发现爱快 LAN 网段。

## 重复运行与旧版迁移

普通重复运行会保留保存的账户、密码、PSK、端口和地址池，忽略对应环境变量，避免重试改变客户端配置。

需要重新配置时：

```bash
sudo bash l2tp.sh --reconfigure
# 或无需交互重新生成密码、PSK 和端口
sudo env NONINTERACTIVE=1 bash l2tp.sh --reconfigure
```

重新配置时保留地址池，账户留空默认 `real`，密码、PSK 和端口留空重新随机生成。可以通过环境变量明确指定值。已连接客户端会断线，需要同步更新爱快配置。

配置保存于 `/etc/l2tp-installer/config`，权限 600；修改前的文件保存在 `/etc/l2tp-installer/backups/`，备份也包含密钥，请仅以 root 访问。不要将这些文件上传到公开仓库。

旧版仅自动导入可明确识别的原仓库单账户配置，保留账户、密码与端口，修正地址池格式，**更换旧 PSK 为随机新值**。其他 VPN、多账户或无法识别的配置不会被覆盖。

如果检测到旧脚本安装在 `/usr/local` 下的源码版 Libreswan，安装器会停止：需要先备份并按原安装记录卸载源码版，再安装系统软件包，避免两个 IPsec 实现争用配置和端口。检测到 strongSwan、firewalld、启用的 nftables 服务或尚未支持的原生 nftables 表时也会停止，不自动替换其他服务。

秋水逸冰原版固定使用 Libreswan 3.27。本二次开发版选择 4.15，并对已抓包确认的爱快零秒 IKE 寿命加入兼容处理。编译源码中的零寿命在 IKE 与 IPsec 两阶段使用本地配置的正寿命，协商回复同步携带该值，并保留认证所需的原始提议。非零寿命保持上游处理。该修改在脚本中明确标注，属于本仓库补丁。运行文件位于 `/opt/l2tp-libreswan/4.15-ikuai2`，配置和旧服务单元在切换前备份。系统安装的原有 Libreswan 软件包保留供回退。首次编译需要数分钟。

对于本次简化版生成的 `/etc/l2tp-deploy/client.txt`，安装器可识别单账户部署，核对连接信息与实际凭据一致后备份并迁移，保留原用户名、密码、PSK、端口和地址池，替换旧版专用网络服务。迁移期间 VPN 会短暂中断。如需重新交互选择，执行 `sudo bash l2tp.sh --reconfigure`。复杂或不一致的配置会停止，需人工核对。

## 爱快填写方法

进入 **网络设置 → VPN 客户端 → L2TP → 添加**，按安装结束的输出填写：

| 爱快字段 | 填写内容 |
| --- | --- |
| 拨号名称 | 如 `L2TP1`，以 L2TP 开头 |
| 服务器地址/域名 | 服务器可达的公网 IPv4 或域名 |
| 服务端口 | 脚本输出的随机 L2TP 端口 |
| 用户名 / 密码 | 脚本输出的账户和密码 |
| 预共享密钥 | 脚本输出的随机 PSK，启用 IPsec 加密时必须填写 |
| 本地标识 / 对方标识 | 留空 |
| MTU / MRU | 1400 |

爱快支持服务端口和预共享密钥，参见[官方说明](https://www.ikuai8.com/support/ymgn/lyym/wlsz/vpn/l2tp.html)。客户端获得本地 IP 后，再测试网关、DNS 与实际转发上网。爱快侧的分流、默认路由、LAN 流量 NAT 和自动重拨按实际用途设置；服务器安装器不修改爱快配置。不同爱快固件的 IPsec 协商与自定义端口组合仍需在实际设备上验证。

## 防火墙、启动与镜像

- 自动识别 IPv4 出口网卡，使用 MASQUERADE 转发客户端流量，适配 `ens3`、`enp1s0` 等网卡名及云主机私网地址。
- 自动设置 IPv4 转发，配置 UDP 500/4500 与 ESP 协议（不是 TCP/UDP 50 端口）；随机 L2TP 端口只接收经 IPsec 保护的数据，拒绝裸 L2TP。
- UFW 已启用时，在 `before.rules` 中维护带标记的专用规则，支持 UFW 重载；否则使用 iptables 专用链（包括 Ubuntu 的 iptables-nft 后端）。不清空其他规则、不启停 UFW、不改变 SSH 规则。
- 启用 `ipsec`、`xl2tpd`、`l2tp-firewall` 开机启动；规则恢复先于 VPN 服务执行。服务退出异常时自动重启，重复运行不重复添加规则。
- 云安全组、运营商过滤与上游路由器无法由本机规则控制。使用 IPsec UDP 封装时，上游通常只需允许/映射 UDP 500/4500；随机 L2TP 端口在服务器解密后匹配，无需直接向公网开放裸 L2TP。仅修改本机防火墙不代表已修改云安全组。
- 安装时对清华、中科大、阿里云镜像进行限时 InRelease 下载并验证 Ubuntu 签名，按耗时优选；实际更新或安装失败，每个候选最多尝试三次，再尝试下一镜像，最后回退官方源。
- 分别处理 `jammy/noble`、`ubuntu/ubuntu-ports`，使用临时 APT 源和独立索引，不永久改写系统软件源，不执行整机升级，不关闭签名校验。
- 失败时输出具体步骤，不宣告安装成功。修改配置后的失败会尝试恢复备份、原服务状态和本脚本管理的规则；软件包安装本身不会自动卸载回滚。请检查恢复输出。

## 排障与验证

```bash
sudo bash l2tp.sh --diagnose\n# 重新拨号后采集，输出不包含配置文件中的密码或 PSK\nsudo systemctl status ipsec xl2tpd l2tp-firewall --no-pager
sudo journalctl -u ipsec -u xl2tpd -u l2tp-firewall -n 100 --no-pager
sudo ipsec auto --status
sudo ss -luntp
sudo iptables -S L2TP-IN
sudo iptables -S L2TP-FWD
sudo iptables -t nat -S L2TP-NAT
# UFW 模式请查看 /etc/ufw/before.rules 中的 L2TP-INSTALLER 标记
```

若日志显示算法协商不匹配，请提供爱快固件版本和双方日志。默认使用 AES、SHA-256/SHA-1、DH14，并加入已知爱快请求使用的 AES128/SHA-256/DH15 提议，不自动启用 DH2 或 3DES。

仓库验证命令：

```bash
bash -n l2tp.sh
shellcheck l2tp.sh
python3 -m unittest discover -s tests -v
```

自动化测试覆盖生成值、转义、配置保留/重新生成、网络冲突、源重试/回退、UFW 合并和专用链幂等性。CI 在 Ubuntu 22.04/24.04 编译固定的 Libreswan 4.15，检查真实组件配置，并在隔离网络与挂载命名空间验证 iptables、已启用 UFW 的放行及重载；CI 通过仍不能代替实际服务器重启和爱快拨号测试。

测试还在隔离网络中发送带零寿命的 IKEv1/PSK 提议，完成双方认证后检查会话继续存活。真实爱快获取本地 IP 与实际通流量仍需现场验收。

寿命兼容 v2 的测试覆盖两个阶段的零寿命、协商回复、双方认证及 IPsec SA 存活，同时检查非零寿命保持不变。

独立编译核心的 leftupdown 显式指向同一安装目录，避免与发行版旧辅助脚本混用。

## 与 SingBox 中转共存

检测到 inet sbm_relay 时，在该表创建带归属注释的 l2tp_installer_input 和 l2tp_installer_forward 两条普通链，分别从现有 input/forward 基链跳转。规则仅允许 IPv4 IPsec 的 UDP 500/4500、ESP、经 IPsec 保护的 L2TP 端口，以及指定 VPN 地址池从 ppp 接口到实际出口的转发和已建立连接回包。

保留中转表的 DROP 策略、SSH、WireGuard、Agent 与 HY2 端口集。在修改前备份表与相关配置，规则用 nft --check 预检并按事务应用。安装器维护 sbm-relay-firewall.service 的专用 ExecStartPost 配置，在中转服务重新建立自己的防火墙表后重建 L2TP 共存规则。安装该配置只重载 systemd 单元，不主动重启中转服务。

其他原生 nftables 表继续要求单独核对。仅在另一张表中添加 ACCEPT，无法覆盖 sbm_relay 基链的默认 DROP。

可与 SK5、中转同机部署。选择 L2TP 端口时会额外读取本项目 SK5 的私有配置，跳过整个 UDP 中继保留范围，即使某个端口当时尚未绑定；手动选择该范围内端口也会按冲突处理。中转最后安装时，请使用支持三服务共存的 SingBox Manager 4.0.4 或更新版本生成节点包。重复运行 L2TP 安装保留现有配置，不会修改 SK5 或中转身份。
