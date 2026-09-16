# EmoSelfie 배포 및 운영 가이드

> 문서 기준일: 2026-09-16
> 대상 환경: AWS 운영 환경(`prod`)
> 기준 저장소: `emoselfie-INFRA`, `emoselfie-BE`, `emoselfie-FE`

이 문서는 새로운 운영자가 EmoSelfie를 전달받아 처음 배포하고, 정상 동작을 확인하고,
장애의 최초 원인을 좁힐 수 있도록 작성한 실행 절차다.

명령과 판정 기준은 현재 저장소의 Terraform, Ansible, Kustomize 매니페스트와 Backend
코드를 기준으로 한다. 실제 운영 배포, DB migration, 복구 작업은 이 문서 작성 중 실행하지
않았다. 이미지 태그, 실행 시각, 명령 결과와 캡처는 배포 건별로 별도 기록한다.

## 0. 먼저 알아둘 운영 구조

운영 요청은 다음 경로로 처리된다.

```text
사용자
  -> Route 53
  -> ALB(ACM TLS 종료, HTTP -> HTTPS 전환)
  -> k3s 노드의 Traefik
  -> web Service / Nginx DaemonSet
  -> backend Service / FastAPI Deployment
  -> PostgreSQL, Redis Sentinel, redis-media
```

현재 운영 구성의 기준은 다음과 같다.

| 구성 요소 | 현재 구성 | 정상 기준 |
|---|---:|---|
| k3s server | 3대, embedded etcd | 3대 모두 `Ready` |
| Backend | HPA 1~3개, 평균 CPU 70% | 현재 목표 Replica 수만큼 `Ready` |
| Web | 노드당 1개 DaemonSet | 정상 노드가 3대면 3/3 `Ready` |
| PostgreSQL | StatefulSet 1개, local-path 5Gi | 1/1 `Ready` |
| Redis | StatefulSet 3개, local-path 각 1Gi | 3/3 `Ready`, Sentinel quorum 정상 |
| Redis Sentinel | StatefulSet 3개, local-path 각 100Mi | 3/3 `Ready` |
| redis-media | Deployment 1개, 비영속 캐시 | 1/1 `Ready` |
| DB migration | 배포마다 Job 1회 | `Complete`; 완료 10분 뒤 자동 삭제 가능 |

중요한 제약:

- PostgreSQL은 단일 인스턴스이며 PVC가 특정 노드의 로컬 디스크에 묶인다. 그 노드가
  장애 나면 자동 HA 복구되지 않는다.
- 원본 셀카는 영구 저장하지 않는다. 결과 표시용 이미지는 `redis-media`의 휘발성 캐시다.
- 모델은 각 노드의 `/models` hostPath에 캐시한다. 새 노드에서는 다시 다운로드한다.
- 별도 Prometheus, Grafana, 중앙 로그, 자동 경보, 저장소가 관리하는 off-host 백업은 없다.
- Backend Replica 수는 고정값이 아니다. HPA가 1~3개 사이에서 바꾸므로 `2/2`만을 정상
  기준으로 사용하면 안 된다.

---

## 1. 배포 전 준비

### 1.1 로컬 도구

배포 명령은 EC2 안이 아니라 운영자의 로컬 Mac에서 실행한다.

```bash
terraform version
ansible-playbook --version
kubectl version --client
aws --version
git --version
command -v ssh
command -v scp
```

필요한 도구가 없을 때 Homebrew를 사용하는 예시는 다음과 같다.

```bash
brew install terraform ansible kubectl awscli
```

Homebrew 자체는 배포 필수 요소가 아니다. 필요한 실행 파일이 이미 설치되어 있으면 된다.

### 1.2 저장소와 키 파일 배치

세 저장소와 EC2 개인키는 같은 상위 디렉터리에 둔다.

```text
project/
├── emoselfie-INFRA/
├── emoselfie-BE/
├── emoselfie-FE/
└── emoselfie_key.pem
```

이 문서에서는 EC2 키페어 이름을 `emoselfie_key`, 개인키 파일 이름을
`emoselfie_key.pem`으로 예시한다. 실제 환경에서는 팀이 발급·보관하는 키 이름과 경로로
바꾸되, Terraform의 `key_name`과 Ansible의 `ssh_private_key_file`이 같은 키를 가리키게
한다.

```bash
chmod 600 emoselfie_key.pem
```

개인키, Terraform state, Ansible Vault, 생성된 kubeconfig는 Git에 커밋하거나 메신저로
공유하지 않는다.

### 1.3 AWS 계정과 선행 리소스

다음 조건이 필요하다.

- AWS CLI가 대상 운영 계정에 인증되어 있어야 한다.
- 기본 리전은 `ap-northeast-2`다.
- EC2, Security Group, ALB, IAM Role/Instance Profile, Route 53을 관리할 권한이 필요하다.
- ECR 로그인과 세 저장소의 이미지 조회 권한이 필요하다.
- 예시 기준 `emoselfie_key` EC2 키페어가 서울 리전에 이미 있어야 한다.
- `emoselfie.click` public hosted zone이 Route 53에 있어야 한다.
- `emoselfie.click`의 상태가 `ISSUED`인 ACM 인증서가 서울 리전에 있어야 한다.
- 기본 VPC에 서로 다른 가용 영역의 기본 서브넷이 최소 3개 있어야 한다.

인증된 계정과 기본 리전을 확인한다.

```bash
aws sts get-caller-identity
aws configure get region
```

