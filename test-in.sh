#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (简化版)"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：2.0"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 安装必要软件..."
apt-get update -y || true
apt-get install -y openvpn iptables curl || true

# 2. 检查 client.ovpn
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client/scripts
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 创建路由脚本
echo ">>> 创建路由脚本..."

# 创建启动脚本
cat > /etc/openvpn/client/scripts/route-up.sh <<'SCRIPT'
#!/bin/bash

# 获取网卡信息
DEV4=$(ip -4 route | grep default | grep -v tun | awk '{print $5}' | head -n 1)
GW4=$(ip -4 route | grep default | grep -v tun | awk '{print $3}' | head -n 1)

# 清除旧的路由规则
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del from all table 200 prio 200 2>/dev/null || true

# 创建路由表200用于出站流量
ip route flush table 200 2>/dev/null || true

# 添加到VPN服务器的直接路由
ip route add $4 via $GW4 dev $DEV4

# 添加默认路由到表200
ip route add default via $5 dev $1 table 200

# 添加DNS服务器的路由
ip rule add to 8.8.8.8/32 table main prio 95
ip rule add to 1.1.1.1/32 table main prio 95

# 标记的流量走原始网卡
ip rule add fwmark 22 table main prio 100

# 非标记流量走VPN
ip rule add from all table 200 prio 200

# 清除路由缓存
ip route flush cache

# 标记所有入站连接使用原始网卡
iptables -t mangle -F

# 标记所有入站连接
iptables -t mangle -A INPUT -j MARK --set-mark 22

# 标记已建立的连接相关的出站流量
iptables -t mangle -A OUTPUT -m state --state ESTABLISHED,RELATED -j MARK --set-mark 22

# IPv6配置
if ip -6 addr show dev $DEV4 | grep -q 'inet6'; then
    # 获取IPv6网关
    GW6=$(ip -6 route | grep default | grep -v tun | awk '{print $3}' | head -n 1)
    
    if [ -n "$GW6" ]; then
        echo "IPv6网关: $GW6"
        
        # 清除旧的IPv6路由规则
        ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true
        ip -6 rule del from all table 200 prio 200 2>/dev/null || true
        
        # 创建路由表200用于IPv6出站流量
        ip -6 route flush table 200 2>/dev/null || true
        
        # 添加IPv6默认路由到表200
        if ip -6 addr show dev tun0 | grep -q 'inet6'; then
            ip -6 route add default dev tun0 table 200
            
            # 标记的IPv6流量走原始网卡
            ip -6 rule add fwmark 22 table main prio 100
            
            # 非标记IPv6流量走VPN
            ip -6 rule add from all table 200 prio 200
            
            # 清除IPv6路由缓存
            ip -6 route flush cache
            
            # 标记所有IPv6入站连接
            ip6tables -t mangle -F
            ip6tables -t mangle -A INPUT -j MARK --set-mark 22
            ip6tables -t mangle -A OUTPUT -m state --state ESTABLISHED,RELATED -j MARK --set-mark 22
        fi
    fi
fi
SCRIPT

# 创建关闭脚本
cat > /etc/openvpn/client/scripts/down.sh <<'SCRIPT'
#!/bin/bash

# 清除所有添加的规则和表
ip rule del from all table 200 prio 200 2>/dev/null || true
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del to 8.8.8.8/32 table main prio 95 2>/dev/null || true
ip rule del to 1.1.1.1/32 table main prio 95 2>/dev/null || true

# 清除IPv6规则(如果存在)
ip -6 rule del from all table 200 prio 200 2>/dev/null || true
ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true

# 清除路由表
ip route flush table 200 2>/dev/null || true
ip -6 route flush table 200 2>/dev/null || true

# 清除iptables规则
iptables -t mangle -F
ip6tables -t mangle -F 2>/dev/null || true
SCRIPT

# 设置脚本权限
chmod +x /etc/openvpn/client/scripts/*.sh

# 5. 修改OpenVPN配置
echo ">>> 修改OpenVPN配置..."
cat >> /etc/openvpn/client/client.conf <<'CONF'

# --- 智能路由控制 ---

# 使用自定义脚本
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

# 屏蔽服务器的重定向网关指令，由我们自己控制
pull-filter ignore "redirect-gateway"
CONF

# 6. 配置系统参数
echo ">>> 配置系统参数..."
# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

# 开启 IPv6 转发
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

sysctl -p >/dev/null 2>&1

# 7. 配置NAT
echo ">>> 配置NAT规则..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# 保存防火墙规则
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > /etc/iptables/rules.v6
fi

# 8. 重启OpenVPN服务
echo ">>> 重启OpenVPN服务..."
systemctl daemon-reload
systemctl restart openvpn-client@client

# 9. 等待并验证
echo ">>> 等待连接建立 (10秒)..."
sleep 10

echo ">>> 验证连接状态..."

# 检查OpenVPN服务状态
if systemctl is-active --quiet openvpn-client@client; then
    echo "OpenVPN服务已成功启动"
else
    echo "错误: OpenVPN服务未启动或启动失败"
    systemctl status openvpn-client@client
    
    # 尝试手动启动OpenVPN
    echo "尝试手动启动OpenVPN..."
    systemctl daemon-reload
    systemctl restart openvpn-client@client
    sleep 5
fi

# 检查tun0接口
if ip addr show tun0 > /dev/null 2>&1; then
    echo "tun0接口已创建"
else
    echo "错误: tun0接口未创建"
fi

# 检查原始IP
echo ">>> 检测原始IPv4..."
ORIG_IP4=$(curl -4s --interface $(ip -4 route | grep default | grep -v tun | awk '{print $5}' | head -n 1) ip.sb)
echo "原始IPv4: $ORIG_IP4"

# 检查出口IP
echo ">>> 检测出口IPv4..."
CURRENT_IP4=$(curl -4s ip.sb)
echo "当前IPv4出口IP: $CURRENT_IP4"

# 检查IPv6出口
echo ">>> 检测出口IPv6..."
CURRENT_IP6=$(curl -6s ip.sb)
if [ -n "$CURRENT_IP6" ]; then
    echo "当前IPv6出口IP: $CURRENT_IP6"
else
    echo "未检测到IPv6出口IP"
fi

echo "==========================================="
echo "安装完成！OpenVPN客户端已配置并运行。"
echo "入口机IPv4和IPv6网络接口均可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接（IPv4和IPv6）。"
echo "==========================================="
