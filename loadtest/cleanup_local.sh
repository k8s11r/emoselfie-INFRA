#!/usr/bin/env bash
# 로컬 k3d의 부하 테스트 시드 데이터 정리. --context를 못박아서 KUBECONFIG이
# 나중에 다른 클러스터를 가리키게 바뀌어도 항상 로컬로 간다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl --kubeconfig ~/.kube/config --context k3d-mycluster \
  exec -i postgres-0 -n local -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < "$DIR/cleanup.sql"
