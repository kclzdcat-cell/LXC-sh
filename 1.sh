#!/bin/bash
# =====================================================
# LXC 机场服务审计工具 v7.1 FINAL
# 严格区分【机场节点】与【自建代理】
# =====================================================

# ---------- 阈值 ----------
THRESHOLD_CONFIRMED=6
THRESHOLD_SUSPECT=4

# ---------- 搜索配置 ----------
SEARCH_PATHS="/etc /opt /usr/local/etc /root"
KEYWORDS="panel_url|node_id|token|api_key|subscribe|v2board|xboard|sspanel|xrayr|v2bx"
EXCLUDE_FILES="geoip.dat|geosite.dat|\\.mmdb$"

# ---------- 工具函数 ----------
exec_safe() {
  local c="$1"
  local bin="$2"
  local cmd="$3"
  lxc exec "$c" -- sh -c "command -v $bin >/dev/null 2>&1 && $cmd" 2>/dev/null
}

echo "======================================================"
echo " LXC 机场服务审计工具 (v7.1 FINAL)"
echo "======================================================"
echo

CONFIRMED=()
SUSPECT=()

# ---------- 主循环 ----------
for c in $(lxc list -c n --format csv); do
  echo "🔍 正在审计容器：$c"

  # ---------- 正确判断运行状态（关键修复点） ----------
  STATE=$(lxc list "$c" -c s --format csv 2>/dev/null)
  if [ "$STATE" != "RUNNING" ]; then
    echo "⏸ 容器未运行（状态：$STATE），跳过"
    echo
    continue
  fi

  PANEL_SCORE=0
  NODE_SCORE=0
  CONFIG_HIT=0
  MATCHED_FILES=()

  # =====================================================
  # 一、机场面板（非常严格）
  # =====================================================
  exec_safe "$c" ps "ps | grep -E 'php-fpm|gunicorn|uwsgi|node .*server' | grep -v grep" \
  && exec_safe "$c" ps "ps | grep -E 'nginx|apache|caddy|traefik' | grep -v grep" \
  && exec_safe "$c" find "find / -maxdepth 3 -name artisan 2>/dev/null | grep -q ." \
  && PANEL_SCORE=6

  # =====================================================
  # 二、机场节点（只认“机场对接程序”）
  # =====================================================

  # 1️⃣ 明确机场节点程序（核心）
  exec_safe "$c" ps "ps | grep -E '[X]rayR|[V]2bX|sspanel-node'" \
    && NODE_SCORE=$((NODE_SCORE+4))

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

  # 3️⃣ 用户 / 流量缓存（辅助证据）
  exec_safe "$c" ls "ls /etc | grep -Ei 'xrayr|v2bx|sspanel'" \
    && NODE_SCORE=$((NODE_SCORE+1))

  # =====================================================
  # 三、明确排除：仅代理内核（防误杀）
  # =====================================================
  exec_safe "$c" ps "ps | grep -E 'xray|sing-box' | grep -v grep" \
  && ! exec_safe "$c" ps "ps | grep -E '[X]rayR|[V]2bX|sspanel-node'" \
  && NODE_SCORE=0

  MAX_SCORE=$(( PANEL_SCORE > NODE_SCORE ? PANEL_SCORE : NODE_SCORE ))

  # =====================================================
  # 四、判定 + 输出
  # =====================================================
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

# =====================================================
# 五、总结
# =====================================================
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
echo "✅ 审计完成（v7.1 FINAL）"