정상이라면 의도한 Account와 Arn이 출력되고, 리전은 `ap-northeast-2`이거나 Terraform
변수로 명시한 값이어야 한다.

### 1.4 배포할 Git 상태 확인

Ansible은 원격 저장소에서 코드를 받아 배포하지 않고 운영자의 로컬
`emoselfie-INFRA` 작업 트리를 사용한다. 배포 전에 다음을 기록한다.

```bash
cd emoselfie-INFRA
git fetch origin main
git status --short
git rev-parse HEAD
git rev-parse origin/main
```

정상 기준:

- `git status --short`가 비어 있다.
- `HEAD`와 `origin/main`이 같다.
- 다르다면 변경 내용을 검토하고 승인 없이 계속하지 않는다.

playbook도 이 검사를 수행하고 차이가 있으면 대화형 확인을 요청한다. CI처럼 입력할 수 없는
환경의 `-e skip_git_check=true`는 차이를 검토하고 승인한 경우에만 사용한다.

### 1.5 Terraform 변수, 버전과 state

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`의 `admin_cidr`를 운영자 현재 공인 IPv4의 `/32`로 바꾼다.

```hcl
admin_cidr = "203.0.113.10/32"
key_name   = "emoselfie_key"
```

주의:

- `0.0.0.0/0`은 검증에서 거부된다.
- 이 CIDR만 SSH 22번과 Kubernetes API 6443에 접근할 수 있다.
- 운영자의 공인 IP가 바뀌면 먼저 Terraform에서 `admin_cidr`를 갱신해야 한다.
- `k3s_version`을 비우면 생성 시점의 `stable`이 설치된다. 재현 가능한 운영 환경이
  필요하면 검증한 정확한 버전을 고정한다.

현재 Terraform에는 원격 backend가 없다. 로컬 `terraform.tfstate`에는 k3s join token과
전체 EC2 user data 등 민감 정보가 들어가므로 다음을 지킨다.

- state를 Git에 커밋하지 않는다.
- state를 잃으면 기존 리소스를 안전하게 변경하기 어려우므로 암호화되고 접근 통제된
  위치에 백업한다.
- 팀 운영 전에는 locking과 암호화를 지원하는 원격 backend 도입을 권장한다.
- `tfplan`도 민감 정보를 포함할 수 있으므로 배포 후 안전하게 보관하거나 폐기한다.

### 1.6 이미지 태그 확인

운영 이미지는 `sha-` 뒤에 소문자 16진수 12자리가 오는 불변 태그를 사용한다.

```bash
export AWS_REGION=ap-northeast-2
export BE_TAG=sha-aaaaaaaaaaaa
export FE_TAG=sha-bbbbbbbbbbbb

aws ecr describe-images --region "$AWS_REGION" \
  --repository-name emoselfie-be --image-ids imageTag="$BE_TAG"
aws ecr describe-images --region "$AWS_REGION" \
  --repository-name emoselfie-be-models --image-ids imageTag="$BE_TAG"
aws ecr describe-images --region "$AWS_REGION" \
  --repository-name emoselfie-fe --image-ids imageTag="$FE_TAG"
```

BE와 models 이미지는 같은 BE 태그를 사용한다. 정상이라면 각 응답에 `imageDigest`와
요청한 태그가 보인다. `ImageNotFoundException`이면 배포를 중단하고 CI 게시 결과부터
확인한다.

### 1.7 운영 Secret 준비

운영 Secret은 `emoselfie-INFRA/ansible/group_vars/all/vault.yml`에 Ansible Vault로
저장한다.

```bash
cd ../ansible
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
ansible-vault create group_vars/all/vault.yml
```

Vault 내용 형식:

```yaml
vault_postgres_password: "서로 다른 32자 이상 값"
vault_cookie_secret: "서로 다른 32자 이상 값"
vault_capture_token_secret: "서로 다른 32자 이상 값"
vault_media_token_secret: "서로 다른 32자 이상 값"
```

기존 파일을 수정할 때는 다음 명령을 사용한다.

```bash
ansible-vault edit group_vars/all/vault.yml
```

`vault_postgres_password`는 기존 DB가 만들어진 뒤 Vault 값만 바꾸면 안 된다. PostgreSQL
데이터 디렉터리가 이미 있으면 컨테이너의 `POSTGRES_PASSWORD` 변경이 기존 DB 계정
비밀번호를 바꾸지 않는다. DB 비밀번호 교체는 별도 변경 작업과 검증된 복구 계획으로
수행한다.

또한 Secret 객체의 내용이 바뀌어도 환경 변수로 읽는 실행 중 Pod는 자동 재시작되지
않는다. 서명 키를 바꾼 뒤에는 8.3절에 따라 Backend를 명시적으로 재시작한다.

### 1.8 배포 전 필수 결정과 백업

배포 승인 전에 다음을 확인한다.

- 이전 정상 BE/FE 태그를 기록했는가?
- migration이 이전 애플리케이션 버전과 호환되는가?
- DB 백업 파일을 클러스터 밖에 만들고 복원 가능성을 확인했는가?
- 장애 시 서비스 중단 허용 시간과 담당자를 정했는가?
- Terraform plan의 `replace` 또는 `destroy` 대상을 검토했는가?
- ACM 인증서, 도메인, AWS 비용 영향을 확인했는가?

현재 `k8s/overlays/prod/kustomization.yaml`에는
`PARTICIPANT_GRACE_SEC=86400`이 들어 있다. Backend 기본값은 60초이고 매니페스트 주석은
이 값을 부하 테스트 창구에서만 사용한다고 설명한다. 운영 릴리스 전에 24시간 유예가
의도된 정책인지 반드시 결정하고, 아니라면 값을 제거하거나 60초로 되돌린 변경을 먼저
승인·반영한다.

---

## 2. 첫 배포

### 2.1 Terraform으로 AWS 인프라 생성

`emoselfie-INFRA/terraform`에서 실행한다.

```bash
terraform fmt -check
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

