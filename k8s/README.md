# k8s 매니페스트

로컬 k3d와 EC2 k3s에 같은 매니페스트를 올린다. 차이는 오버레이로만 표현한다.

## 현재 요청 경로와 전환 순서

표준 Ingress의 Prefix 규칙으로 `/api`, `/media`, `/socket.io`, `/health`는
`backend:8000`에, 나머지는 `web:80`에 전달한다. 경로 접두사는 제거하지 않는다.
`web`은 정적 파일과 SPA fallback만 제공하고 Pod의 `/health/live`에는 직접
`ok`를 반환한다. 외부 `/health/*`는 backend 검사이므로 web의 readiness와 별개다.

```text
브라우저 -> Traefik -> backend  (/api, /media, /socket.io, /health)
                   -> web      (그 밖의 경로, 정적 파일)
```

- BE `SocketGateway`가 Engine.IO 앞에서 `ws/wss` 헤더를 `http/https`로 정규화한다.
  Origin 검사는 끄지 않으며 Host의 포트를 보존한다.
- 로컬 오버레이는 `ALLOW_INSECURE_COOKIE=true`를 명시한다. BE는 개발 환경의
  HTTP 요청에만 Secure를 생략한다. HTTPS 요청과 운영에서는 Secure를 유지한다.
- `es_route`는 Traefik의 Pod 선택 쿠키이며 앱 인증 쿠키 `es_uid`와 다르다.
  FE는 WebSocket 우선이지만 polling 요청도 동일 Pod로 보내도록 설정한다.
  Traefik은 Pod로 직접 분산하며 Service의 `ClientIP` affinity를 사용하지 않는다.
  운영에서는 라우팅 쿠키에도 Secure를 설정하므로 HTTPS가 선행 조건이다.
- Compose는 `compose/web/default.conf`의 기존 nginx 프록시를 유지한다.
  K8s의 정적 서버 설정과 공유하지 않는다.
- 업로드에 Traefik `Buffering` 미들웨어를 붙이지 않는다. 본문 전체를 받은 뒤
  BE에 전달하면 제출 시각 판정이 지연된다. BE의 업로드 한도는 계속 적용되지만
  기존 nginx의 전체 요청 4MB 제한과 완전히 같은 정책은 아니다.

현재 Terraform은 **ALB에서 ACM 인증서로 TLS를 종료하고 노드 80으로 HTTP 전달**한다.
외부 HTTP는 HTTPS로 리다이렉트한다. Traefik의 web entrypoint가 ALB의
`X-Forwarded-Proto: https`를 보존하도록 `ansible/playbooks/traefik.yml`을 먼저 적용한다.
이 playbook은 VPC CIDR과 ServiceLB 중계 시 사용하는 Pod CIDR을 신뢰하도록 설정한다.
실제 피어가 이 범위에 들어가는지 배포 환경에서 확인해야 하며 `insecure: true`로 대체하지 않는다.
BE의 기존 `--forwarded-allow-ips=*`는 유지했다. ClusterIP 자체는 접근 제어가 아니므로
신뢰하지 않은 Pod가 프록시 헤더를 주입하지 못하도록 운영 접근 경계를 확인해야 한다.

### 적용과 복귀

기존 클러스터에 전체 `apply -k`를 한 번에 실행하면 Ingress 반영보다 정적 nginx가
먼저 준비되어 API가 잠시 끊길 수 있다. 기존 migration Job도 이번 라우팅 변경과 분리한다.

1. 변경 전 Ingress, backend Service, web DaemonSet 및 nginx ConfigMap을 보관한다.
2. 보정된 BE 이미지를 새 태그로 먼저 배포하고 readiness를 확인한다. 로컬은
   `ALLOW_INSECURE_COOKIE=true`도 먼저 반영한다. 기존 nginx와도 호환된다.
