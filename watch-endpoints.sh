#!/bin/bash
# watch-endpoints.sh - EndpointSlice 變動監控腳本
# v6: 人類易讀輸出
#     - 每個事件印一張對齊好的表 (endpoint + pod 合併)
#     - 易讀狀態詞: READY / TERMINATING(serving) / (not in this slice)
#     - column -t 自動對齊欄位、TTY 下上色
#     - deletionTimestamp 轉本機 HH:MM:SS 以便與事件時間對照

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
for cmd in kubectl jq awk sha1sum sed; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[錯誤] 缺少必要工具: $cmd"
    exit 1
  fi
done

# 色碼 (僅在輸出是 TTY 時啟用)
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=; C_BOLD=; C_DIM=
  C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_MAGENTA=; C_CYAN=
fi

# 表格內的顏色只用來標出「相對於上一個事件有變動的欄位」,
# 變動偵測與上色都在 print_state_table 裡完成 (jq 標記 + awk 對齊+上色)。

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

# 取得 Pod selector (用於事件發生時批次抓 Pod 狀態)
POD_SELECTOR=$(kubectl get svc "$SVC_NAME" -n "$NS" -o json | jq -r '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")')
if [[ -z "$POD_SELECTOR" || "$POD_SELECTOR" == "null" ]]; then
  echo "[錯誤] Service $NS/$SVC_NAME 沒有 spec.selector,無法對應 Pod。"
  exit 1
fi

# 跨事件狀態:用來與上一個事件 diff 著色 (per slice)
declare -A PREV_EVT_BY_SLICE
PREV_PODS_JSON=""

# 去重用:記住每個 slice 上次「實際印出來」的 plain 內容 hash
# 如果新事件算出來的表內容跟上次一模一樣 (連 cell 都沒差),就跳過不印,
# 避免 K8s 對同一個 pod 連發無效 MODIFIED 時畫面被同一張表洗版。
declare -A LAST_RENDERED_HASH
TABLE_BUFFER=""
TABLE_SKIPPED=0

