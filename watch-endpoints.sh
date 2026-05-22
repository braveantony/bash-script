#!/bin/bash
# watch-endpoints.sh - EndpointSlice 變動監控腳本
# v4: 簡化為「有變動就 show」,拿掉 terminating 狀態追蹤
#     - 參數順序: <namespace> <service> [wait_seconds]
#     - 新增:初始快照
#     - 顯示 kubectl/jq 錯誤(不再 2>/dev/null)

NS="${1:-demo-svc}"
SVC_NAME="${2:-web-app}"
WAIT_SECONDS="${3:-10}"

# 顯示用法說明
usage() {
  echo "用法: $0 <NAMESPACE> <SERVICE_NAME> [WAIT_SECONDS]"
  echo ""
  echo "參數:"
  echo "  NAMESPACE      要監控的 Namespace"
  echo "  SERVICE_NAME   要監控的 Service 名稱"
  echo "  WAIT_SECONDS   Rollout 成功後額外等待的秒數 (預設: 10)"
  echo ""
  echo "範例:"
  echo "  $0 demo-svc web-app"
  echo "  $0 demo-svc web-app 15"
  exit 1
}

if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" || -z "$2" ]]; then
  usage
fi

# 依賴與環境檢查
for cmd in kubectl jq awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[錯誤] 缺少必要工具: $cmd"
    exit 1
  fi
done

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "[錯誤] 無法連線至 Kubernetes 叢集,請檢查 kubeconfig。"
  exit 1
fi

# 確認 Service 是否存在
if ! kubectl get svc "$SVC_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "[錯誤] 找不到 Service: $NS/$SVC_NAME"
  exit 1
fi

# 1. 自動偵測 Deployment 名稱
detect_deployment() {
  local svc=$1
  local ns=$2
  local selector
  selector=$(kubectl get svc "$svc" -n "$ns" -o json | jq -r '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")')
  if [[ -z "$selector" || "$selector" == "null" ]]; then return 1; fi
  local deploy
  deploy=$(kubectl get deployments -n "$ns" -l "$selector" -o jsonpath='{.items[0].metadata.name}')
  if [[ -n "$deploy" ]]; then echo "$deploy"; else return 1; fi
}

echo "[偵測] 正在自動尋找與 Service $SVC_NAME 關聯的 Deployment..."
DEPLOY_NAME=$(detect_deployment "$SVC_NAME" "$NS")
if [[ -z "$DEPLOY_NAME" ]]; then
  echo "[錯誤] 無法自動偵測與 Service $NS/$SVC_NAME 關聯的 Deployment,退出。"
  exit 1
fi
echo "[OK] 偵測到 Deployment: $DEPLOY_NAME"

echo "--------------------------------------------------"
echo "監控目標: $NS/Service/$SVC_NAME -> Deployment/$DEPLOY_NAME"
echo "提示:將在 Rollout 成功後的 ${WAIT_SECONDS} 秒自動停止監控。"
echo "按 Ctrl+C 可手動停止"
echo "--------------------------------------------------"

# 2. 初始快照:列出目前所有 EndpointSlice 內容
echo ""
echo "[$(date +%T)] === 初始快照 (watch 開始前) ==="
SNAPSHOT=$(kubectl get endpointslices -n "$NS" \
  -l "kubernetes.io/service-name=$SVC_NAME" -o json)

SLICE_COUNT=$(echo "$SNAPSHOT" | jq '.items | length')
if [[ "$SLICE_COUNT" == "0" ]]; then
  echo "  (目前沒有任何 EndpointSlice)"
else
  echo "$SNAPSHOT" | jq -r '
    .items[] |
    "  EndpointSlice: \(.metadata.name)",
    (.endpoints // [] | sort_by(.addresses[0])[] |
      "    \(.addresses[0])  ready=\(.conditions.ready // false)  serving=\(.conditions.serving // false)  terminating=\(.conditions.terminating // false)")
  '
