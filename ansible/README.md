# Ansible 운영 배포

Terraform이 EC2 생성, 노드 패키지 설치, k3s server 3대 구성을 담당한다. 이
Ansible playbook은 **로컬 Mac에서** Terraform이 만든 클러스터로 애플리케이션을
배포한다. EC2에 Ansible로 직접 로그인해 k3s를 다시 설치하지 않는다.

한 번 실행하면 다음 순서로 동작한다.

1. 로컬 작업 트리가 `origin/main`과 같은지 확인, 다르면 경고 후 yes/no
2. 노드마다 SSH 호스트 키를 검증해 `.generated/known_hosts`에 기록
3. server 노드에 Traefik forwarded-header 설정을 놓고 반영을 기다림
4. Terraform output에서 k3s server 공인 IP 확인
5. server의 kubeconfig를 로컬 `.generated/`로 복사
6. 세 노드가 모두 `Ready`인지 확인
7. namespace와 애플리케이션 Secret 생성 또는 갱신
8. 새 ECR 로그인 토큰으로 image pull Secret 갱신
9. BE/FE SHA 태그를 임시 Kustomize 오버레이에 주입
10. 이전 migrate Job 삭제 후 매니페스트 적용
11. migration, backend, web 준비 완료까지 대기

## 1. Ansible 설치

```bash
brew install ansible
ansible-playbook --version
```

로컬에 `terraform`, `kubectl`, `aws`, `scp`, `git`도 있어야 한다.

## 2. Secret Vault 만들기

네 비밀값은 Git에 평문으로 두지 않는다. 각각 다른 값을 생성한다.

```bash
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

다음 명령은 편집기를 열고, 저장할 때 내용을 암호화한다.

```bash
cd ansible
ansible-vault create group_vars/all/vault.yml
```

이 Vault 파일은 `playbooks/site.yml`의 `vars_files`에서 명시적으로 읽는다. inventory가
`inventory/` 하위에 있어 Ansible의 기본 `group_vars` 자동 탐색 경로와 다르기
때문이다.

편집기에 아래 형식으로 입력한다. 위에서 생성한 서로 다른 값을 사용한다.

```yaml
vault_postgres_password: "..."
vault_cookie_secret: "..."
vault_capture_token_secret: "..."
vault_media_token_secret: "..."
```

세 k3s 노드에 팀원별 SSH 계정을 만들려면 같은 Vault 파일에 계정명과 공개키를
추가한다. 개인키는 넣지 않는다.

```yaml
vault_ssh_users:
  - username: "gildong"
    public_key: "ssh-ed25519 AAAA... gildong@laptop"
```

기존 Vault를 수정할 때는 다음 명령을 사용한다.

```bash
ansible-vault edit group_vars/all/vault.yml
```

계정과 공개키를 세 노드에 적용한다. Terraform의 `node_public_ips` 출력으로 대상
인스턴스를 자동 구성하며, 생성된 팀원 계정에는 sudo 권한을 부여하지 않는다.

```bash
ansible-playbook playbooks/users.yml --ask-vault-pass
```

Vault 파일은 `.gitignore`에 포함되어 있다. 암호화 파일을 팀에서 공유하려면 ignore
정책을 바꾸기 전에 저장소의 비밀 관리 방식을 먼저 정한다.

## 3. 이미지 태그 확인

BE GitHub Actions가 기록한 두 이미지의 태그는 같은 값이다.

```text
082139775699.dkr.ecr.ap-northeast-2.amazonaws.com/emoselfie-be:sha-aaaaaaaaaaaa
082139775699.dkr.ecr.ap-northeast-2.amazonaws.com/emoselfie-be-models:sha-aaaaaaaaaaaa
```

FE 태그는 별도 커밋 SHA다.

```text
082139775699.dkr.ecr.ap-northeast-2.amazonaws.com/emoselfie-fe:sha-bbbbbbbbbbbb
```

태그는 반드시 `sha-`와 소문자 16진수 12자리 형식이어야 한다. playbook이 잘못된
형식을 배포 전에 거부한다.

## 4. 배포

Terraform apply와 k3s 부팅이 먼저 끝나 있어야 한다.

```bash
cd ansible
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e backend_tag=sha-aaaaaaaaaaaa \
  -e frontend_tag=sha-bbbbbbbbbbbb
```

기본 SSH 키 경로는 저장소 상위의 `project1_key.pem`이다. 다른 키 위치를 쓰려면
실행 시 덮어쓴다.

```bash
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e ssh_private_key_file=/다른/경로/project1_key.pem \
  -e backend_tag=sha-aaaaaaaaaaaa \
  -e frontend_tag=sha-bbbbbbbbbbbb