# 把一個 EndpointSlice 事件 (含 .eps) 算出「endpoint + 對應 pod 狀態」合併表,
# 結果寫到 TABLE_BUFFER (由 caller 決定要不要 echo);
# 若 force_render!=1 且算出來的內容跟上次一樣,設定 TABLE_SKIPPED=1 不更新狀態。
# 對比上一個同 slice 的事件,只把「有變動」的欄位上色。
# 不在這個 slice 但符合 selector 的 pod 會用 "(not in this slice)" 列出。
# 參數: <event_json> <slice_name> [force_render=0]
print_state_table() {
  local evt_json="$1"
  local slice_name="$2"
  local force_render="${3:-0}"

  TABLE_BUFFER=""
  TABLE_SKIPPED=0

  local pods_json
  pods_json=$(kubectl get pods -n "$NS" -l "$POD_SELECTOR" -o json)

  local has_prev="false"
  local prev_evt_json='{"eps":[]}'
  local prev_pods_json='{"items":[]}'
  if [[ -n "${PREV_EVT_BY_SLICE[$slice_name]:-}" ]]; then
    has_prev="true"
    prev_evt_json="${PREV_EVT_BY_SLICE[$slice_name]}"
    prev_pods_json="$PREV_PODS_JSON"
  fi

  # jq:輸出 TSV,變動的欄位前綴 "*"
  local rows
  rows=$(jq -r \
    --argjson cur       "$evt_json" \
    --argjson prev      "$prev_evt_json" \
    --argjson cur_pods  "$pods_json" \
    --argjson prev_pods "$prev_pods_json" \
    --argjson has_prev  "$has_prev" \
    -n '
    # CTR-READY: 就緒容器數 / 總容器數 (containerStatuses[].ready)
    def fmt_ctrs($p):
      (($p.status.containerStatuses // []) |
        if length>0 then "\(map(select(.ready)) | length)/\(length)"
        else "-" end);
    # KUBECTL-STATUS: 模擬 `kubectl get pods` STATUS 欄的合成邏輯
    # (參考 k8s.io/kubernetes pkg/printers/internalversion/printers.go printPod)
    def kubectl_status($p):
      (($p.status.phase // "") as $phase |
       (if ($p.status.reason // "") != "" then $p.status.reason else $phase end)) as $r0 |

      # 1) init container 階段:遇到第一個 non-Completed 就決定 reason 並停下來
      ($p.status.initContainerStatuses // []) as $ics |
      (reduce range(0; $ics | length) as $i
        ({reason: $r0, init: false, done: false};
         if .done then .
         else ($ics[$i]) as $c |
           if   ($c.state.terminated // null) != null and ($c.state.terminated.exitCode // 0) == 0 then .
           elif ($c.state.terminated // null) != null then
             {reason:
                (if ($c.state.terminated.reason // "") == "" then
                   (if ($c.state.terminated.signal // 0) != 0
                    then "Init:Signal:\($c.state.terminated.signal)"
                    else "Init:ExitCode:\($c.state.terminated.exitCode)" end)
                 else "Init:\($c.state.terminated.reason)" end),
              init: true, done: true}
           elif ($c.state.waiting // null) != null
                and ($c.state.waiting.reason // "") != ""
                and $c.state.waiting.reason != "PodInitializing" then
             {reason: "Init:\($c.state.waiting.reason)", init: true, done: true}
           else
             {reason: "Init:\($i)/\($ics | length)", init: true, done: true}
           end
         end)) as $ir |

      # 2) 一般 container 階段 (init 沒接手才跑;逆向走,最後一個 set 的 reason 勝出)
      (if $ir.init then $ir
       else
         ($p.status.containerStatuses // []) as $cs |
         (reduce range($cs | length - 1; -1; -1) as $i
           ({reason: $ir.reason, hasRunning: false};
            ($cs[$i]) as $c |
            if   ($c.state.waiting // null) != null and ($c.state.waiting.reason // "") != "" then
              .reason = $c.state.waiting.reason
            elif ($c.state.terminated // null) != null and ($c.state.terminated.reason // "") != "" then
              .reason = $c.state.terminated.reason
            elif ($c.state.terminated // null) != null then
              (if ($c.state.terminated.signal // 0) != 0
               then .reason = "Signal:\($c.state.terminated.signal)"
               else .reason = "ExitCode:\($c.state.terminated.exitCode)" end)
            elif ($c.ready // false) and (($c.state.running // null) != null) then
              .hasRunning = true
            else . end))
       end) as $cr |

      # 3) "Completed" 且還有 running container → 還原成 Running/NotReady
      (if $cr.reason == "Completed" and $cr.hasRunning then
         (if (($p.status.conditions // []) | any(.type == "Ready" and .status == "True"))
          then "Running" else "NotReady" end)
       else $cr.reason end) as $r3 |

      # 4) deletionTimestamp 覆蓋為 Terminating (NodeLost 例外)
      (if ($p.metadata.deletionTimestamp // null) != null then
         (if ($p.status.reason // "") == "NodeLost" then "Unknown" else "Terminating" end)
       else $r3 end) as $r4 |

      (if $r4 == "" then "Unknown" else $r4 end);
    def fmt_del($p):
      if $p.metadata.deletionTimestamp
      then ($p.metadata.deletionTimestamp | fromdateiso8601 | strflocaltime("%H:%M:%S"))
      else "-" end;
    def ep_status:
      if   .terminating and .serving then "TERMINATING(serving)"
      elif .terminating              then "TERMINATING"
      elif .ready                    then "READY"
      elif .serving                  then "NotReady(serving)"
      else                                "NotReady"
      end;
    # diff($new; $oldval): 第一個事件不標;之後新出現或值不同就在前面加 "*"
    def diff($new; $oldval):
      if ($has_prev | not) then ($new|tostring)
      elif ($oldval == null) then "*" + ($new|tostring)
      elif ($new|tostring) == ($oldval|tostring) then ($new|tostring)
      else "*" + ($new|tostring) end;

    ($cur_pods.items  // []) as $cur_items  |
    ($prev_pods.items // []) as $prev_items |
    ($cur_items  | map({key: .metadata.name, value: .}) | from_entries) as $cur_pidx  |
    ($prev_items | map({key: .metadata.name, value: .}) | from_entries) as $prev_pidx |
    (($prev.eps // []) | map({key: .pod, value: .}) | from_entries)     as $prev_eidx |

    (($cur.eps // []) | map(
      . as $ep |
      ($cur_pidx[$ep.pod]  // {metadata:{},status:{}}) as $p |
      ($prev_pidx[$ep.pod] // null) as $prev_p |
      ($prev_eidx[$ep.pod] // null) as $prev_ep |
      [
        diff(ep_status;           (if $prev_ep then ($prev_ep | ep_status)     else null end)),
        diff(.ready;              (if $prev_ep then $prev_ep.ready             else null end)),
        diff(.serving;            (if $prev_ep then $prev_ep.serving           else null end)),
        diff(.terminating;        (if $prev_ep then $prev_ep.terminating       else null end)),
        $ep.ip, $ep.pod,
        diff(kubectl_status($p);  (if $prev_p  then kubectl_status($prev_p)    else null end)),
        diff(fmt_ctrs($p);        (if $prev_p  then fmt_ctrs($prev_p)          else null end)),
        diff(fmt_del($p);         (if $prev_p  then fmt_del($prev_p)           else null end))
      ]
    )) as $ep_rows |

    (($cur.eps // []) | map(.pod)) as $cur_ep_names |
    ($cur_items | map(select(.metadata.name as $n | ($cur_ep_names | index($n)) | not))
                | sort_by(.metadata.name)
                | map(. as $p |
                  ($prev_pidx[$p.metadata.name] // null) as $prev_p |
                  [ "(not in this slice)", "-", "-", "-",
                    ($p.status.podIP // "-"), $p.metadata.name,
                    diff(kubectl_status($p);  (if $prev_p then kubectl_status($prev_p)  else null end)),
                    diff(fmt_ctrs($p);        (if $prev_p then fmt_ctrs($prev_p)        else null end)),
                    diff(fmt_del($p);         (if $prev_p then fmt_del($prev_p)         else null end))
                  ]
                )) as $extra_rows |

    ($ep_rows + $extra_rows)[] | @tsv
  ')

  if [[ -z "$rows" ]]; then
    TABLE_BUFFER="  (此 slice 沒有 endpoint,也沒有其他匹配 pod)"
    PREV_EVT_BY_SLICE[$slice_name]="$evt_json"
    PREV_PODS_JSON="$pods_json"
    return
  fi

  # 去重檢查:用「拿掉 diff 標記 *」的純內容算 hash,跟上次比對
  if [[ "$force_render" != "1" ]]; then
    local plain_hash
    plain_hash=$(echo "$rows" | sed 's/\t\*/\t/g; s/^\*//' | sha1sum | cut -d' ' -f1)
    if [[ "${LAST_RENDERED_HASH[$slice_name]:-}" == "$plain_hash" ]]; then
      TABLE_SKIPPED=1
      return  # 內容沒變,不印、不更新 PREV
    fi
    LAST_RENDERED_HASH[$slice_name]="$plain_hash"
  fi

  # awk:自行對齊欄位,只對前綴 "*" 的欄位套用顏色 (ANSI 不影響欄寬計算)
  TABLE_BUFFER=$({
    printf "EP-STATUS\tREADY\tSERVING\tTERMINATING\tIP\tPOD\tKUBECTL-STATUS\tCTR-READY\tDELETING@\n"
    echo "$rows"
  } | awk -v ON="${C_YELLOW}${C_BOLD}" -v OFF="${C_RESET}" '
    BEGIN { FS="\t" }
    {
      ncols = NF
      for (i=1; i<=NF; i++) {
        val = $i
        if (substr(val,1,1) == "*") { ch[NR,i]=1; val=substr(val,2) }
        plain[NR,i] = val
        if (length(val) > w[i]) w[i] = length(val)
      }
      nrows = NR
    }
    END {
      for (r=1; r<=nrows; r++) {
        line = "  "
        for (i=1; i<=ncols; i++) {
          v = plain[r,i]
          pad = w[i] - length(v)
          if (ch[r,i]) cell = ON v OFF; else cell = v
          line = line cell sprintf("%*s", pad, "")
          if (i < ncols) line = line "  "
        }
        print line
      }
    }
  ')

  PREV_EVT_BY_SLICE[$slice_name]="$evt_json"
  PREV_PODS_JSON="$pods_json"
}

SEP="------------------------------------------------------------------------"
echo "${C_BOLD}${SEP}${C_RESET}"
echo "${C_BOLD}監控目標${C_RESET}: $NS/Service/$SVC_NAME  ->  Deployment/$DEPLOY_NAME"
echo "${C_DIM}Rollout 成功後 ${WAIT_SECONDS}s 自動結束,Ctrl+C 可手動中止${C_RESET}"
echo "${C_BOLD}${SEP}${C_RESET}"

# 2. 初始快照:列出目前所有 EndpointSlice 內容 (用同一張表呈現)
echo ""
echo "${C_CYAN}=== [$(date +%T)]  INITIAL SNAPSHOT (watch 開始前)${C_RESET}"
SNAPSHOT=$(kubectl get endpointslices -n "$NS" \
  -l "kubernetes.io/service-name=$SVC_NAME" -o json)

SLICE_COUNT=$(echo "$SNAPSHOT" | jq '.items | length')
if [[ "$SLICE_COUNT" == "0" ]]; then
  echo "  (目前沒有任何 EndpointSlice)"
else
  while IFS= read -r SLICE_EVT; do
    SLICE_NAME=$(echo "$SLICE_EVT" | jq -r '.name')
    echo "  ${C_BOLD}EndpointSlice/${SLICE_NAME}${C_RESET}"
    print_state_table "$SLICE_EVT" "$SLICE_NAME" 1  # force_render
    echo "$TABLE_BUFFER"
    echo ""
  done < <(echo "$SNAPSHOT" | jq -c '
    .items[] | {
      evt: "INITIAL",
      name: .metadata.name,
      eps: (.endpoints // [] | sort_by(.addresses[0]) | map({
        ip: .addresses[0],
        pod: (.targetRef.name // "-"),
        ready: (.conditions.ready // false),
        serving: (.conditions.serving // false),
        terminating: (.conditions.terminating // false)
      }))
    }
  ')
fi

WATCHER_PID=$$

# 3. 自動 Rollout 監控邏輯
auto_rollout_task() {
  # 在 watches 也啟動完之後再觸發 rollout,給 kubectl --watch 建立連線一點時間
  sleep 1
  local old_gen
  old_gen=$(kubectl get deployment "$DEPLOY_NAME" -n "$NS" -o jsonpath='{.metadata.generation}')
  echo -e "\n${C_MAGENTA}[ACTION] [$(date +%T)] kubectl rollout restart deployment/${DEPLOY_NAME}${C_RESET}"
  kubectl rollout restart deployment/"$DEPLOY_NAME" -n "$NS" > /dev/null
  local new_gen=$old_gen
  local timeout=30
  while [[ "$new_gen" == "$old_gen" && $timeout -gt 0 ]]; do
    sleep 0.5
    new_gen=$(kubectl get deployment "$DEPLOY_NAME" -n "$NS" -o jsonpath='{.metadata.generation}')
    ((timeout--))
  done
  if [[ "$new_gen" == "$old_gen" ]]; then
    echo -e "\n${C_RED}[ERROR] [$(date +%T)] K8s 並未在超時內回傳新的 Generation,Rollout 失敗${C_RESET}"
    kill -SIGINT "$WATCHER_PID" 2>/dev/null
    return
  fi
  echo "${C_DIM}  K8s 已確認重啟 (Gen: $old_gen -> $new_gen),開始監測...${C_RESET}"
  if kubectl rollout status deployment/"$DEPLOY_NAME" -n "$NS" --timeout=300s > /dev/null 2>&1; then
    echo -e "\n${C_GREEN}[OK] [$(date +%T)] Rollout 成功完成${C_RESET}"
  else
    echo -e "\n${C_YELLOW}[WARN] [$(date +%T)] Rollout 發生異常或超時${C_RESET}"
  fi
  echo "${C_DIM}  等待 ${WAIT_SECONDS}s 收集殘留事件...${C_RESET}"
  sleep "$WAIT_SECONDS"
  kill -SIGINT "$WATCHER_PID" 2>/dev/null
}

cleanup() {
  trap '' SIGINT SIGTERM  # 避免 cleanup 被重複觸發
  # 先殺掉兩個 watch (整個 process group),關掉 FIFO 寫端
  [[ -n "${EP_WATCH_PID:-}"  ]] && kill -- -"$EP_WATCH_PID"  2>/dev/null
  [[ -n "${POD_WATCH_PID:-}" ]] && kill -- -"$POD_WATCH_PID" 2>/dev/null
  [[ -n "${EVT_FIFO:-}"      ]] && rm -f "$EVT_FIFO"

  echo ""
  echo "${C_CYAN}=== [$(date +%T)]  FINAL SNAPSHOT (watch 結束後)${C_RESET}"
  local final_snap
  final_snap=$(kubectl get endpointslices -n "$NS" \
    -l "kubernetes.io/service-name=$SVC_NAME" -o json 2>/dev/null)
  local n
  n=$(echo "$final_snap" | jq '.items | length')
  if [[ "$n" == "0" ]]; then
    echo "  (沒有任何 EndpointSlice)"
  else
    while IFS= read -r slice_evt; do
      local sname
      sname=$(echo "$slice_evt" | jq -r '.name')
      echo "  ${C_BOLD}EndpointSlice/${sname}${C_RESET}"
      print_state_table "$slice_evt" "$sname" 1  # force_render
      echo "$TABLE_BUFFER"
      echo ""
    done < <(echo "$final_snap" | jq -c '
      .items[] | {
        evt: "FINAL",
        name: .metadata.name,
        eps: (.endpoints // [] | sort_by(.addresses[0]) | map({
          ip: .addresses[0],
          pod: (.targetRef.name // "-"),
          ready: (.conditions.ready // false),
          serving: (.conditions.serving // false),
          terminating: (.conditions.terminating // false)
        }))
      }
    ')
  fi
  echo -e "${C_BOLD}[STOP] [$(date +%T)] 停止監控${C_RESET}"
  [[ -n "${ROLLOUT_MONITOR_PID:-}" ]] && kill -- -"$ROLLOUT_MONITOR_PID" 2>/dev/null
  exit 0
}

trap cleanup SIGINT SIGTERM

# 4. 雙 watch 合流:EndpointSlice + Pod
# - 兩個 kubectl --watch-only 都寫到同一條 FIFO,每行用 "EP\t" 或 "POD\t" 前綴
# - 主 shell 從 FIFO 逐行讀,依來源分派
# - POD 事件用 PREV_EVT_BY_SLICE 裡快取的 EP payload 重 render 同一張表
#   (這樣 pod phase=Pending / ContainerCreating 等 EndpointSlice 看不到的階段也能被捕捉)

EVT_FIFO=$(mktemp -u --suffix=.fifo)
mkfifo "$EVT_FIFO"
trap 'rm -f "$EVT_FIFO" 2>/dev/null' EXIT

set -m  # 讓背景 watch 各自有 process group,cleanup 可整組 kill

(
  kubectl get endpointslices -n "$NS" \
    -l "kubernetes.io/service-name=$SVC_NAME" \
    --watch-only --output-watch-events=true -o json 2>/dev/null | \
  jq -r -c --unbuffered '
    select(.type != null and .type != "ERROR") |
    "EP\t" + (
      {
        evt: .type,
        name: (.object.metadata.name // "unknown"),
        eps: (.object.endpoints // [] | sort_by(.addresses[0]) |
              map({
                ip: .addresses[0],
                pod: (.targetRef.name // "-"),
                ready: (.conditions.ready // false),
                serving: (.conditions.serving // false),
                terminating: (.conditions.terminating // false)
              }))
      } | @json
    )
  ' > "$EVT_FIFO"
) &
EP_WATCH_PID=$!

(
  kubectl get pods -n "$NS" -l "$POD_SELECTOR" \
    --watch-only --output-watch-events=true -o json 2>/dev/null | \
  jq -r -c --unbuffered '
    select(.type != null and .type != "ERROR") |
    "POD\t" + (
      { evt: .type, name: (.object.metadata.name // "unknown") } | @json
    )
  ' > "$EVT_FIFO"
) &
POD_WATCH_PID=$!

# Watches 已啟動,再 fork rollout 任務 (set -m 保證它有獨立 pgid,cleanup 才殺得乾淨)
auto_rollout_task &
ROLLOUT_MONITOR_PID=$!

set +m

while IFS=$'\t' read -r SRC PAYLOAD; do
  [[ -z "$SRC" || -z "$PAYLOAD" ]] && continue

  EVT_TYPE=$(echo "$PAYLOAD" | jq -r '.evt')
  NAME=$(echo "$PAYLOAD" | jq -r '.name')
  TS_NOW=$(date +%T.%3N)

  case "$EVT_TYPE" in
    ADDED)    EVT_COLOR=$C_GREEN ;;
    MODIFIED) EVT_COLOR=$C_YELLOW ;;
    DELETED)  EVT_COLOR=$C_RED ;;
    *)        EVT_COLOR=$C_CYAN ;;
  esac

  case "$SRC" in
    EP)
      if [[ "$EVT_TYPE" == "DELETED" ]]; then
        echo ""
        echo "${C_CYAN}===${C_RESET} [${C_BOLD}$TS_NOW${C_RESET}]  ${EVT_COLOR}${C_BOLD}EP-${EVT_TYPE}${C_RESET}  EndpointSlice/${NAME}"
        echo "  ${C_RED}EndpointSlice 已被刪除${C_RESET}"
        unset "PREV_EVT_BY_SLICE[$NAME]"
        unset "LAST_RENDERED_HASH[$NAME]"
      else
        print_state_table "$PAYLOAD" "$NAME"
        if [[ "$TABLE_SKIPPED" != "1" ]]; then
          echo ""
          echo "${C_CYAN}===${C_RESET} [${C_BOLD}$TS_NOW${C_RESET}]  ${EVT_COLOR}${C_BOLD}EP-${EVT_TYPE}${C_RESET}  EndpointSlice/${NAME}"
          echo "$TABLE_BUFFER"
        fi
      fi
      ;;
    POD)
      if [[ ${#PREV_EVT_BY_SLICE[@]} -eq 0 ]]; then
        # 完全沒看過任何 slice → 只能印一行通知 (這條也去重,避免連續同 pod 變動洗版)
        msg="(尚未收到任何 EndpointSlice 事件,僅顯示 pod 變動)"
        msg_hash=$(echo "${NAME}|${msg}" | sha1sum | cut -d' ' -f1)
        if [[ "${LAST_RENDERED_HASH[__pod_no_slice__]:-}" != "$msg_hash" ]]; then
          LAST_RENDERED_HASH[__pod_no_slice__]="$msg_hash"
          echo ""
          echo "${C_CYAN}===${C_RESET} [${C_BOLD}$TS_NOW${C_RESET}]  ${EVT_COLOR}${C_BOLD}POD-${EVT_TYPE}${C_RESET}  Pod/${NAME}"
          echo "  ${C_DIM}${msg}${C_RESET}"
        fi
      else
        # POD 事件不改 EP payload,用快取的最新 EP payload 重畫表;
        # 表內 pod 欄會反映剛抓到的最新 pod 狀態。
        # 多個 slice 的話,每個 slice 各自去重,只把真有變動的印出來。
        rendered_buffers=()
        for slice in "${!PREV_EVT_BY_SLICE[@]}"; do
          print_state_table "${PREV_EVT_BY_SLICE[$slice]}" "$slice"
          if [[ "$TABLE_SKIPPED" != "1" ]]; then
            rendered_buffers+=("$TABLE_BUFFER")
          fi
        done
        if [[ ${#rendered_buffers[@]} -gt 0 ]]; then
          echo ""
          echo "${C_CYAN}===${C_RESET} [${C_BOLD}$TS_NOW${C_RESET}]  ${EVT_COLOR}${C_BOLD}POD-${EVT_TYPE}${C_RESET}  Pod/${NAME}"
          for b in "${rendered_buffers[@]}"; do
            echo "$b"
          done
        fi
      fi
      ;;
  esac
done < "$EVT_FIFO"
