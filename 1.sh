#!/bin/bash

echo "========================================"
echo " LXC 机场面板 / V2bX 节点 精准排查开始 "
echo "========================================"
echo

PANEL_LIST=()
NODE_LIST=()

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在排查容器：$c（机场面板 / 节点）"

  # --------- 面板检测（严格 Laravel 特征）---------
  if lxc exec "$c" -- sh -c '
    (
      find / -maxdepth 3 -type f -name ".env" 2>/dev/null
      find / -maxdepth 3 -type f -name "artisan" 2>/dev/null
    ) | grep -q . &&
    ps aux | grep -E "php-fpm|nginx|apache" | grep -v grep | grep -q .
  ' >/dev/null 2>&1; then
    echo "🚨 命中：疑似【机场面板】"
    PANEL_LIST+=("$c")
    echo
    continue
  fi

  # --------- 节点检测（仅限 V2bX 生态）---------
  if lxc exec "$c" -- sh -c '
    (
      [ -x /etc/V2bX/V2bX ] &&
      ls /etc/V2bX/config.json >/dev/null 2>&1 &&
      grep -R "panel_url\|node_id\|token\|v2board\|xboard" /etc/V2bX 2>/dev/null
    ) ||
    ps aux | grep "[V]2bX" >/dev/null 2>&1
  ' >/dev/null 2>&1; then
    echo "⚠️ 命中：疑似【机场节点（V2bX）】"
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

echo
echo "🚨 疑似【机场面板】容器："
if [ ${#PANEL_LIST[@]} -eq 0 ]; then
  echo "  无"
else
  for i in "${PANEL_LIST[@]}"; do
    echo "  - $i"
  done
fi

echo
echo "⚠️ 疑似【机场节点（V2bX）】容器："
if [ ${#NODE_LIST[@]} -eq 0 ]; then
  echo "  无"
else
  for i in "${NODE_LIST[@]}"; do
    echo "  - $i"
  done
fi

echo
echo "✅ 排查完成（sing-box 自建节点不会被误判）"
