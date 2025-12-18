#!/bin/bash
set -e

echo "==========================================="
echo "   WireGuard 出口部署 (修复版)"
echo "   功能：作为VPN出口服务器"
echo "   版本：1.1"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 安装必要软件..."

# 检查软件是否已安装
WG_INSTALLED=0
IPTABLES_INSTALLED=0
CURL_INSTALLED=0

if command -v wg >/dev/null 2>&1; then
    WG_INSTALLED=1
    echo "WireGuard 已安装"
fi

if command -v iptables >/dev/null 2>&1; then
    IPTABLES_INSTALLED=1
    echo "iptables 已安装"
fi

if command -v curl >/dev/null 2>&1; then
    CURL_INSTALLED=1
    echo "curl 已安装"
fi

# 更新软件源
echo ">>> 更新软件源..."
apt-get update -y || echo "警告: apt update 失败，继续执行"

# 安装 WireGuard
if [[ $WG_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 WireGuard..."
    apt-get install -y wireguard || echo "警告: apt安装WireGuard失败"
    
    # 再次检查是否安装成功
    if ! command -v wg >/dev/null 2>&1; then
        echo "错误: 无法安装WireGuard，请手动安装后重试。"
        exit 1
    else
        echo "WireGuard 安装成功"
        WG_INSTALLED=1
    fi
fi

# 安装 iptables
if [[ $IPTABLES_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 iptables..."
    apt-get install -y iptables iptables-persistent || echo "警告: apt安装iptables失败"
    
    # 再次检查是否安装成功
    if ! command -v iptables >/dev/null 2>&1; then
        echo "错误: 无法安装iptables，请手动安装后重试。"
        exit 1
    else
        echo "iptables 安装成功"
        IPTABLES_INSTALLED=1
    fi
fi

# 安装 curl
if [[ $CURL_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 curl..."
    apt-get install -y curl || echo "警告: apt安装curl失败"
    
    # 再次检查是否安装成功
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误: 无法安装curl，请手动安装后重试。"
        exit 1
    else
        echo "curl 安装成功"
        CURL_INSTALLED=1
    fi
fi

# 2. 获取网络信息
echo ">>> 获取网络信息..."

# 获取公网IPv4
echo ">>> 获取公网IPv4..."
PUBLIC_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
if [ "$PUBLIC_IP4" = "无法获取" ]; then
    echo "警告: 无法获取公网IPv4，尝试其他方法..."
    PUBLIC_IP4=$(curl -4s --connect-timeout 5 ifconfig.me || curl -4s --connect-timeout 5 icanhazip.com || echo "无法获取")
fi
echo "公网IPv4: $PUBLIC_IP4"

# 获取公网IPv6（如果有）
echo ">>> 获取公网IPv6..."
PUBLIC_IP6=$(curl -6s --connect-timeout 5 ip.sb || echo "无法获取")
if [ "$PUBLIC_IP6" = "无法获取" ]; then
    echo "警告: 无法获取公网IPv6，尝试其他方法..."
    PUBLIC_IP6=$(curl -6s --connect-timeout 5 ifconfig.me || curl -6s --connect-timeout 5 icanhazip.com || echo "无法获取")
fi
echo "公网IPv6: $PUBLIC_IP6"

# 获取默认网卡
DEFAULT_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n 1)
echo "默认网卡: $DEFAULT_IFACE"

# 3. 生成密钥
echo ">>> 生成WireGuard密钥..."
mkdir -p /etc/wireguard/keys
cd /etc/wireguard/keys

# 服务器密钥
if [ ! -f server_private.key ]; then
    wg genkey > server_private.key
    chmod 600 server_private.key
fi
SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

# 客户端密钥
if [ ! -f client_private.key ]; then
    wg genkey > client_private.key
    chmod 600 client_private.key
fi
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

echo "服务器公钥: $SERVER_PUBLIC_KEY"
echo "客户端公钥: $CLIENT_PUBLIC_KEY"

# 4. 配置WireGuard服务器
echo ">>> 配置WireGuard服务器..."

# 选择端口
WG_PORT=51820
echo "WireGuard端口: $WG_PORT"

# 创建服务器配置文件
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = $WG_PORT
SaveConfig = true

# 启用IPv4转发
PostUp = sysctl -w net.ipv4.ip_forward=1
# 配置NAT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
# 如果有IPv6，也配置IPv6
PostUp = [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && sysctl -w net.ipv6.conf.all.forwarding=1 || true
PostUp = [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && ip6tables -A FORWARD -i wg0 -j ACCEPT || true
PostUp = [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && ip6tables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE || true

# 清理规则
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
PostDown = [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && ip6tables -D FORWARD -i wg0 -j ACCEPT || true
PostDown = [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && ip6tables -t nat -D POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE || true

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

# 5. 创建客户端配置文件
echo ">>> 创建客户端配置文件..."

cat > /root/wg_client.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $PUBLIC_IP4:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# 6. 配置系统参数
echo ">>> 配置系统参数..."

# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# 开启 IPv6 转发（如果有IPv6）
if [ "$PUBLIC_IP6" != "无法获取" ]; then
    if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
fi

sysctl -p

# 7. 启动WireGuard服务
echo ">>> 启动WireGuard服务..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 8. 验证服务状态
echo ">>> 验证服务状态..."
if systemctl is-active --quiet wg-quick@wg0; then
    echo "WireGuard服务已成功启动"
else
    echo "错误: WireGuard服务启动失败"
    systemctl status wg-quick@wg0
fi

# 显示接口状态
echo ">>> WireGuard接口状态:"
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