3. backend Service의 sticky 설정과 Ingress 경로만 적용한다. 기존 nginx 프록시는
   그대로 둔 채 HTTP/HTTPS 세션, Origin 거부, WebSocket과 강제 polling을 확인한다.
4. 통과하면 정적 nginx ConfigMap과 web DaemonSet을 적용한다. `/`, `/r/...`,
   `/assets/...`, web Pod 자체 `/health/live`, 외부 backend health를 각각 확인한다.
5. 복귀 시 기존 nginx ConfigMap·web DaemonSet을 먼저 복원하고 Ready를 기다린 후
   기존 Ingress·backend Service를 복원한다. BE 호환성 보정은 남겨도 된다.

`kubectl kustomize` 결과를 리소스별로 나누어 위 순서로 적용한다. 실행 대상 context와
namespace, BE 새 이미지 태그, HTTPS 종료 위치를 배포 전에 확인한다.

### 전환 전 검증 기록 (2026-09-14)

BE 기본 pytest는 172개 통과했다. 이 중 프록시 호환성 회귀 테스트 21개는
Engine.IO 핸드셰이크, Origin·포트 거부, 쿠키 복원, 개발 옵션 제한과 Uvicorn의
신뢰 프록시 처리를 검사한다. DB·Redis 통합 및 실제 모델 테스트 61개는 기본 게이트로
미실행했다. Ruff lint/format과 mypy도 통과했다.

local/prod Kustomize 조립 및 경로·포트·쿠키 정책·ConfigMap 참조 검사, Compose
구문 검사, 두 nginx 설정의 `nginx -t`가 통과했다. 기존 FE 이미지에 새 설정을
마운트한 격리 컨테이너에서 health, SPA fallback, 실제 JS 번들 및 캐시 헤더를 확인했다.
실제 클러스터 적용, Traefik 경유 다중 Pod polling 및 운영 TLS 검증은 아직 하지 않았다.

```
k8s/
├── base/                 # 환경 공통
└── overlays/
    ├── local/            # k3d (arm64 네이티브, 추론 real)
    └── prod/             # EC2 k3s (amd64, 추론 real)
```

## Kustomize 읽는 법

Kustomize가 처음이면 이것만 알면 아래 내용을 읽을 수 있다.

**`kustomization.yaml` 은 쿠버네티스 객체가 아니다.** 클러스터에 올라가지 않는다.
"이 디렉터리에서 최종 YAML을 어떻게 조립할지" 적은 설명서다. `kubectl apply -k`
가 이 설명서대로 조립한 결과를 apply한다. 그래서 `-f` 로 주면 실패한다.

```bash
kubectl kustomize k8s/overlays/local    # 조립 결과를 출력만 (적용 안 함)
kubectl apply -k k8s/overlays/local     # 조립 + 적용
```

**`resources` 는 조립에 넣을 목록이다.** 여기 없는 파일은 같은 디렉터리에 있어도
무시된다. 파일뿐 아니라 다른 kustomization 디렉터리도 넣을 수 있고, 오버레이가
base를 끌어오는 방식이 그것이다.

```yaml
# overlays/local/kustomization.yaml
resources:
  - ../../base        # base의 조립 결과를 통째로 가져오고
  - models-pv.yaml    # 로컬에만 필요한 것을 더한다
```

**오버레이는 base를 복사하지 않고 차이만 얹는다.** `namespace`(네임스페이스 박기),
`images`(태그 교체), `replicas`(개수 교체), `patches`(임의 필드 수정),
`configMapGenerator`/`secretGenerator`(설정값). 그래서 공통 변경은 base 한 곳만
고치면 양쪽에 반영된다.

**generator가 만든 ConfigMap/Secret은 이름 뒤에 내용 해시가 붙는다.** 이게 중요한
이유는, 같은 이름으로 내용만 바꾸면 pod 템플릿이 그대로라 **쿠버네티스가 변화를
감지하지 못하고 pod가 재시작되지 않기 때문이다.** nginx처럼 기동 시 설정을 한 번
읽는 프로세스는 옛 설정으로 계속 돈다.

