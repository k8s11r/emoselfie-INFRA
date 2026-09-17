# 업로드 엔드포인트 부하 테스트

`/api/rooms/{slug}/rounds/{round_id}/submissions` 를 직접 때려서 backend(추론)/
postgres/redis의 실사용량을 재고, `k8s/base/*.yaml`의 resources(requests/limits)를
정하기 위한 도구다. Socket.IO/방 참가 같은 실제 게임 흐름은 흉내내지 않는다 —
그 판단 이유는 대화 맥락 참고.

## 왜 이렇게 생겼나

업로드 엔드포인트는 단순 반복 요청을 받아주지 않는다(`emoselfie-BE`
`app/api/submissions.py`, `app/domain/round/service.py`):

- 실제 DB의 `Room`(status=`playing`)과 그 방의 `current_round_id`가 일치해야 함
- `x-capture-token` 헤더가 `HMAC(secret, "{round_id}:{participant_id}:{deadline_ms}")`
  와 일치해야 함 — **1회용**(Redis `SET NX`)
- 참가자당 라운드당 업로드 5회 제한

그래서 `seed.py`가 요청 예상 총량만큼 **1회용 (room, round, participant) 조합**을
DB에 미리 만들어 두고, `locustfile.py`가 요청마다 하나씩 소비한다.

**방 하나에 참가자를 몇 명 둘지(`LOADTEST_PARTICIPANTS_PER_ROOM`, 기본 4)가 중요하다.**
1명만 두면 매 제출이 "이 방의 마지막 제출"이 되어, 정상 게임에선 라운드당 딱 한 번만
도는 무거운 마무리 경로(`app/domain/round/runner.py`의 `close_submissions`+`finalize`
— DB 세션 5개, row lock 2번)가 **요청마다** 실행돼 실측치가 왜곡된다. 여러 명을 두면
방마다 마지막 1건에만 그 경로가 걸려 실제 트래픽 패턴에 가까워진다.

## 전제: PARTICIPANT_GRACE_SEC

이 도구가 만드는 참가자는 Socket.IO에 붙지 않는다. 백엔드는 소켓 연결이 없는
참가자를 `participant_grace_sec`(기본 60초, `app/core/config.py`) 뒤에
`status=left`로 치우고 방을 `finished`로 닫는다(`app/domain/round/runner.py`).
60초를 넘겨 도착하는 요청은 전부 `403 NOT_A_PARTICIPANT`로 막힌다 — 실측: 100명·
90초 테스트에서 시간이 지날수록 실패율이 0%→6%로 계속 올라가는 패턴으로 확인.

그래서 대상 클러스터의 `backend-env`에 `PARTICIPANT_GRACE_SEC`을 크게 잡아야
지속 시간이 긴 테스트가 통과한다. 로컬은 이미 반영돼 있다
(`k8s/overlays/local/kustomization.yaml`). **운영(EC2)에는 아직 없다** — 붙이려면
`k8s/overlays/prod/kustomization.yaml`의 `backend-env`에 똑같이 추가하고
`kubectl apply -k k8s/overlays/prod`로 backend를 재시작해야 한다(실제 플레이의
이탈 판정을 늦추는 값이므로 운영에 상시 반영하지 말고, 부하 테스트 창구에서만
켰다 끄는 걸 권장 — 값을 지우고 다시 apply하면 기본 60초로 돌아간다).

## 실행

locust를 따로 설치할 필요 없다. `run.sh`가 PATH에서 못 찾으면 저장소 밖
전용 가상환경(`~/.venvs/emoselfie-loadtest`, 레포에 venv 금지라 밖에 둔다)에
알아서 설치하고 그걸 쓴다 — 필요한 건 `python3`뿐이다.

```bash
loadtest/run.sh 100 300              # 로컬(k3d), namespace=local, http://localhost
loadtest/run.sh 100 300 prod         # 운영(EC2), namespace=emoselfie, https://emoselfie.click/
```

인자: `<동시 사용자 수> <지속 시간(초)> [local|prod] [대상 호스트]` — 3번째 인자가
`local`(기본)이냐 `prod`냐로 네임스페이스·host 기본값에 더해 **어느 클러스터에
붙을지까지** 같이 정해진다:

- `local`: k3d의 고정 위치·컨텍스트(`~/.kube/config`, `k3d-mycluster`)로 항상
  붙는다 — 지금 쉘의 `KUBECONFIG`가 뭘 가리키든 무시하고 로컬로 간다
- `prod`: `LOADTEST_PROD_KUBECONFIG`/`LOADTEST_PROD_CONTEXT` 환경변수가 있으면
  그걸 쓰고, 없으면 지금 쉘에 이미 설정된 `KUBECONFIG`/컨텍스트를 그대로 쓴다

```bash
LOADTEST_PROD_KUBECONFIG=~/k3s_prod.yaml LOADTEST_PROD_CONTEXT=default \
  loadtest/run.sh 100 300 prod https://other.example.com   # host만 override
```

host를 따로 주면(4번째 인자) 그 값이 우선한다. 내부적으로:

