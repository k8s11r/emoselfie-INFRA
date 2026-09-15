# Longhorn 제거 + 모델 이미지 내장 전환 계획

> 배경: 실무자 멘토링에서 "왜 NFS가 아니라 Longhorn이냐"는 질문을 계기로 재검토.
> 결론적으로 감정 인식 모델(94MB, 고정)을 위해 Longhorn 전체 스택(노드당 상시
> 메모리 점유)을 운영하는 건 과설계로 판단, 모델을 이미지에 내장하는 방향으로 전환.
>
> 이 문서는 **ansible 관련 변경은 제외**한다 (다른 담당자가 별도 진행). 여기서는
> ansible 이외에 수정이 필요한 파일과, 다른 팀원 작업과의 충돌 여지를 정리한다.
>
> **9/17 발표가 촉박해 이 계획 전에 임시로 hostPath 방식을 먼저 적용한다.**
> 임시 조치는 [`longhorn-removal-interim-hostpath.md`](longhorn-removal-interim-hostpath.md)
> 참고. 이 문서(이미지 내장)는 발표 이후 진행할 최종 방향이다.

---

## 결론

모델을 BE 이미지에 COPY로 내장하고, Longhorn·PVC·initContainer 기반의 공유 볼륨
구조를 통째로 걷어낸다. ansible의 Longhorn 설치 스텝 제거는 별도 담당자가 진행.

---

## 수정 대상 파일

### emoselfie-INFRA (이 repo)

| 파일 | 핵심 수정 내용 |
|---|---|
| `k8s/base/models-pvc.yaml` | **삭제.** PVC 자체가 필요 없어짐 |
| `k8s/base/kustomization.yaml` | `resources`에서 `models-pvc.yaml` 항목 제거 |
| `k8s/base/backend.yaml` | `initContainers`의 `prepare-models` 통째로 제거 · `containers.backend.volumeMounts`의 `models` 마운트 제거 · `volumes`의 `models` PVC 정의 제거 |
| `k8s/overlays/prod/kustomization.yaml` | `images`에서 `emoselfie-models` 항목 제거 · `patches`의 models PVC `storageClassName: longhorn` patch 제거 · 관련 주석 정리 |
| `k8s/overlays/local/kustomization.yaml` | `resources`에서 `models-pv.yaml` 제거 · `patches`의 models PVC storageClassName/volumeName patch 제거 · `images`의 `emoselfie-models` 항목 제거 |
| `k8s/overlays/local/models-pv.yaml` | **삭제.** hostPath PV 자체가 불필요 |
| `docs/k3s-node-topology.md`, `k8s/README.md` | Longhorn 설치 안내·"모델 가중치" 섹션 등 서술 갱신 (우선순위 낮음) |

### emoselfie-BE (다른 repo — 별도 PR 필요)

| 파일 | 핵심 수정 내용 |
|---|---|
| `Dockerfile` | `models` 스테이지는 유지하되, `runtime` 스테이지에 `COPY --from=models /models /models` 추가. `httpx`는 여전히 `models` 스테이지에만 있어 런타임 이미지엔 안 들어감(§28 유지). 상단 "모델 가중치는 이미지에 넣지 않는다" 주석 수정 |
| `spec.md` / `guidelines.md` | "Model Volume" 다이어그램 등 낡은 설계 서술 — 우선순위 낮음, 후속 처리 가능 |

BE 쪽은 `EMOTION_MODEL_PATH`/`FACE_MODEL_PATH`가 이미지 내부 경로(`/models/...`)로
COPY 위치만 맞추면 되므로 코드(app) 변경은 없을 가능성이 높다 — Dockerfile의 COPY
대상 경로와 INFRA `backend-env` configMap 경로값(`k8s/base/kustomization.yaml`)이
일치하는지만 확인.

---

## Conflict 검토

- **가장 큰 리스크: ansible ↔ INFRA manifest 순서.** Ansible이 Longhorn 설치를
  먼저 빼고 이 PVC/patch 제거가 늦게 들어가면, `storageClassName: longhorn`을
  요구하는 PVC가 존재하지 않는 StorageClass를 참조해 `Pending`에 갇힌다. 반대로
  **manifest 쪽(이번 변경)을 먼저 merge하고, ansible의 Longhorn 제거는 그 다음에**
  진행하는 순서가 안전하다. 중간 상태(Longhorn은 떠 있지만 아무도 안 씀)는 낭비일
  뿐 장애는 아니다.
- **k3s 노드 구성 의사결정(`docs/k3s-node-topology.md`)이 아직 미확정.** 문서 자체에
  "EC2에서 확인이 필요한 것 — prod 오버레이 전체(Longhorn 포함)"가 남아 있다.
  누군가 그 검증을 진행 중이면 이번 변경으로 prod 오버레이가 통째로 바뀌는 셈이라
  같은 시점에 겹치면 두 번 테스트해야 하는 비효율이 생긴다. 파일 충돌은 아니지만
  일정 조율 필요.
- 최근 커밋(`ca57537` Traefik trustedIPs)이 `k8s/overlays/prod/kustomization.yaml`을
  건드렸는지 확인 필요 — 같은 파일의 다른 섹션(`patches`)을 만지는 것이라 merge는
  되지만 리뷰 시점이 겹치지 않게 조율.

**권장 순서**: BE Dockerfile PR(모델 내장) → 이미지 빌드/검증 → INFRA manifest
PR(PVC/initContainer/overlay patch 제거) → EC2 배포 검증 → 마지막에 ansible
담당자가 Longhorn 설치 스텝 제거. INFRA manifest PR을 올리기 전에 ansible
담당자에게 이 순서로 가면 되는지 확인받을 것.

---

## 트러블슈팅 보고서 (참고)

### Longhorn 도입 철회

**1. 증상**: Longhorn 도입으로 노드마다 메모리를 고정적으로 점유함

**2. 원인**: 모델을 1회만 다운로드받아 여러 pod가 공유하는 방식으로 설계하다
보니 Longhorn을 알게 되었고, 강의에서 배운 방식을 그대로 고집해 이미지에 모델을
포함하지 않고 외부 볼륨에 모델을 받아 추론 pod 기동 시 동일한 모델을 사용하는
데에만 초점을 맞춤

**3. 해결**: 모델 변경이 자주 발생하지 않고, 노드 메모리 비용이 ECR 비용보다
더 크며, 기술 스택의 복잡도를 낮추기 위해 Longhorn을 제거하고 이미지에 모델을
포함하는 방향으로 변경

---

## 부록: 노드별 로컬 캐싱(hostPath) — 장기 방향 아님

Longhorn 대신 "각 노드가 모델을 자기 로컬에 캐싱"하는 방안도 검토했다. 모델이
고정이고 크기가 작아(94MB) 장기적으로는 이미지 내장이 더 단순하다고 판단해
**최종 방향으로는 채택하지 않았지만**, 9/17 발표 일정 때문에 **임시로는 이 방식을
먼저 적용**하기로 했다. 구체적인 변경 내용과 리스크는
[`longhorn-removal-interim-hostpath.md`](longhorn-removal-interim-hostpath.md)에
분리해 정리했다.
