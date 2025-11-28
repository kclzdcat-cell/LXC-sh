#!/bin/bash
set -e

echo "==========================================="
echo "      OpenVPN 入口服务器客户端部署 (IPv6 防断连终极版)"
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
# 核心修改：增加了对 "redirect-gateway" 的屏蔽
echo ">>> 配置路由接管规则..."
cat >> /etc/openvpn/client/client.conf <<EOF

# --- 核心防断连规则 ---
# 1. 强制忽略服务端推送的重定向指令 (关键！防止服务端意外接管 IPv6)
pull-filter ignore "redirect-gateway"

# 2. 忽略服务端推送的 IPv6 路由和地址
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"

# 3. 仅在本地启用 IPv4 网关重定向 (只接管 IPv4，不动 IPv6)
redirect-gateway def1

# 4. 强制使用公共 DNS
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
EOF

# 5. 开启内核转发 (IPv4)
echo ">>> 启用 IPv4 内核转发..."
# 确保文件存在
touch /etc/sysctl.conf
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
else
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sed -i 's/^net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf
fi

# 再次确认没有禁用 IPv6 的设置 (防止旧配置残留)
sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf

# 应用设置
sysctl -p

# 6. 配置防火墙 NAT 规则
echo ">>> 配置 IPTables NAT 规则..."
# 清理旧的 NAT 规则防止冲突
iptables -t nat -F
# 添加 MASQUERADE 规则，确保流量能通过 tun0 出去
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

# 7. 启动 OpenVPN 服务
echo ">>> 启动 OpenVPN 客户端..."
# 先停止可能正在运行的服务
systemctl stop openvpn-client@client || true
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

# 8. 等待几秒让连接建立
echo ">>> 等待 VPN 连接建立 (5秒)..."
sleep 5

# 9. 验证结果
echo "==========================================="
echo "部署完成！正在验证网络状态..."
echo "-------------------------------------------"
echo "1. 本机 IPv4 出口 IP (应显示出口服务器 IP)："
curl -4 --connect-timeout 5 ip.sb || echo "无法获取 IPv4 (VPN可能未连接)"
echo "-------------------------------------------"
echo "2. 隧道接口状态："
ip addr show tun0 | grep "inet" || echo "tun0 未启动"
echo "==========================================="
echo "注意：SSH 连接 (IPv6) 应保持正常。"
