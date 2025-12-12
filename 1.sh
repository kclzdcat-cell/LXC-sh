#!/bin/bash
# =====================================================
# LXC 机场服务审计工具 v8.3 FINAL (收官版)
# =====================================================

SEARCH_PATHS="/etc /opt /usr/local/etc /root"

# ===== 强实体定义 =====
NODE_CONTROLLERS="XrayR|V2bX|soga|sspanel-node"
PANEL_CONTROLLERS="v2board|xboard|ppanel|sspanel|xb"

# ===== 只认“对接级别字段” =====
LINK_FIELDS="panel_url|node_id|webapi|backend_url|api_key|token"

# ===== 明确排除 =====
EXCLUDE_UI="x-ui|3x-ui|hiddify|v2ray-ui"
EXCLUDE_FILES="geoip.dat|geosite.dat|\\.mmdb$"

CONFIRMED=()
SUSPECT=()

echo "======================================================"
echo " LXC 机场服务审计工具 v8.3 FINAL"
echo "======================================================"
echo

for c in $(lxc list -c n --format csv); do
  echo "🔍 审计容器：$c"

  # -------- 机场节点程序 --------
  NODE_BIN=$(lxc exec "$c" -- sh -c "
    ls /usr/bin /usr/local/bin /opt /etc 2>/dev/null \
    | grep -Ei '$NODE_CONTROLLERS' | head -n 1
  " 2>/dev/null)

  # -------- 机场面板程序 --------
  PANEL_BIN=$(lxc exec "$c" -- sh -c "
    ls /var/www /opt /usr/share 2>/dev/null \
    | grep -Ei '$PANEL_CONTROLLERS' | head -n 1
  " 2>/dev/null)

  # -------- 对接配置文件（只列文件） --------
  CONFIG_FILES=$(lxc exec "$c" -- sh -c "
    grep -R -I -l -E '$LINK_FIELDS' $SEARCH_PATHS 2>/dev/null \
    | grep -Ev '$EXCLUDE_FILES' \
    | grep -Ev '$EXCLUDE_UI' \
    | sort -u | head -n 10
  " 2>/dev/null)

  RESULT="CLEAN"

  # -------- 判定逻辑（极度收敛） --------
  if [ -n "$PANEL_BIN" ]; then
    RESULT="CONFIRMED"
  elif [ -n "$NODE_BIN" ] && [ -n "$CONFIG_FILES" ]; then
    RESULT="CONFIRMED"
  elif [ -n "$NODE_BIN" ]; then
    RESULT="SUSPECT"
  fi

  # -------- 输出 --------
  case "$RESULT" in
    CONFIRMED)
      echo "🚨 确定：机场服务"
      CONFIRMED+=("$c")
      ;;
    SUSPECT)
      echo "⚠️ 可疑：疑似机场服务（节点程序存在，未发现对接配置）"
      SUSPECT+=("$c")
      ;;
    CLEAN)
      echo "✅ 未发现机场服务"
      ;;
  esac

  if [ -n "$NODE_BIN" ]; then
    echo "  🧩 节点程序：$NODE_BIN"
  fi

  if [ -n "$PANEL_BIN" ]; then
    echo "  🖥 面板程序：$PANEL_BIN"
  fi

  if [ -n "$CONFIG_FILES" ]; then
    echo "  📂 对接配置文件："
    echo "$CONFIG_FILES" | sed 's/^/    - /'
  fi

  echo
done

# ================== 汇总 ==================
echo "======================================================"
echo "                审计结果汇总"
echo "======================================================"
echo

echo "🚨 确定机场服务容器："
if [ ${#CONFIRMED[@]} -eq 0 ]; then
  echo "  无"
else
  for c in "${CONFIRMED[@]}"; do
    echo "  - $c"
  done
fi

echo
echo "⚠️ 可疑机场服务容器："
if [ ${#SUSPECT[@]} -eq 0 ]; then
  echo "  无"
else
  for c in "${SUSPECT[@]}"; do
    echo "  - $c"
  done
fi

echo
echo "✅ 审计完成（v8.3 FINAL）"