```

### 배포 전 Git 상태 확인

playbook은 Git에서 아무것도 받지 않고 **실행하는 사람의 로컬 작업 트리**를 그대로
배포한다. 그래서 `traefik.yml`(그리고 이를 먼저 가져오는 `site.yml`)은 노드에 손대기 전에
`git fetch origin main` 후 다음을 확인한다.

- `HEAD`가 `origin/main`과 같은 커밋인가
- 미커밋·미추적 변경이 없는가

둘 다 맞으면 아무것도 묻지 않는다. 하나라도 다르면 두 커밋과 변경 파일 목록을
보여 주고 `그래도 계속할까요? (yes/no)`를 묻는다. `yes`만 계속하고, 그 외 입력이나
Enter는 중단한다. 터미널이 아닌 곳(CI 등)에서는 입력을 받을 수 없어 바로 중단되므로,
의도한 상태라면 `-e skip_git_check=true`로 건너뛴다.

```bash
ansible-playbook playbooks/site.yml \
  --ask-vault-pass \
  -e skip_git_check=true \
  -e backend_tag=sha-aaaaaaaaaaaa \
  -e frontend_tag=sha-bbbbbbbbbbbb
```

## SSH 호스트 키 검증

`playbooks/known-hosts.yml`이 담당한다. `traefik.yml`과 `users.yml`이 맨 앞에서
가져오므로 `site.yml`을 포함한 모든 배포가 이 검증을 먼저 거친다. 단독 실행도 된다.

```bash
cd ansible
ansible-playbook playbooks/known-hosts.yml
```

### 왜 필요한가

인스턴스를 교체하면 EIP 덕분에 주소는 그대로인데 호스트 키는 새로 생긴다. SSH는
같은 주소에 다른 키가 오면 중간자 공격일 수 있다며 접속을 거부한다. 검사를 끄면
이 경고와 실제 공격을 구분할 수 없으므로 끄지 않고 검증을 자동화했다.

### 신뢰 기준

노드마다 `ssh-keyscan`으로 받은 키를 둘 중 하나와 대조한다.

| 경우 | 대조 대상 |
|---|---|
| 이 프로젝트가 전에 신뢰한 키와 같다 (중지 후 시작) | `.generated/known_hosts` |
| 그 밖의 경우 (인스턴스 교체·신규, 다른 컴퓨터에서 첫 배포) | EC2 부팅 로그에 남은 지문 |

부팅 로그는 SSH를 거치지 않고 AWS API(`ec2:GetConsoleOutput`)로 가져오므로 중간에서
바꿀 수 없다. 둘 다 맞지 않으면 **한 대라도 멈추고 파일을 쓰지 않는다.**

통과한 키만으로 파일 전체를 다시 쓰고, 쓴 뒤 `ssh-keygen -l`로 다시 읽어 노드마다
하나씩 들어갔는지 확인한다. 교체된 인스턴스의 옛 키는 남지 않는다.

다른 playbook은 `UserKnownHostsFile=.generated/known_hosts`와
`StrictHostKeyChecking=yes`로 접속한다. 사용자의 `~/.ssh/known_hosts`는 쓰지도
고치지도 않는다.

### 부팅할 때마다 지문을 남긴다

cloud-init은 **인스턴스의 첫 부팅에만** 지문을 부팅 로그에 남긴다(`keys_to_console`이
`PER_INSTANCE`). 그대로 두면 중지 후 시작한 인스턴스를 이 컴퓨터에서 한 번도 검증한 적이
없을 때(다른 컴퓨터에서 처음 배포하는 경우 등) 대조할 기준이 없다.

그래서 이 playbook은 검증을 마친 노드에
`/var/lib/cloud/scripts/per-boot/emoselfie-print-ssh-host-keys.sh`를 설치한다
(원본은 `ansible/files/print-ssh-host-keys.sh`). cloud-init의 `scripts_per_boot`가 매
부팅 실행해 cloud-init과 같은 형식으로 지문을 `/dev/console`에 남기므로, 중지 후
시작해도 부팅 로그로 검증할 수 있다. 콘솔에 쓴 내용이 부팅 로그 API에 보이기까지 30초
안팎이 걸려 playbook이 기다렸다가 다시 조회한다.

### 그래도 검증할 수 없는 경우

- 인스턴스를 만든 뒤 이 playbook을 한 번도 돌리지 않은 채 중지 후 시작했다. 스크립트가
  아직 없다
- 부팅 직후라 부팅 로그에 아직 반영되지 않았다. 몇 분 뒤 다시 실행한다

앞의 경우에는 이미 검증한 팀원의 `ansible/.generated/known_hosts`를 받아 같은 위치에
넣는다. 서버의 공개키만 들어 있어 비밀은 아니지만, 바꿔치기되면 안 되므로 믿을 수 있는
경로로 주고받는다.

EC2 Instance Connect(브라우저 접속)와 Session Manager는 지금 구성으로는 쓸 수 없다.
보안 그룹이 22번을 `admin_cidr`에서만 허용하고, 노드 IAM 역할에 SSM 권한이 없다.

## Traefik forwarded-header 설정

`playbooks/traefik.yml`이 담당한다. `site.yml`이 맨 앞에서 가져오므로 배포할 때
따로 실행할 필요는 없다. 클러스터를 새로 만든 뒤 설정만 넣고 싶으면 단독으로
실행한다. Vault를 읽지 않아 `--ask-vault-pass`가 필요 없다.

```bash
cd ansible
ansible-playbook playbooks/traefik.yml
```

### 무엇을 하는가

앞단이 보낸 `X-Forwarded-Proto: https`를 Traefik이 실제 연결 스킴인 `http`로
덮어쓰면, backend의 same-origin 검사가 어긋나 `/api/` POST가 전부
`FORBIDDEN_ORIGIN`이 되고 websocket 업그레이드가 403이 된다(이슈 #11).

playbook은 server 노드에 파일 하나를 놓는다.

```
/var/lib/rancher/k3s/server/manifests/traefik-config.yaml
```

k3s의 deploy 컨트롤러가 이 디렉터리를 감시하다가 `HelmChartConfig`를 만들고,
내장 Helm 컨트롤러가 Traefik 차트의 values에 병합해 Deployment를 갱신한다.
**k3s를 재시작하지 않는다.** Traefik을 `kubectl edit`으로 직접 고치면 Helm
컨트롤러가 되돌리고, k3s가 설치한 `traefik.yaml`을 고치면 k3s 업그레이드 때
사라진다. 이 방식은 둘 다 피하면서 노드를 다시 만들어도 Ansible이 복원한다.

`HelmChartConfig`는 이름과 네임스페이스가 대상 `HelmChart`(`kube-system/traefik`)와
모두 같아야 매칭된다. 어긋나면 **에러 없이 조용히 무시되므로** 템플릿의
`metadata`는 바꾸지 않는다. Kustomize 오버레이에 넣지 못하는 이유도 같다.
오버레이의 `namespace:` 설정이 네임스페이스를 덮어써 매칭이 깨진다.

### 신뢰 범위

기본값은 두 개다. Terraform의 `vpc_cidr` output과 `k3s_cluster_cidr`
(`group_vars/all/main.yml`, k3s 기본값 `10.42.0.0/16`)이다.

**두 대역이 모두 필요하다.** ALB는 VPC 안에서 요청을 보내지만, k3s ServiceLB의
svclb pod가 중계하면서 출발지를 자기 pod IP로 바꾼다. 그래서 Traefik이 실제로 보는
주소는 pod 대역이다. VPC 대역만 신뢰하면 Traefik이 ALB의 헤더를 버리고 `http`로
덮어써서 `/api/` POST가 전부 `FORBIDDEN_ORIGIN`이 된다. 실제로 그렇게 겪었다.

실행 시 덮어쓸 수 있다.

```bash
ansible-playbook playbooks/traefik.yml -e '{"traefik_trusted_ips":["10.0.0.0/16"]}'
```

`insecure: true`는 쓰지 않는다. "누가 보내든 `X-Forwarded-*`를 믿는다"는 뜻이라
노드에 직접 닿을 경로가 하나라도 있으면 헤더를 위조할 수 있다.

> 앞단을 바꾸면 이 값을 다시 맞춰야 한다. Cloudflare Tunnel처럼 `cloudflared`가
> 클러스터 안에서 도는 구성이라면 pod 대역만으로 충분하고, 노드에서 직접 도는
> 구성이라면 VPC 대역이 쓰인다.

### 확인

```bash
KUBECONFIG=ansible/.generated/k3s-prod.yaml \
  kubectl -n kube-system get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ' ' '\n' | grep forwardedHeaders
