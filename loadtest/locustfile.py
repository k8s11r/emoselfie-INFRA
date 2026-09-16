"""업로드 엔드포인트(/api/rooms/{slug}/rounds/{round_id}/submissions) 직격 부하 테스트.

loadtest/seed.py 가 만든 pool.csv (1회용 room/round/participant 조합)를 큐에 올려두고,
가상 사용자마다 한 번 쓰면 버린다 — capture token이 1회용이라 재사용이 안 된다.

실행은 loadtest/run.sh 를 통해서 한다 (시딩 -> 확인 -> 이 파일로 locust 구동).
"""

import csv
import os
import queue
import sys
from pathlib import Path

from locust import HttpUser, between, events, task

HERE = Path(__file__).parent
POOL_CSV = Path(os.environ.get("LOADTEST_POOL_CSV", HERE / "pool.csv"))
IMAGE_BYTES = (HERE / "assets" / "sample_face.jpg").read_bytes()

_pool: "queue.Queue[dict[str, str]]" = queue.Queue()


@events.test_start.add_listener
def _load_pool(environment, **kwargs) -> None:
    with POOL_CSV.open(newline="") as handle:
        for row in csv.DictReader(handle):
            _pool.put(row)
    print(f"[loadtest] {_pool.qsize()}개의 업로드 슬롯 로드 ({POOL_CSV})", file=sys.stderr)


class SubmissionUser(HttpUser):
    wait_time = between(2, 4)

    @task
    def upload(self) -> None:
        try:
            row = _pool.get_nowait()
        except queue.Empty:
            print("[loadtest] 슬롯 소진 — 이 가상 사용자를 멈춘다", file=sys.stderr)
            self.stop(force=True)
            return

        self.client.post(
            f"/api/rooms/{row['slug']}/rounds/{row['round_id']}/submissions",
            headers={
                "Cookie": f"es_uid={row['cookie']}",
                "X-Capture-Token": row["token"],
            },
            files={"image": ("face.jpg", IMAGE_BYTES, "image/jpeg")},
            name="/api/rooms/[slug]/rounds/[id]/submissions",
        )
