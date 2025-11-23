#!/bin/bash
set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查并启动服务
start_service() {
    systemctl daemon-reload
    local service=$1
    if ! systemctl is-active --quiet $service; then
        log "启动 $service 服务..."
        systemctl start $service
    else
        log "$service 服务已在运行"
    fi

    if ! systemctl is-enabled --quiet $service; then
        log "启用 $service 服务..."
        systemctl enable $service
    else
        log "$service 服务已启用"
    fi
}

# 带重试的下载函数
download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log "下载 $url (第 $attempt 次)..."
        if curl -L -o "$output" "$url"; then
            return 0
        else
            log "下载失败"
            if [ $attempt -eq $max_attempts ]; then
                log "下载失败，已达最大重试次数"
                return 1
            fi
            attempt=$((attempt + 1))
            sleep 5
        fi
    done
}

# 主脚本开始
log "开始安装 rfw 防火墙..."

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_SUFFIX="x86_64"
        ;;
    aarch64|arm64)
        ARCH_SUFFIX="aarch64"
        ;;
    *)
        log "❌ 不支持的架构: $ARCH (仅支持 x86_64 和 aarch64)"
        exit 1
        ;;
esac
log "检测到架构: $ARCH ($ARCH_SUFFIX)"

# 检查 curl 是否安装
if ! command -v curl &> /dev/null; then
    log "安装 curl..."
    if command -v apt &> /dev/null; then
        apt update && apt install -y curl
    elif command -v yum &> /dev/null; then
        yum install -y curl
    else
        log "错误: 无法自动安装 curl，请手动安装"
        exit 1
    fi
fi

# 询问是否安装 rfw 防火墙
read -p "是否安装 rfw? [Y/n]: " install_rfw
install_rfw=${install_rfw:-Y}

if [[ "$install_rfw" =~ ^[Yy]$ ]]; then
    # 创建 rfw 目录和文件
    log "设置 rfw..."
    mkdir -p /root/rfw

    # 下载 rfw
    if [ ! -f "/root/rfw/rfw" ]; then
        if ! download_with_retry "https://github.com/narwhal-cloud/rfw/releases/latest/download/rfw-$ARCH-unknown-linux-musl" "/root/rfw/rfw"; then
            log "rfw 下载失败"
            exit 1
        fi
        chmod +x /root/rfw/rfw
    else
        log "rfw 已存在"
    fi

    # 创建系统服务
    if [ ! -f "/etc/systemd/system/rfw.service" ]; then
        log "创建 rfw 系统服务..."
        # 获取所有网络接口
        interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))

        # 检查是否有可用的网络接口
        if [ ${#interfaces[@]} -eq 0 ]; then
            echo "未找到可用的网络接口！"
            exit 1
        fi

        # 显示可用的网络接口
        echo "可用的网络接口："
        for i in "${!interfaces[@]}"; do
            echo "$((i+1)). ${interfaces[$i]}"
        done

        # 获取用户选择
        while true; do
            read -p "请选择网卡编号 (1-${#interfaces[@]}): " choice

            # 验证输入
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#interfaces[@]} ]; then
                selected_interface="${interfaces[$((choice-1))]}"
                break
            else
                echo "无效的选择，请输入 1-${#interfaces[@]} 之间的数字"
            fi
        done

        echo "您选择的网卡是: $selected_interface"

        # 创建 systemd 服务文件
        cat > /etc/systemd/system/rfw.service <<EOF
[Unit]
Description=RFW Firewall Service
After=network.target

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
ExecStart=/root/rfw/rfw --iface $selected_interface --block-email --block-http --block-socks5 --block-fet-strict --block-wireguard --countries CN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        log "rfw 服务已存在"
    fi

    # 启动 rfw 服务
    start_service rfw
else
    log "跳过 rfw 安装"
fi
