#!/usr/bin/env bash
# 운영(EC2)의 부하 테스트 시드 데이터 정리. --context를 못박아서 KUBECONFIG이
# 나중에 다른 클러스터를 가리키게 바뀌어도 항상 이 kubeconfig/context로 간다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl --kubeconfig /Users/asecdycom/project/p1/workspace/k3s_prod.yaml --context default \
  exec -i postgres-0 -n emoselfie -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < "$DIR/cleanup.sql"
