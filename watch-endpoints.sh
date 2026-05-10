#!/bin/bash
# watch-endpoints.sh - 專業級 EndpointSlice 監控與 Rollout 自動化腳本
# v2: 改用逐事件記錄 + 每 IP 狀態追蹤,避免漏抓 terminating 狀態

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

# 1. 自動偵測 Deployment 名稱
detect_deployment() {
  local svc=$1
  local ns=$2
  local selector
  selector=$(kubectl get svc "$svc" -n "$ns" -o json 2>/dev/null | jq -r '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")')
  if [[ -z "$selector" || "$selector" == "null" ]]; then return 1; fi
  local deploy
  deploy=$(kubectl get deployments -n "$ns" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$deploy" ]]; then echo "$deploy"; else return 1; fi
}

if [[ -z "$3" ]]; then
  echo "[偵測] 正在自動尋找與 Service $SVC_NAME 關聯的 Deployment..."
  DEPLOY_NAME=$(detect_deployment "$SVC_NAME" "$NS")
  if [[ -z "$DEPLOY_NAME" ]]; then
    echo "[警告] 無法自動偵測 Deployment,回退使用名稱: $SVC_NAME"
    DEPLOY_NAME="$SVC_NAME"
  else
    echo "[OK] 偵測到 Deployment: $DEPLOY_NAME"
  fi
else
  DEPLOY_NAME="$3"
fi

echo "--------------------------------------------------"
echo "監控目標: Service/$SVC_NAME -> Deployment/$DEPLOY_NAME"
echo "提示:將在 Rollout 成功後的 ${WAIT_SECONDS} 秒自動停止監控。"
echo "重要:若沒抓到 terminating 狀態,建議為 Deployment 加上 preStop: sleep 2"
echo "按 Ctrl+C 可手動停止"
echo "--------------------------------------------------"

WATCHER_PID=$$

# 2. 精確的 Rollout 監控邏輯
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

# 用 associative array 追蹤每個 IP 最後看到的狀態
declare -A LAST_STATE
declare -A SEEN_TERMINATING

cleanup() {
  echo -e "\n[結束] $(date +%T) 停止監控。"

  # 結束時做事後檢查:有哪些 IP 出現過但從未看到 terminating?
  echo ""
  echo "===== 事後分析:Terminating 捕捉狀況 ====="
  if [[ ${#LAST_STATE[@]} -eq 0 ]]; then
    echo "(本次監控期間沒有任何 endpoint 進入過 ready 狀態)"
  else
    for ip in "${!LAST_STATE[@]}"; do
      if [[ "${SEEN_TERMINATING[$ip]}" == "1" ]]; then
        echo "  ✅ $ip  曾捕捉到 terminating 狀態"
      else
        # 只警告那些「曾經 ready 過然後消失」的 IP
        if [[ "${LAST_STATE[$ip]}" == "DISAPPEARED_WHILE_READY" ]]; then
          echo "  ❌ $ip  Pod 直接消失,未捕捉到 terminating(建議檢查 preStop hook)"
        elif [[ "${LAST_STATE[$ip]}" == "STILL_READY" ]]; then
          echo "  ⏸  $ip  監控結束時仍為 ready(未被刪除)"
        fi
      fi
    done
  fi
  echo "=========================================="

  kill -- -"$ROLLOUT_MONITOR_PID" 2>/dev/null
  exit 0
}

trap cleanup SIGINT SIGTERM

# 3. 逐事件串流監控核心
# 關鍵改動:
#   - 不再用 hash 比對「快照」,而是每個 watch event 都印出來
#   - 額外輸出每個 endpoint 的明細,並透過 stdin 餵給 bash 做狀態追蹤
#   - 用 NDJSON 格式每行一個事件,bash 端逐行解析

kubectl get endpointslices -n "$NS" \
  -l "kubernetes.io/service-name=$SVC_NAME" \
  --watch -o json 2>/dev/null | \
jq -u -r -c --unbuffered '
  select(.type != "ERROR" and .type != null) |
  {
    evt: .type,
    ts: now,
    eps: (.object.endpoints // [] | sort_by(.addresses[0]) |
          map({
            ip: .addresses[0],
            ready: (.conditions.ready // false),
            serving: (.conditions.serving // false),
            terminating: (.conditions.terminating // false)
          }))
  } |
  @json
' | while IFS= read -r EVT_JSON; do
  [[ -z "$EVT_JSON" ]] && continue

  EVT_TYPE=$(echo "$EVT_JSON" | jq -r '.evt')
  TS_NOW=$(date +%T.%3N)
  TS_EPOCH=$(date +%s.%3N)

  echo "[$TS_EPOCH|$TS_NOW] === EndpointSlice 事件: $EVT_TYPE ==="

  # 收集本次事件中出現的所有 IP
  CURRENT_IPS=()
  while IFS= read -r EP_LINE; do
    IP=$(echo "$EP_LINE" | jq -r '.ip')
    READY=$(echo "$EP_LINE" | jq -r '.ready')
    SERVING=$(echo "$EP_LINE" | jq -r '.serving')
    TERMINATING=$(echo "$EP_LINE" | jq -r '.terminating')

    [[ -z "$IP" || "$IP" == "null" ]] && continue
    CURRENT_IPS+=("$IP")

    # 標記:這個 IP 在本次事件的狀態
    STATE_MARK=""
    if [[ "$TERMINATING" == "true" ]]; then
      STATE_MARK="  ⚠ TERMINATING"
      SEEN_TERMINATING[$IP]=1
      LAST_STATE[$IP]="TERMINATING"
    elif [[ "$READY" == "true" ]]; then
      LAST_STATE[$IP]="STILL_READY"
    fi

    echo "  $IP  ready=$READY  serving=$SERVING  terminating=$TERMINATING$STATE_MARK"
  done < <(echo "$EVT_JSON" | jq -c '.eps[]')

  # 檢查上一輪有但這輪沒有的 IP(消失了)
  for prev_ip in "${!LAST_STATE[@]}"; do
    found=0
    for cur_ip in "${CURRENT_IPS[@]}"; do
      if [[ "$prev_ip" == "$cur_ip" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      # 這個 IP 消失了
      if [[ "${LAST_STATE[$prev_ip]}" == "STILL_READY" ]]; then
        # ❌ 這就是漏抓 terminating 的情境
        echo "  💥 $prev_ip  從 ready 直接消失(未經 terminating 過渡!)"
        LAST_STATE[$prev_ip]="DISAPPEARED_WHILE_READY"
      elif [[ "${LAST_STATE[$prev_ip]}" == "TERMINATING" ]]; then
        echo "  🪦 $prev_ip  已從 EndpointSlice 移除(正常流程)"
        unset LAST_STATE[$prev_ip]
      fi
    fi
  done

  echo ""
done
