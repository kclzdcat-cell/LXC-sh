#!/bin/bash

echo "==========================================="
echo "   WireGuard 出口部署 (修复版)"
echo "   功能：作为VPN出口服务器"
echo "   版本：5.1"
echo "==========================================="

# 安装WireGuard
echo ">>> 安装WireGuard..."
apt-get update
apt-get install -y wireguard iptables curl

# 获取公网IPv4
echo ">>> 获取公网IPv4..."
PUBLIC_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me || curl -4s icanhazip.com)
echo "公网IPv4: $PUBLIC_IP4"

# 获取默认网卡
DEFAULT_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n 1)
echo "默认网卡: $DEFAULT_IFACE"

# 生成密钥
echo ">>> 生成密钥..."
umask 077
mkdir -p /etc/wireguard
cd /etc/wireguard
wg genkey > server_private.key
wg pubkey < server_private.key > server_public.key
wg genkey > client_private.key
wg pubkey < client_private.key > client_public.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(cat client_public.key)

echo "服务器公钥: $SERVER_PUBLIC_KEY"
echo "客户端公钥: $CLIENT_PUBLIC_KEY"

# 创建服务器配置
echo ">>> 创建服务器配置..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd00::1/64
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32, fd00::2/128
EOF

# 创建客户端配置
echo ">>> 创建客户端配置..."
cat > /root/wg_client.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd00::2/64
PrivateKey = $CLIENT_PRIVATE_KEY
DNS = 8.8.8.8, 1.1.1.1, 2001:4860:4860::8888

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $PUBLIC_IP4:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# 启用IP转发
echo ">>> 启用IP转发..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf

# 配置NAT
echo ">>> 配置NAT..."
iptables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT

# 配置IPv6 NAT
echo ">>> 配置IPv6 NAT..."
ip6tables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE 2>/dev/null || echo "警告: IPv6 NAT配置失败"
ip6tables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || echo "警告: IPv6 FORWARD配置失败"

# 启动WireGuard
echo ">>> 启动WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 检查状态
echo ">>> 检查状态..."
systemctl status wg-quick@wg0 --no-pager
wg show

echo "==========================================="
echo "安装完成！WireGuard服务器已配置并运行。"
echo "客户端配置文件位于: /root/wg_client.conf"
echo "请将此文件安全地传输到入口机。"
echo "==========================================="

# 提供上传选项
echo "是否要将客户端配置上传到入口机？(y/n)"
read -r UPLOAD_CHOICE

if [[ "$UPLOAD_CHOICE" == "y" || "$UPLOAD_CHOICE" == "Y" ]]; then
    echo "请输入入口机的IP地址:"
    read -r ENTRY_IP
    
    echo "请输入入口机的SSH端口 (默认: 22):"
    read -r ENTRY_PORT
    ENTRY_PORT=${ENTRY_PORT:-22}
    
    echo "请输入入口机的用户名 (默认: root):"
    read -r ENTRY_USER
    ENTRY_USER=${ENTRY_USER:-root}

    echo "请输入入口机的ssh密码:"
    read -r ENTER_PAWD
    
    echo "正在上传客户端配置到入口机..."
    scp -P "$ENTRY_PORT" /root/wg_client.conf "$ENTRY_USER@$ENTRY_IP:/root/wg_client.conf"
    
    if [ $? -eq 0 ]; then
        echo "客户端配置已成功上传到入口机。"
    else
        echo "上传失败，请手动传输配置文件。"
    fi
else
    echo "请手动将客户端配置文件传输到入口机。"
fi
