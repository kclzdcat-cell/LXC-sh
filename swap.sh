#!/bin/bash
set -e

echo "[INFO] 检测系统中是否启用 /swapfile ..."

# 检查 /swapfile 是否被启用为swap
SWAPFILE_ACTIVE=$(swapon --noheadings --raw | awk '{print $1}' | grep '^/swapfile$' || true)

if [[ -n "$SWAPFILE_ACTIVE" ]]; then
    echo "[WARN] /swapfile 目前作为 swap 使用中。"
    read -rp "是否关闭 /swapfile 的 swap？[y/N]: " disable_swapfile
    if [[ "$disable_swapfile" =~ ^[Yy]$ ]]; then
        echo "[INFO] 正在关闭 /swapfile ..."
        swapoff /swapfile
        echo "[INFO] /swapfile swap 已关闭。退出脚本。"
        exit 0
    else
        echo "[INFO] 保持 /swapfile swap 状态，不做修改，退出脚本。"
        exit 0
    fi
else
    echo "[INFO] /swapfile 当前未启用为 swap，进入创建流程。"
fi

# 选择单位
while true; do
    read -rp "请选择单位 GB 或 MB (输入 G 或 M): " UNIT
    UNIT=${UNIT^^}  # 转成大写
    if [[ "$UNIT" == "G" || "$UNIT" == "M" ]]; then
        break
    else
        echo "[ERROR] 请输入有效单位 G 或 M"
    fi
done

# 输入大小
while true; do
    read -rp "请输入想创建的 Swap 大小 (单位: $UNIT): " SIZE
    if [[ "$SIZE" =~ ^[1-9][0-9]*$ ]]; then
        break
    else
        echo "[ERROR] 请输入正整数大小"
    fi
done

# 计算字节数
if [[ "$UNIT" == "G" ]]; then
    SWAP_SIZE_BYTES=$((SIZE * 1024 * 1024 * 1024))
else
    SWAP_SIZE_BYTES=$((SIZE * 1024 * 1024))
fi

echo "[INFO] 创建 ${SIZE}${UNIT} 大小的 swap 文件 /swapfile ..."
fallocate -l $SWAP_SIZE_BYTES /swapfile

echo "[INFO] 设置文件权限..."
chmod 600 /swapfile

echo "[INFO] 格式化 swap 文件..."
mkswap /swapfile

echo "[INFO] 启用 swap 文件..."
swapon /swapfile

# 检查 fstab 是否已存在 swapfile 条目
if grep -q '^/swapfile' /etc/fstab; then
    echo "[INFO] /etc/fstab 已存在 swapfile 条目，跳过写入。"
else
    echo "[INFO] 写入 /etc/fstab 以实现开机自动启用 swap ..."
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

echo "[INFO] Swap 创建并启用成功。当前 swap 状态："
swapon --show

echo "[INFO] 脚本执行完毕。"