```
nginx/default.conf 수정
  -> nginx-conf-276cgdm9t8 에서 nginx-conf-bh629bffbh 로 이름이 바뀜
  -> web Deployment의 volume 참조가 바뀜 = pod 템플릿 변경
  -> 롤링 업데이트로 새 설정이 적용됨
```

매니페스트에는 `name: nginx-conf` 라고만 쓰면 된다. 참조 쪽 이름은 Kustomize가
결과물에서 알아서 고쳐준다.

한 가지 부작용이 있다. 옛 ConfigMap이 클러스터에 그대로 남는다. Kustomize는 새
이름으로 만들 뿐 옛것을 지우지 않으므로, 배포를 반복하면 쌓인다. 몇 KB짜리라
급하진 않지만 가끔 정리하면 좋다.

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
docker build -t emoselfie-backend:local ../emoselfie-BE
docker build --target models -t emoselfie-models:local ../emoselfie-BE
docker build -t emoselfie-web:local ../emoselfie-FE

# 2. k3d에 올리기
k3d image import emoselfie-backend:local emoselfie-models:local emoselfie-web:local -c mycluster

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

## 운영 조건 로컬 검증 (k3d https-check)

`overlays/https-check`는 ALB 뒤의 운영과 같은 쿠키 정책(`ALLOW_INSECURE_COOKIE=false`,
라우팅 쿠키 Secure)을 k3d에서 재현한다. TLS 종료는 `edge.conf`를 마운트한 nginx
컨테이너가 ALB 역할을 대신한다. 아래 순서를 빠뜨리면 원인이 다른 곳에 있는 것처럼
보이는 실패가 난다.

```bash
# 1. 클러스터. edge가 serverlb:80 으로 보내므로 @loadbalancer 포트 매핑이 필수다.
#    없으면 serverlb가 80을 열지 않아 502가 난다. 호스트 포트 번호는 무엇이든 된다.
k3d cluster create emoselfie-https-check --servers 3 --servers-memory 4g \
  --volume "$HOME/.emoselfie-models:/models@all" -p "8080:80@loadbalancer"

# 2. Traefik이 edge의 X-Forwarded-Proto를 믿게 한다. 운영은 Ansible traefik.yml이
#    같은 일을 한다. kustomization의 namespace 변환을 피하려고 따로 apply 한다.
#    helm-install-traefik Job이 다시 돌 때까지 20초쯤 걸린다.
kubectl apply -f k8s/overlays/https-check/traefik-config.yaml
kubectl -n kube-system rollout status deploy/traefik
kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep trustedIPs

# 3. 자체 서명 인증서와 edge. 클러스터를 다시 만들면 serverlb IP가 바뀌므로 edge도 재시작한다.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" -keyout /tmp/certs/tls.key -out /tmp/certs/tls.crt
docker run -d --name edge --network k3d-emoselfie-https-check -p 8446:443 \
  -v "$PWD/k8s/overlays/https-check/edge.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v /tmp/certs:/certs:ro nginx:alpine

# 4. 이미지와 배포. backend 태그는 https-check 다.
docker tag emoselfie-backend:local emoselfie-backend:https-check
k3d image import emoselfie-backend:https-check emoselfie-models:local emoselfie-web:local -c emoselfie-https-check
kubectl apply -k k8s/overlays/https-check
kubectl -n https-check wait --for=condition=ready pod -l app=backend --timeout=300s

# 5. 통합 스모크. 얼굴 이미지는 BE의 prepare_models.py --with-example 이 받는 fig1.jpg 를 쓴다.
python tests/smoke_https.py --url https://localhost:8446 --ca /tmp/certs/tls.crt \
  --image "$HOME/.emoselfie-models/fig1.jpg"
```

