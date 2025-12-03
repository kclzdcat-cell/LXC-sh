#!/bin/bash
set -e

echo "========================================================"
echo "   OpenVPN 入口端自动配置脚本 v3.6"
echo "   ✔ 自动判断本机是否有 IPv4"
echo "   ✔ 有 IPv4 则顶替，无 IPv4 则新增"
echo "   ✔ 严格保持 IPv6 路由不变 (保障 SSH)"
echo "========================================================"

# ================= 变量定义 =================
SOURCE_FILE="/root/client.ovpn"
TARGET_FILE="/etc/openvpn/client/client.conf"
# ===========================================

# 1. 优先安装 OpenVPN
echo ">>> 检查并安装 OpenVPN..."
if ! command -v openvpn &> /dev/null; then
    echo ">>> OpenVPN 未安装，正在安装..."
    apt-get update -qq
    apt-get install -y openvpn
    echo "✔ OpenVPN 安装完成"
else
    OPENVPN_VERSION=$(openvpn --version | head -n 1)
    echo "✔ OpenVPN 已安装: $OPENVPN_VERSION"
fi

# 2. 检查并修复 TUN 设备
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

# 3. 处理配置文件
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

# 4. 清理旧服务残留
echo ">>> 清理旧服务残留..."
# 停止可能存在的旧服务
systemctl stop openvpn-client@client 2>/dev/null || true
systemctl disable openvpn-client@client 2>/dev/null || true
# 清理可能存在的旧进程
killall openvpn 2>/dev/null || true
sleep 2
echo "✔ 清理完成"

# 5. 创建必要的目录
echo ">>> 确保目录结构正确..."
mkdir -p /etc/openvpn/client
echo "✔ 目录检查完成"

# 6. 启动服务
echo ">>> 启动 OpenVPN 服务..."
systemctl daemon-reload
echo "   - daemon-reload 完成"

# 先 enable
if systemctl enable openvpn-client@client 2>&1; then
    echo "   - 服务已设置为开机启动"
else
    echo "   ⚠️  enable 失败，但继续尝试启动..."
fi

# 再 start
echo "   - 正在启动服务..."
if systemctl start openvpn-client@client 2>&1; then
    echo "   - 服务启动命令执行完成"
else
    echo "   ❌ 服务启动命令执行失败"
fi

# 7. 检查服务状态
echo ">>> 检查 OpenVPN 服务状态..."
sleep 3

# 获取服务状态
SERVICE_STATUS=$(systemctl is-active openvpn-client@client 2>&1 || echo "inactive")
echo "   服务状态: $SERVICE_STATUS"

if [ "$SERVICE_STATUS" != "active" ]; then
    echo ""
    echo "❌ OpenVPN 服务启动失败！"
    echo "========================================"
    echo ">>> 详细服务状态:"
    echo "========================================"
    systemctl status openvpn-client@client --no-pager -l || true
    echo ""
    echo "========================================"
    echo ">>> 最近50行日志:"
    echo "========================================"
    journalctl -u openvpn-client@client -n 50 --no-pager || true
    echo ""
    echo "========================================"
    echo ">>> 配置文件检查:"
    echo "========================================"
    if [ -f "$TARGET_FILE" ]; then
        echo "配置文件存在: $TARGET_FILE"
        echo "文件大小: $(wc -c < "$TARGET_FILE") bytes"
        echo "前10行内容:"
        head -n 10 "$TARGET_FILE"
    else
        echo "❌ 配置文件不存在: $TARGET_FILE"
    fi
    echo ""
    echo ">>> 请检查以上错误信息。"
    exit 1
fi
echo "✔ OpenVPN 服务运行中"

# 8. 等待连接建立
echo ">>> 正在等待连接建立 (tun0)..."
TIMEOUT=0
MAX_WAIT=30  # 增加到30秒

while [ $TIMEOUT -lt $MAX_WAIT ]; do
    if ip link show tun0 >/dev/null 2>&1; then
        echo "✅ OpenVPN 连接成功！检测到 tun0 接口。"
        # 等待接口完全就绪
        sleep 2
        echo ">>> tun0 接口信息:"
        ip addr show tun0
        break
    fi
    
    # 每5秒输出一次进度
    if [ $((TIMEOUT % 5)) -eq 0 ] && [ $TIMEOUT -gt 0 ]; then
        echo "   等待中... ($TIMEOUT/$MAX_WAIT 秒)"
    fi
    
    sleep 1
    ((TIMEOUT++))
done

if [ $TIMEOUT -ge $MAX_WAIT ]; then
    echo "❌ 连接超时 (等待了 $MAX_WAIT 秒)。"
    echo ""
    echo ">>> OpenVPN 服务状态:"
    systemctl status openvpn-client@client --no-pager -l
    echo ""
    echo ">>> 最近50行日志:"
    journalctl -u openvpn-client@client -n 50 --no-pager
    echo ""
    echo ">>> 网络接口列表:"
    ip link show
    echo ""
    echo ">>> 可能的原因:"
    echo "   1. 出口服务器的 OpenVPN 服务未运行"
    echo "   2. IPv6 连接到出口服务器失败"
    echo "   3. 防火墙阻止了连接"
    echo "   4. client.ovpn 配置文件有误"
    exit 1
fi

# 9. [智能路由配置] - 这里的逻辑完全符合你的要求
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

# 10. 最终测试
echo "========================================================"
echo "   🚀 最终连通性测试"
echo "========================================================"

echo ">>> 当前路由表:"
echo "IPv4 路由:"
ip -4 route show
echo ""
echo "IPv6 路由:"
ip -6 route show | head -n 5
echo ""

echo "1. IPv4 连通性测试 (预期: 显示 Warp 出口 IP):"
IPV4_RESULT=$(curl -4 -s --max-time 10 ip.sb 2>&1)
if [ $? -eq 0 ]; then
    echo "   ✅ IPv4: $IPV4_RESULT"
else
    echo "   ❌ IPv4 访问失败: $IPV4_RESULT"
    echo "   >>> 尝试 ping 测试:"
    ping -4 -c 2 1.1.1.1 || echo "   >>> ping 也失败"
fi

echo ""
echo "2. IPv6 连通性测试 (预期: 显示本机原始 IPv6):"
IPV6_RESULT=$(curl -6 -s --max-time 10 ip.sb 2>&1)
if [ $? -eq 0 ]; then
    echo "   ✅ IPv6: $IPV6_RESULT"
else
    echo "   ⚠️  IPv6 访问失败: $IPV6_RESULT"
fi

echo ""
echo "========================================================"
echo "   部署完成！"
echo "========================================================"
