# [임시 조치] hostPath로 Longhorn 제거 — 9/17 발표 대응

> **최종 방향은 이미지 내장이다.** 이 문서는 발표 일정(9/17)이 촉박해 최소
> 수정으로 Longhorn만 먼저 걷어내기 위한 **임시 방편**을 다룬다. 장기 계획은
> [`longhorn-removal-plan.md`](longhorn-removal-plan.md) 참고. 발표가 끝나면
> 이 hostPath 구조를 걷어내고 그 문서의 이미지 내장 방향으로 다시 전환한다.
>
> 이 문서도 **ansible 관련 변경은 제외**한다 (다른 담당자가 별도 진행).

---

## 왜 이 방식인가

이미지 내장은 emoselfie-BE 레포까지 건드려 새 이미지 빌드 → ECR push → 재배포
검증이 필요하다. 발표 이틀 전에 벌이기엔 변경 범위와 리스크가 크다.

hostPath는 **emoselfie-INFRA 레포 안에서, 그것도 `backend.yaml`의 volume 정의
한 곳만 바꾸면** 된다. `initContainers.prepare-models`, `volumeMounts`는 이미
검증된 로직 그대로 재사용하고, PVC(Longhorn)였던 볼륨 소스만 노드 로컬 디스크로
바꾼다.

## 변경 내용

`k8s/base/backend.yaml`

```yaml
# 변경 전
volumes:
  - name: models
    persistentVolumeClaim:
      claimName: models

# 변경 후
volumes:
  - name: models
    hostPath:
      path: /var/lib/emoselfie/models
      type: DirectoryOrCreate
```

`initContainers.prepare-models`, `containers.backend.volumeMounts`는 수정 없음.

## 수정 대상 파일 (ansible 제외)

| 파일 | 핵심 수정 내용 |
|---|---|
| `k8s/base/backend.yaml` | `volumes.models`를 `persistentVolumeClaim` → `hostPath`로 교체 (위 diff) |
| `k8s/base/models-pvc.yaml` | 삭제 |
| `k8s/base/kustomization.yaml` | `resources`에서 `models-pvc.yaml` 제거 |
| `k8s/overlays/prod/kustomization.yaml` | models PVC의 `storageClassName: longhorn` patch 제거 (대상이 사라지므로). `images`의 `emoselfie-models`는 **그대로 유지** — initContainer가 여전히 그 이미지를 씀 |
| `k8s/overlays/local/kustomization.yaml`, `models-pv.yaml` | k3d의 hostPath 트릭이 base로 흡수되므로 정리 가능 (선택 사항 — 발표 전이라 급하지 않으면 보류 가능) |

이미지 내장 방식과 달리 emoselfie-BE 레포, Dockerfile, `emoselfie-models` 이미지
빌드 파이프라인은 전혀 건드리지 않는다.

## 리스크 (발표 기준으로는 낮음으로 판단)

- backend는 `Deployment` + `topologySpreadConstraints`라 pod가 재생성될 때
  **다른 노드로 스케줄되면 그 노드에서 모델을 1회 재다운로드**한다. 지금은 노드
  고정이 아니기 때문에 100% 보장되는 캐싱이 아니다.
- 발표 전에 3노드 모두 한 번씩 배포해 캐싱을 미리 만들어두면, 발표 당일 노드
  교체 같은 이벤트가 없는 한 이 리스크는 사실상 발생하지 않는다.
- 노드가 실제로 죽고 새 EC2로 교체되면 그 노드는 디스크가 비어 있어 재다운로드가
  발생한다 — 94MB라 몇 초 수준, `startupProbe`(`failureThreshold: 24 ×
  periodSeconds: 5` = 120초 여유)로 충분히 흡수된다.

## 디스크/메모리 비용 참고

- 디스크 사용량은 Longhorn과 사실상 동일하다(94MB × 3노드). 이번 변경의 실익은
  디스크 절약이 아니라 **Longhorn 컨트롤 플레인의 노드당 상시 메모리 오버헤드
  제거**뿐이다.
- `local-path` StorageClass는 이 용도에 맞지 않는다 — 동적 프로비저너라 PVC
  하나당 PV 하나를 `WaitForFirstConsumer`로 노드 하나에 고정시켜, backend
  3 replica가 전부 그 한 노드로 몰리고 `topologySpreadConstraints`와 충돌한다.
  그래서 PVC/StorageClass 계층을 거치지 않는 `hostPath`를 pod spec에 직접
  선언하는 이 방식을 쓴다.

## 발표 이후 할 일

이 hostPath 구조는 그대로 두면 안 된다 — 노드 교체 시 재다운로드, 노드 로컬
디스크 의존 등 [`longhorn-removal-plan.md`](longhorn-removal-plan.md)에서 이미
"채택하지 않기로 한" 이유들이 여전히 유효하다. 발표 이후 여유가 생기면 그
문서의 이미지 내장 계획으로 전환한다.