정리는 `docker rm -f edge && k3d cluster delete emoselfie-https-check`.

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
  --servers-memory 4g \
  --volume "$HOME/.emoselfie-models:/models@all" \
  -p "80:80@loadbalancer" -p "443:443@loadbalancer"
```

`--servers-memory 4g` 는 각 노드를 t3.medium과 같은 크기로 맞춘다. 이게 없으면
k3d 노드가 Docker VM 전체 메모리를 자기 것으로 보고해서, EC2였다면 스케줄되지
않을 pod도 로컬에서는 멀쩡히 뜬다. kubelet까지 반영되는 것을 확인했다.

```
NAME                     CAP_MEM     ALLOC_MEM   CPU
k3d-mycluster-server-0   4294967Ki   4294967Ki   8
k3d-mycluster-server-1   4294967Ki   4294967Ki   8
k3d-mycluster-server-2   4294967Ki   4294967Ki   8
```

Docker Desktop 메모리는 12GB로 둔다(4GB × 3). CPU는 미러링되지 않는다 — k3d에
노드별 CPU 제한 옵션이 없어 노드가 호스트 코어 수(8)를 그대로 보고한다.
t3.medium은 2 vCPU이므로 CPU 압박은 로컬에서 재현되지 않는다.

`--volume` 은 생성 시점 옵션이라 기존 클러스터에 추가할 수 없다. 이미 있으면
`k3d cluster delete mycluster` 후 다시 만들어야 한다.

서로 다른 노드의 pod 두 개가 같은 파일을 보는 것으로 확인했다.

```
rwxprobe-...-k42wq   k3d-mycluster-server-2
rwxprobe-...-kvsmh   k3d-mycluster-server-1
→ 두 pod 모두 상대가 쓴 파일을 본다
```

backend는 `requests == limits` 로 2Gi를 잡고 로컬도 같은 값을 쓴다(base에 있다).
4GB 노드 3대에 replica 3개가 하나씩 들어가므로, EC2에서 스케줄이 되는지를 맥에서
미리 확인할 수 있다.

### 운영 (EC2 k3s)

**Longhorn 설치가 선행돼야 한다.**

```bash
# 각 EC2 노드에서
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# 클러스터에
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.12.1/deploy/longhorn.yaml
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

> 노드 역할(server 3대 vs server 1 + agent 2)은 아직 결정 전이다. 비교와 근거는
> [`docs/k3s-node-topology.md`](../docs/k3s-node-topology.md) 에 있다.

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

## 과거 nginx 프록시 구조의 문제 기록

아래는 전환 전 구조에서의 관찰과 해결 기록이다. 현재 설정·배포 절차는 위
"현재 요청 경로와 전환 순서"를 따른다. 특히 nginx map 보정은 이제 Compose에만 남아 있다.

요청이 backend에 닿기까지 홉이 여럿이고, **홉이 하나 늘 때마다
`X-Forwarded-Proto` 가 망가질 여지가 생긴다.**

```
로컬:  브라우저 -> k3d serverlb -> Traefik -> nginx -> backend
터널:  브라우저 -> Cloudflare -> cloudflared -> k3d serverlb -> Traefik -> nginx -> backend
ALB:   브라우저 -> ALB -> Traefik -> nginx -> backend
```

**여기 적힌 문제들은 Cloudflare 전용이 아니다.** 앞단에서 TLS를 종료하는 구성이면
ALB든 Cloudflare Tunnel이든 똑같이 겪는다. 이 앱은 카메라 접근(`getUserMedia`)
때문에 secure context가 필수라 운영에서는 어느 쪽이든 https다 — `localhost` 만
예외다. AWS 구성이 무엇으로 정해지든 아래 세 가지는 필요하다.

backend는 두 곳에서 오리진을 검사하고, **둘 다 `X-Forwarded-Proto` 에 의존한다.**

