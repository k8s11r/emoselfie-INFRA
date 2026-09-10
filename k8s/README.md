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
# 0. 모델 가중치 준비 (최초 1회, 94MB)
cd ../emoselfie-BE && uv run python scripts/prepare_models.py && cd -

# 1. 이미지 빌드 (arm64 네이티브)
docker build -t emoselfie-backend:local ../emoselfie-BE
docker build -f k8s/models.Dockerfile -t emoselfie-backend:arm64 ../emoselfie-BE
docker build -t emoselfie-web:local ../emoselfie-FE

# 2. k3d에 올리기 (이미지가 4GB대라 몇 분 걸린다)
k3d image import emoselfie-backend:arm64 emoselfie-web:local -c mycluster

# 3. 배포
kubectl create namespace local --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job migrate -n local --ignore-not-found   # Job은 재적용 전에 삭제
kubectl apply -k k8s/overlays/local
```

k3d serverlb가 호스트 80을 잡고 있어 <http://localhost> 로 바로 닿는다.

`k3d image import`가 느린 게 반복 개발에 걸리면 k3d 레지스트리를 붙이는 편이
낫다 (`k3d registry create`).

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

**Sentinel failover를 앱이 따라가지 못한다.** `python-socketio`의
`AsyncRedisManager`가 sentinel 프로토콜을 모른다 (`app/realtime/server.py:75`).
`REDIS_URL`이 부트스트랩 master인 `redis-0`을 직접 가리키므로, failover가
일어나면 Sentinel은 새 master를 승격시키지만 backend는 옛 master(이제 replica)에
계속 붙어 쓰기가 실패한다. backend를 재시작해야 복구된다.

제대로 풀려면 sentinel을 아는 클라이언트를 쓰거나, master pod에 라벨을 붙여
추적하는 Service가 필요하다.

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
