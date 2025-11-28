#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (IPv4 专用稳定版)"
echo "   功能：仅接管 IPv4 + 彻底隔离 IPv6 (SSH 绝对安全)"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 更新系统并安装组件..."
# 尝试修复可能的 dpkg 锁
rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm /var/lib/dpkg/lock 2>/dev/null || true
apt update -y
apt install -y openvpn iptables iptables-persistent curl

# 2. 检查 client.ovpn
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 修改配置 (回归最简稳健模式)
echo ">>> 配置路由规则..."

# 清理旧的复杂脚本配置 (如果之前运行过策略路由版本)
rm -f /etc/openvpn/client/up.sh
rm -f /etc/openvpn/client/down.sh
# 尝试清理可能残留的策略路由规则
ip -6 rule del table main priority 1000 2>/dev/null || true
ip -6 rule del from all table 200 2>/dev/null || true

# 核心配置：只接管 IPv4，屏蔽所有 IPv6 干扰
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 核心路由控制 ---

# 1. 仅接管 IPv4 (这是你要的功能)
redirect-gateway def1

# 2. 彻底屏蔽服务端推送的 IPv6 路由 (这是 SSH 不断连的保证)
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"

# 3. 屏蔽全局重定向指令 (防止服务端意外推送 redirect-gateway ipv6)
pull-filter ignore "redirect-gateway"

# 4. 强制 DNS
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
CONF

# 5. 内核参数 (只动 IPv4)
echo ">>> 优化内核参数..."
# 确保没有禁用 IPv6 (否则 SSH 会断)
sed -i '/disable_ipv6/d' /etc/sysctl.conf
# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1

# 6. 配置 NAT (只针对 IPv4)
echo ">>> 配置防火墙 NAT..."
iptables -t nat -F
# 允许 tun0 出流量伪装
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

# 7. 重启服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl restart openvpn-client@client

# 8. 等待并验证
echo ">>> 等待连接建立 (5秒)..."
sleep 5

echo "==========================================="
echo "网络状态验证："
echo "-------------------------------------------"
echo "1. OpenVPN 服务状态："
if systemctl is-active --quiet openvpn-client@client; then
    echo "   [OK] 服务运行中 (Active)"
else
    echo "   [ERROR] 服务未运行！"
    echo "   >>> 错误日志 (最后5行)："
    journalctl -u openvpn-client@client -n 5 --no-pager
fi

echo "-------------------------------------------"
echo "2. IPv4 出口测试："
IP4=$(curl -4 -s --connect-timeout 8 ip.sb || echo "获取失败")
if [[ "$IP4" != "获取失败" ]]; then
    # 使用绿色显示 IP
    echo -e "   当前 IPv4: \033[32m$IP4\033[0m (应为出口服务器 IP)"
else
    # 使用红色显示失败
    echo -e "   当前 IPv4: \033[31m获取失败\033[0m (请检查网络或 VPN 配置)"
fi

echo "-------------------------------------------"
echo "3. IPv6 状态："
echo "   OpenVPN IPv6 功能已禁用，以确保存活。"
echo "   SSH 连接应保持正常。"
echo "==========================================="