| 검사하는 곳 | 대상 | 판정 기준 |
|---|---|---|
| `app/api/middleware.py` | `/api/`, `/media/` 의 non-GET 요청 | `Origin`의 scheme·netloc이 `scope["scheme"]`·`Host` 와 같은가 |
| engineio (`base_server.py`) | websocket 업그레이드 | `Origin` 이 `{X-Forwarded-Proto}://{Host}` 와 같은가 |

engineio 쪽이 특히 중요한 이유는 소스 주석이 설명한다 — 브라우저의 CORS 보호는
HTTP에만 걸리고 WebSocket에는 걸리지 않으므로 서버가 직접 막아야 한다.

`Origin` 은 브라우저가 자동으로 붙이고 위조할 수 없다. 반대로 **허용 오리진은
서버가 정한다.** 이 프로젝트는 `cors_allowed_origins` 를 명시하지 않아 engineio가
요청 헤더로 추론하는데, 그 재료가 `X-Forwarded-Proto` 다.

```python
# engineio/async_drivers/asgi.py:217
environ['wsgi.url_scheme'] = environ.get('HTTP_X_FORWARDED_PROTO', 'http')
```

`curl` 로 테스트하면 이 문제들이 전부 통과한다. `Origin` 헤더를 보내지 않아
검사 자체가 건너뛰어지기 때문이다. **브라우저에서만 드러난다.**

### 1. Traefik이 websocket에 `ws` 를 넣는다

**앞단과 무관하다.** Traefik이 기본 Ingress인 이상 로컬이든 EC2든 그대로 재현되고,
평범한 `http://localhost` 접속에서 처음 발견했다.

Traefik은 업그레이드 요청의 `X-Forwarded-Proto` 를 `http` 가 아니라 `ws` 로 준다.
engineio가 그대로 스킴으로 쓰므로 허용 오리진이 `ws://host` 가 된다.

| 경로 | X-Forwarded-Proto | 허용 오리진 | 브라우저 Origin | 결과 |
|---|---|---|---|---|
| backend 직접 | 없음 | `http://localhost` | `http://localhost` | 101 |
| Traefik 경유 | `ws` | `ws://localhost` | `http://localhost` | 403 |

nginx의 `$forwarded_proto` map에서 정규화한다.

```nginx
map $http_x_forwarded_proto $forwarded_proto {
    default $http_x_forwarded_proto;
    ''      $scheme;
    ws      http;
    wss     https;
}
```

같은 수정이 잠재 버그 하나도 막는다. `$cookie_secure_flag` 가 `https` 만 보므로,
https 경로로 온 websocket은 `wss` 가 되어 Secure 쿠키가 벗겨졌을 것이다. 로컬은
http라 드러나지 않고 **운영에서만 터졌을 문제다.**

### 2. Traefik이 앞단의 `https` 를 덮어쓴다

Traefik은 기본적으로 들어온 `X-Forwarded-*` 를 믿지 않고 실제 연결 스킴으로
갈아친다. 앞단이 `https` 를 보내도 `http` 가 된다.

**ALB를 써도 같다.** ALB가 `X-Forwarded-Proto: https` 를 보내면 Traefik이 똑같이
덮어쓴다. TLS를 Traefik 자신이 종료하는 구성(cert-manager)만 예외다.

compose에서는 cloudflared -> nginx 직결이라 이 문제가 없었다. Traefik이 사이에
끼면서 생겼다.

```
설정 전:  X-Forwarded-Proto: https -> http
설정 후:  X-Forwarded-Proto: https -> https   (X-Forwarded-Port: 443 도 함께)
```

`HelmChartConfig` 로 Traefik이 헤더를 신뢰하게 한다. k3s는 내장 컴포넌트를 Helm
컨트롤러로 설치하므로 Deployment를 직접 고치면 재조정 때 되돌아간다.

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik          # HelmChart와 같은 이름·네임스페이스여야 매칭된다
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        forwardedHeaders:
          trustedIPs:
            - "10.42.0.0/16"     # 로컬 k3d. 운영은 VPC CIDR
