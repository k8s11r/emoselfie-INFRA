#!/usr/bin/env bash
# 3노드 k3d에 https-check 오버레이를 올리고 운영 조건(HTTPS·Secure 쿠키) 스모크를 돌린다.
# k8s/README.md "운영 조건 로컬 검증" 절을 그대로 스크립트로 옮긴 것이다.
#
#   scripts/https-check.sh all     up + test + down (실패해도 down)
#   scripts/https-check.sh up      클러스터·Traefik 설정·edge·배포
#   scripts/https-check.sh test    반영 확인·쿠키·정적 서빙·통합 스모크·backend 장애 분리
#   scripts/https-check.sh status  켜져 있는지, Pod 상태
#   scripts/https-check.sh down    전부 삭제 (venv는 남긴다)
#
# 전제: emoselfie-backend:local, emoselfie-models:local, emoselfie-web:local 이미지가 있고
#       $MODELS_DIR 에 모델 가중치와 fig1.jpg(prepare_models.py --with-example)가 있다.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLUSTER=emoselfie-https-check
NS=https-check
URL=https://localhost:8446
MODELS_DIR=${MODELS_DIR:-$HOME/.emoselfie-models}
WORK=$ROOT/.https-check          # 인증서·venv. .gitignore 대상
CA=$WORK/certs/tls.crt

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

up() {
  for img in emoselfie-backend:local emoselfie-models:local emoselfie-web:local; do
    docker image inspect "$img" >/dev/null 2>&1 || { echo "이미지 없음: $img"; exit 1; }
  done
  [ -f "$MODELS_DIR/fig1.jpg" ] || { echo "$MODELS_DIR/fig1.jpg 없음. be/에서 uv run python scripts/prepare_models.py --directory $MODELS_DIR --with-example"; exit 1; }

  log "1/5 클러스터 (serverlb:80 을 열려면 @loadbalancer 매핑이 필수)"
  k3d cluster create "$CLUSTER" --servers 3 --servers-memory 4g \
    --volume "$MODELS_DIR:/models@all" -p "8080:80@loadbalancer"

  log "2/5 Traefik trustedIPs (helm-install Job 재실행 대기)"
  kubectl apply -f "$ROOT/k8s/overlays/https-check/traefik-config.yaml"
  for _ in $(seq 24); do
    kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
      | grep -q trustedIPs && break
    sleep 5
  done
  kubectl -n kube-system rollout status deploy/traefik --timeout=120s
  kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].args}' \
    | tr ',' '\n' | grep trustedIPs || { echo "trustedIPs 미반영"; exit 1; }

  log "3/5 자체 서명 인증서 + edge (ALB 역할)"
  mkdir -p "$WORK/certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" -keyout "$WORK/certs/tls.key" -out "$CA" 2>/dev/null
  docker run -d --name edge --network "k3d-$CLUSTER" -p 8446:443 \
    -v "$ROOT/k8s/overlays/https-check/edge.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$WORK/certs:/certs:ro" nginx:alpine >/dev/null

  log "4/5 이미지 import + 배포"
  docker tag emoselfie-backend:local emoselfie-backend:https-check
  k3d image import emoselfie-backend:https-check emoselfie-models:local emoselfie-web:local -c "$CLUSTER"
  kubectl apply -k "$ROOT/k8s/overlays/https-check"
  kubectl -n "$NS" wait --for=condition=ready pod -l app=backend --timeout=300s

  log "5/5 배포 상태"
  kubectl -n "$NS" get pods -o wide
}

test_() {
  local c="curl -s --cacert $CA"
  log "반영 확인"
  printf 'sticky secure: '; kubectl -n "$NS" get svc backend -o jsonpath='{.metadata.annotations.traefik\.ingress\.kubernetes\.io/service\.sticky\.cookie\.secure}'; echo
  printf 'web QoS:       '; kubectl -n "$NS" get pods -l app=web -o jsonpath='{range .items[*]}{.status.qosClass} {end}'; echo

  log "쿠키 (둘 다 Secure 여야 함)"
  $c -D - -o /dev/null "$URL/api/me" -H "Origin: $URL" | grep -i set-cookie

  log "SPA / fallback / web 자체 health"
  $c -o /dev/null -w "/ %{http_code}, " "$URL/"
  $c -o /dev/null -w "/r/abc %{http_code}, " "$URL/r/abc"
  kubectl -n "$NS" exec ds/web -- curl -s localhost/health/live

  log "통합 스모크 (2인 · WebSocket+polling · 3라운드 실제 추론)"
  [ -x "$WORK/venv/bin/python" ] || { uv venv -q "$WORK/venv"; VIRTUAL_ENV=$WORK/venv uv pip install -q aiohttp httpx "python-socketio[asyncio_client]"; }
  "$WORK/venv/bin/python" "$ROOT/tests/smoke_https.py" --url "$URL" --ca "$CA" --image "$MODELS_DIR/fig1.jpg"

  log "backend 0개 → web 은 살아야 함"
  kubectl -n "$NS" scale deploy/backend --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app=backend --timeout=60s >/dev/null 2>&1 || true
  printf 'web ready='; kubectl -n "$NS" get ds web -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}'
  $c -o /dev/null -w ", / %{http_code}, " "$URL/"
  $c -o /dev/null -w "/api/me %{http_code}\n" "$URL/api/me"
  kubectl -n "$NS" scale deploy/backend --replicas=3 >/dev/null
}

status() {
  if ! k3d cluster list 2>/dev/null | grep -q "^$CLUSTER "; then echo "꺼져 있음"; return; fi
  echo "클러스터: $CLUSTER  edge: $(docker inspect -f '{{.State.Status}}' edge 2>/dev/null || echo 없음)  URL: $URL"
  kubectl -n "$NS" get pods -o wide 2>/dev/null
}

down() {
  docker rm -f edge >/dev/null 2>&1 || true
  k3d cluster delete "$CLUSTER" 2>/dev/null || true
  docker rmi emoselfie-backend:https-check >/dev/null 2>&1 || true
  rm -rf "$WORK/certs"
  echo "정리 완료. context: $(kubectl config current-context 2>/dev/null || echo none)"
}

case "${1:-}" in
  up) up ;;
  test) test_ ;;
  status) status ;;
  down) down ;;
  all) trap down EXIT; up; test_ ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
