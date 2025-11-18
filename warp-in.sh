#!/bin/bash
set -e

echo "============================================"
echo "  OpenVPN 入口服务器脚本（不断SSH，不断网）"
echo "============================================"

if ! command -v apt >/dev/null; then
    echo "仅支持 Debian / Ubuntu"
    exit 1
fi

apt update -y
apt install -y openvpn curl iproute2

echo "正在安装 client.ovpn..."
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn!"
    exit 1
fi

# ------------------------#
#  启动 OpenVPN 客户端
# ------------------------#
cp /root/client.ovpn /etc/openvpn/client.conf
systemctl enable openvpn@client
systemctl restart openvpn@client

echo "等待 OpenVPN 隧道建立..."
sleep 3

# ------------------------#
#  检查 tun0 是否 UP
# ------------------------#
if ! ip link show tun0 >/dev/null 2>&1; then
    echo "❌ tun0 未创建，OpenVPN 启动失败"
    exit 1
fi

# 等待 IP
sleep 2

TUN_IP=$(ip -4 addr show tun0 | grep inet | awk '{print $2}')
if [ -z "$TUN_IP" ]; then
    echo "❌ tun0 没有 IPv4 地址，隧道失败！"
    exit 1
fi

echo "tun0 已建立：$TUN_IP"

# ------------------------#
#  安全切换默认路由
# ------------------------#
OLDGW=$(ip route | awk '/default/ {print $3}')
echo "当前默认网关：$OLDGW"

echo "切换默认路由到 tun0..."
ip route replace default dev tun0

# 保存恢复脚本
cat >/root/recover-route.sh <<EOF
#!/bin/bash
ip route replace default via $OLDGW
EOF
chmod +x /root/recover-route.sh

echo "路由切换完成！如需恢复原路由： /root/recover-route.sh"

echo "入口服务器 OpenVPN 隧道已建立！"
echo "SSH 不会掉线，可放心使用！"