```

`insecure: true` 라는 값도 있지만 쓰지 않는다. **누가 보내든 `X-Forwarded-*` 를
믿는다**는 뜻이라, Traefik에 앞단을 거치지 않고 직접 닿을 경로가 없다는 전제에
기댄다. 운영(EC2)에서는 노드 포트가 VPC 안에서 열리므로 그 전제가 약해진다.

`trustedIPs` 로 대역을 좁히고 **보안 그룹으로 2중 방어**하는 쪽을 쓴다. 로컬과
운영이 같은 모양이 되는 것도 이점이다.

| 환경 | 값 | 근거 |
|---|---|---|
| 로컬 k3d | `10.42.0.0/16` | pod CIDR. 요청이 `svclb` DaemonSet을 거쳐 오므로 Traefik이 보는 피어가 이 대역 안이다 |
| 운영 EC2 | VPC CIDR | ALB ENI가 VPC 안에 있다 |

로컬 값은 실제로 확인했다. `X-Forwarded-Proto: https` 와 일치하는 `Origin`/`Host` 를
넣은 요청이 통과하고, `Origin` 만 다른 사이트로 바꾸면 차단된다.

```
POST /api/rooms  (X-Forwarded-Proto: https, Origin/Host 일치)  -> 201
websocket 업그레이드                                            -> 101
POST /api/rooms  (Origin 만 다른 사이트)                        -> FORBIDDEN_ORIGIN
GET  /  와 http Origin 경로                                     -> 200 / 201 (영향 없음)
Set-Cookie (http 접속)                                          -> Secure 없음 (정상)
```

이 파일은 매니페스트에 넣지 않았다. Kustomize의 `namespace:` 설정이 `kube-system`
을 덮어써 매칭이 깨지기 때문이다. 로컬은 실행 스크립트가 적용한다.

**EC2에서도 따로 적용해야 한다.** 앞단(ALB든 Cloudflare든)이 TLS를 종료하는 한
같은 문제가 재현된다. 저장소에 없으니 배포 절차에 넣거나 별도 파일로 빼야 한다.

적용은 비동기다. Helm 컨트롤러가 upgrade Job을 돌리고 **그다음에** Deployment를
갱신하므로, 바로 `rollout status` 를 부르면 옛 Deployment가 아직 안정 상태라
즉시 성공을 반환한다. 스펙에 플래그가 나타날 때까지 기다려야 한다.

```bash
kubectl -n kube-system get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'forwardedHeaders.insecure'
```

### 3. backend가 `--proxy-headers` 없이 뜬다

이것도 TLS 종료 지점이 앞단인 모든 구성에 해당한다. 이미지 기본 CMD에는 이 인자가
없다. 그러면 uvicorn이 `X-Forwarded-Proto` 와
무관하게 `scope["scheme"]` 을 항상 `http` 로 둔다. `middleware.py` 의
`parsed.scheme == scope["scheme"]` 비교가 어긋나 https 요청이 `FORBIDDEN_ORIGIN`
으로 막힌다.

```json
{"error": {"code": "FORBIDDEN_ORIGIN", "message": "같은 사이트에서 다시 시도해 주세요"}}
```

compose는 이 인자를 주고 있었는데(PR #3) 매니페스트로 옮기며 빠졌다. `base` 의
backend에 같은 인자를 넣었다.

```yaml
command: ["uvicorn", "app.main:create_app", "--factory",
          "--host", "0.0.0.0", "--port", "8000",
          "--timeout-graceful-shutdown", "10",
          "--proxy-headers", "--forwarded-allow-ips=*"]
