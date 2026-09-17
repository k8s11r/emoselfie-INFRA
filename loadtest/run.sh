#!/usr/bin/env bash
# 업로드 엔드포인트 부하 테스트. 1) DB에 시드 데이터 준비 2) 사용자 확인(yes) 3) locust 실행.
#
# 사용법: loadtest/run.sh <동시 사용자 수> <지속 시간(초)> [local|prod] [대상 호스트]
#   local(기본): namespace=local,  host 기본 http://localhost
#   prod       : namespace=emoselfie, host 기본 https://emoselfie.click/
#   예: loadtest/run.sh 100 300              # 로컬
#       loadtest/run.sh 100 300 prod         # 운영, 도메인은 기본값 사용
#       loadtest/run.sh 100 300 prod https://other.example.com   # host만 override
#       LOADTEST_PROD_KUBECONFIG=~/k3s_prod.yaml LOADTEST_PROD_CONTEXT=default \
#         loadtest/run.sh 100 300 prod       # 운영 kubeconfig를 지금 쉘과 무관하게 못박기
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
# 가져다 쓴다. locust는 로컬에 `pip install locust`.
set -euo pipefail

USERS="${1:?사용법: loadtest/run.sh <users> <duration_sec> [local|prod] [host]}"
DURATION_SEC="${2:?사용법: loadtest/run.sh <users> <duration_sec> [local|prod] [host]}"
TARGET="${3:-local}"

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
  *) echo "3번째 인자는 local 또는 prod (받은 값: $TARGET)" >&2; exit 1 ;;
esac

KCTL=(kubectl)
[ -n "$KCONFIG" ] && KCTL+=(--kubeconfig "$KCONFIG")
[ -n "$KCONTEXT" ] && KCTL+=(--context "$KCONTEXT")

NAMESPACE="${LOADTEST_NAMESPACE:-$NAMESPACE_DEFAULT}"
HOST="${4:-$HOST_DEFAULT}"
THINK_TIME_SEC="${LOADTEST_THINK_TIME_SEC:-3}"
BUFFER="${LOADTEST_BUFFER:-1.3}"
PARTICIPANTS_PER_ROOM="${LOADTEST_PARTICIPANTS_PER_ROOM:-4}"
DEADLINE_BUFFER_SEC="${LOADTEST_DEADLINE_BUFFER_SEC:-3600}"
SPAWN_RATE="${LOADTEST_SPAWN_RATE:-10}"
SEED_WAIT_TIMEOUT="${LOADTEST_SEED_TIMEOUT:-900s}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_CSV="$DIR/pool.csv"

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

echo
echo "== 2/3 준비 완료 =="
echo "  대상 호스트     : $HOST"
echo "  동시 사용자     : $USERS"
echo "  지속 시간       : ${DURATION_SEC}s"
echo "  준비된 업로드 슬롯: $POOL_SIZE (1회용 room/round/participant 조합)"
echo "  주의: DB에 실제 room/round/participant/user 행이 생성된 상태입니다."
echo "        테스트 후 loadtest/cleanup_${TARGET}.sh 로 정리하세요 (README 참고)"
echo "        (deadline 버퍼 ${DEADLINE_BUFFER_SEC}s 안에 정리 권장 — 그 이후엔"
echo "         백엔드 스케줄러가 이 라운드들을 정상 라운드처럼 처리하려 시도합니다)."
echo
read -r -p "부하 테스트를 시작할까요? (진행하려면 정확히 'yes' 입력): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "취소했습니다. 시드 데이터는 DB에 남아 있습니다 — 필요 없으면 loadtest/cleanup.sql로 지우세요."
  exit 0
fi

echo
echo "== 3/3 부하 테스트 시작 =="
mkdir -p "$DIR/results"
RESULT_PREFIX="$DIR/results/$(date +%Y%m%d-%H%M%S)"

LOADTEST_POOL_CSV="$POOL_CSV" locust -f "$DIR/locustfile.py" \
  --host "$HOST" \
  --users "$USERS" \
  --spawn-rate "$SPAWN_RATE" \
  --run-time "${DURATION_SEC}s" \
  --headless \
  --csv "$RESULT_PREFIX"

echo
echo "완료. 결과: ${RESULT_PREFIX}_stats.csv"
echo "DB 정리 잊지 마세요: loadtest/cleanup.sql"