`apply` 전에 plan에서 다음을 확인한다.

- 대상 AWS 계정과 리전이 맞다.
- EC2 server 3대와 ALB, Target Group, 보안 그룹, IAM 역할이 생성된다.
- 예상하지 않은 기존 리소스 삭제나 교체가 없다.
- AMI, instance type, root volume 크기와 월 비용이 의도와 맞다.

주요 출력을 기록한다.

```bash
terraform output -raw application_url
terraform output -raw server_public_ip
terraform output -json node_public_ips
terraform output -raw load_balancer_dns_name
```

Terraform은 Route 53 alias 레코드까지 생성한다. 별도의 수동 DNS 전환은 필요하지 않지만,
기존 레코드를 변경하는 환경이라면 전환 영향과 되돌리기 방법을 승인받는다.

### 2.2 k3s 부팅 확인

Terraform이 끝난 뒤에도 cloud-init과 k3s 구성이 몇 분 더 걸릴 수 있다.

```bash
ssh -i ../../emoselfie_key.pem \
  ubuntu@$(terraform output -raw server_public_ip)
sudo tail -f /var/log/emoselfie-bootstrap.log
sudo k3s kubectl get nodes -o wide
exit
```

`tail -f`는 `Ctrl+C`로 종료한다.

정상 기준:

- server 노드 3대가 보인다.
- 세 노드가 모두 `Ready`다.
- 부팅 로그 끝에 k3s 설치 실패가 없다.

### 2.3 Ansible로 애플리케이션 배포

`emoselfie-INFRA/ansible`에서 실행한다.

```bash
cd ../ansible
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=../../emoselfie_key.pem \
  -e backend_tag="$BE_TAG" \
  -e frontend_tag="$FE_TAG"
```

개인키를 다른 위치에 보관한다면 실제 경로를 명시한다.

```bash
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=/실제/경로/emoselfie_key.pem \
  -e backend_tag="$BE_TAG" \
  -e frontend_tag="$FE_TAG"
```

playbook은 다음을 수행한다.

1. 로컬 Git 상태와 `origin/main` 비교
2. EC2 부팅 로그를 이용한 SSH host key 검증
3. Traefik trusted proxy 설정과 rollout 확인
4. 관리자 kubeconfig 다운로드
5. 세 노드 `Ready` 확인
6. Namespace와 운영 Secret 적용
7. ECR pull Secret 갱신
8. BE, models, FE의 SHA 태그 주입
9. 이전 migrate Job 삭제와 새 매니페스트 적용
10. migration, Backend, Web rollout 완료 대기

정상 기준:

- `failed=0`으로 playbook이 끝난다.
- migration 대기가 성공한다.
- Backend Deployment와 Web DaemonSet rollout이 성공한다.
- 마지막 Pod, PVC, Ingress 출력에 명백한 오류 상태가 없다.

`ansible/.generated/k3s-prod.yaml`은 cluster-admin 인증 정보다. 파일 권한 0600을 유지하고
외부에 공유하지 않는다.

---

## 3. 배포 상태 확인

새 터미널에서 다음 환경을 설정한다.

```bash
cd emoselfie-INFRA/ansible
export KUBECONFIG="$PWD/.generated/k3s-prod.yaml"
export NS=emoselfie
export APP_URL="$(terraform -chdir=../terraform output -raw application_url)"
```

### 3.1 노드와 시스템 구성 요소

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods
```

정상 기준:

- 노드 3대가 모두 `Ready`다.
- Traefik, CoreDNS, metrics-server 등 k3s 핵심 Pod가 `Running` 또는 완료 상태다.
- 노드의 `MemoryPressure`, `DiskPressure`, `PIDPressure`가 `False`다.

```bash
kubectl describe node <node-name>
```

### 3.2 애플리케이션 전체 상태

```bash
kubectl -n "$NS" get deploy,statefulset,daemonset,hpa,job
kubectl -n "$NS" get pods,pvc,svc,ingress -o wide
```

정상 기준:

- `postgres` 1/1, `redis` 3/3, `redis-sentinel` 3/3이 Ready다.
- `redis-media` 1/1이 Ready다.
- Web DaemonSet의 `DESIRED`, `READY`, `AVAILABLE`이 정상 노드 수와 같다.
- Backend Deployment의 Ready 수가 HPA의 현재 `DESIRED`와 같다.
- 모든 PVC가 `Bound`다.
- `Pending`, `CrashLoopBackOff`, `ImagePullBackOff`, 반복 재시작이 없다.

### 3.3 Backend HPA와 rollout

```bash
kubectl -n "$NS" get hpa backend
kubectl -n "$NS" get deployment backend
kubectl -n "$NS" rollout status deployment/backend --timeout=10m
```

현재 HPA 기준:

- 최소 1개, 최대 3개
- 평균 CPU 목표 70%
- 모델 준비와 warm-up 때문에 새 Pod가 트래픽을 받기까지 최대 약 120초가 걸릴 수 있음

정상 기준:

- Backend Replica 수가 1~3 범위다.
- Deployment의 `READY`, `UP-TO-DATE`, `AVAILABLE`이 현재 목표 Replica 수와 같다.
- HPA `TARGETS`가 장시간 `<unknown>`으로 남지 않는다.

metrics-server가 준비되기 전에는 `TARGETS`가 잠시 `<unknown>`일 수 있다. 지속되면
metrics-server 로그와 Pod resource request를 확인한다.

### 3.4 Web DaemonSet

```bash
kubectl -n "$NS" get daemonset web
kubectl -n "$NS" rollout status daemonset/web --timeout=5m
```

3개 노드가 정상이라면 일반적으로 `DESIRED`, `CURRENT`, `READY`, `UP-TO-DATE`,
`AVAILABLE`이 모두 3이다.

### 3.5 Migration

```bash
kubectl -n "$NS" get job migrate
kubectl -n "$NS" wait --for=condition=complete job/migrate --timeout=10m
kubectl -n "$NS" logs job/migrate --tail=200
```

정상 기준은 `COMPLETIONS 1/1` 또는 `condition met`이다. Job은 완료 후 10분 뒤 자동
삭제될 수 있다. 삭제 후 `NotFound`가 나오면 직전 Ansible 결과와 배포 시 보존한 로그로
성공 여부를 확인한다.

### 3.6 데이터 계층

```bash
kubectl -n "$NS" exec postgres-0 -- \
  sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

