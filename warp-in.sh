#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (KVM + 路由隔离版)"
echo "   功能：接管 IPv4 + 彻底隔离 IPv6 (SSH 安全)"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 确保 TUN 模块加载 (KVM 标准操作)
modprobe tun 2>/dev/null || true

# 2. 安装软件
rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
apt update -y
apt install -y openvpn iptables iptables-persistent curl

# 3. 检查配置文件
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请先在出口端运行脚本并上传！"
    exit 1
fi

# 4. 部署配置文件 (双重文件名，防止服务报错)
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf
cp /root/client.ovpn /etc/openvpn/client/client.ovpn

# 5. 修改配置 (注入你的路由隔离逻辑)
echo ">>> 优化配置规则..."

# 清理旧钩子
rm -f /etc/openvpn/client/up.sh
rm -f /etc/openvpn/client/down.sh

# 如果出口脚本没改对，这里强制修正
sed -i 's/^proto udp$/proto udp6/g' /etc/openvpn/client/client.conf
sed -i 's/ udp$/ udp6/g' /etc/openvpn/client/client.conf

# 注入核心配置 (保留你原脚本的精华)
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 核心路由控制 ---

# 1. 仅接管 IPv4 (覆盖默认路由)
redirect-gateway def1

# 2. 彻底屏蔽服务端推送的 IPv6 路由 (保护 SSH 连接)
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"
pull-filter ignore "redirect-gateway"

# 3. [Warp 必需] 限制 MTU，防止 curl 卡死
mssfix 1280

# 4. DNS
dhcp-option DNS 1.1.1.1
dhcp-option DNS 8.8.8.8
CONF

# 同步修改备份文件
cp /etc/openvpn/client/client.conf /etc/openvpn/client/client.ovpn

# 6. 内核参数
echo ">>> 优化内核..."
sed -i '/disable_ipv6/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl --system >/dev/null 2>&1

# 7. NAT 配置 (确保流量能回来)
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

# 8. 重启服务
echo ">>> 重启 OpenVPN..."
systemctl daemon-reload
systemctl enable openvpn-client@client --now
systemctl restart openvpn-client@client

# 9. 验证
echo ">>> 等待 5 秒..."
sleep 5

echo "==========================================="
if systemctl is-active --quiet openvpn-client@client; then
    echo "✅ OpenVPN 服务运行中"
    
    # 测试 IPv4 (应该显示 Warp IP)
    IP4=$(curl -4 -s --max-time 8 ip.sb || echo "Fail")
    if [[ "$IP4" != "Fail" ]]; then
        echo -e "IPv4 出口: \033[32m$IP4\033[0m (成功)"
    else
        echo -e "IPv4 出口: \033[31m失败\033[0m (检查出口端 NAT)"
    fi
    
    # 测试 IPv6 (应该没变)
    IP6=$(curl -6 -s --max-time 5 ip.sb || echo "Fail")
    echo "IPv6 出口: $IP6 (应保持本机不变)"
else
    echo "❌ 服务启动失败！"
    echo "日志："
    journalctl -u openvpn-client@client -n 10 --no-pager
fi
echo "==========================================="
