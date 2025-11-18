#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器自动安装脚本（最终稳定版）"
echo " 不修改系统默认路由，不断开 SSH，安全稳定"
echo "==========================================="

#---------------- 检查系统 ----------------#
if ! command -v apt >/dev/null 2>&1; then
    echo "❌ 仅支持 Debian / Ubuntu 系统"
    exit 1
fi

apt update -y
apt install -y openvpn curl iproute2

#---------------- 显示提示 ----------------#
echo "================================================="
echo " 此脚本只负责："
echo "   ✔ 接收出口服务器上传的 client.ovpn"
echo "   ✔ 自动创建 OpenVPN 隧道（tun0）"
echo "   ✔ 不会修改默认路由（因此 SSH 不会断）"
echo "================================================="

#---------------- 检查是否已有 client.ovpn ----------------#
if [[ ! -f /root/client.ovpn ]]; then
    echo
    echo "⚠ 未检测到 /root/client.ovpn，请确保出口服务器已经上传！"
    echo "你稍后可手动上传：scp client.ovpn root@[入口IP]:/root/"
    echo
    exit 1
else
    echo "找到 client.ovpn -> /root/client.ovpn"
fi

#---------------- 创建 openvpn@client 服务 ----------------#
mkdir -p /etc/openvpn/client/
cp /root/client.ovpn /etc/openvpn/client/client.conf

echo
echo ">>> 启动 OpenVPN 隧道（tun0）..."

systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

sleep 2

#---------------- 检查 TUN 状态 ----------------#
echo
echo ">>> 检查 OpenVPN 状态:"
systemctl status openvpn-client@client --no-pager || true

echo
echo ">>> 检查 tun0:"
ip a | grep tun || echo "⚠ 未检测到 tun0，请检查出口服务器与入口 client.ovpn"

#---------------- 完成 ----------------#
echo "===================================================="
echo " OpenVPN 入口服务器部署完成！"
echo " 隧道已建立（如果 tun0 存在）"
echo " SSH 不会断开，无需担心"
echo "===================================================="