kubectl -n "$NS" exec redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

kubectl -n "$NS" exec redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL ckquorum mymaster
```

정상 기준:

- PostgreSQL이 `accepting connections`를 출력한다.
- Sentinel이 master의 hostname과 6379 포트를 반환한다.
- `ckquorum`이 quorum과 failover 가능 상태를 `OK`로 보고한다.

### 3.7 DNS, TLS와 ALB Target

```bash
dig +short emoselfie.click
curl -I http://emoselfie.click
curl -I https://emoselfie.click
openssl s_client -connect emoselfie.click:443 -servername emoselfie.click </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

정상 기준:

- HTTP는 HTTPS로 `301` 리다이렉트된다.
- HTTPS 루트는 `200`을 반환한다.
- 인증서 이름이 도메인과 맞고 만료일에 여유가 있다.

기본 이름을 바꾸지 않았다면 ALB Target 상태도 확인한다.

```bash
export TG_ARN="$(aws elbv2 describe-target-groups \
  --region ap-northeast-2 \
  --names emoselfie-prod-http \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"

aws elbv2 describe-target-health \
  --region ap-northeast-2 \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}'
```

정상 기준은 등록된 EC2 3대가 모두 `healthy`인 것이다. ALB 검사는 `/health/live`만
사용하므로 Target이 healthy여도 DB, Redis, 모델 readiness는 별도로 확인해야 한다.

---

## 4. 서비스 정상 동작 확인

### 4.1 Liveness

```bash
curl --fail-with-body -i "$APP_URL/health/live"
```

정상 결과:

```json
{"status":"ok"}
```

HTTP 200은 Backend 프로세스가 응답한다는 뜻이다. DB, Redis, 모델 준비 완료까지
보장하지 않는다.

### 4.2 Readiness

```bash
curl --fail-with-body -i "$APP_URL/health/ready"
```

정상 결과:

```json
{
  "status": "ready",
  "inferenceBackend": "real",
  "checks": {
    "database": true,
    "redis": true,
    "mediaRedis": true,
    "inference": true
  }
}
```

HTTP 200, `status=ready`, `inferenceBackend=real`, 네 check가 모두 `true`여야 한다.
의존성 장애나 모델 미준비 시 HTTP 503과 `not_ready`가 정상적인 실패 표현이다.

### 4.3 정적 페이지와 SPA 경로

```bash
curl --fail-with-body -I "$APP_URL/"
curl --fail-with-body -I "$APP_URL/r/test-room"
```

두 요청 모두 HTTP 200이어야 한다. `/r/test-room`은 실제 방 존재 여부와 무관하게 Nginx
SPA fallback이 `index.html`을 제공하는지 확인하는 용도다.

### 4.4 실제 AI 게임 smoke test

공개된 별도 `/infer` 또는 `/predict` API는 없다. 실제 추론 확인은 게임 흐름으로 한다.

1. 브라우저에서 운영 URL에 접속한다.
2. 방을 만든다.
3. 다른 브라우저 또는 다른 기기로 같은 방에 입장한다.
4. 2명 이상인 상태에서 게임을 시작한다.
5. 라운드에서 실제 JPEG 사진을 제출한다.
6. 개발자 도구 Network에서 제출 응답이 HTTP 202인지 확인한다.
7. Socket.IO `submission:scored` 이벤트가 도착하는지 확인한다.
8. 결과 화면에 감정 점수와 순위가 표시되는지 확인한다.
9. WebSocket과 polling fallback을 각각 검증할 수 있으면 둘 다 확인한다.

HTTP 202는 접수 성공일 뿐 추론 완료가 아니다. `submission:scored`와 결과 화면까지
확인해야 AI 기능이 정상이다.

캡처를 공유할 때 쿠키, 촬영 토큰, media token, 얼굴 사진, 사용자 식별자를 가린다.

---

## 5. 로그 확인

### 5.1 Backend와 init container

