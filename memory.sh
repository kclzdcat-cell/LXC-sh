#!/bin/bash

echo "====== 优化前内存情况 ======"
free -h

echo
echo "====== 开始清理内核缓存 ======"
sync
echo 3 > /proc/sys/vm/drop_caches

echo
echo "====== 设置 swappiness = 60（更积极使用 swap） ======"
sysctl -w vm.swappiness=60 >/dev/null

if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
    echo "vm.swappiness=60" >> /etc/sysctl.conf
fi

echo
echo "====== 禁用不必要服务（如果存在） ======"
systemctl stop apport.service 2>/dev/null
systemctl disable apport.service 2>/dev/null
systemctl stop ufw.service 2>/dev/null
systemctl disable ufw.service 2>/dev/null
systemctl stop snapd.service 2>/dev/null
systemctl disable snapd.service 2>/dev/null

echo
echo "====== 再次清理内存缓存 ======"
sync
echo 3 > /proc/sys/vm/drop_caches

echo
echo "====== 优化后内存情况 ======"
free -h

echo
echo "====== 优化完成 ======"
