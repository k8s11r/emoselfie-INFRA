#!/usr/bin/env bash
# 부하 테스트 중 pod별 CPU/메모리를 주기적으로 CSV에 기록한다. k9s로 수동
# 캡처하는 대신, run.sh와 별개 터미널에서 같이 띄워두고 나중에 locust의
# stats_history.csv와 timestamp로 맞춰 비교하기 위한 것 — run.sh 자체는
# 안 건드리고, 그 옆에서 관찰만 한다.
#
# 사용법: loadtest/monitor.sh [local|prod] [간격(초), 기본 5] [지속시간(초), 기본 0=무제한]
#   예: loadtest/monitor.sh local           # Ctrl+C로 멈출 때까지
#       loadtest/monitor.sh prod 5 300      # 운영, 5초 간격, 300초 후 자동 종료
#
# local/prod의 kubeconfig 고정 방식은 run.sh와 동일하다.
set -euo pipefail

TARGET="${1:-local}"
INTERVAL="${2:-5}"
DURATION="${3:-0}"

case "$TARGET" in
  local)
    NAMESPACE=local
    KCONFIG="$HOME/.kube/config"
    KCONTEXT="k3d-mycluster"
    ;;
  prod)
    NAMESPACE=emoselfie
    KCONFIG="${LOADTEST_PROD_KUBECONFIG:-}"
    KCONTEXT="${LOADTEST_PROD_CONTEXT:-}"
    ;;
  *) echo "1번째 인자는 local 또는 prod (받은 값: $TARGET)" >&2; exit 1 ;;
esac

KCTL=(kubectl)
[ -n "$KCONFIG" ] && KCTL+=(--kubeconfig "$KCONFIG")
[ -n "$KCONTEXT" ] && KCTL+=(--context "$KCONTEXT")

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DIR/results"
OUT="$DIR/results/$(date +%Y%m%d-%H%M%S)_monitor.csv"

echo "timestamp,pod,cpu,memory" > "$OUT"
echo "기록 시작: $OUT (namespace=$NAMESPACE, 간격 ${INTERVAL}s)"
if [ "$DURATION" -gt 0 ]; then
  echo "${DURATION}초 후 자동 종료 (그 전에 멈추려면 Ctrl+C)"
else
  echo "멈추려면 Ctrl+C"
fi

trap 'echo; echo "종료. 기록: $OUT"' EXIT

END_TIME=0
[ "$DURATION" -gt 0 ] && END_TIME=$(( $(date +%s) + DURATION ))

while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "${KCTL[@]}" top pod -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk -v ts="$TS" '{print ts","$1","$2","$3}' >> "$OUT"

  if [ "$END_TIME" -gt 0 ] && [ "$(date +%s)" -ge "$END_TIME" ]; then
    break
  fi
  sleep "$INTERVAL"
done
