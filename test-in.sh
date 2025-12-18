#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (IPv4+IPv6 智能路由版)"
echo "   功能：保留SSH入口IP + 安全控制出站流量"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 更新系统并安装组件..."
# 尝试修复可能的 dpkg 锁
rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm /var/lib/dpkg/lock 2>/dev/null || true
apt update -y
apt install -y openvpn iptables iptables-persistent curl

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
read -p "请选择SSH端口处理方式 [1/2] (默认:2): " SSH_PORT_CHOICE
SSH_PORT_CHOICE=${SSH_PORT_CHOICE:-2}

if [[ "$SSH_PORT_CHOICE" == "2" ]]; then
    read -p "请输入需要保留的额外SSH端口(以空格分隔，例如 '2222 2223 2224'): " EXTRA_SSH_PORTS
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

# 创建路由表
ip route add default via $4 dev $1 table 200

# 创建基于源IP的策略路由
ip rule add from all to 224.0.0.0/4 table main prio 100
ip rule add from all to 255.255.255.255 table main prio 100

# 让SSH流量保持直连 - 标准22端口
ip rule add fwmark 22 table main prio 100
iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22

# 处理额外的SSH端口
if [[ "$SSH_PORT_CHOICE" == "2" && -n "$EXTRA_SSH_PORTS" ]]; then
    echo "为额外SSH端口添加标记规则：$EXTRA_SSH_PORTS"
    for port in $EXTRA_SSH_PORTS; do
        iptables -t mangle -A OUTPUT -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A OUTPUT -p tcp --dport $port -j MARK --set-mark 22
        iptables -t mangle -A INPUT -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A INPUT -p tcp --dport $port -j MARK --set-mark 22
        iptables -t mangle -A FORWARD -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A FORWARD -p tcp --dport $port -j MARK --set-mark 22
    done
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
iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true

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
    done
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

# DNS设置
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

# 接受服务器推送的路由，但由我们的脚本决定如何使用
# pull-filter accept "route"
# pull-filter accept "route-ipv6"

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
EOF

# 8. 应用IPv6配置
if [[ -x /etc/openvpn/client/scripts/ipv6-setup.sh ]]; then
    echo ">>> 配置IPv6路由..."
    /etc/openvpn/client/scripts/ipv6-setup.sh "$IPV6_CHOICE"
fi

# 8. 等待并验证
echo ">>> 等待连接建立 (5秒)..."
sleep 5

echo "==========================================="
echo "网络状态验证："
echo "-------------------------------------------"
echo "1. OpenVPN 服务状态："
if systemctl is-active --quiet openvpn-client@client; then
    echo "   [OK] 服务运行中 (Active)"
else
    echo "   [ERROR] 服务未运行！"
    echo "   >>> 错误日志 (最后5行)："
    journalctl -u openvpn-client@client -n 5 --no-pager
fi

echo "-------------------------------------------"
echo "2. IPv4 出口测试："
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
    echo "   LXC容器的转发SSH端口也应正常工作。"
fi
echo "==========================================="
