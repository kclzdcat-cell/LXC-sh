#!/bin/bash

echo "==========================================="
echo "   WireGuard 入口部署 (修复版)"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：4.0"
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

# 添加路由规则
echo ">>> 添加路由规则..."

# 确保WireGuard服务器IP走原始网卡
echo "添加到WireGuard服务器的直接路由..."
ip route add $WG_SERVER_IP4 via $(ip route | grep default | awk '{print $3}') dev $DEFAULT_IFACE

# 保护SSH连接
echo "保护SSH连接..."
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 22 -j ACCEPT

# 标记SSH流量
echo "标记SSH流量..."
iptables -t mangle -A PREROUTING -i $DEFAULT_IFACE -p tcp -j MARK --set-mark 22
iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22

# 添加路由规则
echo "添加路由规则..."
ip rule add fwmark 22 table main
ip route add default dev wg0 table 200
ip rule add from all table 200

# 检查出口IP
echo ">>> 检查出口IP..."
sleep 3
NEW_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me || curl -4s icanhazip.com)
echo "当前出口IPv4: $NEW_IP4"

if [ "$NEW_IP4" = "$ORIG_IP4" ]; then
    echo "警告：出口IP未改变，可能配置有误"
    
    # 尝试修复
    echo ">>> 尝试修复路由..."
    ip route flush table 200
    ip route add default dev wg0 table 200
    
    sleep 3
    NEW_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me || curl -4s icanhazip.com)
    echo "修复后出口IPv4: $NEW_IP4"
else
    echo "成功：出口IP已改变，VPN工作正常"
fi

echo "==========================================="
echo "安装完成！WireGuard客户端已配置并运行。"
echo "入口机网络接口可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接。"
echo "==========================================="