fi
echo ""

WATCHER_PID=$$

# 3. 自動 Rollout 監控邏輯
auto_rollout_task() {
  set -m
  local old_gen
  old_gen=$(kubectl get deployment "$DEPLOY_NAME" -n "$NS" -o jsonpath='{.metadata.generation}')
  echo -e "\n[動作] $(date +%T) 執行 kubectl rollout restart..."
  kubectl rollout restart deployment/"$DEPLOY_NAME" -n "$NS" > /dev/null
  local new_gen=$old_gen
  local timeout=30
  while [[ "$new_gen" == "$old_gen" && $timeout -gt 0 ]]; do
    sleep 0.5
    new_gen=$(kubectl get deployment "$DEPLOY_NAME" -n "$NS" -o jsonpath='{.metadata.generation}')
    ((timeout--))
  done
  if [[ "$new_gen" == "$old_gen" ]]; then
    echo -e "\n[錯誤] $(date +%T) K8s 並未在超時內回傳新的 Generation,Rollout 失敗。"
    kill -SIGINT "$WATCHER_PID" 2>/dev/null
    return
  fi
  echo "[狀態] $(date +%T) K8s 已確認重啟 (Gen: $old_gen -> $new_gen),開始監測..."
  if kubectl rollout status deployment/"$DEPLOY_NAME" -n "$NS" --timeout=300s > /dev/null 2>&1; then
    echo -e "\n[通知] $(date +%T) Rollout 成功完成。"
  else
    echo -e "\n[警告] $(date +%T) Rollout 發生異常或超時。"
  fi
  echo "[通知] 等待 ${WAIT_SECONDS} 秒以收集殘留的 Endpoint 事件..."
  sleep "$WAIT_SECONDS"
  kill -SIGINT "$WATCHER_PID" 2>/dev/null
}

auto_rollout_task &
ROLLOUT_MONITOR_PID=$!

cleanup() {
  echo -e "\n[結束] $(date +%T) 停止監控。"
  kill -- -"$ROLLOUT_MONITOR_PID" 2>/dev/null
  exit 0
}

trap cleanup SIGINT SIGTERM

# 4. 逐事件串流監控:有變動就 show
# - kubectl --watch 推送 EndpointSlice 變動事件
# - jq 把每個事件壓成單行 NDJSON
# - bash 端逐行解析並印出
# - 用 process substitution 讓 while 在主 shell 跑

while IFS= read -r EVT_JSON; do
  [[ -z "$EVT_JSON" ]] && continue

  EVT_TYPE=$(echo "$EVT_JSON" | jq -r '.evt')
  SLICE_NAME=$(echo "$EVT_JSON" | jq -r '.name')
  TS_NOW=$(date +%T.%3N)

  echo "[$TS_NOW] === 事件: $EVT_TYPE  EndpointSlice: $SLICE_NAME ==="

  EP_COUNT=$(echo "$EVT_JSON" | jq '.eps | length')
  if [[ "$EP_COUNT" == "0" ]]; then
    echo "  (此 EndpointSlice 目前沒有 endpoint)"
  else
    echo "$EVT_JSON" | jq -r '
      .eps[] |
      "  \(.ip)  ready=\(.ready)  serving=\(.serving)  terminating=\(.terminating)"
    '
  fi

  echo ""
done < <(
  kubectl get endpointslices -n "$NS" \
    -l "kubernetes.io/service-name=$SVC_NAME" \
    --watch --output-watch-events=true -o json | \
  jq -r -c --unbuffered '
    select(.type != null and .type != "ERROR") |
    {
      evt: .type,
      name: (.object.metadata.name // "unknown"),
      eps: (.object.endpoints // [] | sort_by(.addresses[0]) |
            map({
              ip: .addresses[0],
              ready: (.conditions.ready // false),
              serving: (.conditions.serving // false),
              terminating: (.conditions.terminating // false)
            }))
    } |
    @json
  '
)