```bash
kubectl -n "$NS" get pods -l app=backend -o wide
kubectl -n "$NS" logs -l app=backend -c backend \
  --tail=200 --prefix --timestamps
kubectl -n "$NS" logs -l app=backend -c wait-dependencies \
  --tail=100 --prefix --timestamps
kubectl -n "$NS" logs -l app=backend -c prepare-models \
  --tail=100 --prefix --timestamps
```

특정 Pod가 재시작했다면 이전 컨테이너 로그를 확인한다.

```bash
kubectl -n "$NS" logs <backend-pod-name> -c backend \
  --previous --tail=200 --timestamps
```

### 5.2 Web, DB와 Redis

```bash
kubectl -n "$NS" logs -l app=web --tail=200 --prefix --timestamps
kubectl -n "$NS" logs postgres-0 --tail=200 --timestamps
kubectl -n "$NS" logs redis-0 --tail=200 --timestamps
kubectl -n "$NS" logs redis-sentinel-0 --tail=200 --timestamps
kubectl -n "$NS" logs -l app=redis-media --tail=200 --prefix --timestamps
```

확인할 오류:

- DB 연결 또는 migration 실패
- Redis Sentinel 연결, quorum 또는 failover 실패
- 모델 다운로드, 크기, SHA-256, 로드 또는 warm-up 실패
- `FORBIDDEN_ORIGIN`, WebSocket 403
- 지속적인 HTTP 5xx
- `OOMKilled`, 반복 재시작, probe 실패

현재 중앙 로그 보관이 없으므로 Pod와 노드가 사라지면 로그도 잃을 수 있다. 장애 로그는
즉시 시간 범위와 Pod 이름을 포함해 외부 증빙 위치에 저장한다. 이미지 원본, base64,
얼굴 좌표, UUID, 쿠키와 토큰은 로그나 증빙에 남기지 않는다.

---

## 6. 자원과 용량 확인

```bash
kubectl top node
kubectl -n "$NS" top pod
kubectl -n "$NS" top pod --containers
kubectl -n "$NS" get hpa backend
kubectl -n "$NS" get pods \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,QOS:.status.qosClass'
```

현재 애플리케이션 컨테이너 기준:

| 컨테이너 | CPU Request / Limit | Memory Request / Limit |
|---|---:|---:|
| backend | 1 / 1 | 2Gi / 2Gi |
| web | 50m / 50m | 32Mi / 32Mi |

판정 기준:

- Backend CPU가 70%를 지속해서 넘으면 HPA가 scale-out하는지 본다.
- CPU limit 1에 장시간 붙고 최대 3개까지 확장됐으면 용량 부족으로 본다.
- Backend 메모리가 2Gi에 계속 근접하거나 `OOMKilled`가 발생하면 장애로 본다.
- `RESTARTS`가 계속 증가하면 정상으로 보지 않는다.
- 노드의 Memory/Disk Pressure와 EBS 여유 공간을 함께 본다.

PostgreSQL, Redis, Sentinel, redis-media에는 현재 CPU·Memory request/limit가 명시되지
않았다. `kubectl top`의 순간값만으로 안전 여유를 단정하지 말고 추세와 노드 압박을 함께
기록한다.

`Metrics API not available`은 사용량이 0이라는 뜻이 아니다. metrics-server 상태부터
확인한다.

---

## 7. 재배포와 업데이트

### 7.1 배포 전 현재 상태 기록

```bash
kubectl -n "$NS" get deployment backend \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="backend")].image}{"\n"}'
kubectl -n "$NS" get daemonset web \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].image}{"\n"}'
kubectl -n "$NS" get hpa backend
curl --fail-with-body "$APP_URL/health/ready"
```

이전 정상 태그, DB 백업 위치, 배포 승인자와 변경 내용을 기록한다.

### 7.2 새 버전 배포

```bash
cd emoselfie-INFRA/ansible
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=../../emoselfie_key.pem \
  -e backend_tag=sha-새로운BE태그 \
  -e frontend_tag=sha-새로운FE태그
```

playbook은 기존 migrate Job을 삭제하고 새 migration을 먼저 실행한 뒤 Backend와 Web
rollout을 기다린다.

### 7.3 배포 후 검증

```bash
kubectl -n "$NS" rollout status deployment/backend --timeout=10m
kubectl -n "$NS" rollout status daemonset/web --timeout=5m
kubectl -n "$NS" get hpa backend
kubectl -n "$NS" get pods -o wide
curl --fail-with-body "$APP_URL/health/live"
curl --fail-with-body "$APP_URL/health/ready"
```

실행 중인 Pod의 image digest도 남긴다.

```bash
kubectl -n "$NS" get pods -l app=backend \
  -o jsonpath='{range .items[*]}{.metadata.name}{" backend="}{.status.containerStatuses[?(@.name=="backend")].imageID}{"\n"}{end}'
kubectl -n "$NS" get pods -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{" web="}{.status.containerStatuses[?(@.name=="web")].imageID}{"\n"}{end}'
```

마지막으로 4.4절의 2인 실제 게임과 추론까지 확인한다.

### 7.4 이미지 롤백

Kubernetes revision에만 의존하지 않고 직전 정상 SHA 태그로 Ansible을 다시 실행한다.

```bash
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=../../emoselfie_key.pem \
  -e backend_tag=sha-직전정상BE태그 \
  -e frontend_tag=sha-직전정상FE태그
```

주의:

- migration이 이미 적용된 뒤에는 이미지 롤백만으로 DB schema가 되돌아가지 않는다.
- down migration 또는 DB restore는 데이터 손실 가능성이 있는 별도 변경이다.
- migration은 가능하면 이전·신규 애플리케이션이 동시에 동작할 수 있는 후방 호환 방식으로
  설계한다.
