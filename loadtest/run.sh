#!/usr/bin/env bash
# 업로드 엔드포인트 부하 테스트. 1) DB에 시드 데이터 준비 2) 사용자 확인(yes)
# 3) locust 실행 — 기본적으로 pod 리소스 모니터링(monitor.sh)도 백그라운드로 같이 돈다.
#
# local/prod가 클러스터도 같이 고른다 — 매번 KUBECONFIG를 손으로 unset/전환할
# 필요 없다. local은 k3d 고정 위치·이름을 그대로 박아도 이식성 문제가 없어서
# 하드코딩한다. prod는 사람마다 kubeconfig 저장 위치가 달라서(개인 경로) 여기
# 하드코딩하지 않고 LOADTEST_PROD_KUBECONFIG/LOADTEST_PROD_CONTEXT 환경변수로
# 받는다 — 안 주면 지금 쉘에 이미 설정된 KUBECONFIG/컨텍스트를 그대로 쓴다.
#
# --kubeconfig/--context를 매 kubectl 호출에 직접 붙인다(`kubectl config
# use-context`는 안 쓴다 — 그건 ~/.kube/config 파일 자체의 current-context를
# 영구히 바꿔버려서, 이 스크립트 밖에서 쓰던 컨텍스트까지 건드리게 된다).
#
# backend Deployment가 이미 떠 있어야 한다 — 이미지 태그와 backend-env/
# emoselfie-secrets 실제 이름(kustomize 해시 접미사 포함)을 거기서 그대로
# 가져다 쓴다. locust는 따로 설치할 필요 없다 — 없으면 이 스크립트가 전용
# 가상환경(~/.venvs/emoselfie-loadtest)에 알아서 깔아 쓴다. python3만 있으면 됨.
set -euo pipefail

usage() {
  cat <<'USAGE'
사용법: loadtest/run.sh [옵션]

  --users N               동시 사용자 수, 기본 100
  --duration SEC          지속 시간(초), 기본 300
  --target local|prod     기본 local — namespace/host 기본값과 kubeconfig까지 같이 정해짐
  --host URL              기본값은 --target에 따름
                            (local: http://localhost, prod: https://emoselfie.click/)
  --monitor-interval SEC  monitor.sh 기록 간격, 기본 5
  --no-monitor            모니터링 끄기 (기본은 켜짐)
  -h, --help              이 도움말

예:
  loadtest/run.sh                                          # 로컬, 100명, 300초
  loadtest/run.sh --users 100 --duration 300 --target prod
  loadtest/run.sh --users 100 --duration 300 --target prod --host https://other.example.com
  loadtest/run.sh --users 100 --duration 300 --no-monitor
  LOADTEST_PROD_KUBECONFIG=~/k3s_prod.yaml LOADTEST_PROD_CONTEXT=default \
    loadtest/run.sh --users 100 --duration 300 --target prod
USAGE
}

USERS="100"
DURATION_SEC="300"
TARGET="local"
HOST=""
MONITOR_INTERVAL=5
MONITOR_ENABLED=1

while [ $# -gt 0 ]; do
  case "$1" in
    --users) USERS="${2:?--users 값 필요}"; shift 2 ;;
    --duration) DURATION_SEC="${2:?--duration 값 필요}"; shift 2 ;;
    --target) TARGET="${2:?--target 값 필요}"; shift 2 ;;
    --host) HOST="${2:?--host 값 필요}"; shift 2 ;;
    --monitor-interval) MONITOR_INTERVAL="${2:?--monitor-interval 값 필요}"; shift 2 ;;
    --no-monitor) MONITOR_ENABLED=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "알 수 없는 옵션: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$TARGET" in
  local)
    NAMESPACE_DEFAULT=local
    HOST_DEFAULT="http://localhost"
    KCONFIG="$HOME/.kube/config"
    KCONTEXT="k3d-mycluster"
    ;;
  prod)
    NAMESPACE_DEFAULT=emoselfie
    HOST_DEFAULT="https://emoselfie.click/"
    KCONFIG="${LOADTEST_PROD_KUBECONFIG:-}"
    KCONTEXT="${LOADTEST_PROD_CONTEXT:-}"
    ;;
  *) echo "--target은 local 또는 prod (받은 값: $TARGET)" >&2; exit 1 ;;
esac

KCTL=(kubectl)
[ -n "$KCONFIG" ] && KCTL+=(--kubeconfig "$KCONFIG")
[ -n "$KCONTEXT" ] && KCTL+=(--context "$KCONTEXT")

NAMESPACE="${LOADTEST_NAMESPACE:-$NAMESPACE_DEFAULT}"
HOST="${HOST:-$HOST_DEFAULT}"
THINK_TIME_SEC="${LOADTEST_THINK_TIME_SEC:-3}"
BUFFER="${LOADTEST_BUFFER:-1.3}"
PARTICIPANTS_PER_ROOM="${LOADTEST_PARTICIPANTS_PER_ROOM:-4}"
DEADLINE_BUFFER_SEC="${LOADTEST_DEADLINE_BUFFER_SEC:-3600}"
SPAWN_RATE="${LOADTEST_SPAWN_RATE:-10}"
SEED_WAIT_TIMEOUT="${LOADTEST_SEED_TIMEOUT:-900s}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_CSV="$DIR/pool.csv"

# locust 확보 — 이미 PATH에 있으면 그거(누가 pipx 등으로 따로 관리 중이면 존중),
# 없으면 전용 venv를 쓰고, venv도 없으면 그 자리에서 만든다. 클러스터 작업
# 시작하기 전에 미리 확인해서, python3 자체가 없는 경우 시딩 다 해놓고 나서야
# 실패하는 걸 피한다.
VENV_DIR="$HOME/.venvs/emoselfie-loadtest"
if command -v locust >/dev/null 2>&1; then
  LOCUST=locust