```

backend는 포트를 노출하지 않아 nginx를 통해서만 닿으므로 신뢰 범위를 넓혀도 된다.

### 검증

로컬 http 직접 접속:

```
Origin: http://localhost                        -> 201
Origin: https://localhost (스킴 불일치)          -> FORBIDDEN_ORIGIN
X-Forwarded-Proto: https + 일치하는 Origin/Host  -> 201
같은 조건에서 Origin만 다른 사이트                -> FORBIDDEN_ORIGIN  (차단 정상)
```

실제 Cloudflare Quick Tunnel(앞단 TLS 종료 구성의 한 예):

```
GET  /                     200
POST /api/rooms            201  {"slug":"4nc6SVXHRV0J","status":"waiting",...}
websocket 업그레이드         101 Switching Protocols
Set-Cookie                 ... SameSite=lax; Secure
```

http로 직접 접속하면 `Secure` 가 벗겨지는 것도 그대로다(Safari가 http 오리진에
Secure 쿠키를 저장하지 않아 필요한 동작). PR #3이 의도한 동작이 여기서 처음으로
실증됐다.

## 선행 의존성

`backend-env`의 `REDIS_URL`이 Sentinel 형식이다.

```
redis+sentinel://redis-sentinel-0.redis-sentinel:26379,\
                redis-sentinel-1.redis-sentinel:26379,\
                redis-sentinel-2.redis-sentinel:26379/0/mymaster
```

`emoselfie-BE#7` 이 설정 계층을 열어준 뒤에야 이 값이 통과한다(머지 완료).
그 전에는 `redis_url: RedisDsn` 이 이 형식을 거부해 backend가 startup에서 죽었다.

세 sentinel을 모두 나열하는 이유는 하나가 죽어도 나머지에게 물어볼 수 있어야
하기 때문이다. StatefulSet pod DNS라 주소가 고정되고, 짧은 이름이라 네임스페이스에
무관하다.

## 알려진 한계

**failover 창의 pub/sub 유실.** Redis pub/sub은 master에서 replica 방향으로만
전파된다. failover 직후 일부 pod가 아직 옛 master를 보고 있는 몇 초 동안 한쪽
방향으로만 메시지가 샌다. pub/sub은 저장되지 않으므로 그 창에서 놓친 이벤트는
재시도로 복구되지 않는다.

리액션 누락 정도는 넘어갈 만하지만, 라운드 마감 브로드캐스트가 일부 pod에만
닿으면 그 pod에 붙은 참가자 화면이 멈춘다. 재연결 시 방/라운드 상태를 다시 받는
경로를 두면 자동 복구된다. `presence:ping` 위에 얹기 좋다.

구조적으로 없앨 수 없는 문제다. 관리형 Redis는 failover 창이 짧고 프록시
엔드포인트를 줘서 클라이언트가 주소 변경을 겪지 않는다.

**postgres는 단일 인스턴스다.** k3s 기본 스토리지가 local-path라 PVC가 특정
노드에 묶인다. 그 노드가 죽으면 pod가 재스케줄되지 못하고 Pending에 갇힌다.
3노드 구성에서 여기만 단일 장애점으로 남는다. CloudNativePG 오퍼레이터로
교체하면 공유 스토리지 없이 스트리밍 복제 + 자동 failover가 가능하다.

**Job 재적용.** `migrate` Job은 완료 후 spec이 immutable이라 재배포 전에
`kubectl delete job migrate` 가 필요하다. 기동 순서는 `wait-postgres`
initContainer가 처리하므로 재시도에 기대지 않는다.

**Pod 간 격리 없음.** backend는 Traefik만 거친다는 전제로 `--forwarded-allow-ips=*`를
쓰지만 NetworkPolicy가 없어 클러스터 안 어떤 Pod든 직접 붙을 수 있다. 단일 테넌트라
지금은 두고, 다른 앱이 같은 클러스터에 올라오면 backend·postgres·redis를 함께 격리한다.

**ALB 헬스체크는 backend 상태다.** `/health/live`가 Ingress를 타고 backend에 닿으므로
노드 건강 = backend 건강이다. backend가 전멸해도 ALB는 fail-open으로 노드에 계속 보내므로
`/`는 web이 200, `/api`·`/socket.io`는 Traefik이 503을 낸다. 이때 점검 안내 화면은 FE 책임이다.

