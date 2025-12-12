#!/bin/bash
# =====================================================
# LXC 机场服务审计工具 v8 FINAL
# 覆盖所有机场形态，防误杀自建代理
# =====================================================

SEARCH_PATHS="/etc /opt /usr/local/etc /root"
NODE_BIN_KEYWORDS="XrayR|V2bX|soga|sspanel-node|airun|anxray"
PANEL_KEYWORDS="panel_url|node_id|token|api_key|webapi|backend_url|ppanel|soga|v2board|xboard|sspanel|subscribe"
EXCLUDE_UI="x-ui|3x-ui|v2ray-ui|hiddify"
EXCLUDE_FILES="geoip.dat|geosite.dat|\\.mmdb$"

echo "======================================================"
echo " LXC 机场服务审计工具 v8 FINAL"
echo "======================================================"
echo

CONFIRMED=()
SUSPECT=()

exec_safe() {
  lxc exec "$1" -- sh -c "command -v $2 >/dev/null 2>&1 && $3" 2>/dev/null
}

for c in $(lxc list -c n --format csv); do
  echo "🔍 审计容器：$c"

  STATE=$(lxc list "$c" -c s --format csv 2>/dev/null)
  if [ "$STATE" != "RUNNING" ]; then
    echo "⏸ 未运行（$STATE），仅做静态审计"
  fi

  RESULT="CLEAN"
  MATCHED_FILES=()

  # ---------- 1. 排除 UI 面板 ----------
  UI_HIT=$(lxc exec "$c" -- sh -c "
    grep -R -I -l -E '$EXCLUDE_UI' $SEARCH_PATHS 2>/dev/null | head -n 1
  ")
  [ -n "$UI_HIT" ] && UI_ONLY=1 || UI_ONLY=0

  # ---------- 2. 机场节点程序 ----------
  NODE_BIN=$(lxc exec "$c" -- sh -c "
    ls /usr/bin /usr/local/bin /opt /etc 2>/dev/null | grep -Ei '$NODE_BIN_KEYWORDS' | head -n 1
  ")

  # ---------- 3. 机场配置文件 ----------
  CONFIG_FILES=$(lxc exec "$c" -- sh -c "
    grep -R -I -l -E '$PANEL_KEYWORDS' $SEARCH_PATHS 2>/dev/null \
    | grep -Ev '$EXCLUDE_FILES' \
    | grep -Ev '$EXCLUDE_UI' \
    | sort -u | head -n 10
  ")

  # ---------- 4. 连接数检测 ----------
  CUR_CONN=0
  HIS_CONN=0

  exec_safe "$c" ss "ss -H state established | wc -l" && CUR_CONN=$(lxc exec "$c" -- ss -H state established 2>/dev/null | wc -l)
  exec_safe "$c" conntrack "conntrack -L 2>/dev/null | wc -l" && HIS_CONN=$(lxc exec "$c" -- conntrack -L 2>/dev/null | wc -l)

  # ---------- 5. 判定逻辑 ----------
  if [ "$UI_ONLY" -eq 1 ] && [ -z "$NODE_BIN" ]; then
    RESULT="CLEAN"
  elif [ -n "$NODE_BIN" ] && [ -n "$CONFIG_FILES" ]; then
    RESULT="CONFIRMED"
  elif [ -n "$CONFIG_FILES" ] && [ "$CUR_CONN" -gt 50 ]; then
    RESULT="CONFIRMED"
  elif [ -n "$NODE_BIN" ] || [ -n "$CONFIG_FILES" ] || [ "$CUR_CONN" -gt 100 ]; then
    RESULT="SUSPECT"
  fi

  # ---------- 6. 输出 ----------
  case "$RESULT" in
    CONFIRMED)
      echo "🚨 确定：机场服务"
      CONFIRMED+=("$c")
      ;;
    SUSPECT)
      echo "⚠️ 可疑：疑似机场服务"
      SUSPECT+=("$c")
      ;;
    CLEAN)
      echo "✅ 未发现机场行为"
      ;;
  esac

  if [ -n "$CONFIG_FILES" ]; then
    echo "  📂 命中配置文件："
    echo "$CONFIG_FILES" | sed 's/^/    - /'
  fi

  if [ "$CUR_CONN" -gt 0 ] || [ "$HIS_CONN" -gt 0 ]; then
    echo "  📊 连接情况："
    echo "    - 当前连接数：$CUR_CONN"
    echo "    - 历史连接数：$HIS_CONN"
  fi

  echo
done

echo "======================================================"
echo "               审计结果汇总"
echo "======================================================"

echo
echo "🚨 确定机场服务容器："
[ ${#CONFIRMED[@]} -eq 0 ] && echo "  无" || printf "  - %s\n" "${CONFIRMED[@]}"

echo
echo "⚠️ 可疑机场服务容器："
[ ${#SUSPECT[@]} -eq 0 ] && echo "  无" || printf "  - %s\n" "${SUSPECT[@]}"

echo
echo "✅ 审计完成（v8 FINAL）"
