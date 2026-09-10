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
않으므로 arm64로는 빌드할 수 없다"고 하는데, mediapipe 0.10.x 기준이라 지금은
맞지 않는다. 실제로 arm64 네이티브 빌드가 된다.

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

BE가 Linux에서 torch를 CPU 인덱스로 고정한 뒤(fc7442c) 이미지가 12GB에서
약 2GB로 줄었다. GPU를 쓰지 않는데 CUDA 빌드가 nvidia 패키지 14개(4.1GB)를
끌고 오던 것이 빠졌다. `k3d image import`가 이 크기에서도 반복 개발에 걸리면
k3d 레지스트리를 붙이는 편이 낫다 (`k3d registry create`).

## 모델 가중치

감정 인식 모델(`FER_static_ResNet50_AffectNet.pt`)이 94MB다. 이미지에 넣지 않고
pod가 뜰 때 받아서 공유 볼륨에 놓는다.

### 왜 이미지에 안 넣나

BE 가이드라인 §28이 운영 이미지에 다운로드 클라이언트를 넣지 않도록 한다. 받는
데 쓰는 `httpx`는 dev 의존성이라 런타임 이미지에 아예 없다. 그래서 BE
Dockerfile이 다운로드 전용 스테이지를 따로 만들어 둔다.

```dockerfile
FROM ${PYTHON_IMAGE} AS models
RUN pip install --no-cache-dir httpx==0.28.1
COPY scripts/prepare_models.py ./scripts/prepare_models.py
ENTRYPOINT ["python", "scripts/prepare_models.py"]
CMD ["--directory", "/models"]
```

이 스테이지를 그대로 backend pod의 **initContainer**로 쓴다. initContainer는
본 컨테이너보다 먼저 실행되고 끝나는 컨테이너다. 여기서는 모델을 볼륨에 놓고
종료하며, 그다음 backend 컨테이너가 그 볼륨을 읽기 전용으로 마운트해 시작한다.

### 3노드가 하나를 공유한다

`models` PVC를 `ReadWriteMany`로 잡아 세 노드의 pod가 같은 볼륨을 동시에
붙인다. **최초 1회만 받고 이후 생성되는 pod는 그대로 재사용한다.** 3노드지만
실물은 하나다.

`prepare_models.py`가 이미 이 방식에 맞게 쓰여 있다.

```python
if target.is_file():
    if hashlib.file_digest(source, "sha256").hexdigest() == artifact["sha256"]:
        print(f"Verified {name}")
        continue          # 이미 있고 해시가 맞으면 받지 않는다
...
os.replace(temporary, target)   # 임시 파일에 받고 원자적으로 교체
```

파일이 있으면 sha256만 확인하고 건너뛰므로 두 번째 pod부터는 다운로드가 없다.
받을 때도 임시 파일에 쓴 뒤 `os.replace`로 원자 교체하므로, 여러 pod가 동시에
초기화해도 반쯤 쓰인 파일이 보이는 일이 없다. 최악의 경우 두 pod가 각자 받아
같은 결과를 쓰는 정도다.

`ReadWriteMany`를 지원하는 스토리지가 필요하다. k3s 기본 local-path는 노드
종속이라 안 된다. 로컬과 운영이 다른 방식으로 같은 접근 모드를 만든다.

| | 로컬 k3d | EC2 k3s |
|---|---|---|
| 방식 | 호스트 디렉터리를 세 노드에 마운트 | Longhorn 복제 볼륨 |
| 추가 컴포넌트 | 없음 | Longhorn |
| PV | `models-k3d-hostpath` (정적) | 동적 프로비저닝 |

### 로컬 (k3d)

k3d는 노드가 전부 같은 Docker 호스트의 컨테이너다. 호스트 디렉터리 하나를 세
노드에 모두 물리면 그게 곧 공유 스토리지가 된다. 클러스터 생성 시 지정한다.

```bash
mkdir -p "$HOME/.emoselfie-models"
k3d cluster create mycluster --servers 3 \
  --volume "$HOME/.emoselfie-models:/models@all" \
  -p "80:80@loadbalancer" -p "443:443@loadbalancer"
```

`--volume` 은 생성 시점 옵션이라 기존 클러스터에 추가할 수 없다. 이미 있으면
`k3d cluster delete mycluster` 후 다시 만들어야 한다.

서로 다른 노드의 pod 두 개가 같은 파일을 보는 것으로 확인했다.

```
rwxprobe-...-k42wq   k3d-mycluster-server-2
rwxprobe-...-kvsmh   k3d-mycluster-server-1
→ 두 pod 모두 상대가 쓴 파일을 본다
```

Docker Desktop 메모리가 8.3GB라 backend 3개는 들어가지 않는다(pod당 약 2GB).
local overlay가 2개로 두며, 2개여도 서로 다른 노드에 흩어져 공유 경로는
검증된다.

### 운영 (EC2 k3s)

**Longhorn 설치가 선행돼야 한다.**

```bash
# 각 EC2 노드에서
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# 클러스터에
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml
kubectl -n longhorn-system get pods -w    # 전부 Running 확인
```

Longhorn 자체가 노드당 수백 MB를 쓴다. t3.medium(4GB) 3대에서는 backend가
이미 대부분을 차지하므로, 메모리가 빠듯하면 backend replica를 줄여야 할 수 있다.

k3d에서는 Longhorn을 쓸 수 없다. 노드가 최소 이미지라 `iscsiadm`도 `mount.nfs`도
없고 설치할 패키지 관리자도 없다. 위 호스트 디렉터리 방식을 쓰는 이유다.

### 경로

`prepare_models.py`는 `--directory` 아래에 파일을 **그대로** 놓는다.

```
/models/FER_static_ResNet50_AffectNet.pt
/models/blaze_face_short_range.tflite
```

compose는 파일 하나씩 bind mount라 원하는 경로 아무 데나 놓을 수 있어
`/models/emotion/v1/...` 같은 중첩 경로를 쓴다. k8s는 볼륨 디렉터리를 통째로
마운트하므로 스크립트가 놓는 위치를 그대로 따라야 한다. `backend-env`의
`EMOTION_MODEL_PATH`/`FACE_MODEL_PATH`가 위 평평한 경로를 가리키는 이유다.

## 운영 (EC2 k3s)

EC2가 amd64라 거기서 빌드한다. arm Mac에서 크로스 빌드하면 에뮬레이션이라
느리고 이미지를 푸시/풀 하는 비용도 든다.

Longhorn 설치가 선행돼야 한다 (위 "모델 가중치" 참고).

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
