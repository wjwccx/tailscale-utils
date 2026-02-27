#!/bin/bash
ROUTE_SUBNETS="${ROUTE_SUBNETS:-}" # 最终用当前IP网段兜底
ROUTE_VIA="${ROUTE_VIA:-}"         # 最终用当前IP地址兜底
LABEL_KEY="${LABEL_KEY:-app.route.inject}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-3}" #事件缓冲默认3s，用于防抖
DEBOUNCE_DIR="/tmp/watcher/debounce"
mkdir -p "$DEBOUNCE_DIR"

log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S.%6N%:z') $*"
}

# 获取当前容器的 IP 网段，作为默认的 ROUTE_SUBNETS
detect_self_subnet() {
  ip -4 -o addr show eth0 | awk '{print $4}'
}

# 获取当前容器的 IP 地址，作为默认的 ROUTE_VIA
detect_self_ip() {
  detect_self_subnet | cut -d/ -f1
}

# 检查目标容器是否拥有指定的 label 且为 true
has_target_label() {
  docker inspect -f '{{ index .Config.Labels "'"$LABEL_KEY"'" }}' "$1" 2>/dev/null | grep -qE '^true$'
}

# 获取目标容器的 PID
get_container_pid() {
  docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null || echo 0
}

# 执行静态路由注入
inject_routes() {
  cid="$1"
  pid=$(get_container_pid "$cid")

  if [ "$pid" -le 1 ]; then
    log "WARN  [${cid:0:12}] Invalid container PID: $pid"
    return 1
  fi

  # 每个源网段都注入路由 （ "//,/ "将$ROUTE_SUBNETS中所有逗号替换为空格 )
  for subnet in ${ROUTE_SUBNETS//,/ }; do
    route_rule="$subnet via $ROUTE_VIA"
    if nsenter -t "$pid" -n ip route list | grep -q "$route_rule"; then
      log "INFO [${cid:0:12}] Route existed (skipping): $route_rule"
    elif nsenter -t "$pid" -n ip route add $subnet via $ROUTE_VIA ; then
      log "INFO [${cid:0:12}] Route injected (success): $route_rule"
    else
      log "ERROR [${cid:0:12}] Failed to inject route: $route_rule"
    fi
  done
}

# 防抖去重：放入文件队列，同时去重
debounced_inject() {
  touch "$DEBOUNCE_DIR/$1"  # 用cid做文件名
}
# 防抖批处理：批量处理文件队列
process_debounce() {
  for file in "$DEBOUNCE_DIR"/*; do
    [ -f "$file" ] || continue
    cid=$(basename "$file")
    has_target_label "$cid" && inject_routes "$cid"
    rm -f "$file"
  done
}

# 初始化时注入所有已启动且符合条件的容器
initial_scan() {
  log "INFO Initial scan of running containers..."
  docker ps -q | while read -r cid; do
    has_target_label "$cid" && inject_routes "$cid"
  done
}

# 自动检测 ROUTE_SUBNETS
if [ -z "$ROUTE_SUBNETS" ]; then
  ROUTE_SUBNETS=$(detect_self_subnet)
  log "INFO ROUTE_SUBNETS not specified, auto-detected as: $ROUTE_SUBNETS"
fi

# 自动检测 ROUTE_VIA
if [ -z "$ROUTE_VIA" ]; then
  ROUTE_VIA=$(detect_self_ip)
  log "INFO ROUTE_VIA not specified, auto-detected as: $ROUTE_VIA"
fi

log "INFO Startup with: ROUTE_SUBNETS=$ROUTE_SUBNETS, ROUTE_VIA=$ROUTE_VIA, LABEL_KEY=$LABEL_KEY, DEBOUNCE_SECONDS=$DEBOUNCE_SECONDS"
# 启动时扫描已有容器
initial_scan

# 启动后台防抖处理器（默认每3秒处理一次）
while true; do
  process_debounce
  sleep $DEBOUNCE_SECONDS 
done &

# 监听 Docker 事件
log "INFO Listening for container events ..."
docker events --filter event=start --filter event=restart --format '{{.ID}}' | while read -r cid; do
  debounced_inject "$cid"
done

