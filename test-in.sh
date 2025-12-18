#!/bin/bash

echo "==========================================="
echo "   WireGuard 入口部署 (修复版)"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：5.0"
echo "==========================================="

# 安装WireGuard
echo ">>> 安装WireGuard..."
apt-get update
apt-get install -y wireguard iptables curl

# 检查客户端配置
if [ ! -f /root/wg_client.conf ]; then
    echo "错误：未找到 /root/wg_client.conf，请上传后重试！"
    exit 1
fi

# 获取原始IP
echo ">>> 获取原始IP..."
ORIG_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me || curl -4s icanhazip.com)
echo "原始IPv4: $ORIG_IP4"

# 获取默认网卡
DEFAULT_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n 1)
echo "默认网卡: $DEFAULT_IFACE"

# 提取WireGuard服务器IP和端口
WG_SERVER_IP4=$(grep "Endpoint" /root/wg_client.conf | awk '{print $3}' | cut -d':' -f1 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
WG_SERVER_PORT=$(grep "Endpoint" /root/wg_client.conf | awk '{print $3}' | cut -d':' -f2)
echo "WireGuard服务器IPv4: $WG_SERVER_IP4"
echo "WireGuard服务器端口: $WG_SERVER_PORT"

# 提取客户端私钥和地址
CLIENT_PRIVATE_KEY=$(grep "PrivateKey" /root/wg_client.conf | awk '{print $3}')
CLIENT_ADDRESS=$(grep "Address" /root/wg_client.conf | awk '{print $3}')
SERVER_PUBLIC_KEY=$(grep "PublicKey" /root/wg_client.conf | awk '{print $3}')

# 创建全新的配置文件
echo ">>> 创建WireGuard配置..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_ADDRESS
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $WG_SERVER_IP4:$WG_SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# 启用IP转发
echo ">>> 启用IP转发..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf

# 启动WireGuard
echo ">>> 启动WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 等待连接建立
echo ">>> 等待连接建立 (5秒)..."
sleep 5

# 检查状态
echo ">>> 检查状态..."
systemctl status wg-quick@wg0 --no-pager
wg show

# 检查wg0是否创建
if ip addr show wg0 > /dev/null 2>&1; then
    echo "wg0接口已创建，配置路由..."
    
    # 获取默认网关
    DEFAULT_GW=$(ip route | grep default | awk '{print $3}' | head -n 1)
    
    # 添加到WireGuard服务器的路由
    echo "添加到WireGuard服务器的直接路由..."
    ip route add $WG_SERVER_IP4 via $DEFAULT_GW dev $DEFAULT_IFACE
    
    # 应用成功的路由配置方法
    echo "配置IPv4路由..."
    ip route del default
    ip route add default dev wg0
    ip route add default via $DEFAULT_GW dev $DEFAULT_IFACE metric 100
    
    # 保护SSH连接
    echo "保护SSH连接..."
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A OUTPUT -p tcp --sport 22 -j ACCEPT
else
    echo "错误: wg0接口未创建，请检查配置"
    exit 1
fi

# IPv6路由配置选项
echo ">>> IPv6路由配置选项"
echo "是否启用IPv6出口流量通过VPN？"
echo "1) 是 - IPv6流量走出口机"
echo "2) 否 - IPv6流量走入口机本地"
read -p "请选择 (1/2): " IPV6_CHOICE

if [[ "$IPV6_CHOICE" == "1" ]]; then
    echo ">>> 配置IPv6路由通过VPN..."
    
    # 检查是否有IPv6
    if ip -6 addr show dev $DEFAULT_IFACE | grep -q 'inet6' 2>/dev/null; then
        # 获取IPv6默认网关
        DEFAULT_GW6=$(ip -6 route | grep default | grep -v wg | awk '{print $3}' | head -n 1)
        
        if [ -n "$DEFAULT_GW6" ]; then
            echo "配置IPv6路由..."
            echo "原IPv6网关: $DEFAULT_GW6"
            
            # 添加IPv6 SSH保护
            ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
            ip6tables -A OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || true
            
            # 删除IPv6默认路由
            ip -6 route del default 2>/dev/null || true
            
            # 等待wg0接口启动
            sleep 2
            
            # 检查wg0是否有IPv6地址
            if ip -6 addr show dev wg0 | grep -q 'fd00::' 2>/dev/null; then
                echo "wg0接口有IPv6地址，配置IPv6路由..."
                ip -6 route add default dev wg0 metric 1 2>/dev/null || true
            else
                echo "wg0接口没有IPv6地址，使用替代方案..."
                # 使用路由表方式
                ip -6 rule add from all table 200 prio 100 2>/dev/null || true
                ip -6 route add default dev wg0 table 200 2>/dev/null || true
            fi
            
            # 添加备用IPv6路由（更高metric）
            ip -6 route add default via $DEFAULT_GW6 dev $DEFAULT_IFACE metric 100 2>/dev/null || true
            
            # 检查wg0是否有IPv6地址
            if ip -6 addr show dev wg0 | grep -q 'inet6' 2>/dev/null; then
                echo "wg0接口有IPv6地址"
            else
                echo "wg0接口没有IPv6地址，但仍强制IPv6流量通过wg0"
            fi
            
            # 刷新IPv6路由缓存
            ip -6 route flush cache 2>/dev/null || true
            
            echo "IPv6路由已配置为通过VPN"
            
            # 显示IPv6路由表
            echo "IPv6路由表:"
            ip -6 route show | head -5
        else
            echo "未检测到IPv6网关，跳过IPv6配置"
        fi
    else
        echo "未检测到IPv6接口，跳过IPv6配置"
    fi
else
    echo ">>> 保持IPv6流量走入口机本地"
    # 确保IPv6路由不变
    if ip -6 addr show dev $DEFAULT_IFACE | grep -q 'inet6' 2>/dev/null; then
        DEFAULT_GW6=$(ip -6 route | grep default | grep -v wg | awk '{print $3}' | head -n 1)
        if [ -n "$DEFAULT_GW6" ]; then
            ip -6 route add default via $DEFAULT_GW6 dev $DEFAULT_IFACE 2>/dev/null || true
            echo "IPv6路由保持走入口机本地"
        fi
    fi
fi

# 检查出口IP
echo ">>> 检查出口IP..."
sleep 3
NEW_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me || curl -4s icanhazip.com)
echo "当前出口IPv4: $NEW_IP4"

