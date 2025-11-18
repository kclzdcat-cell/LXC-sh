#!/bin/bash
set -e

echo "======================================="
echo "     OpenVPN 入口服务器安装脚本"
echo "   （自动建立隧道，不会断 SSH）"
echo "======================================="

# ------- 1. 检查系统 -------
OS=$(grep -Eo "Ubuntu|Debian" /etc/os-release)
if [[ -z $OS ]]; then
    echo "❌ 不支持的系统，请使用 Debian 或 Ubuntu"
    exit 1
fi

echo "检测系统: $OS"

# ------- 2. 更新系统 -------
apt update -y
apt install -y openvpn iproute2 iptables iptables-persistent curl wget sshpass net-tools

# ------- 3. 检查 client.ovpn -------
CLIENT_FILE="/root/client.ovpn"
if [[ ! -f $CLIENT_FILE ]]; then
    echo "❌ 未找到 client.ovpn"
    echo "请先在出口服务器运行 out.sh 并上传 client.ovpn 到入口服务器 /root/"
    exit 1
fi

echo "✔ 发现 client.ovpn：$CLIENT_FILE"

# ------- 4. 创建 OpenVPN 客户端配置 -------
mkdir -p /etc/openvpn/client
cp $CLIENT_FILE /etc/openvpn/client/client.conf

# 修改为适用于 systemd 的配置文件名
ln -sf /etc/openvpn/client/client.conf /etc/openvpn/client.conf

echo "✔ 已复制 client.ovpn → /etc/openvpn/client/client.conf"

# ------- 5. 防止 SSH 断开：添加路由保护 -------
SSH_IP=$(echo $SSH_CONNECTION | awk '{print $1}')
SSH_GW=$(ip route get $SSH_IP | awk '/via/ {print $3}')

SSH_IF=$(ip route get $SSH_IP | awk '/dev/ {print $5}')

echo "SSH 来源 IP: $SSH_IP"
echo "SSH 网关: $SSH_GW"
echo "SSH 接口: $SSH_IF"

if [[ -n $SSH_GW ]]; then
    echo "为 SSH 保留直连路由..."
    ip route replace $SSH_IP via $SSH_GW dev $SSH_IF
fi

# ------- 6. 开启 IPv4 & IPv6 转发 -------
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
sysctl -p

# ------- 7. 启动 OpenVPN 客户端 -------
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo "等待 VPN 启动..."
sleep 4

# ------- 8. 检查 tun0 -------
if ip a | grep -q "tun0"; then
    echo "✔ tun0 接口已启用"
else
    echo "❌ tun0 未启动，请检查 VPN 配置"
    exit 1
fi

VPN_GW=$(ip route | awk '/10.8.0.1/ {print $3}')
echo "VPN 网关: $VPN_GW"

# ------- 9. 设置默认路由到 tun0 -------
echo "切换默认路由到 tun0..."

# 删除旧默认路由（不会影响 SSH，因为前面添加了保护路由）
ip route del default || true

# 添加新的默认路由
ip route add default via 10.8.0.1 dev tun0

echo "✔ 默认路由已切换到 tun0"

# ------- 10. 输出结果 -------
echo ""
echo "======================================="
echo " OpenVPN 入口服务器隧道已建立成功！"
echo " SSH 不断开，所有出口 IPv4/IPv6 走出口服务器！"
echo " 测试命令："
echo "   curl -4 ip.sb"
echo "   curl -6 ip.sb"
echo "======================================="
