#!/bin/bash
clear
echo "=========================================="
echo "  OpenVPN 入口服务器安装脚本（仅建立隧道，不改路由）"
echo "=========================================="

### 自动检测系统
if [ -f /etc/debian_version ]; then
    apt update -y
    apt install -y curl wget iproute2 openvpn iptables iptables-persistent
else
    echo "不支持的系统"
    exit 1
fi

### 检查 client.ovpn 是否存在
if [ ! -f /root/client.ovpn ]; then
    echo "❌ /root/client.ovpn 未找到！请从出口服务器复制过来！"
    exit 1
fi

### 创建 OpenVPN client 配置
cp /root/client.ovpn /etc/openvpn/client.conf

### 不要 push 路由，不改变默认出口，由入口服务器保持本地 IPv4 出站
### 只建立隧道用于远端 NAT

### 启动 OpenVPN 客户端
systemctl enable openvpn@client
systemctl restart openvpn@client

echo "=========================================="
echo " 入口服务器 OpenVPN 隧道已建立！"
echo " 请使用：ip a  查看 tun0 状态"
echo "=========================================="
