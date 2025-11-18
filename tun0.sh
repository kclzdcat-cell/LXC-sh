#!/bin/bash

echo "==============================="
echo "🚀 强制走 OpenVPN tun0 默认路由"
echo "==============================="

# 确保 OpenVPN 运行（必要时可补 systemctl restart）
# systemctl restart openvpn-client@client 2>/dev/null
# sleep 3

# 等待 tun0 出现
echo ">>> 检查 tun0 是否存在..."
while ! ip link show tun0 >/dev/null 2>&1; do
    echo ">>> 未检测到 tun0，等待 1 秒..."
    sleep 1
done

echo ">>> 已检测到 tun0，准备切换默认路由"

# 删除原默认路由（eth0）
echo ">>> 删除原默认路由..."
ip route del default 2>/dev/null

# 设置默认路由为 tun0
echo ">>> 设置默认路由为 tun0..."
ip route add default dev tun0

echo ">>> 已完成默认路由切换"

# 显示新的路由表
echo "==============================="
echo "🛰 当前路由："
ip route

# 显示当前出口 IP
echo "==============================="
echo "🌐 当前出口 IP："
curl -4 ip.sb || curl ip.sb

echo "==============================="
echo "✔ 已强制走 tun0"
echo "==============================="
