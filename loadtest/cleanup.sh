#!/usr/bin/env bash
# 부하 테스트 시드 데이터 정리. local/prod 인자와 kubeconfig 고정 방식은
# run.sh·monitor.sh와 동일하다.
#
# 사용법: loadtest/cleanup.sh [local|prod]
#   예: loadtest/cleanup.sh          # 로컬(기본)
#       loadtest/cleanup.sh prod     # 운영
set -euo pipefail

TARGET="${1:-local}"

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

"${KCTL[@]}" exec -i postgres-0 -n "$NAMESPACE" -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < "$DIR/cleanup.sql"
