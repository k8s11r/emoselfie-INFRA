#!/usr/bin/env bash
# cleanup.sh로 이전 시드 잔여물을 지운 뒤 run.sh를 그대로 이어서 돌린다.
# 인자는 run.sh에 그대로 전달한다(플래그 방식) — 그중 --target 값만 뽑아서
# cleanup.sh에도 같이 넘긴다. --target을 안 주면 run.sh와 동일하게 local.
#
# 사용법: loadtest/clean_run.sh --users N --duration SEC [run.sh의 다른 옵션들]
set -euo pipefail

TARGET="local"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--target" ]; then
    TARGET="${args[$((i + 1))]:-local}"
  fi
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/cleanup.sh" "$TARGET"
exec "$DIR/run.sh" "$@"
