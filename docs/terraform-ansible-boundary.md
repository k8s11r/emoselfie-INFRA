# Terraform / Ansible 역할 경계: k3s 설치는 어디로 가야 하는가

> 대상: emoselfie 팀
> 계기: `prod` 오버레이에서 default StorageClass가 `local-path`(k3s 내장)와
> `longhorn`(Ansible이 설치) 둘 다로 마킹돼 충돌한 사건. 원인 조사 중 두 도구의
> 역할 경계가 애초에 불명확하다는 게 드러나서 별도로 정리한다.
> 관련 문서: [`k3s-node-topology.md`](k3s-node-topology.md) (이 문서와 별개 주제 — 노드 대수가 아니라 "누가 설치하는가")

---

## 결론 먼저

**k3s 설치·설정은 Ansible로 옮기고, Terraform은 "리소스가 존재하는가"까지만 책임진다.**

지금은 Terraform user-data가 k3s를 설치하고, Ansible이 그 위에 Longhorn을 얹는다.
StorageClass 충돌은 이 분리의 부작용이었다 — 두 도구가 클러스터 소프트웨어 상태를
나눠 가지면 서로 모르는 채로 같은 종류의 설정(이 경우 default 마킹)을 각자 주장할
수 있다. 버그 자체는 작지만, 구조가 같은 종류의 문제를 계속 만들 수 있어서 원칙을
정리해둔다.

---

## 지금 구조

```
Terraform (main.tf, user-data-*.sh.tftpl)
  └─ EC2 생성 + k3s 설치 (server/agent, 버전은 var.k3s_version)

Ansible (site.yml, group_vars/all/main.yml)
  └─ Longhorn 설치 (버전은 longhorn_version) + 앱 배포
```

소프트웨어 레이어(k3s, Longhorn)가 두 도구에 걸쳐 있고, 버전 정보도 두 군데
(`terraform/variables.tf`의 `k3s_version` / `ansible/group_vars/all/main.yml`의
`longhorn_version`)에 나뉘어 있다.

---

## 원칙: 두 도구는 애초에 다른 문제를 풀도록 설계됐다

| | Terraform | Ansible |
|---|---|---|
| 모델 | 선언적 **리소스** 관리 (존재하냐/안 하냐) | **상태** 관리 (설치돼 있냐, 설정이 맞냐) |
| 잘하는 것 | 클라우드 리소스 생성·변경·삭제, state로 drift 추적 | 순서 있는 다단계 설치, 조건 대기(`wait_for`/`until`), 재실행 시 idempotent 수렴 |
| 못하는 것 | 다단계 오케스트레이션, 재시도/대기 로직 | 클라우드 리소스 자체의 생성/삭제 |
| 재실행 시 | user_data는 부팅 시 1회만 실행(cloud-init) — 바꾸려면 인스턴스 replace | 몇 번을 돌려도 같은 결과로 수렴 |

HashiCorp 공식 문서도 이 경계를 명시한다: `user_data`는 **인스턴스 초기화** 용도로
권장되고, 소프트웨어 설치·**지속적인 유지보수**는 Ansible/Chef 같은 전용 설정관리
도구로 넘기라고 안내한다. k3s는 "한 번 설치하고 끝"이 아니라 버전을 올리고 플래그를
바꿔가며 계속 유지보수하는 대상이므로 후자에 해당한다.

---

## 이 저장소에 이미 있는 증거

**1. `terraform/main.tf:180,228` — `user_data_replace_on_change = true`**

k3s 버전이나 설치 플래그를 하나 바꾸면 user_data가 바뀌고, 이 옵션 때문에
**EC2 인스턴스 전체가 destroy/recreate** 된다. 소프트웨어 설정 하나 고치자고
노드를 갈아엎는 구조다. Ansible이었다면 재실행만으로 끝난다.

**2. 버전 소스가 이미 두 군데로 쪼개져 있다**

- k3s 버전: `terraform/variables.tf:68-69` (`k3s_version`)
- Longhorn 버전: `ansible/group_vars/all/main.yml:9` (`longhorn_version`)

"이 클러스터에 뭐가 몇 버전으로 떠 있나"를 확인하려면 두 파일을 다 봐야 한다.

**3. Longhorn의 OS 의존성은 이미 Terraform이 준비해주고 있다**

`terraform/user-data-server.sh.tftpl:7`에서 `open-iscsi`, `nfs-common`을 설치한다.
이건 k3s가 아니라 **나중에 Ansible이 설치할 Longhorn**이 필요로 하는 패키지다.
즉 지금도 Terraform이 "Ansible이 나중에 뭘 설치할지"를 미리 알고 준비해주는
암묵적 결합이 이미 존재한다 — 경계가 문서상으로만 있고 실제로는 이미 새고 있다.

**4. StorageClass 충돌 자체**

- `terraform/user-data-server.sh.tftpl:19-27`: k3s 설치 시 `--disable local-storage`
  같은 플래그 없이 기본 설치 → 내장 `local-path-provisioner`가 자동으로
  default StorageClass로 마킹됨
- Ansible이 적용하는 upstream `longhorn.yaml`도 자체적으로 `longhorn`을 default로
  마킹함
- 결과: `k8s/base/postgres.yaml`(67-74행, `storageClassName` 미지정)은 두 default
  중 **나중에 생성된 쪽**(우연히 longhorn)에 붙었고, `k8s/base/redis.yaml:82`,
  `k8s/base/redis-sentinel.yaml:73`는 `local-path`를 명시해서 우연히 피해갔다.
  두 자동화가 서로 몰라서 생긴 문제다.

---

## k3s 설치 자체의 특성도 Ansible 쪽에 맞는다