if [ "$NEW_IP4" = "$ORIG_IP4" ]; then
    echo "警告：IPv4出口IP未改变，可能配置有误"
else
    echo "成功：IPv4出口IP已改变为 $NEW_IP4 (VPN工作正常)"
fi

# 检查IPv6出口
echo ">>> 检查IPv6出口..."
if [[ "$IPV6_CHOICE" == "1" ]]; then
    echo "等待IPv6路由生效..."
    sleep 2
    
    # 尝试多种方式检测IPv6
    NEW_IP6=$(curl -6s --connect-timeout 10 ip.sb 2>/dev/null || curl -6s --connect-timeout 10 ifconfig.me 2>/dev/null || echo "无法获取")
    
    if [ "$NEW_IP6" != "无法获取" ] && [ -n "$NEW_IP6" ]; then
        echo "当前出口IPv6: $NEW_IP6 (通过VPN)"
        # 检查是否为出口机IPv6
        if [[ "$NEW_IP6" == "2a13:2c0"* ]]; then
            echo "✓ 成功：IPv6已通过出口机(爱尔兰)"
        else
            echo "✓ IPv6已通过VPN，但不是预期的爱尔兰IP"
        fi
    else
        echo "IPv6通过VPN访问失败"
        echo "尝试诊断问题..."
        
        # 检查IPv6路由
        echo "IPv6路由表:"
        ip -6 route show | grep default
        
        # 尝试ping IPv6 DNS
        echo "测试IPv6连接..."
        ping6 -c 2 2001:4860:4860::8888 2>/dev/null && echo "IPv6网络连接正常" || echo "IPv6网络连接失败"
    fi
else
    NEW_IP6=$(curl -6s --connect-timeout 5 ip.sb || echo "无法获取")
    if [ "$NEW_IP6" != "无法获取" ]; then
        echo "当前出口IPv6: $NEW_IP6 (本地)"
    else
        echo "未检测到IPv6出口"
    fi
fi

echo "==========================================="
echo "安装完成！WireGuard客户端已配置并运行。"
echo "入口机网络接口可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接。"
echo "==========================================="
