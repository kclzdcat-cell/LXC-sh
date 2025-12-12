#!/bin/bash

# ==============================
# 基础配置
# ==============================
THRESHOLD_CONFIRMED=7
THRESHOLD_SUSPECT=4

SEARCH_PATHS="/etc /opt /usr/local/etc /root"
KEYWORDS="panel_url|node_id|token|api_key|subscribe|v2board|xboard|sspanel|xrayr|v2bx"

echo "======================================================"
echo " LXC 机场服务审计工具 FINAL"
echo " 行为 + 配置 + 评分 + 证据输出 7.0版本"
echo "======================================================"
echo

# ==============================
# 安全执行函数（防 command not found）
# ==============================
exec_safe() {
  local container="$1"
  local cmd="$2"
  local run="$3"
  lxc exec "$container" -- sh -c "command -v $cmd >/dev/null 2>&1 && $run" 2>/dev/null
}

CONFIRMED=()
SUSPECT=()

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在审计容器：$c"

  PANEL_SCORE=0
  NODE_SCORE=0
  CONFIG_HIT=0
  MATCHED_FILES=()

  # ==============================
  # 一、机场面板行为
  # ==============================
  exec_safe "$c" ps "ps | grep -E 'nginx|apache|caddy|traefik' | grep -v grep" \
    && PANEL_SCORE=$((PANEL_SCORE+2))

  exec_safe "$c" ps "ps | grep -E 'php-fpm|node .*server|gunicorn|uwsgi' | grep -v grep" \
    && PANEL_SCORE=$((PANEL_SCORE+2))

  exec_safe "$c" find "find / -maxdepth 3 -name artisan 2>/dev/null | grep -q ." \
    && PANEL_SCORE=$((PANEL_SCORE+2))

  exec_safe "$c" find "find / -maxdepth 3 -name .env 2>/dev/null | grep -q ." \
    && PANEL_SCORE=$((PANEL_SCORE+1))

  # ==============================
  # 二、机场节点行为
  # ==============================
  exec_safe "$c" ps "ps | grep -E '[V]2bX|[X]rayR|sspanel-node'" \
    && NODE_SCORE=$((NODE_SCORE+3))

  exec_safe "$c" ss "ss -tn | grep ESTAB | grep -E 'xray|sing-box|V2bX'" \
    && NODE_SCORE=$((NODE_SCORE+1))

  exec_safe "$c" ls "ls /etc | grep -Ei 'V2bX|XrayR|sspanel'" \
    && NODE_SCORE=$((NODE_SCORE+2))

  # ==============================
  # 三、机场配置文件扫描（新增）
  # ==============================
  MATCH_OUTPUT=$(lxc exec "$c" -- sh -c "
    grep -R -n -E '$KEYWORDS' $SEARCH_PATHS 2>/dev/null | head -n 20
  ")

  if [ -n "$MATCH_OUTPUT" ]; then
    CONFIG_HIT=1
    NODE_SCORE=$((NODE_SCORE+2))
    PANEL_SCORE=$((PANEL_SCORE+1))

    while IFS= read -r line; do
      MATCHED_FILES+=("$line")
    done <<< "$MATCH_OUTPUT"
  fi

  # ==============================
  # 四、自建代理降权
  # ==============================
  exec_safe "$c" ps "ps | grep -E 'sing-box|xray' | grep -v grep" \
    && ! exec_safe "$c" ps "ps | grep -E '[V]2bX|[X]rayR|sspanel'" \
    && NODE_SCORE=$((NODE_SCORE-2))

  MAX_SCORE=$(( PANEL_SCORE > NODE_SCORE ? PANEL_SCORE : NODE_SCORE ))

  # ==============================
  # 五、单容器结论 + 可疑文件输出
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
# 六、最终总结
# ==============================
echo "======================================================"
echo "                审计结果总结"
echo "======================================================"
echo

echo "🚨【确定机场服务】容器："
if [ ${#CONFIRMED[@]} -eq 0 ]; then
  echo "  无"
else
  for c in "${CONFIRMED[@]}"; do
    echo "  - $c"
  done
fi

echo
echo "⚠️【可疑机场服务】容器（建议人工复核）："
if [ ${#SUSPECT[@]} -eq 0 ]; then
  echo "  无"
else
  for c in "${SUSPECT[@]}"; do
    echo "  - $c"
  done
fi

echo
echo "✅ 审计完成"
