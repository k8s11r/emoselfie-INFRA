# k3s 노드 구성 의사결정: server 1 + agent 2 → server 3

> 대상: emoselfie 팀
> 결정 기한: EC2 프로비저닝 전 (Terraform 작성 시작 전)
> 배경 문서: [`k8s/README.md`](../k8s/README.md)
>
> [INFRA #11](https://github.com/k8s11r/emoselfie-INFRA/issues/11)은 이 결정과
> **독립적인 작업**이다. 혼동을 피하려고 "이슈 #11과의 관계" 절에서 따로 설명한다.

---

## 결론 먼저

**server 3대를 권고합니다. EC2 요금은 동일하고, 현재 구성은 "3노드 고가용성"이라는 프로젝트 목표를 절반만 달성합니다.**

어느 쪽으로 결정하든 **`--cluster-init` 플래그는 반드시 붙여야 합니다.** 이것만 빠지면 나중에 되돌릴 수 없습니다. (상세: "되돌릴 수 있는가")

---

## 무엇을 결정하는가

EC2 3대에 k3s를 올릴 때 각 노드의 역할입니다.

| | AS-IS | TO-BE |
|---|---|---|
| 구성 | server 1 + agent 2 | server 3 |
| control plane | 1대 | 3대 (embedded etcd) |
| 워크로드 실행 | 3대 모두 | 3대 모두 |
| EC2 비용 | 3 × t3.medium | **동일** |

**워크로드(backend, redis, postgres 등)는 양쪽 모두 3대에서 돕니다.** 차이는 control plane(apiserver, scheduler, etcd)의 이중화 여부뿐입니다.

---

## 비용 — 차이 없음

EC2는 인스턴스 타입으로 요금이 정해지며 **k3s의 역할(server/agent)과 무관합니다.**

```
t3.medium × 3 × 7일  ≈  $26        (양쪽 동일)
gp3 8GB × 3          ≈  $1         (양쪽 동일)
```

즉 이 결정은 **비용 트레이드오프가 아닙니다.**

---

## 장애 시나리오 비교

### 시나리오 A — agent 노드 하나가 죽는다

| | AS-IS | TO-BE |
|---|---|---|
| 서비스 지속 | 유지 | 유지 |
| 죽은 pod 재스케줄 | 자동 | 자동 |
| 결과 | 정상 동작 | 정상 동작 |

여기서는 차이가 없습니다.

### 시나리오 B — server 노드가 죽는다

| | AS-IS | TO-BE |
|---|---|---|
| 기존 pod | 계속 돌아감 | 계속 돌아감 |
| **죽은 pod 재스케줄** | **불가** (scheduler 없음) | 자동 |
| **kubectl** | **불가** (apiserver 없음) | 가능 |
| Service 엔드포인트 갱신 | 멈춤 | 정상 |
| Longhorn 볼륨 재연결 | **불가** | 가능 |
| 복구 방법 | **그 노드를 되살려야 함** | 자동 |
| **그 노드를 재생성하면** | **클러스터 전체 소실** (데이터스토어가 거기 있음) | 클러스터 유지, 새 노드가 재합류 |

마지막 행이 이 결정의 무게를 가장 잘 보여줍니다. AS-IS에서 server 노드를 Terraform으로 교체하면 **설정이 아니라 클러스터가 사라집니다.** etcd/SQLite 데이터가 그 노드의 디스크에 있기 때문입니다. 처음부터 다시 올려야 합니다.

**AS-IS에서 가장 치명적인 조합**: Traefik(입구) pod가 하필 server 노드에 있었던 경우입니다.

검증한 사실 — Traefik Deployment에는 `nodeSelector`도 `affinity`도 없습니다.

```
nodeSelector=           (없음)
affinity=               (없음)
tolerations=[control-plane NoSchedule, CriticalAddonsOnly]
```

`tolerations`는 "control-plane taint가 있어도 **허용한다**"는 뜻이지 "거기만 간다"는 게 아닙니다. 즉 **Traefik pod는 아무 노드나 갑니다.** server에 떠 있는데 그 노드가 죽으면:

```
agent 2대는 멀쩡함
→ 하지만 Traefik을 재스케줄할 scheduler가 없음
→ 입구가 영구히 사라짐. 서비스 전체 중단
```

### 시나리오 C — 발표장에서 노드를 drain한다

| | AS-IS | TO-BE |
|---|---|---|
| drain 가능한 노드 | agent 2대만 | 3대 전부 |
| 시연 멘트 | "이 노드는 빼고 죽여주세요" | "아무 노드나 죽여보세요" |
| server를 고르면 | 시연이 아니라 사고 | 정상 동작 |

---

## 되돌릴 수 있는가 — `--cluster-init`

**이 결정의 핵심 리스크입니다.**

k3s는 단일 server일 때 기본으로 **SQLite**를 씁니다. etcd가 아닙니다.

```bash
# SQLite (되돌릴 수 없음)
curl -sfL https://get.k3s.io | sh -s - server

# embedded etcd (1대여도. 나중에 확장 가능)
curl -sfL https://get.k3s.io | sh -s - server --cluster-init
```

SQLite로 시작하면 **나중에 server를 추가할 때 그냥 붙지 않습니다.** etcd로 데이터를 마이그레이션해야 하고, 남은 일정에 하고 싶은 작업이 아닙니다.

| 출발 방식 | 나중에 server 추가 |
|---|---|
| `server` (SQLite) | **불가. 마이그레이션 필요** |
| `server --cluster-init` (etcd) | 명령 한 줄씩 |

**AS-IS를 유지하기로 결정하더라도 `--cluster-init`은 붙이세요.** 그러면 EC2에서 돌려보고 판단을 바꿀 여지가 남습니다.

---

## TO-BE의 대가 (정직하게)

공짜는 아닙니다. 두 가지 비용이 있습니다.

**1. etcd 합의 오버헤드.** 모든 쓰기가 과반 노드에 복제돼야 커밋되므로 CPU·디스크·네트워크를 더 씁니다. t3.medium(2 vCPU, gp3)에서 버스트 크레딧이 소진되면 etcd가 느려지고 클러스터 전체가 둔해질 수 있습니다.

> **미검증**: 우리 워크로드는 pod 13개에 배포가 하루 몇 번이라 etcd 쓰기량이 거의 없습니다. 문제 가능성은 낮다고 보지만 EC2에서 실제로 돌려봐야 확인됩니다.

**2. quorum 제약.** 3대 중 2대가 죽으면 클러스터가 읽기 전용이 됩니다. (AS-IS는 1대 죽으면 끝이므로 어쨌든 개선입니다.)

---

## 설치 명령 차이

```bash
# ── TO-BE (server 3대) ──
# 1번째
curl -sfL https://get.k3s.io | sh -s - server --cluster-init

# 2, 3번째
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<1번 사설IP>:6443 --token <토큰>


# ── AS-IS (server 1 + agent 2) ──
# 1번째
curl -sfL https://get.k3s.io | sh -s - server --cluster-init

# 2, 3번째
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://<1번 사설IP>:6443 --token <토큰>
```

**차이는 `server` / `agent` 단어 하나입니다.**

Ansible 관점에서는 TO-BE가 오히려 단순합니다.

```ini
# TO-BE — 그룹 하나
[k3s_servers]
node1 k3s_init=true
node2
node3

# AS-IS — 그룹 둘, 태스크 분기 필요
[k3s_server]
node1
[k3s_agents]
node2
node3
```

---

## 이슈 #11과의 관계 — 의사결정 요인이 아님

혼동을 피하기 위해 명시합니다. [#11](https://github.com/k8s11r/emoselfie-INFRA/issues/11)은
**이 결정과 독립적인 작업입니다.** server가 1대든 3대든 똑같이 필요하고, 구현 방법도
같습니다.

`#11`이 필수가 된 이유는 노드 구성이 아니라 **운영을 ALB로 가기로 한 결정**입니다.

```
ALB --https--> 노드:80 --> Traefik --> nginx --> backend
                           ↑
                    X-Forwarded-Proto를 http로 덮어씀
                    → /api/ POST 전부 FORBIDDEN_ORIGIN
                    → websocket 403
                    → https로 얻은 카메라 권한이 무의미해짐
```

운영에서는 `insecure: true` 대신 범위를 좁힌 값을 씁니다. 보안 그룹에서 노드 80을
ALB의 SG만 허용하도록 함께 설정해 2중으로 막습니다.

```yaml
forwardedHeaders:
  trustedIPs:
    - "<VPC CIDR>"     # ALB ENI가 이 안에 있다
```

### 구현 시 참고 (server 수와 무관)

`#11`의 해결 방식은 Ansible이 이 경로에 파일을 놓는 것입니다.

```
/var/lib/rancher/k3s/server/manifests/traefik-config.yaml
```

**이 디렉터리는 server 노드에만 있습니다.** agent에 놓으면 무시되므로 Ansible 태스크가
server 그룹을 대상으로 해야 합니다. server가 1대면 대상 1대, 3대면 3대 — 그뿐이고
**어느 쪽이 유리하다는 근거가 되지 않습니다.**

검증한 사실 — k3s는 이 디렉터리를 **실시간 감시**합니다. 파일을 놓으면 재시작 없이
3초 만에 적용됩니다. 따라서 Ansible 태스크에 재시작 핸들러가 필요 없습니다.

```
server 노드에 파일만 배치 (재시작 없음)
  → 3초 후 HelmChartConfig 객체 자동 생성
  → Traefik Deployment에 --entryPoints.web.forwardedHeaders.insecure 반영
```

설정의 실체는 파일이 아니라 **etcd에 저장된 HelmChartConfig 객체**입니다. 파일은 k3s가
그 객체를 만들기 위한 소스일 뿐입니다. 그래서 파일을 몇 대에 두는지는 내구성과 무관합니다.

## 권고

```
1. server 3대로 구성한다                       ← 비용 동일, 목표 달성
2. 어느 쪽이든 --cluster-init 을 붙인다          ← 되돌릴 여지 확보
3. #11을 Ansible 방식으로 해결한다              ← 별개 작업. ALB 때문에 필수
4. 운영은 trustedIPs + 보안 그룹 2중 방어        ← insecure: true 는 로컬 전용
```

### AS-IS를 유지하기로 결정한다면

그것도 합리적인 선택일 수 있습니다. 다만 세 가지를 함께 하셔야 합니다.

1. **`--cluster-init` 필수** (위 참조)
2. **Traefik과 web pod를 agent에 고정** (`nodeSelector`). server가 죽어도 입구가 살아남습니다
3. **발표에서 "control plane은 의도적으로 SPOF로 남겼다"를 명시.** 트레이드오프를 설명하면 오히려 이해도를 보여줍니다

---

## 검증 상태

이 문서의 주장을 구분합니다.

**로컬 k3d 3노드에서 직접 확인한 것**

- Traefik Deployment에 `nodeSelector`/`affinity`가 없어 아무 노드나 스케줄됨
- k3s server 노드에 기본 taint가 없음
- `/var/lib/rancher/k3s/server/manifests/` 를 k3s가 실시간 감시하며, 파일 배치 후 3초 만에 적용 (재시작 불필요)
- `HelmChartConfig` 적용 시 Traefik Deployment args에 플래그가 추가되고 pod가 교체됨
- `traefik.yaml` 직접 수정은 노드 재시작으로는 날아가지 않음 (다만 k3s 업그레이드 시 교체되고, 노드마다 수동 관리가 필요하므로 권장하지 않음)
- ALB/터널처럼 앞단에서 TLS를 종료하면 `forwardedHeaders` 없이 `FORBIDDEN_ORIGIN`과 websocket 403이 발생

**문서 근거이며 직접 검증하지 않은 것**

- 단일 server의 기본 백엔드가 SQLite이고 etcd 전환에 마이그레이션이 필요하다는 점
- t3.medium에서 etcd 3노드 합의의 실제 오버헤드

**EC2에서 확인이 필요한 것**

- `prod` 오버레이 전체 (Longhorn 포함)
- ALB + ACM + Route53 경로
