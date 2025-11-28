#!/bin/bash
set -e

echo "==========================================="
echo "      OpenVPN 入口服务器客户端部署 (IPv6 修复版)"
echo "==========================================="

# 1. 安装必要软件
echo ">>> 更新系统并安装 OpenVPN..."
apt update -y
apt install -y openvpn iptables iptables-persistent

# 2. 检查配置文件是否存在
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请确认已上传配置文件！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 修改 OpenVPN 配置以接管 IPv4 流量
# 注意：这里追加 redirect-gateway def1 是核心，它会强制 IPv4 走 VPN
# block-outside-dns 也是为了防止 DNS 泄露，但在纯 IPv6 环境下若报错可移除
echo ">>> 配置路由接管规则..."
cat >> /etc/openvpn/client/client.conf <<EOF

# --- 自动添加的路由规则 ---
# 强制将默认 IPv4 网关重定向到 VPN (tun0)
redirect-gateway def1

# 保持 IPv6 路由不走 VPN (防止 SSH 断连)
# 如果你的 VPN 服务端同时也推流了 IPv6 路由，建议加上下面这行忽略服务端推过来的 IPv6 路由：
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"

# 强制使用公共 DNS (可选，防止原 DNS 不可达)
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
EOF

# 5. 开启内核转发 (IPv4)
echo ">>> 启用 IPv4 内核转发..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
else
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sed -i 's/^net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf
fi
# 这里特别注意：我们只开启 IPv4 转发，不动 IPv6 的设置，避免断连
sysctl -p

# 6. 配置防火墙 NAT 规则
# 确保从本机发出的流量或转发的流量可以通过 tun0 出去
echo ">>> 配置 IPTables NAT 规则..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

# 7. 启动 OpenVPN 服务
echo ">>> 启动 OpenVPN 客户端..."
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

# 8. 等待几秒让连接建立
echo ">>> 等待 VPN 连接建立 (5秒)..."
sleep 5

# 9. 验证结果
echo "==========================================="
echo "部署完成！正在验证网络状态..."
echo "-------------------------------------------"
echo "1. 本机 IPv4 出口 IP (应显示服务器 1 号 IP)："
curl -4 --connect-timeout 5 ip.sb || echo "无法获取 IPv4 (VPN可能未连接)"
echo "-------------------------------------------"
echo "2. 隧道接口状态："
ip addr show tun0 | grep "inet" || echo "tun0 未启动"
echo "==========================================="
echo "注意：SSH 连接应通过 IPv6 保持正常。"