elif [ -x "$VENV_DIR/bin/locust" ]; then
  LOCUST="$VENV_DIR/bin/locust"
else
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3가 필요합니다. https://python.org 에서 설치하거나 (macOS) brew install python3 후 다시 실행하세요." >&2
    exit 1
  fi
  echo "== locust 없음 — $VENV_DIR 에 설치 (한 번만) =="
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install -q --upgrade pip locust
  LOCUST="$VENV_DIR/bin/locust"
fi

echo "== 0/3 배포된 backend에서 이미지/설정 이름 확인 (namespace: $NAMESPACE) =="
BACKEND_IMAGE=$("${KCTL[@]}" get deployment backend -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
CONFIGMAP_NAME=$("${KCTL[@]}" get deployment backend -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
SECRET_NAME=$("${KCTL[@]}" get deployment backend -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[1].secretRef.name}')
echo "  image=$BACKEND_IMAGE configmap=$CONFIGMAP_NAME secret=$SECRET_NAME"

echo "== 1/3 시드 데이터 준비 (DB에 room/round/participant 생성) =="

"${KCTL[@]}" create configmap loadtest-seed-script -n "$NAMESPACE" \
  --from-file=seed.py="$DIR/seed.py" \
  --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

"${KCTL[@]}" delete job loadtest-seed -n "$NAMESPACE" --ignore-not-found

"${KCTL[@]}" apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest-seed
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: seed
          image: ${BACKEND_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["python", "/loadtest/seed.py"]
          envFrom:
            - configMapRef: {name: ${CONFIGMAP_NAME}}
            - secretRef: {name: ${SECRET_NAME}}
          env:
            - {name: LOADTEST_USERS, value: "${USERS}"}
            - {name: LOADTEST_DURATION_SEC, value: "${DURATION_SEC}"}
            - {name: LOADTEST_THINK_TIME_SEC, value: "${THINK_TIME_SEC}"}
            - {name: LOADTEST_BUFFER, value: "${BUFFER}"}
            - {name: LOADTEST_PARTICIPANTS_PER_ROOM, value: "${PARTICIPANTS_PER_ROOM}"}
            - {name: LOADTEST_DEADLINE_BUFFER_SEC, value: "${DEADLINE_BUFFER_SEC}"}
          resources:
            requests: {cpu: "200m", memory: "128Mi"}
            limits:   {cpu: "500m", memory: "256Mi"}
          volumeMounts:
            - {name: script, mountPath: /loadtest}
      volumes:
        - name: script
          configMap: {name: loadtest-seed-script}
EOF

echo "시딩 Job 대기 중 (최대 ${SEED_WAIT_TIMEOUT})..."
"${KCTL[@]}" wait --for=condition=complete --timeout="$SEED_WAIT_TIMEOUT" job/loadtest-seed -n "$NAMESPACE"

"${KCTL[@]}" logs job/loadtest-seed -n "$NAMESPACE" | grep -v '^# ' > "$POOL_CSV"
POOL_SIZE=$(( $(wc -l < "$POOL_CSV") - 1 ))

MONITOR_STATUS="꺼짐"
[ "$MONITOR_ENABLED" -eq 1 ] && MONITOR_STATUS="켜짐 (간격 ${MONITOR_INTERVAL}s)"

echo
echo "== 2/3 준비 완료 =="
echo "  대상 호스트     : $HOST"
echo "  동시 사용자     : $USERS"
echo "  지속 시간       : ${DURATION_SEC}s"
echo "  모니터링        : $MONITOR_STATUS"
echo "  준비된 업로드 슬롯: $POOL_SIZE (1회용 room/round/participant 조합)"
echo "  주의: DB에 실제 room/round/participant/user 행이 생성된 상태입니다."
echo "        테스트 후 loadtest/cleanup.sh $TARGET 로 정리하세요 (README 참고)"
echo "        (deadline 버퍼 ${DEADLINE_BUFFER_SEC}s 안에 정리 권장 — 그 이후엔"
echo "         백엔드 스케줄러가 이 라운드들을 정상 라운드처럼 처리하려 시도합니다)."
echo
read -r -p "부하 테스트를 시작할까요? (진행하려면 정확히 'yes' 입력): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "취소했습니다. 시드 데이터는 DB에 남아 있습니다 — 필요 없으면 loadtest/cleanup.sh $TARGET 로 지우세요."
  exit 0
fi

echo
echo "== 3/3 부하 테스트 시작 =="
mkdir -p "$DIR/results"
RESULT_PREFIX="$DIR/results/$(date +%Y%m%d-%H%M%S)"

MONITOR_PID=""
if [ "$MONITOR_ENABLED" -eq 1 ]; then
  "$DIR/monitor.sh" "$TARGET" "$MONITOR_INTERVAL" &
  MONITOR_PID=$!
fi

LOADTEST_POOL_CSV="$POOL_CSV" "$LOCUST" -f "$DIR/locustfile.py" \
  --host "$HOST" \
  --users "$USERS" \
  --spawn-rate "$SPAWN_RATE" \
  --run-time "${DURATION_SEC}s" \
  --headless \
  --csv "$RESULT_PREFIX"

if [ -n "$MONITOR_PID" ]; then
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
fi

echo
echo "완료. 결과: ${RESULT_PREFIX}_stats.csv"
echo "DB 정리 잊지 마세요: loadtest/cleanup.sh $TARGET"
