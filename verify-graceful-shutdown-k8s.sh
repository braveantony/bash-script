#!/bin/bash
# 驗證 K8s Deployment 環境下 srv.Shutdown() 三個行為：
#   1. 立刻停止接受新的連線請求
#   2. 立刻關閉沒有請求在跑的閒置連線
#   3. 等待正在處理中的請求自然完成才退出

cd "$(dirname "$0")/.." || { echo "ERROR: 無法切換到專案根目錄"; exit 1; }

IMAGE="quay.io/hahappyman/goweb:v1-gs"
CLIENT_IMAGE="quay.io/hahappyman/netshoot:latest"
DEPLOYMENT="gs-verify"
CLIENT_POD="gs-client"

kubectl cluster-info > /dev/null 2>&1 || { echo "ERROR: 無法連線到 K8s cluster"; exit 1; }

# 清理舊 Deployment，等待舊 Pod 確實消失，避免 label selector 撈到舊 Pod
kubectl delete deployment "$DEPLOYMENT" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete pod "$CLIENT_POD" --ignore-not-found > /dev/null 2>&1 || true
kubectl wait pod -l "app=$DEPLOYMENT" --for=delete --timeout=40s > /dev/null 2>&1 || true
kubectl wait pod/"$CLIENT_POD" --for=delete --timeout=40s > /dev/null 2>&1 || true

WORK_DIR=$(mktemp -d)
LOG_PID=""
trap 'kill $LOG_PID 2>/dev/null || true
      kubectl delete deployment "$DEPLOYMENT" --ignore-not-found --wait=false > /dev/null 2>&1 || true
      kubectl delete pod "$CLIENT_POD" --ignore-not-found --wait=false > /dev/null 2>&1 || true
      kill $(jobs -p) 2>/dev/null || true
      wait 2>/dev/null || true
      rm -rf "$WORK_DIR"' EXIT

echo "======================================"
echo " 驗證 srv.Shutdown() 三個行為"
echo "  行為一：立刻停止接受新的連線請求"
echo "  行為二：立刻關閉沒有請求在跑的閒置連線"
echo "  行為三：等待正在處理中的請求自然完成才退出"
echo "======================================"
echo ""
echo "=== [1] 建立 Deployment 與 client Pod ==="
kubectl create deployment "$DEPLOYMENT" --image="$IMAGE" --replicas=1 > /dev/null \
  || { echo "ERROR: 無法建立 Deployment $DEPLOYMENT"; exit 1; }
kubectl run "$CLIENT_POD" --image="$CLIENT_IMAGE" --restart=Never -- sleep infinity > /dev/null \
  || { echo "ERROR: 無法建立 client Pod $CLIENT_POD"; exit 1; }
echo "→ Deployment $DEPLOYMENT、client Pod $CLIENT_POD 已建立"

echo ""
echo "=== [2] 等待兩個 Pod Ready ==="
kubectl wait deployment/"$DEPLOYMENT" --for=condition=Available --timeout=60s > /dev/null \
  || { echo "ERROR: server Deployment 未能在 60 秒內就緒"; exit 1; }
kubectl wait pod/"$CLIENT_POD" --for=condition=Ready --timeout=60s > /dev/null \
  || { echo "ERROR: client Pod 未能在 60 秒內就緒"; exit 1; }
POD=$(kubectl get pod -l "app=$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')
POD_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.podIP}')
echo "→ server Pod：$POD  IP：$POD_IP"

# 清理 client Pod 內殘留暫存檔（來自上次異常中斷）
kubectl exec "$CLIENT_POD" -- rm -f /tmp/gs-nc-resp.txt /tmp/gs-slow-resp.txt 2>/dev/null || true

# 確認 client 可到達 server
kubectl exec "$CLIENT_POD" -- curl -sf --max-time 5 "http://$POD_IP:8080/healthz" > /dev/null \
  || { echo "ERROR: client Pod 無法連線到 server Pod IP $POD_IP"; exit 1; }
echo "→ client Pod 可連線到 server Pod"

echo ""
echo "=== [3] 開始 follow Pod log（避免 Pod 被刪後 log 撈不到）==="
kubectl logs -f "$POD" > "$WORK_DIR/gs.log" 2>&1 &
LOG_PID=$!
sleep 0.5
kill -0 $LOG_PID 2>/dev/null || { echo "ERROR: kubectl logs -f 啟動失敗"; exit 1; }
echo "→ log stream 已啟動（PID: $LOG_PID），log 寫入 $WORK_DIR/gs.log"

