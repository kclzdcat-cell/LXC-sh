#!/bin/bash
set -e

echo "========================================================"
echo "   OpenVPN 入口端自动配置脚本 v3.31 (完美配对版)"
echo "   ✔ 自动接管 /root/client.ovpn"
echo "   ✔ 强制修正协议为 udp6 (适配纯 IPv6)"
echo "   ✔ 自动修复 LXC TUN 设备"
echo "========================================================"

# ================= 变量定义 =================
# 这是 warp-out.sh 上传文件的位置
SOURCE_FILE="/root/client.ovpn"
# 这是 OpenVPN 服务启动读取的位置
TARGET_FILE="/etc/openvpn/client/client.conf"
# ===========================================

# 1. 检查并修复 TUN 设备 (LXC/VPS 常见问题)
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
    
    # --- 关键修正：强制改为 IPv6 协议 ---
    # 防止出口端生成的配置是 proto udp，导致无法连接 IPv6 地址
    echo ">>> 正在修正协议适配纯 IPv6 环境..."
    sed -i 's/^proto udp$/proto udp6/g' "$SOURCE_FILE"
    sed -i 's/^proto tcp$/proto tcp6/g' "$SOURCE_FILE"
    # 修正 remote 行，例如 "remote xxxx udp" -> "remote xxxx udp6"
    sed -i 's/ udp$/ udp6/g' "$SOURCE_FILE"
    sed -i 's/ tcp$/ tcp6/g' "$SOURCE_FILE"
    
    # 复制到系统目录
    cp "$SOURCE_FILE" "$TARGET_FILE"
    echo "✔ 已部署到系统路径：$TARGET_FILE"
elif [ -f "$TARGET_FILE" ]; then
    echo "⚠ 未在 /root 发现新文件，使用现有的系统配置继续..."
else
    echo "❌ 错误：找不到 $SOURCE_FILE！"
    echo "   请确认 warp-out.sh 的自动上传已显示“验证成功”。"
    echo "   或者手动将 client.ovpn 上传到入口服务器的 /root/ 目录。"
    exit 1
fi

# 3. 安装 OpenVPN (如果没有安装)
if ! command -v openvpn &> /dev/null; then
    echo ">>> 检测到未安装 OpenVPN，正在安装..."
    apt-get update && apt-get install -y openvpn
fi

# 4. 启动服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl enable openvpn-client@client --now
systemctl restart openvpn-client@client

# 5. 循环检测连接状态
echo ">>> 正在等待连接建立 (tun0)..."
TIMEOUT=0
while [ $TIMEOUT -lt 20 ]; do
    if ip link show tun0 >/dev/null 2>&1; then
        echo "✅ OpenVPN 连接成功！检测到 tun0 接口。"
        break
    fi
    echo -n "."
    sleep 1
    ((TIMEOUT++))
done
echo ""

if [ $TIMEOUT -ge 20 ]; then
    echo "❌ 连接超时：未检测到 tun0。"
    echo ">>> 正在获取最后 20 行错误日志..."
    journalctl -u openvpn-client@client -n 20 --no-pager
    exit 1
fi

# 6. 配置路由 (强制 IPv4 走隧道)
echo ">>> 配置路由表..."
# 获取 tun0 的 IP 信息
TUN_IP=$(ip -4 addr show tun0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "    tun0 IP: $TUN_IP"

# 删除旧的默认 IPv4 路由（避免冲突，如果有的话）
ip route del default 2>/dev/null || true

# 添加覆盖路由 (0.0.0.0/1 和 128.0.0.0/1)
# 这种方式比 default 更安全，不会破坏系统原有路由表结构
ip route add 0.0.0.0/1 dev tun0
ip route add 128.0.0.0/1 dev tun0

echo "✔ 路由规则已应用：IPv4 流量 -> tun0 -> 出口服务器"

# 7. 最终测试
echo "========================================================"
echo "   🚀 最终连通性测试"
echo "========================================================"

echo "1. 测试 IPv4 (应显示 Cloudflare Warp IP)："
curl -4 -s --max-time 5 ip.sb || echo "   ❌ IPv4 请求失败 (请检查出口 NAT/转发)"

echo "2. 测试 IPv6 (应保持入口本机 IP)："
curl -6 -s --max-time 5 ip.sb || echo "   ❌ IPv6 请求失败 (请检查本机 IPv6 网络)"

echo "========================================================"
echo "如果上方 IPv4 显示了南极洲/Warp IP，则部署完全成功！"