- server가 먼저 뜨고 agent가 join token으로 합류하는 **순서 의존적 부트스트랩** —
  Ansible의 `wait_for`/`until`/handler가 정확히 이 용도로 설계됐다.
- 실행 플래그(addon disable, 노드 라벨 등)를 바꾸는 건 "설정 변경"이지
  "리소스 재생성"이 아니다 — Ansible 재실행이 자연스럽다.
- drift 복구: 누가 노드에서 수동으로 k3s 설정을 건드려도 Ansible을 다시 돌리면
  원복된다. Terraform user-data는 최초 부팅 이후엔 관여하지 않아 drift를 못 잡는다.

---

## 권고

```
1. Terraform은 EC2/보안그룹/NLB/IAM/DNS 등 "리소스 존재"까지만 담당한다.
   user_data는 SSH 접속 가능하게 만드는 최소한(호스트네임, 패키지 설치 정도)까지만 남긴다.
2. k3s 설치(server/agent 순서 포함)를 Ansible로 옮긴다.
3. k3s 버전과 Longhorn 버전을 group_vars 한 곳으로 합쳐 단일 소스 오브 트루스로 만든다.
4. default StorageClass 조율(local-path 끄기/유지)을 Ansible의 k3s 설치 롤 안에서
   Longhorn 설치보다 먼저 처리한다 — 순서가 한 플레이북 안에서 보장된다.
```

### 지금 구조를 유지하기로 결정한다면

그것도 선택지일 수 있다. 다만 이 경우 아래를 함께 해야 재발을 막을 수 있다.

1. StorageClass default 조율을 **Terraform 쪽**(k3s가 설치되는 바로 그 지점)에서
   끝낸다 — k3s의 auto-deploying manifest 디렉터리(`/var/lib/rancher/k3s/server/manifests/`)에
   local-path의 default 어노테이션을 `false`로 만드는 override manifest를 user-data에서
   떨어뜨려 두면, k3s가 이 디렉터리를 지속 감시하므로 재부팅/업그레이드에도 self-healing된다
   (이 메커니즘 자체는 [`k3s-node-topology.md`](k3s-node-topology.md)에서 이미 검증됨).
2. Ansible이 Longhorn을 설치할 때 default 마킹이 이미 꺼진 `local-path`를 전제로
   하도록 순서를 문서화한다 — "Longhorn은 항상 이 override 이후에 설치된다"는 가정을
   코드가 아니라 사람 머릿속에만 남기지 않는다.

이 경우도 "누가 설치하냐"의 근본 구조는 그대로 두고 증상만 막는 것이므로, 다음에
같은 종류의 설정(예: CNI 플러그인, 노드 라벨)이 두 도구에 걸치면 같은 문제가
재발할 수 있다는 점은 감수해야 한다.

---

## 검증 상태

**직접 확인한 것 (저장소 파일 조회)**

- `terraform/main.tf:180,228`에 `user_data_replace_on_change = true`
- `terraform/user-data-server.sh.tftpl`에 `--disable` 계열 플래그 없음, `open-iscsi`/`nfs-common` 설치 포함
- k3s 버전은 `terraform/variables.tf`, Longhorn 버전은 `ansible/group_vars/all/main.yml`로 분리돼 있음
- `k8s/base/redis.yaml:82`, `k8s/base/redis-sentinel.yaml:73`는 `storageClassName: local-path` 명시, `k8s/base/postgres.yaml`은 미지정
- 실제 클러스터에서 `postgres-data-postgres-0`이 `longhorn`으로, `redis-data-*`/`sentinel-data-*`가 `local-path`로 바인딩된 것을 `kubectl get pvc`로 확인
- 여러 default StorageClass가 있을 때 "가장 최근에 생성된 것이 이긴다"는 Kubernetes 동작 —
  Kubernetes 공식 문서 두 곳에서 원문으로 확인함 (2026-09-15 기준):

  > "If you set the `storageclass.kubernetes.io/is-default-class` annotation to true
  > on more than one StorageClass in your cluster, and you then create a
  > PersistentVolumeClaim with no `storageClassName` set, Kubernetes uses the most
  > recently created default StorageClass."
  > — [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)

  > "If more than one StorageClass is marked as default, a PersistentVolumeClaim
  > without an explicitly defined storageClassName will be created using the most
  > recently created default StorageClass."
  > — [Change the default StorageClass](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/)

  `Change the default StorageClass` 문서는 덧붙여 "클러스터엔 default로 마킹된
  StorageClass가 하나만 있도록 하라"고 권고하면서, 여러 개를 **허용하는 이유는
  마이그레이션 중 잠깐 겹치는 상황을 지원하기 위해서**라고 설명한다. 즉 지금 상황
  (k3s와 Longhorn이 서로 몰라서 우연히 둘 다 default가 된 것)은 이 기능이 의도한
  사용 사례가 아니라, 의도치 않게 그 허용 범위에 걸려버린 경우다.

**문서 근거이며 직접 검증하지 않은 것**

- HashiCorp 공식 문서의 "user_data는 초기화용, 설정관리 도구는 유지보수용" 권고
  ([Terraform Provisioners 문서](https://developer.hashicorp.com/terraform/language/provisioners))

**EC2에서 확인이 필요한 것**

- k3s 설치를 실제로 Ansible로 옮겼을 때, 신규 EC2가 뜨고 SSH가 준비되는 시점까지
  Ansible이 안정적으로 대기·재시도하는지 (현재는 Terraform user-data가 부팅과
  동시에 동기적으로 처리하므로 이 대기 로직 자체가 새로 필요함)
- 기존 운영 클러스터를 이 구조로 전환할 때 노드 재생성 없이 넘어갈 수 있는지,
  아니면 최소 1회 노드 교체가 필요한지
