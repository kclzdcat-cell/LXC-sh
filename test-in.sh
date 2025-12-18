#!/bin/bash
set -e

echo "==========================================="
echo "   WireGuard 入口部署 (修复版)"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：1.1"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 安装必要软件..."

# 检查软件是否已安装
WG_INSTALLED=0
IPTABLES_INSTALLED=0
CURL_INSTALLED=0
HOST_INSTALLED=0

if command -v wg >/dev/null 2>&1; then
    WG_INSTALLED=1
    echo "WireGuard 已安装"
fi

if command -v iptables >/dev/null 2>&1; then
    IPTABLES_INSTALLED=1
    echo "iptables 已安装"
fi

if command -v curl >/dev/null 2>&1; then
    CURL_INSTALLED=1
    echo "curl 已安装"
fi

if command -v host >/dev/null 2>&1; then
    HOST_INSTALLED=1
    echo "host命令已安装"
fi

# 更新软件源
echo ">>> 更新软件源..."
apt-get update -y || echo "警告: apt update 失败，继续执行"

# 安装 WireGuard
if [[ $WG_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 WireGuard..."
    apt-get install -y wireguard || echo "警告: apt安装WireGuard失败"
    
    # 再次检查是否安装成功
    if ! command -v wg >/dev/null 2>&1; then
        echo "错误: 无法安装WireGuard，请手动安装后重试。"
        exit 1
    else
        echo "WireGuard 安装成功"
        WG_INSTALLED=1
    fi
fi

# 安装 iptables
if [[ $IPTABLES_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 iptables..."
    apt-get install -y iptables iptables-persistent || echo "警告: apt安装iptables失败"
    
    # 再次检查是否安装成功
    if ! command -v iptables >/dev/null 2>&1; then
        echo "错误: 无法安装iptables，请手动安装后重试。"
        exit 1
    else
        echo "iptables 安装成功"
        IPTABLES_INSTALLED=1
    fi
fi

# 安装 curl
if [[ $CURL_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 curl..."
    apt-get install -y curl || echo "警告: apt安装curl失败"
    
    # 再次检查是否安装成功
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误: 无法安装curl，请手动安装后重试。"
        exit 1
    else
        echo "curl 安装成功"
        CURL_INSTALLED=1
    fi
fi

# 安装 host 命令
if [[ $HOST_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 host命令..."
    apt-get install -y bind9-host dnsutils || echo "警告: 安装host命令失败"
    
    # 再次检查是否安装成功
    if command -v host >/dev/null 2>&1; then
        HOST_INSTALLED=1
        echo "host命令安装成功"
    else
        echo "警告: 无法安装host命令，将跳过DNS解析测试"
    fi
fi

# 2. 检查 wg_client.conf
if [ ! -f /root/wg_client.conf ]; then
    echo "错误：未找到 /root/wg_client.conf，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf

# 4. 创建路由脚本
echo ">>> 创建路由脚本..."

# 创建scripts目录
mkdir -p /etc/wireguard/scripts

# 提取WireGuard服务器IP和端口
WG_SERVER_IP=$(grep "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d':' -f1)
WG_SERVER_PORT=$(grep "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d':' -f2)

echo "WireGuard服务器IP: $WG_SERVER_IP"
echo "WireGuard服务器端口: $WG_SERVER_PORT"

# 5. 修改WireGuard配置
echo ">>> 修改WireGuard配置..."

# 添加自定义脚本到配置
if ! grep -q "PostUp" /etc/wireguard/wg0.conf; then
    # 备份原始配置
    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
    
    # 创建简化版的配置文件
    cat > /etc/wireguard/wg0.conf <<EOF
$(cat /etc/wireguard/wg0.conf)

# 添加NAT规则
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip -4 route | grep default | awk '{print $5}' | head -n 1) -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip -4 route | grep default | awk '{print $5}' | head -n 1) -j MASQUERADE
EOF
fi

# 6. 配置系统参数
echo ">>> 配置系统参数..."

# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# 开启 IPv6 转发
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

sysctl -p >/dev/null 2>&1

# 7. 启动WireGuard服务
echo ">>> 启动WireGuard服务..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 8. 等待并验证
echo ">>> 等待连接建立 (10秒)..."
sleep 10

echo ">>> 验证连接状态..."

# 检查WireGuard服务状态
if systemctl is-active --quiet wg-quick@wg0; then
    echo "WireGuard服务已成功启动"
else
    echo "错误: WireGuard服务未启动或启动失败"
    systemctl status wg-quick@wg0
    
    # 尝试手动启动WireGuard
    echo "尝试手动启动WireGuard..."
    systemctl daemon-reload
    systemctl restart wg-quick@wg0
    sleep 5
fi

# 检查wg0接口
if ip addr show wg0 > /dev/null 2>&1; then
    echo "wg0接口已创建"
    WG_CREATED=1
else
    echo "错误: wg0接口未创建，脚本将不会修改路由表"
    WG_CREATED=0
    
    # 如果没有wg0接口，则不要修改路由表
fi

# 检查原始IP
echo ">>> 检测原始IPv4..."
ORIG_DEV=$(ip -4 route | grep default | grep -v wg | awk '{print $5}' | head -n 1)
echo "原始网卡: $ORIG_DEV"
ORIG_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
echo "原始IPv4: $ORIG_IP4"

# 检查当前出口IP
echo ">>> 检测当前出口IPv4..."
CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
echo "当前IPv4出口IP: $CURRENT_IP4"

# 如果出口IP与原始IP相同，尝试修复
if [ "$CURRENT_IP4" = "$ORIG_IP4" ] && [ "$CURRENT_IP4" != "无法获取" ]; then
    echo ">>> 警告: 出口IP与原始IP相同，尝试修复..."
    
    # 检查WireGuard状态
    echo ">>> 检查WireGuard状态..."
    wg show
    
    # 尝试重启WireGuard
    echo ">>> 尝试重启WireGuard服务..."
    systemctl restart wg-quick@wg0
    sleep 5
    
    # 再次检查出口IP
    CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
    echo "重启WireGuard后的出口IPv4: $CURRENT_IP4"
fi

# 检查IPv6出口
echo ">>> 检测出口IPv6..."
CURRENT_IP6=$(curl -6s --connect-timeout 5 ip.sb || echo "无法获取")
if [ "$CURRENT_IP6" != "无法获取" ]; then
    echo "当前IPv6出口IP: $CURRENT_IP6"
else
    echo "未检测到IPv6出口IP"
fi

# 测试连接性
echo ">>> 测试连接性..."
ping -c 3 8.8.8.8 || echo "ping 8.8.8.8 失败"

echo "==========================================="
echo "安装完成！WireGuard客户端已配置并运行。"
echo "入口机IPv4和IPv6网络接口均可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接（IPv4和IPv6）。"
echo "==========================================="