- 복구 경로가 검증되지 않은 schema 변경은 운영에 배포하지 않는다.

---

## 8. 정기 운영 작업

### 8.1 ECR 인증 갱신

Ansible은 실행할 때마다 ECR pull Secret을 새 토큰으로 갱신한다. ECR 토큰은 단기
자격증명이므로 장기간 배포가 없던 중 새 노드가 이미지를 받아야 하면
`ImagePullBackOff`가 발생할 수 있다.

이 경우 이미지 태그와 IAM을 확인한 뒤 같은 `site.yml`을 다시 실행해 pull Secret을
갱신한다. 장기 운영에는 kubelet ECR credential provider 도입이 필요하다.

### 8.2 EC2 중지 후 재시작

비용 절감을 위해 세 인스턴스를 중지했다 켠 경우 다음 순서로 복구한다.

```bash
cd emoselfie-INFRA/terraform
terraform apply -refresh-only

cd ../ansible
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=../../emoselfie_key.pem \
  -e backend_tag=sha-현재BE태그 \
  -e frontend_tag=sha-현재FE태그
```

그 뒤 노드 3대, etcd quorum, PVC, HPA, readiness, ALB Target, 실제 게임을 확인한다.
중지 중에도 ALB, EBS와 Elastic IP 비용은 남는다.

### 8.3 서명 Secret 교체

Cookie, capture token, media token을 교체할 때는 다음 영향을 고려한다.

- Cookie Secret 교체는 기존 사용자 쿠키를 무효화할 수 있다.
- Capture/Media Secret 교체는 이미 발급된 토큰을 무효화한다.
- 애플리케이션은 `COOKIE_SECRET_PREVIOUS`를 지원하지만 현재 Ansible Secret에는 이 값이
  연결되어 있지 않다.
- Kubernetes Secret 변경만으로 실행 중 Backend가 새 환경 변수를 읽지 않는다.

승인된 작업 시간에 Vault를 수정하고 `site.yml`을 실행한 뒤 Backend를 재시작한다.

```bash
kubectl -n "$NS" rollout restart deployment/backend
kubectl -n "$NS" rollout status deployment/backend --timeout=10m
curl --fail-with-body "$APP_URL/health/ready"
```

PostgreSQL 비밀번호는 이 절차로 교체하지 않는다. DB role 비밀번호와 Kubernetes Secret을
한 작업으로 맞추는 별도 runbook이 필요하다.

### 8.4 팀원 SSH 계정

Vault에 공개키 목록을 넣은 뒤 실행한다.

```yaml
vault_ssh_users:
  - username: "gildong"
    public_key: "ssh-ed25519 AAAA... gildong@laptop"
```

```bash
ansible-playbook playbooks/users.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=../../emoselfie_key.pem
```

현재 k3s bootstrap은 서버의 `/etc/rancher/k3s/k3s.yaml`을 mode 0644로 생성한다. 이
파일은 cluster-admin 인증 정보이므로 서버 셸 계정을 가진 사용자가 읽을 수 있는 현재
설정은 보안 위험이다. 권한과 배포 자동화가 0600 기준으로 개선되기 전에는 팀원 셸 계정을
넓게 배포하지 않는다.

### 8.5 정기 점검 권장 주기

| 주기 | 확인 항목 |
|---|---|
| 배포마다 | 태그/digest, migration, rollout, readiness, 실제 게임, 오류 로그 |
| 매일 또는 서비스 운영일 | 노드/Pod 상태, 재시작, HPA, PVC, ALB Target, 5xx |
| 매주 | CPU·Memory·디스크 추세, 인증서 만료일, 백업 생성과 복원 검증 결과 |
| 매월 | AWS 비용, IAM/SSH 사용자, k3s/OS 보안 업데이트, 미사용 리소스 |

---

## 9. 장애 발생 시 기본 점검 순서

장애가 생기면 증상과 최초 실패 시각을 먼저 기록하고 아래 순서를 지킨다.

### 9.1 1단계: 외부 영향 범위

```bash
curl -I http://emoselfie.click
curl -i "$APP_URL/health/live"
curl -i "$APP_URL/health/ready"
```

- DNS/TLS도 실패: Route 53, ACM, ALB부터 확인한다.
- live 실패, ready 실패: Backend 또는 Ingress 경로를 확인한다.
- live 성공, ready 503: DB, Redis, inference check 중 `false`인 항목을 우선한다.
- health 정상, 게임만 실패: Origin, WebSocket, 세션 고정, 실제 API 로그를 확인한다.

### 9.2 2단계: 노드와 Pod

```bash
kubectl get nodes -o wide
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" describe pod <pod-name>
```

상태별 최초 확인:

| 상태 | 먼저 확인할 것 |
|---|---|
| `ImagePullBackOff` | ECR 태그, pull Secret 만료, IAM과 네트워크 |
| `CrashLoopBackOff` | 현재/이전 로그, Secret, DB/Redis, 모델 로드 |
| `Init:Error` | `wait-dependencies`, `prepare-models` 로그 |
| `Pending` | 노드 자원, topology spread, PVC가 묶인 노드 |
| `OOMKilled` | limit, 메모리 추세, 동시 추론량 |
| `NotReady` 노드 | EC2 상태, k3s, 디스크, 네트워크, etcd quorum |

### 9.3 3단계: Event