echo ""
echo "=== [4] 建立閒置連線 ==="
kubectl exec "$CLIENT_POD" -- sh -c \
  "(printf 'GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n'; \
    sleep 0.5; \
    printf 'GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n'; \
    sleep 30) | nc $POD_IP 8080 > /tmp/gs-nc-resp.txt" &
NC_BG_PID=$!
sleep 1.5
NC_COUNT=$(kubectl exec "$CLIENT_POD" -- grep -c "HTTP/1.1" /tmp/gs-nc-resp.txt 2>/dev/null || echo 0)
[[ $NC_COUNT -ge 2 ]] || { echo "ERROR: nc 只收到 ${NC_COUNT} 個回應，閒置連線未確立"; exit 1; }
echo "→ 同一條連線送兩個請求，兩次都收到回應，連線目前閒置中："
kubectl exec "$CLIENT_POD" -- grep -o "HTTP/1.1 [0-9]* [A-Z]*" /tmp/gs-nc-resp.txt | nl

echo ""
echo "=== [5] 建立 active 連線 ==="
kubectl exec "$CLIENT_POD" -- sh -c "curl -s http://$POD_IP:8080/slow > /tmp/gs-slow-resp.txt" &
SLOW_BG_PID=$!
sleep 0.3
echo "→ /slow 請求已送出，handler 正在執行"

echo ""
echo "=== [6] SIGTERM 前：兩條連線都正常，看不出閒置與處理中的差異 ==="
echo "$ kubectl exec $CLIENT_POD -- ss -tnp 'dport = :8080'"
SS_BEFORE=$(kubectl exec "$CLIENT_POD" -- ss -tnp 'dport = :8080')
echo "$SS_BEFORE"
ESTAB_BEFORE=$(echo "$SS_BEFORE" | grep -c ESTAB)
[[ $ESTAB_BEFORE -eq 2 ]] || { echo "ERROR: 預期 2 條正常連線，實際有 ${ESTAB_BEFORE} 條"; exit 1; }
echo "→ nc 和 curl 連線都正常，符合預期"

echo ""
echo "=== [7] 發送 SIGTERM（kubectl delete deployment）==="
kubectl delete deployment "$DEPLOYMENT" --wait=false > /dev/null \
  || { echo "ERROR: 無法刪除 Deployment"; exit 1; }
echo "→ SIGTERM 已送出（K8s 控制器傳送給 Pod）"
sleep 1

echo ""
echo "=== [8] 驗證一：立刻停止接受新的連線請求 ==="
echo "$ kubectl exec $CLIENT_POD -- curl -sf --max-time 1 http://$POD_IP:8080/healthz > /dev/null 2>&1; echo \$?"
LISTENER_CODE=$(kubectl exec "$CLIENT_POD" -- sh -c \
  "curl -sf --max-time 1 http://$POD_IP:8080/healthz > /dev/null 2>&1; echo \$?")
echo "→ curl exit code：$LISTENER_CODE"
[[ "$LISTENER_CODE" != "0" ]] || { echo "ERROR: 新連線仍收到 200，listener 可能仍在監聽"; exit 1; }
echo "→ 新連線未收到成功回應，立刻停止接受新的連線請求，符合預期"
echo "→ 行為一驗證通過"

echo ""
echo "=== [9] 驗證二：閒置連線已被關閉，處理中連線仍維持 ==="
echo "$ kubectl exec $CLIENT_POD -- ss -tnp 'dport = :8080'"
SS_AFTER=$(kubectl exec "$CLIENT_POD" -- ss -tnp 'dport = :8080')
echo "$SS_AFTER"
CLOSE_WAIT=$(echo "$SS_AFTER" | grep -c CLOSE-WAIT)
ESTAB_AFTER=$(echo "$SS_AFTER" | grep -c ESTAB)
[[ $CLOSE_WAIT -ge 1 ]] || { echo "ERROR: nc 連線未進入關閉狀態，閒置連線未被關閉"; exit 1; }
[[ $ESTAB_AFTER -ge 1 ]] || { echo "ERROR: curl 連線已中斷，處理中連線被提前終止"; exit 1; }
echo "→ nc 連線關閉中（閒置連線已關），curl 連線正常（處理中連線保留），符合預期"
echo "→ 行為二驗證通過"

