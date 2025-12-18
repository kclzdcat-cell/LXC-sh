#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (IPv4+IPv6 智能路由版)"
echo "   功能：保留SSH入口IP + 安全控制出站流量"
echo "   版本：1.3"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 检查必要软件
echo ">>> 检查必要软件..."

# 检查软件是否已安装
OPENVPN_INSTALLED=0
IPTABLES_INSTALLED=0
CURL_INSTALLED=0

if command -v openvpn >/dev/null 2>&1; then
    OPENVPN_INSTALLED=1
    echo "OpenVPN 已安装"
fi

if command -v iptables >/dev/null 2>&1; then
    IPTABLES_INSTALLED=1
    echo "iptables 已安装"
fi

if command -v curl >/dev/null 2>&1; then
    CURL_INSTALLED=1
    echo "curl 已安装"
fi

# 检查是否需要安装软件
if [[ $OPENVPN_INSTALLED -eq 0 || $IPTABLES_INSTALLED -eq 0 || $CURL_INSTALLED -eq 0 ]]; then
    echo "警告: 检测到缺失的软件包。"
    read -p "是否尝试更新和安装缺失的软件包? [y/N] " INSTALL_CHOICE
    
    if [[ "$INSTALL_CHOICE" == "y" || "$INSTALL_CHOICE" == "Y" ]]; then
        echo ">>> 尝试更新系统并安装缺失组件..."
        # 尝试修复可能的 dpkg 锁
        rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
        rm /var/lib/dpkg/lock 2>/dev/null || true
        
        # 尝试更新，忽略错误
        apt update -y || echo "警告: apt update 失败，继续执行脚本"
        
        # 尝试安装缺失的软件
        if [[ $OPENVPN_INSTALLED -eq 0 ]]; then
            apt install -y openvpn || echo "警告: openvpn 安装失败"
        fi
        
        if [[ $IPTABLES_INSTALLED -eq 0 ]]; then
            apt install -y iptables || echo "警告: iptables 安装失败"
            apt install -y iptables-persistent || echo "警告: iptables-persistent 安装失败"
        fi
        
        if [[ $CURL_INSTALLED -eq 0 ]]; then
            apt install -y curl || echo "警告: curl 安装失败"
        fi
    else
        echo "跳过安装步骤，继续执行脚本..."
    fi
fi

# 再次检查关键软件
if ! command -v openvpn >/dev/null 2>&1; then
    echo "错误：OpenVPN未安装，脚本可能无法正常工作。"
    read -p "是否继续执行? [y/N] " CONTINUE_CHOICE
    if [[ "$CONTINUE_CHOICE" != "y" && "$CONTINUE_CHOICE" != "Y" ]]; then
        echo "退出脚本。"
        exit 1
    fi
fi

# 2. 检查 client.ovpn
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 修改配置 (智能路由模式)
echo ">>> 配置路由规则..."

# 创建路由脚本目录
mkdir -p /etc/openvpn/client/scripts