1. **시딩** — `seed.py`를 k8s Job으로 클러스터 안에서 실행(`emoselfie-backend`
   이미지 재사용, DB만 씀). 결과 CSV를 `kubectl logs`로 받아 `pool.csv`에 저장.
2. **확인** — 준비된 슬롯 수를 보여주고 `yes`를 정확히 입력해야 다음 단계로 감.
   `yes`가 아니면 여기서 멈춘다(시드 데이터는 DB에 남음).
3. **부하** — 로컬 머신에서 locust가 공인 도메인(ALB 경유)으로 직접 요청.
   클러스터 안에 부하 생성기를 넣지 않는 이유는 이전 대화에서 정리한 대로,
   같은 노드 CPU를 나눠 쓰면 측정치가 왜곡되기 때문.

## 측정

k9s로 직접 눈으로 보는 것도 되지만, 나중에 locust 결과와 시간 맞춰 비교하려면
`monitor.sh`로 CSV에 기록해두는 게 낫다 — `run.sh`와 별개 터미널에서 같이 띄운다:

```bash
loadtest/monitor.sh local           # Ctrl+C로 멈출 때까지, 5초 간격
loadtest/monitor.sh prod 5 300      # 운영, 5초 간격, 300초 후 자동 종료
```

`local`/`prod` 인자는 `run.sh`와 동일하게 kubeconfig/컨텍스트를 함께 고정한다.
결과는 `loadtest/results/<타임스탬프>_monitor.csv`에 `timestamp,pod,cpu,memory`
형태로 쌓이고, `run.sh`가 남기는 `<타임스탬프>_stats_history.csv`와 시각 기준으로
맞춰볼 수 있다(둘 다 UTC).

(`metrics-server`가 클러스터에 있어야 함. 없으면 `kubectl describe node`의
Allocated resources나 별도 모니터링으로 대체.)

## 정리 (중요)

시딩은 **실제 postgres에 행을 씁니다** (room/round/participant/user, 테스트당
수천~수만 건). 테스트가 끝나면:

```bash
loadtest/cleanup.sh          # 로컬(기본)
loadtest/cleanup.sh prod     # 운영
```

`local`/`prod` 인자와 kubeconfig 고정 방식은 `run.sh`와 동일하다. `cleanup.sh`는
`cleanup.sql`을 postgres pod에 흘려보내는 얇은 래퍼일 뿐이다. 다른
네임스페이스/클러스터면 직접
`kubectl exec -i postgres-0 -n <namespace> -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < loadtest/cleanup.sql`.

**반복 테스트 중이면 `clean_run.sh`로 정리+실행을 한 번에** 할 수 있다 —
인자는 `run.sh`와 완전히 동일하게 그대로 전달된다:

```bash
loadtest/clean_run.sh 100 300 prod
```

**deadline 버퍼(기본 1시간) 안에 정리할 것.** 이 시딩은 `round_count=3`인데
라운드를 1개만 만들어 둔다 — deadline이 지나면 백엔드 스케줄러가 이 라운드를
정상 라운드처럼 finalize하려 시도하는데, 다음 라운드(index 2)가 없어서 그
이후 동작은 **확인하지 못했다**. 버퍼 안에 지우면 스케줄러가 이 행들을 볼
일이 없으므로 이 위험 자체가 발생하지 않는다.

## 설정 바꾸기

사용자 수/지속 시간/local·prod는 `run.sh`의 처음 세 인자로 바로 바뀐다. 그 외
(참가자/방, think time, 버퍼, deadline 여유, spawn rate)는 환경변수로:

```bash
LOADTEST_PARTICIPANTS_PER_ROOM=6 LOADTEST_THINK_TIME_SEC=2 LOADTEST_SPAWN_RATE=20 \
  loadtest/run.sh 300 600 prod
```

네임스페이스는 `local`/`prod` 인자로 정해진 기본값(각각 `local`, `emoselfie`)을
쓰지만, `LOADTEST_NAMESPACE` 환경변수를 따로 주면 그게 우선한다(기본값 둘 다
아닌 제3의 네임스페이스가 필요할 때). run.sh는 그 네임스페이스에 이미 떠 있는
`backend` Deployment에서 이미지 태그와 ConfigMap/Secret의 실제 이름(kustomize
해시 접미사 포함)을 그대로 읽어와 시딩 Job에 쓴다 — 직접 값을 맞출 필요 없다.

## 파일

- `seed.py` — DB 시딩 스크립트 (k8s Job에서 실행, stdlib hmac + asyncpg만 씀)
- `locustfile.py` — 부하 시나리오 (로컬에서 `locust` 커맨드로 실행됨, run.sh가 호출)
- `monitor.sh` — pod별 CPU/메모리를 CSV에 기록 (run.sh가 기본으로 백그라운드 실행)
- `cleanup.sql`, `cleanup.sh` — 시드 데이터 삭제
- `clean_run.sh` — `cleanup.sh` 후 `run.sh`를 이어서 실행하는 래퍼
- `assets/sample_face.jpg` — 업로드용 실제 얼굴 사진(matplotlib 샘플 데이터,
  512x600). "no_face" 조기 종료가 아니라 실제 얼굴 검출+감정 추론 전체
  파이프라인을 태우기 위해 빈 이미지 대신 이걸 씀.