echo ""
echo "=== [10] 驗證三：等待正在處理中的請求自然完成才退出 ==="
# 同時在背景 poll exit code，利用等待 /slow 的視窗，避免錯過 Pod Terminated 窗口
{
  for i in $(seq 1 60); do
    if ! kubectl get pod "$POD" > /dev/null 2>&1; then
      echo "DELETED" > "$WORK_DIR/exit-code.txt"; exit 0
    fi
    TERMINATED=$(kubectl get pod "$POD" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
    if [[ -n "$TERMINATED" ]]; then
      echo "$TERMINATED" > "$WORK_DIR/exit-code.txt"; exit 0
    fi
    sleep 0.5
  done
} &
EXIT_POLL_PID=$!

wait $SLOW_BG_PID || { echo "ERROR: /slow curl 異常退出"; exit 1; }
SLOW_RESP=$(kubectl exec "$CLIENT_POD" -- cat /tmp/gs-slow-resp.txt 2>/dev/null)
[[ "$SLOW_RESP" == "slow ok" ]] || { echo "ERROR: /slow 回應不符預期（got: '$SLOW_RESP'）"; exit 1; }
echo "→ /slow 回應：$SLOW_RESP"
echo "→ 行為三驗證通過"

echo ""
echo "=== [11] Pod exit code（預期 0）==="
wait $EXIT_POLL_PID 2>/dev/null || true
SERVER_EXIT=$(cat "$WORK_DIR/exit-code.txt" 2>/dev/null)
if [[ "$SERVER_EXIT" == "DELETED" ]]; then
  echo "→ Pod 已被 K8s 清除（exit code 將由 step [12] log 確認）"
elif [[ -n "$SERVER_EXIT" ]] && [[ $SERVER_EXIT -eq 0 ]]; then
  echo "→ exit code：$SERVER_EXIT"
else
  echo "ERROR: Pod 未正常退出或超時（exit code: ${SERVER_EXIT:-timeout}）"; exit 1
fi

echo ""
echo "=== [12] Pod log（從預先啟動的 follow stream 收集）==="
# 等 kubectl logs -f 自然結束（Pod 真的退出後 stream 會 EOF）
# 設個 timeout 避免無窮等
for i in $(seq 1 20); do
  if ! kill -0 $LOG_PID 2>/dev/null; then break; fi
  sleep 0.5
done
# 若超時仍未結束就主動 kill
if kill -0 $LOG_PID 2>/dev/null; then
  kill $LOG_PID 2>/dev/null || true
  sleep 0.3
fi
wait $LOG_PID 2>/dev/null || true

echo "$ kubectl logs $POD（從 $WORK_DIR/gs.log 讀取）"
cat "$WORK_DIR/gs.log"
[[ -s "$WORK_DIR/gs.log" ]] || { echo "ERROR: log 檔案為空，可能 follow stream 未正常啟動"; exit 1; }
grep -q "server exited cleanly" "$WORK_DIR/gs.log" \
  || { echo "ERROR: log 未見 'server exited cleanly'，server 可能非正常退出"; exit 1; }
SIGNAL_LINE=$(grep -n "received signal" "$WORK_DIR/gs.log" | head -1 | cut -d: -f1)
COMPLETED_LINE=$(grep -n "request completed" "$WORK_DIR/gs.log" | head -1 | cut -d: -f1)
[[ -n "$SIGNAL_LINE" && -n "$COMPLETED_LINE" ]] \
  || { echo "ERROR: log 缺少必要紀錄（received signal 或 request completed）"; exit 1; }
[[ $SIGNAL_LINE -lt $COMPLETED_LINE ]] \
  || { echo "ERROR: /slow 在 SIGTERM 之前就完成了，未真正驗證等待行為（line $SIGNAL_LINE vs $COMPLETED_LINE）"; exit 1; }
echo "→ log 確認順序正確：SIGTERM 在 line $SIGNAL_LINE，/slow 完成在 line $COMPLETED_LINE"

echo ""
echo "=== 驗證完成 ==="
