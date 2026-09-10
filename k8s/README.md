# k8s 매니페스트

로컬 k3d와 EC2 k3s에 같은 매니페스트를 올린다. 차이는 오버레이로만 표현한다.

```
k8s/
├── base/                 # 환경 공통
└── overlays/
    ├── local/            # k3d (arm64 네이티브, 추론 real)
    └── prod/             # EC2 k3s (amd64, 추론 real)
```

## 로컬 (k3d)

로컬은 arm64 네이티브다. mediapipe 1.0.1과 torch 2.8.0 모두 `manylinux_2_28_aarch64`
휠을 배포하고 `emoselfie-BE/pyproject.toml`이 이미 플랫폼별로 분기하므로,
**추론을 그대로 쓴다.** 에뮬레이션이 없어 빠르다.

```toml
inference = [
  "torch==2.8.0",
  "mediapipe==0.10.35; platform_machine != 'aarch64' or sys_platform == 'darwin'",
  "mediapipe==1.0.1; platform_machine == 'aarch64' and sys_platform != 'darwin'",
]
```

`emoselfie-BE/Dockerfile` 상단 주석은 "MediaPipe가 linux/aarch64 휠을 배포하지
않는다"고 하는데, mediapipe 0.10.x 기준이라 지금은 맞지 않는다.

```bash
# 1. 이미지 빌드 (arm64 네이티브)
docker build -t emoselfie-backend:arm64 ../emoselfie-BE
docker build --target models -t emoselfie-models:local ../emoselfie-BE
docker build -t emoselfie-web:local ../emoselfie-FE

# 2. k3d에 올리기
k3d image import emoselfie-backend:arm64 emoselfie-models:local emoselfie-web:local -c mycluster

# 3. 배포
kubectl create namespace local --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job migrate -n local --ignore-not-found   # Job은 재적용 전에 삭제
kubectl apply -k k8s/overlays/local
```

k3d serverlb가 호스트 80을 잡고 있어 <http://localhost> 로 바로 닿는다.

`k3d image import`가 느린 게 반복 개발에 걸리면 k3d 레지스트리를 붙이는 편이
낫다 (`k3d registry create`).

## 모델 가중치

94MB라 이미지에 들어 있지 않다. BE Dockerfile의 `models` 스테이지가 이 용도로
만들어져 있고(`ENTRYPOINT prepare_models.py`, `CMD --directory /models`),
backend pod의 initContainer로 그대로 쓴다. 운영 이미지에 다운로드 클라이언트를
넣지 않기 위한 분리다(BE 가이드라인 §28). 스크립트는 멱등하고 sha256을 검증한다.

`emptyDir`이라 pod가 새로 뜰 때마다 다시 받는다. 노드마다 파일을 수동으로 뿌리지
않아도 되는 대신 기동이 느려지는 교환이다.

`prepare_models.py`는 `--directory` 아래 **평평하게** 파일을 놓는다. compose는
파일 단위 bind mount라 `/models/emotion/v1/...` 중첩 경로를 쓰지만 여기서는
맞지 않으므로 `backend-env`가 평평한 경로를 가리킨다.

## 운영 (EC2 k3s)

EC2가 amd64라 거기서 빌드한다. 모델 가중치 94MB는 이미지에 굽는다 — 3노드에
파일을 수동으로 뿌리고 동기화하는 것보다 안전하다.

Secret은 저장소에 두지 않는다. 배포 전에 클러스터에 직접 만든다.

```bash
kubectl create secret generic emoselfie-secrets -n emoselfie \
  --from-literal=POSTGRES_USER=... \
  --from-literal=POSTGRES_PASSWORD=... \
  --from-literal=POSTGRES_DB=... \
  --from-literal=DATABASE_URL=postgresql+asyncpg://... \
  --from-literal=COOKIE_SECRET=... \
  --from-literal=CAPTURE_TOKEN_SECRET=... \
  --from-literal=MEDIA_TOKEN_SECRET=...

kubectl apply -k k8s/overlays/prod
```

## 알려진 한계

**Sentinel failover를 앱이 따라가지 못한다.** 라이브러리가 아니라 설정 계층이
막고 있다.

`python-socketio`의 `AsyncRedisManager`는 Sentinel을 지원한다.
`socketio/async_redis_manager.py:110`에 `redis+sentinel://` 분기가 있고,
`Sentinel(...).master_for(service_name)`으로 마스터를 물어보는 클라이언트를 만든다.
재연결 시에도 다시 물어본다.

그런데 `app/realtime/server.py:75`가 평범한 URL을 넘겨서 `Redis.from_url()`
가지로 빠진다. 이 커넥션은 특정 주소에 고정되므로 failover 후 강등된 replica에
계속 붙어 `READONLY You can't write against a read only replica.` 로 실패하고,
재연결도 같은 주소로 붙어 복구되지 않는다.

`app/core/resources.py:30,35`의 일반 Redis 클라이언트도 같은 방식이다. 이쪽이
영향이 더 크다 — 방 상태, 라운드, 점수, 분산 락(`lock:room:{roomId}`)을 전부
다루기 때문이다.

바꾸려면 설정 계층부터 풀어야 한다. pydantic `RedisDsn`이 Sentinel URL을
거부한다.

```
redis://redis:6379/0                            -> OK
redis+sentinel://s1:26379,s2:26379/0/mymaster   -> url_parsing 에러
```

`allowed_schemes`가 `redis`/`rediss`뿐이고, 스킴을 열어줘도 쉼표로 나열된 다중
호스트를 파싱하지 못한다. Sentinel은 최소 3대가 필요하니 이 형식을 피할 수 없다.

failover 창에는 pub/sub 특유의 문제도 남는다. Redis pub/sub은 master에서
replica 방향으로만 전파되므로, 일부 pod가 아직 옛 master를 보고 있는 몇 초 동안
한쪽 방향만 메시지가 샌다. pub/sub은 저장되지 않아 그 창에서 놓친 이벤트는
재시도로 복구되지 않는다. 리액션 누락은 넘어갈 만하지만 라운드 마감 브로드캐스트가
일부 pod에만 닿으면 그 pod에 붙은 참가자 화면이 멈춘다. 재연결 시 방/라운드
상태를 다시 받는 경로를 두면 자동 복구된다.

현재 `REDIS_URL`은 부트스트랩 master인 `redis-0`을 직접 가리킨다. failover 후에는
backend 재시작이 필요하다.

**postgres는 단일 인스턴스다.** k3s 기본 스토리지가 local-path라 PVC가 특정
노드에 묶인다. 그 노드가 죽으면 pod가 재스케줄되지 못하고 Pending에 갇힌다.
3노드 구성에서 여기만 단일 장애점으로 남는다. CloudNativePG 오퍼레이터로
교체하면 공유 스토리지 없이 스트리밍 복제 + 자동 failover가 가능하다.

**Job 재적용.** `migrate` Job은 완료 후 spec이 immutable이라 재배포 전에
`kubectl delete job migrate` 가 필요하다.

## HA 확인

```bash
kubectl get nodes                                  # 3대 모두 control-plane
kubectl get pods -o wide -n local                  # 노드별 분산 확인
kubectl drain <node> --ignore-daemonsets           # 노드 하나 빼기
kubectl delete pod redis-0 -n local                # Redis master 강제 종료
kubectl exec -n local redis-sentinel-0 -- redis-cli -p 26379 sentinel master mymaster
```
