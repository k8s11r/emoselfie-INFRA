# EC2 k3s 인프라

서울 리전의 기존 기본 VPC에 EC2 세 대를 만들고, 부팅 과정에서 k3s 클러스터를
구성한다.

- server 1대, agent 2대
- Ubuntu 24.04 amd64 최신 AMI
- 기본 `t3.medium`, 노드별 암호화된 gp3 30 GiB
- 기존 EC2 키페어 `project1_key` 사용
- 서로 다른 가용 영역의 기본 퍼블릭 서브넷 3개 사용
- 세 노드를 대상으로 하는 인터넷-facing AWS Application Load Balancer 사용
- ACM 인증서로 ALB에서 TLS를 종료하고 `emoselfie.click`을 alias 레코드로 연결
- 노드 IAM 역할에 `AmazonEC2ContainerRegistryReadOnly` 연결
- Longhorn의 호스트 선행 패키지(`open-iscsi`, `nfs-common`) 설치

기존 `team1_first_project` 인스턴스는 이 Terraform 상태에 포함하지 않으므로
수정하거나 삭제하지 않는다.

## 사전 조건

- AWS CLI가 `terraform` IAM 사용자로 인증돼 있어야 한다.
- 이 사용자에게 EC2 리소스와 제한된 IAM 역할/인스턴스 프로파일을 만들고
  `iam:PassRole`을 수행할 권한이 있어야 한다.
- `project1_key.pem` 개인 키를 로컬에서 보관하고 있어야 한다. Terraform은 AWS에
  등록된 공개 키 이름만 참조하며 개인 키 파일을 읽거나 저장하지 않는다.

## 실행

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`의 `admin_cidr`를 현재 공인 IPv4의 `/32` CIDR로 바꾼다. 이 값은
SSH(22)와 Kubernetes API(6443)에 접근할 수 있는 범위다. `0.0.0.0/0`은 검증에서
거부한다.

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

ALB가 443에서 TLS를 종료하고 세 EC2 노드의 80 포트로 평문 HTTP를 전달한다. 80으로
들어온 요청은 443으로 301 리다이렉트한다. 카메라 API가 secure context를 요구하므로
(PM-14) 평문으로 서비스되는 경로를 남기지 않는다.

노드 보안 그룹은 80을 ALB 보안 그룹에서만 허용하므로 노드 공인 IP로 애플리케이션에
직접 접근할 수 없다. SSH(22)와 Kubernetes API(6443)는 기존처럼 `admin_cidr`에서만
접근할 수 있다.

애플리케이션 접속 주소는 다음 출력으로 확인한다.

```bash
terraform output -raw application_url
```

Target Group은 Traefik Ingress를 통과하는 `/health/live` 요청으로 각 노드의 상태를
확인한다. FE는 WebSocket 우선이다. polling 사용 시 ALB 쿠키는 노드를,
Traefik의 `es_route` 쿠키는 backend Pod를 선택한다. Service의 `ClientIP` affinity는 사용하지 않는다.

ALB는 `X-Forwarded-Proto: https`를 붙여 보낸다. Traefik이 이 헤더를 신뢰하도록
`ansible/playbooks/traefik.yml`이 설정하며, 그것이 없으면 `/api/` POST가
`FORBIDDEN_ORIGIN`으로 막힌다(이슈 #11).

`apply`가 끝났다고 k3s 부팅까지 끝난 것은 아니다. 일반적으로 몇 분이 더 필요하다.
진행 상태는 server에서 확인한다.

```bash
ssh -i /실제/경로/project1_key.pem ubuntu@$(terraform output -raw server_public_ip)
sudo tail -f /var/log/emoselfie-bootstrap.log
sudo k3s kubectl get nodes -o wide
```

로컬 kubeconfig 복사 명령은 다음 출력에서 확인한다.

```bash
terraform output -raw kubeconfig_command
```

출력의 `/path/to/project1_key.pem`을 실제 개인 키 경로로 바꿔 실행한다.

## 중요한 동작

- 정확한 `k3s_version`을 지정하지 않으면 생성 시점의 `stable` 채널을 설치한다.
  운영에 들어가기 전 실제 설치 버전을 확인하고 변수에 고정하는 것이 좋다.
- 자동 생성된 클러스터 조인 토큰과 전체 user data가 로컬 Terraform state에
  저장된다. state를 Git에 커밋하거나 외부에 공유하면 안 된다.
- `user_data`가 바뀌면 해당 EC2가 교체된다. 먼저 `terraform plan`의 교체 표시를
  확인한다.
- server에는 Elastic IP를 붙여 중지 후 시작해도 주소가 유지된다. k3s가 부팅 때
  `--tls-san`으로 인증서에 주소를 박기 때문에, 주소가 바뀌면 kubectl이 TLS 검증에서
  막히고 kubeconfig와 Ansible 인벤토리까지 함께 틀어진다. agent는 공인 IP로
  통신하지 않으므로 고정하지 않았고, 중지 후 시작하면 주소가 바뀐다. 필요하면
  Terraform 출력에서 확인한다.
- ACM 인증서는 Terraform이 만들지 않고 `data`로 찾기만 한다. 도메인 소유 검증이
  필요해 콘솔에서 한 번 발급해 두는 편이 단순하다. **ALB와 같은 리전
  (`ap-northeast-2`)에 있어야 한다.** 다른 리전의 인증서는 찾지 못해 plan에서
  실패한다.
- 로드밸런서 보안 그룹의 이름은 `-nlb`로 남아 있다. 보안 그룹의 이름과 설명은
  변경 불가 속성이라 고치면 보안 그룹이 교체되고 이를 참조하는 노드 규칙까지
  연쇄로 교체된다. 클러스터를 새로 만들 때 함께 정리한다.
- EC2 인스턴스 프로파일은 ECR API 권한만 제공한다. kubelet이 만료되는 ECR
  인증을 자동 갱신하도록 하는 credential provider 구성은 애플리케이션 배포
  단계에서 별도로 추가하고 검증한다.

## 중지와 재시작

비용을 아끼려고 인스턴스를 중지했다 켜는 경우다.

```bash
# 상태를 실제 값으로 맞춘다. 인프라는 바꾸지 않는다.
terraform apply -refresh-only

# 애플리케이션 재점검. ECR 토큰이 12시간이라 만료됐을 것이므로 갱신이 필요하다.
cd ../ansible
ansible-playbook playbooks/site.yml --ask-vault-pass \
  -e backend_tag=sha-xxxxxxxxxxxx -e frontend_tag=sha-yyyyyyyyyyyy
```

- 사설 IP는 유지되므로 agent가 server를 다시 찾아 클러스터는 스스로 복구된다.
- server 공인 IP도 Elastic IP라 그대로다. 인증서를 다시 만들 필요가 없다.
- ALB 타깃은 인스턴스 ID 기준이라 헬스체크를 통과하면 자동으로 복구된다.
- Postgres와 Longhorn 데이터는 EBS에 남는다.

중지해도 ALB(월 약 $16), EBS(3대 30GiB 기준 월 약 $7), Elastic IP 요금은 계속
나간다. 며칠 이상 쉰다면 `terraform destroy`가 저렴하다. 도메인·인증서·호스팅
영역은 이 상태에 없으므로 남아 있고, 재구축 후 Ansible로 다시 배포하면 된다.

## 삭제

```bash
terraform plan -destroy
terraform destroy
```

이 디렉터리가 만든 세 노드, 보안 그룹, IAM 역할과 인스턴스 프로파일만 삭제한다.
기존 `team1_first_project`는 대상이 아니다.
