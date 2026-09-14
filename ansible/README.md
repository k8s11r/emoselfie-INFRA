# Ansible 운영 배포

Terraform이 EC2 생성, 노드 패키지 설치, k3s server/agent 구성을 담당한다. 이
Ansible playbook은 **로컬 Mac에서** Terraform이 만든 클러스터로 애플리케이션을
배포한다. EC2에 Ansible로 직접 로그인해 k3s를 다시 설치하지 않는다.

한 번 실행하면 다음 순서로 동작한다.

1. server 노드에 Traefik forwarded-header 설정을 놓고 반영을 기다림
2. Terraform output에서 k3s server 공인 IP 확인
3. server의 kubeconfig를 로컬 `.generated/`로 복사
4. 세 노드가 모두 `Ready`인지 확인
5. Longhorn 설치 또는 갱신
6. namespace와 애플리케이션 Secret 생성 또는 갱신
7. 새 ECR 로그인 토큰으로 image pull Secret 갱신
8. BE/FE SHA 태그를 임시 Kustomize 오버레이에 주입
9. 이전 migrate Job 삭제 후 매니페스트 적용
10. migration, backend, web 준비 완료까지 대기

## 1. Ansible 설치

```bash
brew install ansible
ansible-playbook --version
```

로컬에 `terraform`, `kubectl`, `aws`, `scp`도 있어야 한다.

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

기본값은 Terraform의 `vpc_cidr` output이다. 로드밸런서가 VPC 안에서 요청을
보낸다는 전제이며, 실행 시 덮어쓸 수 있다.

```bash
ansible-playbook playbooks/traefik.yml -e '{"traefik_trusted_ips":["10.0.0.0/16"]}'
```

`insecure: true`는 쓰지 않는다. "누가 보내든 `X-Forwarded-*`를 믿는다"는 뜻이라
노드에 직접 닿을 경로가 하나라도 있으면 헤더를 위조할 수 있다.

> **현재 구성에서의 한계** — `terraform/load-balancer.tf`가 만드는 것은 ALB가
> 아니라 TCP 리스너를 쓰는 **NLB(L4)**다. L4는 `X-Forwarded-*`를 붙이지 않고,
> instance 대상 NLB는 클라이언트 IP를 보존하므로 Traefik이 보는 출발지는 VPC가
> 아니라 브라우저의 공인 IP다. 즉 지금은 이 설정이 **동작하지 않는 것이 아니라
> 쓰일 일이 없다**(무해하게 통과된다). 앞단을 ALB로 바꾸거나 Cloudflare Tunnel을
> 붙이는 순간 필요해지고, 그때 `vpc_cidr` 기본값이 맞는 값이 된다.

### 확인

```bash
KUBECONFIG=ansible/.generated/k3s-prod.yaml \
  kubectl -n kube-system get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ' ' '\n' | grep forwardedHeaders
```

브라우저에서 방 만들기(`POST /api/rooms`)와 websocket 연결까지 확인한다. `curl`은
`Origin` 헤더를 보내지 않아 검사가 건너뛰어지므로 재현되지 않는다.

## 재배포

새 이미지 SHA로 같은 명령을 다시 실행한다. Longhorn과 기존 리소스에는
`kubectl apply`가 사용되므로 필요한 차이만 반영한다. migrate Job은 Kubernetes에서
spec 수정이 불가능해 매 배포마다 삭제하고 다시 만든다.

Ansible은 실행할 때마다 ECR 로그인 토큰도 새로 만든다. ECR 토큰은 단기
자격증명이므로 장시간 Ansible 배포가 없는 동안 새 노드가 이미지를 받아야 하는
상황까지 처리하려면 이후 kubelet ECR credential provider를 추가해야 한다.

## 생성되는 로컬 파일

`ansible/.generated/`에 다음 파일을 만든다.

- 운영 관리자 kubeconfig
- 실제 ECR SHA 태그가 들어간 임시 Kustomize 오버레이

둘 다 Git에서 제외된다. kubeconfig는 클러스터 관리자 인증 정보이므로 외부에
공유하지 않는다.

## 문제 확인

Ansible이 중간에 실패하면 같은 명령을 다시 실행해도 된다. 먼저 현재 상태를 직접
보고 싶다면:

```bash
KUBECONFIG=ansible/.generated/k3s-prod.yaml kubectl get nodes
KUBECONFIG=ansible/.generated/k3s-prod.yaml kubectl -n emoselfie get pods,pvc,ingress
```
