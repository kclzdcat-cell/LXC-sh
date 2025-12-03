#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (KVM 修复版)"
echo "   ✔ 修复：同时生成 client.conf 和 client.ovpn"
echo "   ✔ 修复：强制 udp6 协议 (KVM 互联必须)"
echo "   ✔ 保留：IPv6 路由彻底隔离 (SSH 安全)"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装软件
rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
apt update -y
apt install -y openvpn iptables iptables-persistent curl

# 2. 检查源文件
if [ ! -f /root/client.ovpn ]; then
    echo "❌ 错误：未找到 /root/client.ovpn，请确保出口脚本已运行并上传成功！"
    exit 1
fi

# 3. [核心修复] 双重部署配置文件
# 解决报错 "Error opening configuration file: .../client.ovpn"
echo ">>> 部署配置文件 (双重备份)..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf
cp /root/client.ovpn /etc/openvpn/client/client.ovpn

# 4. [环境修复] 批量修正协议与配置
echo ">>> 正在修正协议与路由策略..."

# 对两个文件同时操作，确保万无一失
for CONF in /etc/openvpn/client/client.conf /etc/openvpn/client/client.ovpn; do
    
    # 强制修正为 udp6 (解决 KVM 纯 IPv6 无法握手的问题)
    sed -i 's/^proto udp$/proto udp6/g' "$CONF"
    sed -i 's/^proto tcp$/proto tcp6/g' "$CONF"
    sed -i 's/ udp$/ udp6/g' "$CONF"
    
    # 清理可能存在的旧配置
    sed -i '/redirect-gateway/d' "$CONF"
    sed -i '/pull-filter/d' "$CONF"
    sed -i '/mssfix/d' "$CONF"
    sed -i '/dhcp-option DNS/d' "$CONF"

    # 注入你的“稳定版”核心逻辑
    cat >> "$CONF" <<EOF

# --- 核心路由控制 (你的原版逻辑) ---
# 1. 仅接管 IPv4
redirect-gateway def1

# 2. [SSH 保护] 屏蔽服务端推送的 IPv6 路由
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"
pull-filter ignore "redirect-gateway"

# 3. [Warp 适配] 限制 MTU 防止卡死
mssfix 1280

# 4. 强制 DNS
dhcp-option DNS 1.1.1.1
dhcp-option DNS 8.8.8.8
EOF
done

# 5. 内核参数 (KVM IPv4 转发)
echo ">>> 优化内核参数..."
sed -i '/disable_ipv6/d' /etc/sysctl.conf
# 确保开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1

# 6. 配置 NAT
echo ">>> 配置防火墙 NAT..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save >/dev/null 2>&1

# 7. 重启服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
# 先停止以防冲突
systemctl stop openvpn-client@client
# 启动
systemctl enable openvpn-client@client --now
systemctl restart openvpn-client@client

# 8. 验证
echo ">>> 等待 5 秒..."
sleep 5

echo "==========================================="
echo "验证结果："
if systemctl is-active --quiet openvpn-client@client; then
    echo "✅ OpenVPN 服务运行中"
    
    # 测试 IPv4 (Warp)
    IP4=$(curl -4 -s --max-time 5 ip.sb || echo "Fail")
    if [[ "$IP4" != "Fail" ]]; then
        echo -e "IPv4 出口: \033[32m$IP4\033[0m (成功)"
    else
        echo -e "IPv4 出口: \033[31m连接超时\033[0m (可能是出口端 Warp 网络问题)"
    fi
    
    # 测试 IPv6 (SSH 安全)
    IP6=$(curl -6 -s --max-time 5 ip.sb || echo "Fail")
    echo "IPv6 出口: $IP6 (应保持本机不变)"
else
    echo "❌ 服务启动失败！"
    echo ">>> 最新错误日志："
    journalctl -u openvpn-client@client -n 10 --no-pager
fi
echo "==========================================="
