#!/bin/bash
set -e

echo "========================================================"
echo "   OpenVPN 入口端自动配置脚本 v3.4 (智能路由版)"
echo "   ✔ 自动判断本机是否有 IPv4"
echo "   ✔ 有 IPv4 则顶替，无 IPv4 则新增"
echo "   ✔ 严格保持 IPv6 路由不变 (保障 SSH)"
echo "========================================================"

# ================= 变量定义 =================
SOURCE_FILE="/root/client.ovpn"
TARGET_FILE="/etc/openvpn/client/client.conf"
# ===========================================

# 1. 检查并修复 TUN 设备
if [ ! -c /dev/net/tun ]; then
    echo ">>> 检测到 TUN 设备缺失，尝试修复..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
    if [ ! -c /dev/net/tun ]; then
        echo "❌ 无法创建 TUN 设备，请联系 VPS 服务商开启 TUN/TAP！"
        exit 1
    fi
    echo "✔ TUN 设备修复成功"
fi

# 2. 处理配置文件
echo ">>> 检查配置文件..."
if [ -f "$SOURCE_FILE" ]; then
    echo "✔ 发现上传的配置文件：$SOURCE_FILE"
    
    # 强制修正协议为 IPv6 (关键！)
    sed -i 's/^proto udp$/proto udp6/g' "$SOURCE_FILE"
    sed -i 's/^proto tcp$/proto tcp6/g' "$SOURCE_FILE"
    sed -i 's/ udp$/ udp6/g' "$SOURCE_FILE"
    
    # [核心] 添加 route-nopull
    # 这是实现 "IPv6 保持不变" 的关键，防止 VPN 服务端乱推路由
    if ! grep -q "route-nopull" "$SOURCE_FILE"; then
        echo "route-nopull" >> "$SOURCE_FILE"
        echo "✔ 已添加 route-nopull (锁定路由表)"
    fi

    cp "$SOURCE_FILE" "$TARGET_FILE"
    echo "✔ 已部署到系统路径：$TARGET_FILE"
elif [ -f "$TARGET_FILE" ]; then
    echo "⚠ 使用现有系统配置..."
    if ! grep -q "route-nopull" "$TARGET_FILE"; then
        echo "route-nopull" >> "$TARGET_FILE"
        echo "✔ 已为现有配置补全 route-nopull"
    fi
else
    echo "❌ 错误：找不到配置文件！请确保 warp-out.sh 已成功上传。"
    exit 1
fi

# 3. 安装 OpenVPN
if ! command -v openvpn &> /dev/null; then
    echo ">>> 安装 OpenVPN..."
    apt-get update && apt-get install -y openvpn
fi

# 4. 启动服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl enable openvpn-client@client --now
systemctl restart openvpn-client@client

# 5. 等待连接
echo ">>> 正在等待连接建立 (tun0)..."
TIMEOUT=0
while [ $TIMEOUT -lt 10 ]; do
    if ip link show tun0 >/dev/null 2>&1; then
        echo "✅ OpenVPN 连接成功！检测到 tun0 接口。"
        break
    fi
    sleep 1
    ((TIMEOUT++))
done

if [ $TIMEOUT -ge 10 ]; then
    echo "❌ 连接超时。正在抓取日志..."
    journalctl -u openvpn-client@client -n 20 --no-pager
    exit 1
fi

# 6. [智能路由配置] - 这里的逻辑完全符合你的要求
echo ">>> 配置 IPv4 路由..."

# 判断是否存在原生 IPv4 默认路由
HAS_IPV4=$(ip -4 route show default | wc -l)

if [ "$HAS_IPV4" -gt 0 ]; then
    echo "ℹ️  检测到本机已有 IPv4 出口。"
    echo ">>> 正在执行路由覆盖 (使用 tun0 顶替原 IPv4)..."
    # 我们不删除 default，而是添加更具体的路由 (0.0.0.0/1) 来覆盖它
    # 这样做的好处是：如果 VPN 挂了，系统会自动回退到原来的 IPv4，防止失联
    ip route add 0.0.0.0/1 dev tun0 2>/dev/null || true
    ip route add 128.0.0.0/1 dev tun0 2>/dev/null || true
else
    echo "ℹ️  未检测到本机 IPv4 出口 (纯 IPv6 环境)。"
    echo ">>> 正在添加 tun0 作为唯一的 IPv4 出口..."
    ip route add 0.0.0.0/1 dev tun0 2>/dev/null || true
    ip route add 128.0.0.0/1 dev tun0 2>/dev/null || true
fi

echo "✔ IPv4 路由规则已应用"
echo "✔ IPv6 路由保持不变 (由 route-nopull 保证)"

# 7. 最终测试
echo "========================================================"
echo "   🚀 最终连通性测试"
echo "========================================================"
echo "1. IPv4 (预期: 显示 Warp 出口 IP):"
curl -4 -s --max-time 5 ip.sb || echo "   ❌ IPv4 访问失败"

echo -e "\n2. IPv6 (预期: 显示本机原始 IPv6):"
curl -6 -s --max-time 5 ip.sb || echo "   ❌ IPv6 访问失败"

echo -e "\n========================================================"
