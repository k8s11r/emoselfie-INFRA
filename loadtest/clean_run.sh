#!/usr/bin/env bash
# cleanup.sh로 이전 시드 잔여물을 지운 뒤 run.sh를 그대로 이어서 돌린다.
# 인자는 run.sh와 완전히 동일하게 그대로 전달한다 — 클린업 대상(local/prod)은
# run.sh와 같은 3번째 인자를 그대로 같이 쓴다.
#
# 사용법: loadtest/clean_run.sh <users> <duration_sec> [local|prod] [host]
set -euo pipefail

TARGET="${3:-local}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/cleanup.sh" "$TARGET"
exec "$DIR/run.sh" "$@"
