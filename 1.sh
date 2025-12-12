#!/bin/bash

echo "========================================"
echo " LXC 容器机场 面板 / 节点 自动排查开始 "
echo "========================================"
echo

PANEL_LIST=()
NODE_LIST=()

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在排查容器：$c（机场面板 / 节点）"

  # --------- 面板检测（v2board / xboard）---------
  if lxc exec "$c" -- sh -c '
    (
      ps aux | grep -E "php-fpm|php artisan|nginx|apache" | grep -v grep
      find / -maxdepth 3 -type f -name ".env" 2>/dev/null
      find / -maxdepth 3 -type f -name "artisan" 2>/dev/null
    ) | grep -q .
  ' >/dev/null 2>&1; then
    echo "🚨 命中：疑似【机场面板】"
    PANEL_LIST+=("$c")
    echo
    continue
  fi

  # --------- 节点检测（V2bX / xray / sing-box）---------
  if lxc exec "$c" -- sh -c '
    (
      ps aux | grep -E "xray|sing-box|v2ray|V2bX" | grep -v grep
      ls /etc/V2bX 2>/dev/null
    ) | grep -q .
  ' >/dev/null 2>&1; then
    echo "⚠️ 命中：疑似【机场节点】"
    NODE_LIST+=("$c")
    echo
    continue
  fi

  echo "✅ 未发现机场相关特征"
  echo
done

echo "========================================"
echo "              排查结果汇总              "
echo "========================================"

if [ ${#PANEL_LIST[@]} -gt 0 ]; then
  echo
  echo "🚨 疑似【机场面板】容器："
  for i in "${PANEL_LIST[@]}"; do
    echo "  - $i"
  done
else
  echo
  echo "🚨 疑似【机场面板】容器：无"
fi

if [ ${#NODE_LIST[@]} -gt 0 ]; then
  echo
  echo "⚠️ 疑似【机场节点】容器："
  for i in "${NODE_LIST[@]}"; do
    echo "  - $i"
  done
else
  echo
  echo "⚠️ 疑似【机场节点】容器：无"
fi

echo
echo "✅ 排查完成"
