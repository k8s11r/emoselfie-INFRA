#!/usr/bin/env python3
"""부하 테스트용 시드 데이터 생성기.

/api/rooms/{slug}/rounds/{round_id}/submissions 는 room(PLAYING) + 그 방의
current_round(OPEN_STATUSES) + participant + 1회용 capture token을 요구한다
(emoselfie-BE app/api/submissions.py, app/domain/round/service.py). 이 제약을
우회하지 않고, 요청 하나당 쓸 수 있는 (room, round, participant) 조합을 미리
DB에 만들어 둔다.

방마다 참가자를 LOADTEST_PARTICIPANTS_PER_ROOM명(기본 4) 심는다. 참가자를
1명만 두면 매 제출이 "이 방의 마지막 제출"이 되어 app/domain/round/runner.py의
close_submissions+finalize(정상 게임에선 라운드당 1번만 도는 무거운 경로 —
DB 세션 5개, row lock 2번)가 요청마다 실행돼 버린다. 여러 명을 두면 방마다
마지막 1건에만 그 경로가 걸려 실제 게임 트래픽 패턴에 가까워진다.

서명 로직(capture_token/sign_cookie)은 app/core/security.py와 반드시 동일해야
하므로 그 파일을 그대로 옮겨왔다. HMAC-SHA256, stdlib만 쓴다.

실행: k8s Job (emoselfie-backend 이미지 재사용 — asyncpg가 이미 있고 torch는
불러오지 않는다). k8s/base의 backend-env ConfigMap + emoselfie-secrets Secret을
그대로 envFrom으로 받는다.

출력: stdout에 CSV 한 줄씩(slug,round_id,participant_id,cookie,token).
진행 로그는 stderr에 '# ' 접두사로 남긴다 — kubectl logs로 받은 뒤
`grep -v '^# '` 하면 순수 CSV만 남는다.
"""

import asyncio
import base64
import hmac
import os
import random
import string
import sys
import uuid
from datetime import UTC, datetime, timedelta

import asyncpg

EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


def env_int(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


USERS = env_int("LOADTEST_USERS", 100)
DURATION_SEC = env_int("LOADTEST_DURATION_SEC", 300)
THINK_TIME_SEC = env_int("LOADTEST_THINK_TIME_SEC", 3)
BUFFER = float(os.environ.get("LOADTEST_BUFFER", "1.3"))
DEADLINE_BUFFER_SEC = env_int("LOADTEST_DEADLINE_BUFFER_SEC", 3600)
PARTICIPANTS_PER_ROOM = env_int("LOADTEST_PARTICIPANTS_PER_ROOM", 4)

# 캡처 토큰은 1회용이라 사용자당 요청 수만큼 (round, participant) 쌍이 필요하다.
REQUESTS_PER_USER = max(1, int((DURATION_SEC / THINK_TIME_SEC) * BUFFER) + 3)
TOTAL = USERS * REQUESTS_PER_USER


def sign_cookie(user_id: uuid.UUID, secret: str) -> str:
    """app/core/security.py:sign_cookie 와 동일해야 함."""
    signature = hmac.digest(secret.encode(), str(user_id).encode(), "sha256")[:16]
    encoded = base64.urlsafe_b64encode(signature).rstrip(b"=").decode("ascii")
    return f"{user_id}.{encoded}"


def capture_token(round_id: int, participant_id: int, deadline_at_ms: int, secret: str) -> str:
    """app/core/security.py:capture_token 과 동일해야 함."""
    payload = f"{round_id}:{participant_id}:{deadline_at_ms}"
    digest = hmac.digest(secret.encode(), payload.encode(), "sha256")
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")[:32]


def new_slug() -> str:
    suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=16))
    return f"loadtest-{suffix}"


def log(message: str) -> None:
    print(f"# {message}", file=sys.stderr, flush=True)


async def main() -> None:
    database_url = os.environ["DATABASE_URL"].replace("postgresql+asyncpg://", "postgresql://")
    cookie_secret = os.environ["COOKIE_SECRET"]
    capture_secret = os.environ["CAPTURE_TOKEN_SECRET"]

    log(
        f"users={USERS} duration={DURATION_SEC}s think_time={THINK_TIME_SEC}s "
        f"requests/user={REQUESTS_PER_USER} total_slots={TOTAL} "
        f"participants_per_room={PARTICIPANTS_PER_ROOM}"
    )

    # to_epoch_ms(app/core/clock.py)는 마이크로초를 밀리초로 내림한다. 나중에
    # round.deadline_at을 다시 읽어 서명을 검증할 때 여기서 만든 deadline_ms와
    # 정확히 같아야 하므로, ms 경계에 맞춘 datetime을 거꾸로 만들어 끼운다.
    now = datetime.now(UTC)
    deadline_ms = int((now + timedelta(seconds=DURATION_SEC + DEADLINE_BUFFER_SEC)).timestamp() * 1000)
    deadline = EPOCH + timedelta(milliseconds=deadline_ms)

    conn = await asyncpg.connect(database_url)
    try:
        print("slug,round_id,participant_id,cookie,token")
        rows_written = 0
        while rows_written < TOTAL:
            room_size = min(PARTICIPANTS_PER_ROOM, TOTAL - rows_written)

            host_user_id = uuid.uuid4()
            await conn.execute(
                "INSERT INTO users (uuid, nickname) VALUES ($1, $2)", host_user_id, "lt"
            )

            room_slug = new_slug()
            room_id = await conn.fetchval(
                """INSERT INTO rooms (invite_slug, host_user_id, status, round_count)
                   VALUES ($1, $2, 'playing', 3) RETURNING id""",
                room_slug,
                host_user_id,
            )

            round_id = await conn.fetchval(
                """INSERT INTO rounds (room_id, "index", target_emotion, status, revealed_at, deadline_at)
                   VALUES ($1, 1, 'happy', 'capturing', $2, $3) RETURNING id""",
                room_id,
                now,
                deadline,
            )
            await conn.execute(
                "UPDATE rooms SET current_round_id = $1 WHERE id = $2", round_id, room_id
            )

            for color_tag in range(room_size):
                # 방의 첫 참가자는 host를 그대로 쓴다 — 별도 유저 만들 이유가 없다.
                user_id = host_user_id if color_tag == 0 else uuid.uuid4()
                if color_tag != 0:
                    await conn.execute(
                        "INSERT INTO users (uuid, nickname) VALUES ($1, $2)", user_id, "lt"
                    )

                participant_id = await conn.fetchval(
                    """INSERT INTO participants (room_id, user_id, nickname, color_tag)
                       VALUES ($1, $2, 'lt', $3) RETURNING id""",
                    room_id,
                    user_id,
                    color_tag % 12,
                )

                cookie = sign_cookie(user_id, cookie_secret)
                token = capture_token(round_id, participant_id, deadline_ms, capture_secret)
                print(f"{room_slug},{round_id},{participant_id},{cookie},{token}")

            rows_written += room_size
            if rows_written % 500 < room_size:
                log(f"{rows_written}/{TOTAL} 완료")
    finally:
        await conn.close()

    log(f"완료. deadline={deadline.isoformat()} — 이 시각 이후엔 스케줄러가 라운드를 건드리기 시작하니 "
        f"그 전에 loadtest/cleanup.sql 로 정리할 것.")


if __name__ == "__main__":
    asyncio.run(main())
