#!/bin/bash

echo "==========================================="
echo "   WireGuard 入口部署 (极简版)"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：2.0"
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

# 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf

# 获取原始IP
echo ">>> 获取原始IP..."
ORIG_IP=$(curl -s ip.sb)
echo "原始IP: $ORIG_IP"

# 获取默认网卡
DEFAULT_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n 1)
echo "默认网卡: $DEFAULT_IFACE"

# 修改客户端配置，添加路由规则
echo ">>> 修改客户端配置..."
if ! grep -q "PostUp" /etc/wireguard/wg0.conf; then
    # 提取WireGuard服务器IP
    WG_SERVER_IP=$(grep "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d':' -f1)
    echo "WireGuard服务器IP: $WG_SERVER_IP"
    
    # 备份原始配置
    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
    
    # 添加路由规则
    cat > /etc/wireguard/wg0.conf <<EOF
$(cat /etc/wireguard/wg0.conf)

# 添加路由规则
PostUp = ip route add $WG_SERVER_IP via $(ip route | grep default | awk '{print $3}') dev $DEFAULT_IFACE
PostUp = iptables -A INPUT -p tcp --dport 22 -j ACCEPT
PostUp = iptables -A OUTPUT -p tcp --sport 22 -j ACCEPT
PostUp = iptables -t mangle -A PREROUTING -i $DEFAULT_IFACE -p tcp -j MARK --set-mark 22
PostUp = iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
PostUp = ip rule add fwmark 22 table main
PostUp = ip rule add from all table 200
PostUp = ip route add default dev wg0 table 200

PostDown = ip route del $WG_SERVER_IP via $(ip route | grep default | awk '{print $3}') dev $DEFAULT_IFACE
PostDown = iptables -D INPUT -p tcp --dport 22 -j ACCEPT
PostDown = iptables -D OUTPUT -p tcp --sport 22 -j ACCEPT
PostDown = iptables -t mangle -F
PostDown = ip rule del fwmark 22 table main
PostDown = ip rule del from all table 200
PostDown = ip route flush table 200
EOF
fi

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

# 检查出口IP
echo ">>> 检查出口IP..."
NEW_IP=$(curl -s ip.sb)
echo "当前出口IP: $NEW_IP"

if [ "$NEW_IP" = "$ORIG_IP" ]; then
    echo "警告：出口IP未改变，可能配置有误"
else
    echo "成功：出口IP已改变，VPN工作正常"
fi

echo "==========================================="
echo "安装完成！WireGuard客户端已配置并运行。"
echo "入口机网络接口可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接。"
echo "==========================================="