## 검증 기록

로컬 k3d(3노드)에서 전체 스택을 띄우고 확인한 내용이다. 오리진·프로토콜 전달
관련 검증은 위 "오리진과 프로토콜 전달" 절에 있다.

**노드 분산.** backend 3개가 노드 하나씩에 흩어졌다. `podAntiAffinity`가 동작한다.

**모델 공유.** 최초 부팅에서는 3개 pod가 동시에 떠서 각자 받았다(경합). 이후
pod를 지우고 새로 뜨게 하면 `Verified ...` 만 찍고 다시 받지 않는다. 공유 볼륨
재사용이 성립한다.

**복제 부트스트랩.** `start.sh` 가 redis-0을 master로, redis-1/2를 replica로
잡았다. Sentinel이 `num-slaves 2`, `num-other-sentinels 2` 로 인식한다.

**Sentinel failover.** `kubectl delete pod redis-0` 후 master가 redis-1로
승격됐다. **재시작하지 않은 backend pod(RESTARTS=0)가 새 master로 쓰기에
성공했다.** `redis+sentinel://` 전환이 의도대로 동작한다.

```
failover 전:  OK  value=before  master=redis-0.redis.local.svc.cluster.local
failover 후:  OK  value=after   master=redis-1.redis.local.svc.cluster.local
```

**migrate 기동 순서.** 처음에는 `migrate` 가 postgres보다 먼저 떠서 DNS 조회부터
실패했다. `backoffLimit: 3` 중 2를 소진하고 세 번째에 겨우 성공했다. Job은 한도를
넘기면 영구 실패라 재시도에 기대면 안 된다.

`wait-postgres` initContainer를 붙이고, postgres와 Job을 지운 뒤 동시에 다시
올려 재현 검증했다. 첫 시도에 성공했고 실패 pod가 없다.

```
nc: bad address 'postgres'    <- postgres가 not ready. headless DNS가 비어 있다
nc: bad address 'postgres'
postgres 대기 중               <- ready 되자 이름이 풀리고 연결됨

이전: migrate pod 3개 (Error, Error, Completed)
이후: migrate pod 1개 (Completed)
```

`pg_isready` 가 아니라 `nc` 를 쓰는 이유가 여기 있다. postgres Service가
headless라 DNS가 ready인 pod만 반환하고, postgres pod에는 이미 `pg_isready`
readinessProbe가 걸려 있다. 이름이 풀리는 시점이 곧 `pg_isready` 가 통과한
시점이라 initContainer에서 다시 확인할 필요가 없다. 처음 실패도 연결 거부가
아니라 `socket.gaierror: Name or service not known` 이었다.

busybox는 1.85MB고 k3s가 번들로 갖고 있어 노드에 이미 있다. postgres 이미지는
108MB이고, migrate가 postgres-0과 다른 노드에 스케줄되면 그만큼 받아야 한다.

**redis-0 복귀 시 과도 상태.** 재생성된 redis-0이 몇 초간 master로 떴다.
Sentinel이 아직 failover를 끝내지 않아 `start.sh` 의 조회가 옛 답을 받았기
때문이다. 곧 Sentinel이 `REPLICAOF redis-1` 을 보내 교정했고 최종 상태는
master 1 / replica 2 로 수렴했다. 자가 치유되지만 그 몇 초간 두 master가
공존한다.

## HA 확인

```bash
kubectl get nodes                                  # 3대 모두 control-plane
kubectl get pods -o wide -n local                  # 노드별 분산 확인
kubectl drain <node> --ignore-daemonsets           # 노드 하나 빼기
kubectl delete pod redis-0 -n local                # Redis master 강제 종료
kubectl exec -n local redis-sentinel-0 -- redis-cli -p 26379 sentinel master mymaster
```