```bash
kubectl -n "$NS" get events --sort-by=.lastTimestamp
kubectl -n kube-system get events --sort-by=.lastTimestamp
```

이미지 pull, Secret/ConfigMap 없음, probe 실패, volume mount, scheduling 실패를 본다.

### 9.4 4단계: 로그

```bash
kubectl -n "$NS" logs <backend-pod-name> -c backend --tail=200 --timestamps
kubectl -n "$NS" logs <backend-pod-name> -c backend --previous --tail=200 --timestamps
kubectl -n "$NS" logs job/migrate --tail=200 --timestamps
```

Job이 TTL로 삭제되었다면 배포 당시 Ansible 출력과 외부에 보존한 로그를 사용한다.

### 9.5 5단계: Service와 EndpointSlice

```bash
kubectl -n "$NS" get svc
kubectl -n "$NS" get endpointslice \
  -l kubernetes.io/service-name=backend -o wide
kubectl -n "$NS" get endpointslice \
  -l kubernetes.io/service-name=web -o wide
```

Endpoint가 비면 Service selector, Pod label, readiness 실패를 확인한다.

### 9.6 6단계: Ingress, Traefik과 ALB

```bash
kubectl -n "$NS" get ingress -o wide
kubectl -n "$NS" describe ingress emoselfie
kubectl -n kube-system get deployment traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
```

정상 경로:

- `/api`, `/media`, `/socket.io`, `/health` -> `backend:8000`
- `/`와 나머지 -> `web:80`

`FORBIDDEN_ORIGIN` 또는 WebSocket 403이면 Traefik 인자에
`entryPoints.web.forwardedHeaders.trustedIPs`가 있고 현재 VPC CIDR과 k3s Pod CIDR이
맞는지 확인한다. 임의로 `insecure: true`를 사용하지 않는다.

ALB Target이 unhealthy면 3.7절의 Target 상태와 reason을 확인한다.

### 9.7 7단계: 자원, PVC와 데이터 계층

```bash
kubectl top node
kubectl -n "$NS" top pod
kubectl -n "$NS" get pvc -o wide
kubectl -n "$NS" get statefulset
kubectl describe node <node-name>
```

PostgreSQL PVC가 붙은 노드가 죽으면 Pod가 다른 노드에 단순 재스케줄되지 않는다. 이
상황에서 PVC나 StatefulSet을 임의 삭제하면 데이터 복구 가능성을 낮출 수 있으므로 먼저
중단하고 백업/복구 담당자에게 에스컬레이션한다.

### 9.8 8단계: ConfigMap과 Secret 참조

```bash
kubectl -n "$NS" get configmap
kubectl -n "$NS" describe configmap backend-env
kubectl -n "$NS" get secret
kubectl -n "$NS" get deployment backend -o yaml
```

Secret 값 자체를 화면이나 티켓에 출력하지 않는다. 존재, key 이름, workload 참조만 본다.

운영 핵심 설정:

- `APP_ENV=production`
- `ALLOW_INSECURE_COOKIE=false`
- `INFERENCE_BACKEND=real`
- `DATABASE_URL`은 `postgres:5432`
- `REDIS_URL`은 Sentinel 3개와 `mymaster`
- `REDIS_MEDIA_URL`은 `redis-media:6379`

### 9.9 노드 장애 시 주의

- 한 server 장애: 나머지 2대가 etcd quorum을 유지해 서비스는 계속될 수 있다.
- 2대 장애: etcd가 과반을 잃어 Kubernetes API 쓰기와 스케줄링이 중단된다.
- 첫 server 장애: 워크로드는 남을 수 있지만 kubeconfig와 Ansible이 첫 server의 EIP를
  사용하므로 운영 접근이 막힌다. 모든 server 인증서에는 EIP SAN이 들어 있어 EIP를 다른
  server로 옮길 수 있지만 Terraform drift를 만들 수 있으므로 승인된 복구 절차로 수행한다.
- PostgreSQL 노드 장애: 클러스터가 살아도 DB 때문에 전체 서비스가 not ready가 될 수 있다.

---

## 10. 백업과 복구

### 10.1 현재 상태

저장소에는 다음이 구현되어 있지 않다.

- PostgreSQL 자동 스케줄 백업
- 클러스터 밖의 백업 저장소와 보존 정책
- 자동 복원 Job
- 정기 복원 훈련
- k3s/etcd snapshot의 외부 보관 절차

따라서 운영 개시 전에 RPO, RTO, 백업 주기, 암호화, 보존 기간, 복원 담당자와 검증 환경을
정해야 한다. `terraform destroy` 또는 EC2 교체 시 root EBS가 삭제되므로 local-path의
PostgreSQL과 Redis 데이터도 함께 사라질 수 있다.

### 10.2 수동 PostgreSQL 논리 백업 예시

변경 작업 직전 최소 백업 예시는 다음과 같다. 출력 파일은 클러스터 밖의 암호화되고 접근
통제된 경로에 둔다. archive 확인 명령을 실행할 로컬 PC에는 PostgreSQL 16과 호환되는
`pg_restore`가 필요하다.

```bash
export BACKUP_FILE=/보안경로/emoselfie-before-deploy.dump
kubectl -n "$NS" exec postgres-0 -- \
  sh -c 'pg_dump --format=custom -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > "$BACKUP_FILE"
pg_restore --list "$BACKUP_FILE" | head
```

