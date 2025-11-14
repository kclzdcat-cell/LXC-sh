#!/bin/bash
echo "==============================="
echo "🔴 一键清理 OpenGFW 残留服务与进程"
echo "==============================="

echo ">>> 停止 systemd 服务..."
systemctl stop opengfw.service 2>/dev/null

echo ">>> 禁用自启动..."
systemctl disable opengfw.service 2>/dev/null

echo ">>> 删除 systemd 服务文件..."
rm -f /etc/systemd/system/opengfw.service
rm -f /etc/systemd/system/opengfw*.service

echo ">>> 重载 systemd..."
systemctl daemon-reload

echo ">>> 杀掉残留进程..."
pkill -f opengfw 2>/dev/null
pkill -f gfw 2>/dev/null

echo ">>> 删除 /root 下的 OpenGFW 目录和脚本..."
rm -rf /root/opengfw 2>/dev/null
rm -f /root/opengfw.sh 2>/dev/null

echo ">>> 清理 Docker/Podman 容器（如果存在）..."
docker ps >/dev/null 2>&1 && docker stop $(docker ps -q 2>/dev/null) 2>/dev/null
podman ps >/dev/null 2>&1 && podman stop $(podman ps -q 2>/dev/null) 2>/dev/null

echo ">>> 清理完毕！"
echo
echo "==============================="
echo "🟢 开始检测 OpenGFW 运行状态"
echo "==============================="

echo ">>> 检查 Docker 容器"
docker ps 2>/dev/null | grep -i gfw && echo "Docker: 发现 OpenGFW 容器" || echo "Docker: 未发现 OpenGFW 容器"
echo

echo ">>> 检查 Podman 容器"
podman ps 2>/dev/null | grep -i gfw && echo "Podman: 发现 OpenGFW 容器" || echo "Podman: 未发现 OpenGFW 容器"
echo

echo ">>> 检查 systemd 服务"
systemctl list-units --type=service 2>/dev/null | grep -i gfw && echo "systemd: 服务仍存在" || echo "systemd: 未发现相关服务"
echo

echo ">>> 检查进程"
ps aux | grep -i gfw | grep -v grep && echo "进程: 发现 OpenGFW 相关进程" || echo "进程: 未发现相关进程"
echo

echo "==============================="
echo "✔ 检查完成（若全部显示未发现，则已完全卸载）"
echo "==============================="