# 清理旧的配置 (如果之前运行过)
rm -f /etc/openvpn/client/up.sh
rm -f /etc/openvpn/client/down.sh
rm -f /etc/openvpn/client/scripts/*

# 尝试清理可能残留的路由规则
ip -6 rule del table main priority 1000 2>/dev/null || true
ip -6 rule del from all table 200 2>/dev/null || true

# 检测IPv6能力
HAS_IPV6=0
OUTPUT_IPV6=$(curl -s --max-time 5 -6 ipv6.ip.sb || echo "")
if [[ -n "$OUTPUT_IPV6" ]]; then
    HAS_IPV6=1
    echo ">>> 检测到可用的IPv6: $OUTPUT_IPV6"
fi

# 配置IPV6处理方式
echo -e "\n配置IPv6路由:\n"
echo "1) 使用出口服务器的IPv6（推荐，如果出口服务器有IPv6）"
echo "2) 使用本机IPv6（保持IPv6独立）"
echo "3) 禁用所有IPv6路由（只使用IPv4）"
read -p "请选择IPv6配置方式 [1/2/3] (默认:1): " IPV6_CHOICE
IPV6_CHOICE=${IPV6_CHOICE:-1}

# 配置SSH端口处理方式
echo -e "\nSSH端口设置:\n"
echo "1) 只保留标准SSH端口(22)走原始网卡"
echo "2) 保留所有SSH相关端口(包括转发到LXC容器的端口)走原始网卡"
echo "3) 保留所有TCP端口连接走原始网卡(适用于随机分配的端口)"
read -p "请选择SSH端口处理方式 [1/2/3] (默认:3): " SSH_PORT_CHOICE
SSH_PORT_CHOICE=${SSH_PORT_CHOICE:-3}

if [[ "$SSH_PORT_CHOICE" == "2" ]]; then
    read -p "请输入需要保留的额外SSH端口(以空格分隔，例如 '2222 2223 2224'): " EXTRA_SSH_PORTS
elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    echo "将保留所有TCP端口连接，包括随机分配的SSH端口"
    read -p "请输入LXC容器内网IP范围(默认: 10.0.0.0/8): " LXC_IP_RANGE
    LXC_IP_RANGE=${LXC_IP_RANGE:-"10.0.0.0/8"}
fi

# 创建启动脚本
cat > /etc/openvpn/client/scripts/route-up.sh <<'SCRIPT'
#!/bin/bash

# 加载保留端口设置
if [ -f "/etc/openvpn/client/scripts/ssh_ports.conf" ]; then
    source "/etc/openvpn/client/scripts/ssh_ports.conf"
fi

# 记录原始默认路由
GW4=$(ip route show default | grep -v tun | head -n1 | awk '{print $3}')
DEV4=$(ip route show default | grep -v tun | head -n1 | awk '{print $5}')

if [[ -z "$GW4" || -z "$DEV4" ]]; then
    echo "警告: 无法找到原始IPv4默认网关，路由可能不正确"
fi

# 记录到文件，方便down脚本使用
echo "$GW4 $DEV4" > /etc/openvpn/client/scripts/orig_gateway.txt

# 添加到OpenVPN服务器的路由以确保VPN连接
# 使用实际的VPN网关
ip route add $4 via $GW4 dev $DEV4

# 创建路由表
ip route add default via $4 dev $1 table 200

# 确保DNS服务器通过原始路由可访问
ip rule add to 8.8.8.8/32 table main prio 95
ip rule add to 1.1.1.1/32 table main prio 95
# 添加ip.sb等IP查询服务通过原始网卡访问
ip rule add to 108.61.196.101/32 table main prio 95  # ip.sb

# 创建基于源IP的策略路由
ip rule add from all to 224.0.0.0/4 table main prio 100
ip rule add from all to 255.255.255.255 table main prio 100

# SSH流量标记配置

# 创建规则来处理SSH流量
ip rule add fwmark 22 table main prio 100

if [[ "$SSH_PORT_CHOICE" == "1" ]]; then
    # 选项1: 只标记标准22端口
    echo "只保留标准22端口走原始网卡"
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --dport 22 -j MARK --set-mark 22

elif [[ "$SSH_PORT_CHOICE" == "2" && -n "$EXTRA_SSH_PORTS" ]]; then
    # 选项2: 标准22端口和指定的额外端口
    echo "保留标准22端口和指定的额外端口"
    # 标记22端口
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --dport 22 -j MARK --set-mark 22
    
    # 标记额外SSH端口
    echo "为额外SSH端口添加标记规则：$EXTRA_SSH_PORTS"
    for port in $EXTRA_SSH_PORTS; do
        iptables -t mangle -A OUTPUT -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A OUTPUT -p tcp --dport $port -j MARK --set-mark 22
        iptables -t mangle -A INPUT -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A INPUT -p tcp --dport $port -j MARK --set-mark 22
        iptables -t mangle -A FORWARD -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A FORWARD -p tcp --dport $port -j MARK --set-mark 22
    done

elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    # 选项3: 保留所有TCP端口连接，包括随机分配的SSH端口
    echo "保留所有TCP连接，特别是到$LXC_IP_RANGE的连接"
    
    # 1. 标记所有到LXC容器的TCP流量
    iptables -t mangle -A FORWARD -p tcp -d $LXC_IP_RANGE -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp -s $LXC_IP_RANGE -j MARK --set-mark 22
    
    # 2. 标记标准SSH端口和其他常用需要保留的端口
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --dport 22 -j MARK --set-mark 22
    
    # 3. 标记所有来自外部的新连接(即入站连接)
    iptables -t mangle -A INPUT -p tcp -m state --state NEW -j MARK --set-mark 22
fi

# 其他所有流量走VPN
ip rule add from all table 200 prio 200

# 清除路由缓存
ip route flush cache
SCRIPT

# 创建关闭脚本
cat > /etc/openvpn/client/scripts/down.sh <<'SCRIPT'
#!/bin/bash

# 加载保留端口设置
if [ -f "/etc/openvpn/client/scripts/ssh_ports.conf" ]; then
    source "/etc/openvpn/client/scripts/ssh_ports.conf"
fi

# 清除所有添加的规则和表
ip rule del from all table 200 prio 200 2>/dev/null || true
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del from all to 224.0.0.0/4 table main prio 100 2>/dev/null || true 
ip rule del from all to 255.255.255.255 table main prio 100 2>/dev/null || true

# 清除IPv6规则(如果存在)
ip -6 rule del from all table 200 prio 200 2>/dev/null || true
ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true

# 清除标准SSH端口的iptables标记规则
if [[ "$SSH_PORT_CHOICE" == "1" || "$SSH_PORT_CHOICE" == "2" ]]; then
    # 清除标准22端口规则
    iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    
    ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D INPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D INPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D FORWARD -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D FORWARD -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    
    # 处理额外的SSH端口
    if [[ "$SSH_PORT_CHOICE" == "2" && -n "$EXTRA_SSH_PORTS" ]]; then
        echo "清除额外SSH端口的标记规则..."
        for port in $EXTRA_SSH_PORTS; do
            iptables -t mangle -D OUTPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D INPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D INPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            
            ip6tables -t mangle -D OUTPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D OUTPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D INPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D INPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D FORWARD -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D FORWARD -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
        done
    fi
elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    # 清除标准22端口规则
    iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    
    # 清除到LXC容器的TCP流量规则
    iptables -t mangle -D FORWARD -p tcp -d $LXC_IP_RANGE -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp -s $LXC_IP_RANGE -j MARK --set-mark 22 2>/dev/null || true
    
    # 清除新连接标记规则
    iptables -t mangle -D INPUT -p tcp -m state --state NEW -j MARK --set-mark 22 2>/dev/null || true
fi
SCRIPT

# 设置脚本权限
chmod +x /etc/openvpn/client/scripts/*.sh

# IPv6配置创建
cat > /etc/openvpn/client/scripts/ipv6-setup.sh <<'SCRIPT'
#!/bin/bash

IPV6_CHOICE=$1

if [[ "$IPV6_CHOICE" == "1" ]]; then
    # 启用IPv6 VPN路由
    echo "配置IPv6通过VPN路由..."
    
    # 记录原始IPv6路由
    GW6=$(ip -6 route show default | grep -v tun | head -n1 | awk '{print $3}')
    DEV6=$(ip -6 route show default | grep -v tun | head -n1 | awk '{print $5}')
    
    if [[ -n "$GW6" && -n "$DEV6" ]]; then
        echo "$GW6 $DEV6" > /etc/openvpn/client/scripts/orig_gateway6.txt
        
        # 添加IPv6策略路由
        ip -6 route add default dev tun0 table 200
        ip -6 rule add fwmark 22 table main prio 100
        ip -6 rule add from all table 200 prio 200
        ip -6 route flush cache
    else
        echo "没有找到有效的IPv6路由，跳过IPv6配置"
    fi
elif [[ "$IPV6_CHOICE" == "2" ]]; then
    echo "保持IPv6使用本机直接连接..."
    # 不做任何IPv6路由修改
elif [[ "$IPV6_CHOICE" == "3" ]]; then
    echo "禁用所有IPv6路由..."
    # 临时禁用IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
fi
SCRIPT

chmod +x /etc/openvpn/client/scripts/ipv6-setup.sh

# 核心配置：智能路由控制
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 智能路由控制 ---

# 使用自定义脚本而不是redirect-gateway
script-security 2
route-noexec
up "/etc/openvpn/client/scripts/route-up.sh"
down "/etc/openvpn/client/scripts/down.sh"

# 设置最大连接重试次数和重试间隔
resolv-retry infinite
connect-retry 5 10

# 使用强制ping确保连接存活
ping 10
ping-restart 60

# DNS设置
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

# 接受服务器推送的路由参数
pull-filter accept "route"
pull-filter accept "route-ipv6"

# 屏蔽服务器的重定向网关指令，由我们自己控制
pull-filter ignore "redirect-gateway"
CONF

# 5. 内核参数 (IPv4 + IPv6)
echo ">>> 优化内核参数..."
# 确保IPv6启用状态根据用户选择
if [[ "$IPV6_CHOICE" == "3" ]]; then
    # 用户选择禁用IPv6
    echo "配置系统禁用IPv6..."
    grep -v "disable_ipv6" /etc/sysctl.conf > /tmp/sysctl.conf.tmp
    echo "net.ipv6.conf.all.disable_ipv6=1" >> /tmp/sysctl.conf.tmp
    echo "net.ipv6.conf.default.disable_ipv6=1" >> /tmp/sysctl.conf.tmp
    mv /tmp/sysctl.conf.tmp /etc/sysctl.conf
else
    # 确保IPv6启用
    sed -i '/disable_ipv6/d' /etc/sysctl.conf
fi

# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# 开启 IPv6 转发 (如果IPv6启用)
if [[ "$IPV6_CHOICE" != "3" ]]; then
    if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
fi

sysctl -p >/dev/null 2>&1

# 6. 配置 NAT (只针对 IPv4)
echo ">>> 配置防火墙 NAT..."
iptables -t nat -F
# 允许 tun0 出流量伪装
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

# 7. 重启服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl restart openvpn-client@client

# 保存SSH端口设置到配置文件供脚本使用
cat > /etc/openvpn/client/scripts/ssh_ports.conf <<EOF
SSH_PORT_CHOICE="$SSH_PORT_CHOICE"
EXTRA_SSH_PORTS="$EXTRA_SSH_PORTS"
LXC_IP_RANGE="$LXC_IP_RANGE"
EOF

# 8. 应用IPv6配置
if [[ -x /etc/openvpn/client/scripts/ipv6-setup.sh ]]; then
    echo ">>> 配置IPv6路由..."
    /etc/openvpn/client/scripts/ipv6-setup.sh "$IPV6_CHOICE"
fi

# 8. 等待并验证
echo ">>> 等待连接建立 (10秒)..."
sleep 10

echo "=========================================="
echo "网络状态验证："
echo "-------------------------------------------"
echo "1. OpenVPN 服务状态："
if systemctl is-active --quiet openvpn-client@client; then
    echo "   [OK] 服务运行中 (Active)"
    echo "   >>> 连接日志 (最近5行)："
    journalctl -u openvpn-client@client -n 5 --no-pager
    
    # 检查tun0接口是否创建成功
    if ip addr show tun0 > /dev/null 2>&1; then
        TUN0_IP=$(ip -4 addr show tun0 | grep -oP '(?<=inet ).*(?=/')
        echo "   [OK] tun0接口已创建: IP=$TUN0_IP"
    else
        echo "   [ERROR] tun0接口未创建！"
    fi
else
    echo "   [ERROR] 服务未运行！"
    echo "   >>> 错误日志 (最后5行)："
    journalctl -u openvpn-client@client -n 5 --no-pager
fi

echo "-------------------------------------------"
echo "2. IPv4 连接测试："

# 先测试原生网络连接
echo "   原生网络测试（通过原始网卡）："
ORIG_IP4=$(curl -4 -s --connect-timeout 5 --interface $(ip route show default | grep -v tun | head -n1 | awk '{print $5}') ip.sb || echo "获取失败")
if [[ "$ORIG_IP4" != "获取失败" ]]; then
    echo -e "      原始网络可用，外网IP: \033[32m$ORIG_IP4\033[0m"
else
    echo -e "      \033[31m原始网络连接失败\033[0m (请检查网络设置)"
fi

# 再测试VPN路由
echo "   VPN路由测试（通过VPN隔离）："
TUN_IP4=""
if ip addr show tun0 > /dev/null 2>&1; then
    TUN_IP4=$(curl -4 -s --connect-timeout 8 --interface tun0 ip.sb || echo "获取失败")
    if [[ "$TUN_IP4" != "获取失败" ]]; then
        echo -e "      VPN路由正常，外网IP: \033[32m$TUN_IP4\033[0m (应为出口服务器IP)"
    else
        echo -e "      \033[31mVPN路由连接失败\033[0m (可能是DNS解析问题)"
    fi
else
    echo -e "      \033[31m未检测到tun0接口\033[0m"
fi

# 最后测试全局路由 (这应该显示出口服务器IP)
IP4=$(curl -4 -s --connect-timeout 8 ip.sb || echo "获取失败")
if [[ "$IP4" != "获取失败" ]]; then
    # 使用绿色显示 IP
    echo -e "   当前 IPv4: \033[32m$IP4\033[0m (应为出口服务器 IP)"
else
    # 使用红色显示失败
    echo -e "   当前 IPv4: \033[31m获取失败\033[0m (请检查网络或 VPN 配置)"
fi

echo "-------------------------------------------"
echo "3. IPv6 状态："
if [[ "$IPV6_CHOICE" == "1" ]]; then
    IP6=$(curl -6 -s --connect-timeout 8 ip.sb || echo "获取失败")
    if [[ "$IP6" != "获取失败" ]]; then
        echo -e "   当前 IPv6: \033[32m$IP6\033[0m (应为出口服务器 IP)"
    else
        echo -e "   当前 IPv6: \033[33m获取失败\033[0m (可能出口服务器没有IPv6)"
    fi
elif [[ "$IPV6_CHOICE" == "2" ]]; then
    IP6=$(curl -6 -s --connect-timeout 8 ip.sb || echo "获取失败")
    if [[ "$IP6" != "获取失败" ]]; then
        echo -e "   当前 IPv6: \033[32m$IP6\033[0m (使用本机 IPv6)"
    else
        echo -e "   当前 IPv6: \033[33m获取失败\033[0m (本机可能没有IPv6)"
    fi
elif [[ "$IPV6_CHOICE" == "3" ]]; then
    echo -e "   IPv6: \033[33m已禁用\033[0m (按用户选择)"
fi

echo "-------------------------------------------"
echo "4. SSH 连接状态："
if [[ "$SSH_PORT_CHOICE" == "1" ]]; then
    echo "   标准SSH端口(22)应保持正常连接。本机原始IP保持可访问。"
elif [[ "$SSH_PORT_CHOICE" == "2" ]]; then
    echo "   SSH端口(22 及 $EXTRA_SSH_PORTS)应保持正常连接。本机原始IP保持可访问。"
    echo "   指定的LXC容器转发SSH端口应正常工作。"
elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    echo "   所有入站TCP连接（包括随机分配的SSH端口）都应保持正常。"
    echo "   所有LXC容器的转发连接应能正常工作。"
fi
echo "==========================================="
