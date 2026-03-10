#!/bin/bash
SUBNET_NAME="${SUBNET_NAME:-}"  # 监控目标子网
POST_URL="${POST_URL:-}"        # DNS更新Endpoint
LABEL_KEY="${LABEL_KEY:-app.dns.name}"  # DNS注册名称
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-3}" #事件缓冲默认3s，用于防抖

log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S.%6N%:z') $*"
}

get_target_label() {
  docker inspect -f '{{ index .Config.Labels "'"$LABEL_KEY"'" }}' "$1" 2>/dev/null;
}

# 重试提交POST 
post_json_with_retry() {
    local max_retry=10
    local retry_delay=3
    local attempt=1
    local result body code

    CURL_RETRY_OPTS=(
      --connect-timeout 3  # tcp连接超时3秒
      --max-time 10        # 整个请求过程最多10秒
    )

    while (( attempt <= max_retry )); do
        result=$(curl -s "${CURL_RETRY_OPTS[@]}" \
            -w $'\n%{http_code}' \
            -X POST -H "Content-Type: application/json" \
            -d @"$TMP_FILE" "$POST_URL?subnet=$SUBNET_NAME")
        code="${result##*$'\n'}"
        body="${result%$'\n'*}"

        if [[ "$code" == "200" ]]; then
            resp="$body"
            return 0
        fi

        log "WARN POST attempt $attempt/$max_retry failed, http=$code, body=$body"
        if (( attempt < max_retry )); then
            sleep "$retry_delay"
        fi
        ((attempt++))
    done

    resp="$body"
    return 1
}

# 生成并提交DNS
post_records() {
  TMP_FILE="/tmp/records.json"
  #echo "[]" > "$TMP_FILE"
  docker network inspect $SUBNET_NAME -f '{{json .Containers}}' | \
      jq -r 'to_entries[] | .value.Name + " " + .key + " " + (.value.IPv4Address | split("/")[0])' | \
      while read -r cname cid ip; do
        if [[ -n "$ip" ]]; then
          label_value=$(get_target_label "$cid")
          for server in ${label_value//,/ }; do  # "//,/ "将变量中的逗号都替换为空格
            jq -n '{name: "'$server'", type: "A", value: "'$ip'", remark: "'$cname'"}'
          done
        fi
      done | jq -s '.' > "$TMP_FILE"

  if [[ -s "$TMP_FILE" ]] ; then
    resp=""
    if post_json_with_retry; then
        log "INFO Posted records to $POST_URL, response: $resp"
    else
        log "ERROR Failed to post records to $POST_URL after retries, last response: $resp"
    fi
    LAST_POST_TIME=$(date +%s)
  else
    log "ERROR Generate records to post failed, $TMP_FILE is empty ..."
  fi
}

# 是否还在上次提交的冷却期内
get_cooling_time(){
  NOW=$(date +%s)
  past_time=$((NOW - ${LAST_POST_TIME:-0}))
  echo $((DEBOUNCE_SECONDS - past_time))
}

# 基于冷却+延时任务来实现事件防抖
debounce_and_post() {
  if [[ -n "${DEBOUNCE_PID:-}" ]] && kill -0 "$DEBOUNCE_PID" 2>/dev/null; then
    return  # 正在延时冷却中
  fi

  cooling_time=$(get_cooling_time)
  if [[ $cooling_time -le 0 ]] ; then
    # 直接提交更新
    post_records
  else 
    # 创建延时任务
    (
      sleep "$cooling_time"
      post_records
    ) &
    DEBOUNCE_PID=$!
  fi
}

listen_events() {
  docker events --filter type=network --filter event=connect --filter event=disconnect | \
    while read -r line; do
      echo "$line" | grep "name=$SUBNET_NAME," | while read -r _; do
        debounce_and_post
      done
    done
}

if [[ -z $SUBNET_NAME || -z $POST_URL ]] ; then
  log "ERROR \$SUBNET_NAME and \$POST_URL must not be emtpy."
  exit 1
fi

log "INFO Startup with: SUBNET_NAME=$SUBNET_NAME LABEL_KEY=$LABEL_KEY DEBOUNCE_SECONDS=$DEBOUNCE_SECONDS POST_URL=$POST_URL"

# Initial full scan
log "INFO Initial scan for network: $SUBNET_NAME"
post_records

# Start event listener
log "INFO Listening for container events ..."
listen_events
