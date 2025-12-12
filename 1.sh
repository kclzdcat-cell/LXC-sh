#!/bin/bash

THRESHOLD_CONFIRMED=7
THRESHOLD_SUSPECT=4

echo "=================================================="
echo " LXC 机场审计工具（FINAL · 行为 + 配置 + 总结）"
echo "=================================================="
echo

CONFIRMED=()
SUSPECT=()

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在审计容器：$c"

  PANEL_SCORE=0
  NODE_SCORE=0
  CONFIG_HIT=0

  # ------------------------------------------------
  # 一、机场面板行为
  # ------------------------------------------------
  lxc exec "$c" -- ps aux | grep -E "nginx|apache|caddy|traefik" | grep -v grep >/dev/null 2>&1 \
    && PANEL_SCORE=$((PANEL_SCORE+2))

  lxc exec "$c" -- ps aux | grep -E "php-fpm|node .*server|gunicorn|uwsgi" | grep -v grep >/dev/null 2>&1 \
    && PANEL_SCORE=$((PANEL_SCORE+2))

  lxc exec "$c" -- sh -c 'find / -maxdepth 3 -name artisan 2>/dev/null | grep -q .' \
    && PANEL_SCORE=$((PANEL_SCORE+2))

  lxc exec "$c" -- sh -c 'find / -maxdepth 3 -name ".env" 2>/dev/null | grep -q .' \
    && PANEL_SCORE=$((PANEL_SCORE+1))

  # ------------------------------------------------
  # 二、机场节点行为
  # ------------------------------------------------
  lxc exec "$c" -- ps aux | grep -E "[V]2bX|[X]rayR|sspanel-node" >/dev/null 2>&1 \
    && NODE_SCORE=$((NODE_SCORE+3))

  lxc exec "$c" -- ss -tnp | grep ESTAB | grep -E "xray|sing-box|V2bX" >/dev/null 2>&1 \
    && NODE_SCORE=$((NODE_SCORE+1))

  lxc exec "$c" -- sh -c 'ls /etc | grep -Ei "V2bX|XrayR|sspanel" >/dev/null 2>&1' \
    && NODE_SCORE=$((NODE_SCORE+2))

  # ------------------------------------------------
  # 三、机场配置文件特征（关键新增）
  # ------------------------------------------------
  if lxc exec "$c" -- sh -c '
    grep -R -E "panel_url|node_id|token|api_key|subscribe|v2board|xboard|sspanel|xrayr|v2bx" \
      /etc /opt /usr/local/etc /root 2>/dev/null | grep -q .
  ' ; then
    CONFIG_HIT=1
    NODE_SCORE=$((NODE_SCORE+2))
    PANEL_SCORE=$((PANEL_SCORE+1))
  fi

  # ------------------------------------------------
  # 四、自建代理降权
  # ------------------------------------------------
  if lxc exec "$c" -- ps aux | grep -E "sing-box|xray" | grep -v grep >/dev/null 2>&1 &&
     ! lxc exec "$c" -- ps aux | grep -E "[V]2bX|[X]rayR|sspanel" >/dev/null 2>&1; then
    NODE_SCORE=$((NODE_SCORE-2))
  fi

  MAX_SCORE=$(( PANEL_SCORE > NODE_SCORE ? PANEL_SCORE : NODE_SCORE ))

  # ------------------------------------------------
  # 五、单容器结论
  # ------------------------------------------------
  if [ "$MAX_SCORE" -ge "$THRESHOLD_CONFIRMED" ]; then
    echo "🚨 确定：机场服务（score=$MAX_SCORE）"
    CONFIRMED+=("$c")
  elif [ "$MAX_SCORE" -ge "$THRESHOLD_SUSPECT" ] && [ "$CONFIG_HIT" -eq 1 ]; then
    echo "⚠️ 可疑：疑似机场（score=$MAX_SCORE）"
    SUSPECT+=("$c")
  else
    echo "✅ 无机场特征（panel=$PANEL_SCORE, node=$NODE_SCORE）"
  fi

  echo
done

echo "=================================================="
echo "                审计结果总结"
echo "=================================================="

echo
echo "🚨【确定机场】容器："
if [ ${#CONFIRMED[@]} -eq 0 ]; then
  echo "  无"
else
  for c in "${CONFIRMED[@]}"; do
    echo "  - $c"
  done
fi

echo
echo "⚠️【可疑机场】容器（建议人工复核）："
if [ ${#SUSPECT[@]} -eq 0 ]; then
  echo "  无"
else
  for c in "${SUSPECT[@]}"; do
    echo "  - $c"
  done
fi

echo
echo "✅ 审计完成"
