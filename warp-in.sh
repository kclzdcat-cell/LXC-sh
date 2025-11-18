#!/bin/bash

echo "========================================"
echo " OpenVPN 入口服务器安装脚本 (不会断 IPv6 SSH)"
echo "========================================"

[ "$(id -u)" != "0" ] && echo "请用 root" && exit 1

apt update -y
apt install -y openvpn iproute2 curl

# 自动找入口网卡 (IPv6)
INET6=$(ip -6 route show default | awk '{print $5}' | head -n1)
echo "入口服务器出站 IPv6 网卡: $INET6"

# 复制 client.ovpn
if [ ! -f "/root/client.ovpn" ]; then
    echo "未找到 /root/client.ovpn，请先从出口服务器上传"
    exit 1
fi

mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

sleep 3

# 获取 tun0 是否正常
TUN=$(ip addr | grep tun0)
if [ -z "$TUN" ]; then
    echo "⚠️ OpenVPN 可能尚未建立，请检查日志"
else
    echo "OpenVPN 隧道已建立"
fi

# 🔥 只修改 IPv4 默认路由，不动 IPv6
VPN_GW=$(ip addr show tun0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
if [ -n "$VPN_GW" ]; then
    ip route del default 2>/dev/null
    ip route add default dev tun0
    echo "默认 IPv4 流量已成功改为 tun0"
else
    echo "⚠️ 未能检测到 VPN IPv4 地址，可能未连上 OpenVPN"
fi

echo "=============================="
echo " 入口安装完成！"
echo "IPv4 出口应显示出口服务器的 IPv4"
echo "执行：curl -4 ip.sb"
echo "=============================="
