#!/bin/bash
# watch-endpoints.sh - 專業級 EndpointSlice 監控與 Rollout 自動化腳本

SVC_NAME="${1:-web-app}"
NS="${2:-demo-svc}"
WAIT_SECONDS="${4:-10}"

# 顯示用法說明
usage() {
  echo "用法: $0 [SERVICE_NAME] [NAMESPACE] [DEPLOY_NAME] [WAIT_SECONDS]"
  exit 1
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

# 依賴與環境檢查
for cmd in kubectl jq md5sum awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[錯誤] 缺少必要工具: $cmd"
    exit 1
  fi
done

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "[錯誤] 無法連線至 Kubernetes 叢集，請檢查 kubeconfig。"
  exit 1
fi

# 1. 自動偵測 Deployment 名稱 (使用 jq 增強相容性)
detect_deployment() {
  local svc=$1
  local ns=$2
  
  # 取得 Service 的 Selector (轉為 app=web-app 格式)
  local selector
  selector=$(kubectl get svc "$svc" -n "$ns" -o json 2>/dev/null | jq -r '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")')
  
  if [[ -z "$selector" || "$selector" == "null" ]]; then return 1; fi
  
  # 尋找符合此 Selector 的 Deployment
  local deploy
  deploy=$(kubectl get deployments -n "$ns" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [[ -n "$deploy" ]]; then
    echo "$deploy"
  else
    return 1
  fi
}

if [[ -z "$3" ]]; then
  echo "[偵測] 正在自動尋找與 Service $SVC_NAME 關聯的 Deployment..."
  DEPLOY_NAME=$(detect_deployment "$SVC_NAME" "$NS")
  if [[ -z "$DEPLOY_NAME" ]]; then
    echo "[警告] 無法自動偵測 Deployment，回退使用名稱: $SVC_NAME"
    DEPLOY_NAME="$SVC_NAME"
  else
    echo "[OK] 偵測到 Deployment: $DEPLOY_NAME"
  fi
else
  DEPLOY_NAME="$3"
fi

# 檢查 Deployment 是否存在
if ! kubectl get deployment "$DEPLOY_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "[錯誤] 找不到 Deployment: $DEPLOY_NAME (Namespace: $NS)"
  exit 1
fi

echo "--------------------------------------------------"
echo "監控目標: Service/$SVC_NAME -> Deployment/$DEPLOY_NAME"
echo "等待時間: ${WAIT_SECONDS}s"
echo "--------------------------------------------------"

WATCHER_PID=$$

# 2. 精確的 Rollout 監控邏輯 (使用 Generation Tracking 與 子程序組控制)
auto_rollout_task() {
  # 讓此背景任務擁有獨立的 PGID，以便清理
  set -m 
  
  # 取得目前的 Generation 號碼
  local old_gen
  old_gen=$(kubectl get deployment "$DEPLOY_NAME" -n "$NS" -o jsonpath='{.metadata.generation}')
  
  echo -e "\n[動作] $(date +%T) 執行 kubectl rollout restart..."
  kubectl rollout restart deployment/"$DEPLOY_NAME" -n "$NS" > /dev/null
  
  # 等待直到 Generation 增加
  local new_gen=$old_gen
  local timeout=30
  while [[ "$new_gen" == "$old_gen" && $timeout -gt 0 ]]; do
    sleep 0.5
    new_gen=$(kubectl get deployment "$DEPLOY_NAME" -n "$NS" -o jsonpath='{.metadata.generation}')
    ((timeout--))
  done
  
  if [[ "$new_gen" == "$old_gen" ]]; then
    echo -e "\n[錯誤] $(date +%T) K8s 並未在超時內回傳新的 Generation，Rollout 失敗。"
    kill -SIGINT "$WATCHER_PID" 2>/dev/null
    return
  fi

  echo "[狀態] $(date +%T) K8s 已確認重啟 (Gen: $old_gen -> $new_gen)，開始監測..."
  
  # 等待 Rollout 完成
  if kubectl rollout status deployment/"$DEPLOY_NAME" -n "$NS" --timeout=300s > /dev/null 2>&1; then
    echo -e "\n[通知] $(date +%T) Rollout 成功完成。"
  else
    echo -e "\n[警告] $(date +%T) Rollout 發生異常或超時。"
  fi
  
  echo "[通知] 等待 ${WAIT_SECONDS} 秒以收集殘留的 Endpoint 事件..."
  sleep "$WAIT_SECONDS"
  kill -SIGINT "$WATCHER_PID" 2>/dev/null
}

# 啟動自動化任務 (並記錄其 PID)
auto_rollout_task &
ROLLOUT_MONITOR_PID=$!

# 清理函式
cleanup() {
  echo -e "\n[結束] $(date +%T) 停止監控。"
  # 殺死背景任務子程序組 (使用負號 PID)
  kill -- -"$ROLLOUT_MONITOR_PID" 2>/dev/null
  exit 0
}

trap cleanup SIGINT SIGTERM

# 3. 高效率監控迴圈 (改用 jq 解析)
PREV_HASH=""
while true; do
  CURRENT=$(kubectl get endpointslices -n "$NS" -l "kubernetes.io/service-name=$SVC_NAME" -o json 2>/dev/null | \
    jq -r '.items[]?.endpoints[]? | 
      "\(.addresses[0])  ready=\(.conditions.ready)  serving=\(.conditions.serving)  terminating=\(.conditions.terminating)"' | sort)
  
  CURRENT_HASH=$(echo "$CURRENT" | md5sum | awk '{print $1}')
  if [[ "$CURRENT_HASH" != "$PREV_HASH" ]]; then
    echo "[$(date +%s.%3N)|$(date +%T.%3N)] === EndpointSlice 變動 ==="
    if [[ -z "$CURRENT" ]]; then
      echo "(無端點資料)"
    else
      echo "$CURRENT"
    fi
    echo ""
    PREV_HASH="$CURRENT_HASH"
  fi
  sleep 0.2
done