명령 성공, 파일 크기가 0보다 큼, `pg_restore --list`가 archive를 읽는 것을 확인한다.
이 확인은 실제 복원 성공을 보장하지 않는다. 별도 격리 환경에 정기적으로 복원해
애플리케이션 조회까지 검증해야 한다.

### 10.3 복구 원칙

실운영 DB 복원은 기존 데이터를 덮는 파괴적 작업이다. 검증되지 않은 즉석 명령으로
수행하지 않는다. 다음 조건이 갖춰진 별도 복구 runbook을 사용한다.

1. 쓰기 트래픽 중단과 공지
2. 현재 장애 상태의 보존용 백업
3. 대상 DB와 백업 시점 확인
4. 격리 환경에서 restore 검증
5. 운영 restore 승인
6. migration version 확인
7. readiness와 실제 게임 검증
8. 서비스 재개와 사후 기록

---

## 11. 현재 운영 위험과 개선 과제

인수인계 시 아래 항목을 숨기지 않고 운영 책임자에게 전달한다.

| 위험 | 현재 영향 | 권장 개선 |
|---|---|---|
| PostgreSQL 단일 인스턴스 + local-path | 해당 노드 장애 시 서비스 중단 | RDS 또는 CloudNativePG, 검증된 백업/복원 |
| 자동 off-host 백업 없음 | 노드 교체·삭제 시 데이터 유실 | 주기 백업, 암호화 저장, 복원 훈련 |
| 중앙 로그·메트릭·경보 없음 | 장애를 사용자가 먼저 발견할 수 있음 | Prometheus/Grafana, 로그 수집, 알림 |
| ECR 토큰 수동 갱신 | 장기간 뒤 새 Pod pull 실패 가능 | kubelet ECR credential provider |
| 모델 hostPath | 새 노드에서 외부 다운로드 필요 | checksum 고정 모델 이미지로 내장 |
| Backend HPA가 CPU만 사용 | 갑작스러운 요청과 queue를 늦게 반영 | 추론 queue/latency custom metric |
| 데이터 서비스 resource 제한 없음 | 노드 압박 시 예측 어려움 | 측정 후 request/limit 설정 |
| `PARTICIPANT_GRACE_SEC=86400` | 이탈 사용자가 슬롯을 24시간 점유 가능 | 운영 정책 확인 후 기본 60초 복원 |
| Secret 변경 시 자동 재시작 없음 | 새 값과 기존 Pod 값 불일치 | checksum annotation 또는 rollout 자동화 |
| PostgreSQL 비밀번호 rotation runbook 없음 | Vault와 실제 DB 불일치 위험 | 무중단/점검시간 교체 절차 작성 |
| k3s kubeconfig 서버 mode 0644 | 서버 셸 사용자가 cluster-admin 획득 가능 | 0600으로 변경하고 역할별 접근 분리 |
| Kubernetes Secret at-rest 암호화 미설정 | etcd 접근 시 Secret 노출 가능 | k3s secrets encryption 활성화 및 회전 |
| 일부 이미지 태그가 mutable | 재배포 결과가 달라질 수 있음 | 모든 base image digest 고정 |
| PDB 없음 | 유지보수 시 가용 Pod 동시 축소 가능 | Backend와 중요 데이터 계층 정책 검토 |

---

## 12. 배포 결과 기록 양식

```text
배포 시작/종료 시각:
배포자 / 승인자:
AWS Account / Region:
INFRA Git commit:
BE 이미지 태그 / digest:
FE 이미지 태그 / digest:
이전 정상 BE/FE 태그:
Terraform plan 요약:
DB 백업 경로 / 검증 결과:
Migration 결과:
노드 Ready 수:
Backend 현재/목표 Replica:
Web Ready 수:
PostgreSQL / Redis / Sentinel 상태:
ALB healthy Target 수:
/health/live 결과:
/health/ready 결과:
실제 게임 및 추론 결과:
오류 로그 유무:
롤백 여부와 결과:
특이사항 / 후속 작업:
```

장애 기록 양식:

```text
장애 시작/인지/복구 시각:
확인자:
사용자 증상과 영향 범위:
마지막 정상 시각:
마지막 배포 태그:
최초 실패 계층(DNS/ALB/Ingress/App/DB/Redis/Node):
확인한 명령과 주요 출력:
임시 조치:
근본 원인:
재발 방지 작업과 담당자:
```

## 13. 빠른 정상 확인

```bash
kubectl get nodes
kubectl -n "$NS" get deploy,statefulset,daemonset,hpa,pods,pvc
kubectl -n "$NS" get events --sort-by=.lastTimestamp
curl --fail-with-body "$APP_URL/health/live"
curl --fail-with-body "$APP_URL/health/ready"
```

배포가 정상이라고 판단하는 최소 기준:

- k3s 노드 3대가 `Ready`다.
- Backend Ready 수가 HPA의 현재 목표 수와 같다.
- Web DaemonSet이 정상 노드마다 Ready다.
- PostgreSQL 1/1, Redis 3/3, Sentinel 3/3, redis-media 1/1이다.
- PVC가 모두 `Bound`다.
- migration이 성공했다.
- `/health/live`가 HTTP 200과 `status=ok`를 반환한다.
- `/health/ready`가 HTTP 200, `status=ready`, `inferenceBackend=real`을 반환한다.
- ALB Target 3대가 healthy다.
- 실제 2인 게임에서 HTTP 202 이후 `submission:scored`와 점수·순위가 표시된다.
- 반복 재시작, 지속적인 5xx, `OOMKilled`, probe 실패가 없다.
