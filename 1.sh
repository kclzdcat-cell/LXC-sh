#!/bin/bash

THRESHOLD_PANEL=6
THRESHOLD_NODE=6

echo "=================================================="
echo " LXC 机场服务审计工具（FINAL 可用版）"
echo " 基于多证据评分制，避免误杀自建服务"
echo "=================================================="
echo

declare -A PANEL_SCORE
declare -A NODE_SCORE

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在审计容器：$c"
  PANEL_SCORE[$c]=0
  NODE_SCORE[$c]=0

  # ------------------------------------------------
  # 一、机场面板行为检测
  # ------------------------------------------------

  # Web 服务运行
  if lxc exec "$c" -- ps aux | grep -E "nginx|apache|caddy|traefik" | grep -v grep >/dev/null 2>&1; then
    PANEL_SCORE[$c]=$((PANEL_SCORE[$c]+2))
  fi

  # 后端语言（php / node / python）
  if lxc exec "$c" -- ps aux | grep -E "php-fpm|node .*server|gunicorn|uwsgi" | grep -v grep >/dev/null 2>&1; then
    PANEL_SCORE[$c]=$((PANEL_SCORE[$c]+2))
  fi

  # Laravel / 常见面板结构
  if lxc exec "$c" -- sh -c 'find / -maxdepth 3 -name artisan 2>/dev/null | grep -q .' ; then
    PANEL_SCORE[$c]=$((PANEL_SCORE[$c]+2))
  fi

  if lxc exec "$c" -- sh -c 'find / -maxdepth 3 -name ".env" 2>/dev/null | grep -q .' ; then
    PANEL_SCORE[$c]=$((PANEL_SCORE[$c]+1))
  fi

  # API 行为特征
  if lxc exec "$c" -- sh -c 'ss -tnp | grep -E ":80|:443" | grep -E "php|node|python" >/dev/null 2>&1' ; then
    PANEL_SCORE[$c]=$((PANEL_SCORE[$c]+1))
  fi

  # ------------------------------------------------
  # 二、机场节点行为检测
  # ------------------------------------------------

  # 控制程序（V2bX / XrayR / sspanel-node 等）
  if lxc exec "$c" -- ps aux | grep -E "[V]2bX|[X]rayR|sspanel-node" >/dev/null 2>&1; then
    NODE_SCORE[$c]=$((NODE_SCORE[$c]+3))
  fi

  # 明确的面板对接配置（强证据）
  if lxc exec "$c" -- sh -c '
    grep -R "panel_url\|node_id\|api_key\|token" /etc /opt 2>/dev/null | grep -q .
  ' ; then
    NODE_SCORE[$c]=$((NODE_SCORE[$c]+3))
  fi

  # 用户 / 流量缓存
  if lxc exec "$c" -- sh -c 'ls /etc | grep -E "V2bX|xrayr|sspanel" >/dev/null 2>&1' ; then
    NODE_SCORE[$c]=$((NODE_SCORE[$c]+2))
  fi

  # 长连接通信（节点与面板）
  if lxc exec "$c" -- ss -tnp | grep -E "ESTAB" | grep -E "xray|sing-box|V2bX" >/dev/null 2>&1; then
    NODE_SCORE[$c]=$((NODE_SCORE[$c]+1))
  fi

  # ------------------------------------------------
  # 三、明显自建特征（降权）
  # ------------------------------------------------

  # 只有代理，没有控制程序
  if lxc exec "$c" -- ps aux | grep -E "sing-box|xray" | grep -v grep >/dev/null 2>&1 &&
     ! lxc exec "$c" -- ps aux | grep -E "[V]2bX|[X]rayR|sspanel" >/dev/null 2>&1; then
    NODE_SCORE[$c]=$((NODE_SCORE[$c]-2))
  fi

  # ------------------------------------------------
  # 四、输出单容器结果
  # ------------------------------------------------

  if [ ${PANEL_SCORE[$c]} -ge $THRESHOLD_PANEL ]; then
    echo "🚨 判定：机场【面板】 (score=${PANEL_SCORE[$c]})"
  elif [ ${NODE_SCORE[$c]} -ge $THRESHOLD_NODE ]; then
    echo "⚠️ 判定：机场【节点】 (score=${NODE_SCORE[$c]})"
  else
    echo "✅ 未发现机场行为 (panel=${PANEL_SCORE[$c]}, node=${NODE_SCORE[$c]})"
  fi

  echo
done

echo "=================================================="
echo " 审计完成：仅高置信机场行为被标记"
echo "=================================================="
