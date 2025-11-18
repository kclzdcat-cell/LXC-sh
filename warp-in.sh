#!/bin/bash
clear
echo "=========================================================="
echo " OpenVPN 入口服务器安装脚本（只建立隧道，不断SSH）"
echo "=========================================================="

# 必须 root
if [ "$(id -u)" != "0" ]; then
  echo "❌ 请使用 root 运行！"
  exit 1
fi

# 检查系统
if ! grep -qiE "debian|ubuntu" /etc/os-release; then
  echo "❌ 此脚本仅支持 Debian / Ubuntu"
  exit 1
fi

echo
echo ">>> 更新系统中 ..."
apt update -y
apt install -y openvpn curl iproute2 iptables iptables-persistent

echo
echo ">>> 检测入口服务器 IPv6 ..."
IN_IPV6=$(curl -6 --connect-timeout 3 -s ipv6.ip.sb)
if [[ -z "$IN_IPV6" ]]; then
    IN_IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d/ -f1 | head -n 1)
fi

if [[ -z "$IN_IPV6" ]]; then
    echo "❌ 未检测到入口服务器 IPv6！必须使用 IPv6 才能安全 SSH。"
    exit 1
fi

echo "入口服务器 IPv6: $IN_IPV6"

echo
echo ">>> 自动检测网卡 ..."
NIC=$(ip route | grep default | awk '{print $5}' | head -n 1)
echo "入口服务器网卡: $NIC"

echo
echo ">>> 检查是否存在 client.ovpn ..."
if [ ! -f "/root/client.ovpn" ]; then
    echo "❌ 未找到 /root/client.ovpn，请先运行出口服务器脚本上传！"
    exit 1
fi

echo "找到 client.ovpn，准备创建隧道..."

mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

echo
echo ">>> 禁用 resolvconf 服务（避免 DNS 冲突）"
systemctl disable systemd-resolved --now 2>/dev/null
systemctl stop systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" >/etc/resolv.conf

echo
echo ">>> 启动 OpenVPN 隧道 ..."
systemctl enable openvpn@client
systemctl restart openvpn@client

sleep 3

echo
echo ">>> 检查 tun0 是否正常 ..."
if ! ip a | grep -q tun0; then
    echo "❌ tun0 未建立，请检查 client.ovpn 或出口服务器"
    exit 1
fi
echo "✅ tun0 已建立！"

echo
echo ">>> 配置路由：默认 IPv4 改为 tun0（走出口服务器 WARP）"

# 删除旧默认路由
ip route del default 2>/dev/null

# 让 tun0 成为默认 IPv4 出口
ip route add default dev tun0

echo
echo ">>> 保留 IPv6 直接走本地"
# IPv6 不动，保持入口服务器纯 IPv6 SSH 稳定

echo
echo ">>> 配置 NAT（使服务器自身也走隧道）"
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

echo
echo "================ 设置完成 ================="
echo "入口服务器 OpenVPN 隧道已建立！"
echo "入口 SSH 不会断开，你现在可以："
echo "✔ 使用 IPv6 SSH 继续管理服务器"
echo "✔ IPv4 已全部走出口服务器（WARP IPv4）"
echo
echo "检查 IPv4 出口: curl -4 ip.sb"
echo "查看隧道状态: systemctl status openvpn@client"
echo "查看 tun0: ip a | grep tun"
echo "=========================================================="