```

브라우저에서 방 만들기(`POST /api/rooms`)와 websocket 연결까지 확인한다. `curl`은
`Origin` 헤더를 보내지 않아 검사가 건너뛰어지므로 재현되지 않는다.

## 재배포

새 이미지 SHA로 같은 명령을 다시 실행한다. 기존 리소스에는
`kubectl apply`가 사용되므로 필요한 차이만 반영한다. migrate Job은 Kubernetes에서
spec 수정이 불가능해 매 배포마다 삭제하고 다시 만든다.

Ansible은 실행할 때마다 ECR 로그인 토큰도 새로 만든다. ECR 토큰은 단기
자격증명이므로 장시간 Ansible 배포가 없는 동안 새 노드가 이미지를 받아야 하는
상황까지 처리하려면 이후 kubelet ECR credential provider를 추가해야 한다.

## 생성되는 로컬 파일

`ansible/.generated/`에 다음 파일을 만든다.

- 검증한 노드 SSH 호스트 키 (`known_hosts`)
- 운영 관리자 kubeconfig
- 실제 ECR SHA 태그가 들어간 임시 Kustomize 오버레이

모두 Git에서 제외된다. kubeconfig는 클러스터 관리자 인증 정보이므로 외부에
공유하지 않는다.

## 문제 확인

Ansible이 중간에 실패하면 같은 명령을 다시 실행해도 된다. 먼저 현재 상태를 직접
보고 싶다면:

```bash
KUBECONFIG=ansible/.generated/k3s-prod.yaml kubectl get nodes
KUBECONFIG=ansible/.generated/k3s-prod.yaml kubectl -n emoselfie get pods,pvc,ingress
```
