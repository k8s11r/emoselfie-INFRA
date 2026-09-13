# Ansible 운영 배포

Terraform이 EC2 생성, 노드 패키지 설치, k3s server/agent 구성을 담당한다. 이
Ansible playbook은 **로컬 Mac에서** Terraform이 만든 클러스터로 애플리케이션을
배포한다. EC2에 Ansible로 직접 로그인해 k3s를 다시 설치하지 않는다.

한 번 실행하면 다음 순서로 동작한다.

1. Terraform output에서 k3s server 공인 IP 확인
2. server의 kubeconfig를 로컬 `.generated/`로 복사
3. 세 노드가 모두 `Ready`인지 확인
4. Longhorn 설치 또는 갱신
5. namespace와 애플리케이션 Secret 생성 또는 갱신
6. 새 ECR 로그인 토큰으로 image pull Secret 갱신
7. BE/FE SHA 태그를 임시 Kustomize 오버레이에 주입
8. 이전 migrate Job 삭제 후 매니페스트 적용
9. migration, backend, web 준비 완료까지 대기

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
