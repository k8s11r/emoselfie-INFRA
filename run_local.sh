#!/usr/bin/env bash
#
# 로컬 k3d에 전체 스택을 올린다.
#
#   ./run_local.sh
#
# 클러스터가 없으면 만들고, 이미지가 바뀐 것만 k3d에 넣고, 배포한다.
# 이미지 빌드는 하지 않는다 (오래 걸리고 어느 저장소를 쓸지는 사람이 정한다).
set -euo pipefail

CLUSTER=mycluster
NS=local
MODELS_DIR="$HOME/.emoselfie-models"
OVERLAY="$(cd "$(dirname "$0")" && pwd)/k8s/overlays/local"
IMAGES="emoselfie-backend:local emoselfie-models:local emoselfie-web:local"

# ─────────────────────────────── 1. 클러스터 ───────────────────────────────
if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  echo "[1/4] 클러스터 $CLUSTER 이미 있음"
else
  echo "[1/4] 클러스터 $CLUSTER 생성"
  # --volume 은 생성 시점 옵션이라 나중에 못 붙인다. 세 노드가 맥의 같은
  # 디렉터리를 물어야 models PVC가 ReadWriteMany로 성립한다.
  # --servers-memory 4g 는 노드를 t3.medium과 같게 맞춰 EC2 스케줄을 미리 검증한다.
  mkdir -p "$MODELS_DIR"
  k3d cluster create "$CLUSTER" --servers 3 \
    --servers-memory 4g \
    --volume "$MODELS_DIR:/models@all" \
    -p "80:80@loadbalancer" -p "443:443@loadbalancer"
fi

# ─────────────────────────────── 2. 이미지 확인 ───────────────────────────────
missing=""
for img in $IMAGES; do
  docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
done

if [ -n "$missing" ]; then
  echo
  echo "다음 이미지가 로컬에 없다:$missing"
  echo
  echo "  docker build -t emoselfie-backend:local ../emoselfie-BE"
  echo "  docker build --target models -t emoselfie-models:local ../emoselfie-BE"
  echo "  docker build -t emoselfie-web:local ../emoselfie-FE"
  echo
  exit 1
fi
echo "[2/4] 이미지 3개 확인"

# ─────────────────────────────── 3. 이미지 반영 ───────────────────────────────
# 이미지 config의 created 타임스탬프를 비교한다. docker의 image ID는 save/import
# 왕복에서 바뀌어 쓸 수 없지만, created는 config의 일부라 그대로 보존된다.
# 나노초 단위라 재빌드하면 반드시 달라진다.
NODE="k3d-${CLUSTER}-server-0"
to_import=""
for img in $IMAGES; do
  here=$(docker image inspect "$img" --format '{{.Created}}')
  there=$(docker exec "$NODE" crictl inspecti --output go-template \
            --template '{{.info.imageSpec.created}}' "docker.io/library/$img" 2>/dev/null || true)
  if [ "$here" = "$there" ]; then
    echo "       $img 최신 (건너뜀)"
  else
    to_import="$to_import $img"
  fi
done

if [ -n "$to_import" ]; then
  echo "[3/4] k3d에 넣기:$to_import"
  # shellcheck disable=SC2086
  k3d image import $to_import -c "$CLUSTER"
else
  echo "[3/4] 반영할 이미지 없음"
fi

# ─────────────────────────────── 4. 배포 ───────────────────────────────
echo "[4/4] 배포"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# Job은 완료 후 spec이 immutable이라 재적용 전에 지워야 한다.
kubectl delete job migrate -n "$NS" --ignore-not-found
kubectl apply -k "$OVERLAY"

echo
echo "완료. 진행 상황:  kubectl get pods -n $NS -w"
echo "접속:            http://localhost"
