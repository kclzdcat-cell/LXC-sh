#!/bin/bash

# ==============================
# 基础参数
# ==============================
THRESHOLD_CONFIRMED=7
THRESHOLD_SUSPECT=4

SEARCH_PATHS="/etc /opt /usr/local/etc /root"
KEYWORDS="panel_url|node_id|token|api_key|subscribe|v2board|xboard|sspanel|xrayr|v2bx"
EXCLUDE_FILES="geoip.dat|geosite.dat|\\.mmdb$"

echo "======================================================"
echo " LXC 机场服务审计工具（v7 FINAL）"
echo " 严格区分【机场节点】与【自建代理】"
echo "======================================================"
echo

# ==============================
# 安全执行（避免 command not found）
# ==============================
exec_safe() {
  local c="$1"
  local bin="$2"
  local cmd="$3"
  lxc exec "$c" -- sh -c "command -v $bin >/dev/null 2>&1 && $cmd" 2>/dev/null
}

CONFIRMED=()
SUSPECT=()

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在审计容器：$c"

  # ---------- 跳过未运行容器 ----------
  STATE=$(lxc info "$c" 2>/dev/null | awk '/Status:/ {print $2}')
  if [ "$STATE" != "Running" ]; then
    echo "⏸ 容器未运行（$STATE），跳过"
    echo
    continue
  fi

  PANEL_SCORE=0
  NODE_SCORE=0
  CONFIG_HIT=0
  MATCHED_FILES=()

  # ==============================
  # 一、机场面板（严格）
  # ==============================
  exec_safe "$c" ps "ps | grep -E 'php-fpm|node .*server|gunicorn|uwsgi' | grep -v grep" \
    && exec_safe "$c" ps "ps | grep -E 'nginx|apache|caddy|traefik' | grep -v grep" \
    && exec_safe "$c" find "find / -maxdepth 3 -name artisan 2>/dev/null | grep -q ." \
    && PANEL_SCORE=7

  # ==============================
  # 二、机场节点（只认“对接程序”）
  # ==============================

  # 1️⃣ 明确的机场节点程序（最高权重）
  exec_safe "$c" ps "ps | grep -E '[X]rayR|[V]2bX|sspanel-node'" \
    && NODE_SCORE=$((NODE_SCORE+5))

  # 2️⃣ 面板对接配置（强证据）
  MATCH_FILES_RAW=$(lxc exec "$c" -- sh -c "
    grep -R -I -l -E '$KEYWORDS' $SEARCH_PATHS 2>/dev/null \
    | grep -Ev '$EXCLUDE_FILES' \
    | head -n 10
  ")

  if [ -n "$MATCH_FILES_RAW" ]; then
    CONFIG_HIT=1
    NODE_SCORE=$((NODE_SCORE+2))

    while read -r f; do
      kw=$(lxc exec "$c" -- sh -c "
        grep -o -E '$KEYWORDS' '$f' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,\$//'
      ")
      MATCHED_FILES+=("$f  [keywords: $kw]")
    done <<< "$MATCH_FILES_RAW"
  fi

  # 3️⃣ 用户 / 流量缓存（行为证据）
  exec_safe "$c" ls "ls /etc | grep -Ei 'xrayr|v2bx|sspanel'" \
    && NODE_SCORE=$((NODE_SCORE+1))

  # ==============================
  # 三、明确排除：仅代理内核
  # ==============================
  exec_safe "$c" ps "ps | grep -E 'xray|sing-box' | grep -v grep" \
    && ! exec_safe "$c" ps "ps | grep -E '[X]rayR|[V]2bX|sspanel-node'" \
    && NODE_SCORE=0

  MAX_SCORE=$(( PANEL_SCORE > NODE_SCORE ? PANEL_SCORE : NODE_SCORE ))

  # ==============================
  # 四、最终判定 + 文件展示
  # ==============================
  if [ "$MAX_SCORE" -ge "$THRESHOLD_CONFIRMED" ]; then
    echo "🚨 确定：机场服务（score=$MAX_SCORE）"
    CONFIRMED+=("$c")

    if [ ${#MATCHED_FILES[@]} -gt 0 ]; then
      echo "  📂 命中配置文件："
      for f in "${MATCHED_FILES[@]}"; do
        echo "    - $f"
      done
    fi

  elif [ "$MAX_SCORE" -ge "$THRESHOLD_SUSPECT" ] && [ "$CONFIG_HIT" -eq 1 ]; then
    echo "⚠️ 可疑：疑似机场服务（score=$MAX_SCORE）"
    SUSPECT+=("$c")

    echo "  📂 可疑配置文件："
    for f in "${MATCHED_FILES[@]}"; do
      echo "    - $f"
    done
  else
    echo "✅ 未发现机场行为（panel=$PANEL_SCORE, node=$NODE_SCORE）"
  fi

  echo
done

# ==============================
# 五、总结
# ==============================
echo "======================================================"
echo "                审计结果总结"
echo "======================================================"
echo

echo "🚨【确定机场服务】容器："
[ ${#CONFIRMED[@]} -eq 0 ] && echo "  无" || printf "  - %s\n" "${CONFIRMED[@]}"

echo
echo "⚠️【可疑机场服务】容器："
[ ${#SUSPECT[@]} -eq 0 ] && echo "  无" || printf "  - %s\n" "${SUSPECT[@]}"

echo
echo "✅ 审计完成（v7 FINAL）"
