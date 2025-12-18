#!/bin/bash
set -e

echo "==========================================="
echo "   WireGuard 入口部署"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：1.0"
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

# 提取WireGuard服务器IP和端口
WG_SERVER_IP=$(grep "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d':' -f1)
WG_SERVER_PORT=$(grep "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d':' -f2)

echo "WireGuard服务器IP: $WG_SERVER_IP"
echo "WireGuard服务器端口: $WG_SERVER_PORT"

# 创建启动脚本
cat > /etc/wireguard/scripts/route-up.sh <<'SCRIPT'
#!/bin/bash

# 获取网卡信息
DEV4=$(ip -4 route | grep default | grep -v wg | awk '{print $5}' | head -n 1)
GW4=$(ip -4 route | grep default | grep -v wg | awk '{print $3}' | head -n 1)

echo "[路由配置] 原始网卡: $DEV4, 网关: $GW4"

# 清除旧的路由规则
echo "[路由配置] 清除旧的路由规则..."
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del from all table 200 prio 200 2>/dev/null || true

# 清除旧的防火墙规则
echo "[路由配置] 清除iptables规则..."
iptables -t mangle -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true

# 首先保护SSH连接
echo "[路由配置] 保护SSH连接..."
# 获取当前SSH端口
SSH_PORT=22  # 默认SSH端口
if netstat -tnlp 2>/dev/null | grep -q sshd; then
    SSH_PORT=$(netstat -tnlp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -n 1)
    echo "[路由配置] 检测到SSH端口: $SSH_PORT"
fi

# 先添加SSH规则，确保SSH不会断开
iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
iptables -A OUTPUT -p tcp --sport $SSH_PORT -j ACCEPT

# 对所有SSH相关流量进行标记
iptables -t mangle -A INPUT -p tcp --dport $SSH_PORT -j MARK --set-mark 22
iptables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 22

# 标记所有TCP入站连接
echo "[路由配置] 标记所有TCP入站连接..."
iptables -t mangle -A INPUT -p tcp -j MARK --set-mark 22
iptables -t mangle -A OUTPUT -p tcp -m state --state ESTABLISHED,RELATED -j MARK --set-mark 22

# 如果有IPv6，也标记IPv6流量
if ip -6 addr show dev $DEV4 | grep -q 'inet6' 2>/dev/null; then
    # 保护IPv6 SSH连接
    ip6tables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -p tcp --sport $SSH_PORT -j ACCEPT 2>/dev/null || true
    
    # 标记IPv6流量
    ip6tables -t mangle -A INPUT -p tcp --dport $SSH_PORT -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -A INPUT -p tcp -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -A OUTPUT -p tcp -m state --state ESTABLISHED,RELATED -j MARK --set-mark 22 2>/dev/null || true
fi

# 获取WireGuard服务器IP
WG_SERVER_IP=$(grep "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d':' -f1)

# 先添加到WireGuard服务器的直接路由
echo "[路由配置] 添加到WireGuard服务器的直接路由: $WG_SERVER_IP via $GW4 dev $DEV4"
ip route add $WG_SERVER_IP via $GW4 dev $DEV4 2>/dev/null || true

# 标记的流量走原始网卡
echo "[路由配置] 添加标记流量规则..."
ip rule add fwmark 22 table main prio 100

# 添加DNS服务器的路由
echo "[路由配置] 添加DNS服务器路由..."
ip rule add to 8.8.8.8/32 table main prio 95
ip rule add to 1.1.1.1/32 table main prio 95

# 创建路由表200用于出站流量
echo "[路由配置] 创建路由表200..."
ip route flush table 200 2>/dev/null || true

# 添加默认路由到表200
echo "[路由配置] 添加默认路由到表200: default dev wg0"
ip route add default dev wg0 table 200 2>/dev/null || true

# 非标记流量走WireGuard
echo "[路由配置] 添加非标记流量规则..."
ip rule add from all table 200 prio 200

# 清除路由缓存
echo "[路由配置] 清除路由缓存..."
ip route flush cache

# 显示路由规则
echo "[路由配置] 当前路由规则:"
ip rule show

# 显示路由表
echo "[路由配置] 路由表200:"
ip route show table 200

# IPv6配置
if ip -6 addr show dev $DEV4 | grep -q 'inet6' 2>/dev/null; then
    # 获取IPv6网关
    GW6=$(ip -6 route | grep default | grep -v wg | awk '{print $3}' | head -n 1)
    
    if [ -n "$GW6" ]; then
        echo "[路由配置] IPv6网关: $GW6"
        
        # 清除旧的IPv6路由规则
        ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true
        ip -6 rule del from all table 200 prio 200 2>/dev/null || true
        
        # 创建路由表200用于IPv6出站流量
        ip -6 route flush table 200 2>/dev/null || true
        
        # 标记的IPv6流量走原始网卡
        ip -6 rule add fwmark 22 table main prio 100 2>/dev/null || true
        
        # 添加IPv6默认路由到表200
        if ip -6 addr show dev wg0 | grep -q 'inet6' 2>/dev/null; then
            echo "[路由配置] 添加IPv6默认路由到表200"
            ip -6 route add default dev wg0 table 200 2>/dev/null || true
            
            # 非标记IPv6流量走WireGuard
            ip -6 rule add from all table 200 prio 200 2>/dev/null || true
            
            # 清除IPv6路由缓存
            ip -6 route flush cache 2>/dev/null || true
        else
            echo "[路由配置] wg0接口没有IPv6地址，跳过IPv6路由配置"
        fi
    else
        echo "[路由配置] 未检测到IPv6网关，跳过IPv6路由配置"
    fi
else
    echo "[路由配置] 未检测到IPv6接口，跳过IPv6路由配置"
fi
SCRIPT

# 创建关闭脚本
cat > /etc/wireguard/scripts/down.sh <<'SCRIPT'
#!/bin/bash

# 清除所有添加的规则和表
echo "[清理] 清除路由规则..."
ip rule del from all table 200 prio 200 2>/dev/null || true
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del to 8.8.8.8/32 table main prio 95 2>/dev/null || true
ip rule del to 1.1.1.1/32 table main prio 95 2>/dev/null || true

# 清除IPv6规则(如果存在)
echo "[清理] 清除IPv6路由规则..."
ip -6 rule del from all table 200 prio 200 2>/dev/null || true
ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true

# 清除路由表
echo "[清理] 清除路由表..."
ip route flush table 200 2>/dev/null || true
ip -6 route flush table 200 2>/dev/null || true

# 清除iptables规则
echo "[清理] 清除iptables规则..."
iptables -t mangle -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || true

# 清除ip6tables规则
echo "[清理] 清除ip6tables规则..."
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
ip6tables -D OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || true

# 恢复原始路由
echo "[清理] 恢复原始路由..."
ip route flush cache
SCRIPT

# 设置脚本权限
mkdir -p /etc/wireguard/scripts
chmod +x /etc/wireguard/scripts/*.sh

# 5. 修改WireGuard配置
echo ">>> 修改WireGuard配置..."

# 添加自定义脚本到配置
if ! grep -q "PostUp" /etc/wireguard/wg0.conf; then
    # 备份原始配置
    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
    
    # 修改配置文件
    sed -i '/\[Interface\]/a PostUp = /etc/wireguard/scripts/route-up.sh\nPostDown = /etc/wireguard/scripts/down.sh' /etc/wireguard/wg0.conf
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

# 7. 配置NAT
echo ">>> 配置NAT规则..."

echo ">>> 使用iptables配置NAT..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

# 如果有IPv6，添加IPv6 NAT规则
if ip -6 addr show | grep -q 'inet6' 2>/dev/null; then
    echo ">>> 配置IPv6 NAT规则..."
    ip6tables -t nat -F 2>/dev/null || true
    ip6tables -t nat -A POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || true
fi

# 保存防火墙规则
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > /etc/iptables/rules.v6
fi

# 8. 启动WireGuard服务
echo ">>> 启动WireGuard服务..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 9. 等待并验证
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
ORIG_IP4=$(curl -4s --interface $ORIG_DEV --connect-timeout 5 ip.sb || echo "无法获取")
echo "原始IPv4: $ORIG_IP4"

# 检查wg0接口IP
echo ">>> 检测wg0接口IPv4..."
if ip addr show wg0 > /dev/null 2>&1; then
    WG_IP4=$(curl -4s --interface wg0 --connect-timeout 5 ip.sb || echo "无法获取")
    echo "wg0接口IPv4: $WG_IP4"
else
    echo "wg0接口不存在"
fi

# 检查当前出口IP
echo ">>> 检测当前出口IPv4..."
CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
echo "当前IPv4出口IP: $CURRENT_IP4"

# 如果出口IP与原始IP相同，尝试修复路由
if [ "$CURRENT_IP4" = "$ORIG_IP4" ] && [ "$CURRENT_IP4" != "无法获取" ]; then
    echo ">>> 警告: 出口IP与原始IP相同，尝试修复路由..."
    
    # 检查wg0接口状态
    echo ">>> 检查wg0接口详细状态..."
    ip addr show wg0
    
    # 检查WireGuard连接状态
    echo ">>> 检查WireGuard状态..."
    wg show
    
    # 检查路由表
    echo ">>> 检查路由表详情..."
    ip route
    ip route show table 200
    ip rule show
    
    # 检查防火墙规则
    echo ">>> 检查iptables规则..."
    iptables -t mangle -L -v -n
    iptables -t nat -L -v -n
    
    # 检查IPv6防火墙规则
    if ip -6 addr show | grep -q 'inet6' 2>/dev/null; then
        echo ">>> 检查ip6tables规则..."
        ip6tables -t mangle -L -v -n 2>/dev/null || true
        ip6tables -t nat -L -v -n 2>/dev/null || true
    fi
    
    # 尝试修复路由
    echo ">>> 尝试修复路由..."
    
    # 重新配置路由表
    echo "重新配置路由表..."
    ip route flush table 200
    ip rule del table 200 2>/dev/null || true
    ip rule add from all table 200 prio 200
    ip route add default dev wg0 table 200
    ip route flush cache
    
    # 再次检查出口IP
    sleep 3
    CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
    echo "重新配置后的出口IPv4: $CURRENT_IP4"
    
    # 如果仍然失败，尝试重启WireGuard
    if [ "$CURRENT_IP4" = "$ORIG_IP4" ] || [ "$CURRENT_IP4" = "无法获取" ]; then
        echo ">>> 尝试重启WireGuard服务..."
        systemctl restart wg-quick@wg0
        sleep 5
        
        # 再次检查出口IP
        CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
        echo "重启WireGuard后的出口IPv4: $CURRENT_IP4"
    fi
fi

# 检查IPv6出口
echo ">>> 检测出口IPv6..."
CURRENT_IP6=$(curl -6s --connect-timeout 5 ip.sb || echo "无法获取")
if [ "$CURRENT_IP6" != "无法获取" ]; then
    echo "当前IPv6出口IP: $CURRENT_IP6"
else
    echo "未检测到IPv6出口IP"
fi

# 检查DNS解析
echo ">>> 检查DNS解析..."
if [[ $HOST_INSTALLED -eq 1 ]]; then
    host -t A google.com || echo "DNS解析失败"
else
    echo "host命令未安装，跳过DNS解析测试"
fi

# 测试连接性
echo ">>> 测试连接性..."
ping -c 3 8.8.8.8 || echo "ping 8.8.8.8 失败"

echo "==========================================="
echo "安装完成！WireGuard客户端已配置并运行。"
echo "入口机IPv4和IPv6网络接口均可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接（IPv4和IPv6）。"
echo "==========================================="
