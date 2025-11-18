#!/bin/bash
clear
echo "=========================================="
echo "  OpenVPN 入口服务器安装脚本（不会修改路由，不会断开 SSH）"
echo "=========================================="

### 自动检测系统
if [ -f /etc/debian_version ]; then
    apt update -y
    apt install -y curl wget iproute2 openvpn
else
    echo "不支持的系统"
    exit 1
fi

### 检查 client.ovpn 是否存在
if [ ! -f /root/client.ovpn ]; then
    echo "❌ /root/client.ovpn 未找到！请从出口服务器复制过来！"
    exit 1
fi

### 写入 OpenVPN 客户端配置（禁止路由变更）
mkdir -p /etc/openvpn
cat >/etc/openvpn/client.conf <<EOF
$(cat /root/client.ovpn)

### ===== 强制禁止任何路由修改，避免 SSH 掉线 =====
route-noexec
pull-filter ignore redirect-gateway
pull-filter ignore "route "
pull-filter ignore "dhcp-option"
EOF

### 启动 OpenVPN 客户端
systemctl enable openvpn@client
systemctl restart openvpn@client

echo "=========================================="
echo "入口服务器 OpenVPN 隧道已建立"
echo "SSH 不会断开，无需担心！"
echo "查看状态：systemctl status openvpn@client"
echo "查看隧道：ip a | grep tun"
echo "=========================================="
