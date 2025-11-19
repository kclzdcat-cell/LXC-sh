#!/bin/bash

echo "======================================"
echo "   OpenVPN 入口服务器路由修复脚本 v3.0"
echo "   IPv6 保持不变（用于 SSH / 外网）"
echo "   所有 IPv4 流量强制通过 tun0 → 出口机"
echo "======================================"

# 关闭 OpenVPN（确保重新加载）
systemctl restart openvpn-client@client 2>/dev/null || true

echo ">>> 检查 OpenVPN（等待 tun0 出现）..."
for i in {1..20}; do
    if ip link show tun0 >/dev/null 2>&1; then
        echo ">>> 已检测到 tun0"
        break
    fi
    echo "等待 tun0..."
    sleep 1
done

if ! ip link show tun0 >/dev/null 2>&1; then
    echo "❌ 未检测到 tun0，OpenVPN 未成功连接！"
    exit 1
fi

echo ">>> tun0 信息："
ip addr show tun0

echo ">>> 删除旧的 IPv4 默认路由（如果有）..."
ip route del default 2>/dev/null || true

echo ">>> 为 IPv4 添加双半段路由（def1 等价）..."
ip route add 0.0.0.0/1 dev tun0
ip route add 128.0.0.0/1 dev tun0

echo ">>> IPv4 现在走 tun0，IPv6 保持原样"

echo ">>> 当前 IPv4 路由："
ip route

echo ">>> 当前 IPv6 路由（不变）："
ip -6 route

echo ">>> 测试 IPv4 出口（应显示出口服务器 IP）"
curl -4 ip.sb --max-time 3 || echo "无法访问 IPv4，请检查出口 NAT"

echo ">>> 测试 IPv6 出口（应显示入口机自己的 IPv6）"
curl -6 ip.sb --max-time 3 || echo "IPv6 测试失败"

echo "======================================"
echo "✔ 完成：IPv4 已通过 tun0 → 出口服务器"
echo "✔ 完成：IPv6 保持入口机原本线路"
echo "======================================"
