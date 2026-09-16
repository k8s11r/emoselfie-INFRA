# EmoSelfie 인프라 트러블슈팅 보고서

이 문서는 2026년 9월 로컬 Docker Compose 및 Kubernetes 배포 과정에서 실제로 확인된 장애와 운영 문제를 정리한 것이다. 발생 일시는 별도 장애 티켓이 없는 경우 조치 커밋의 작성일을 기준으로 기록했다.

## 보고서 요약

| 번호 | 발생 일시 | 문제 | 주요 원인 | 상태 |
| --- | --- | --- | --- | --- |
| 1 | 2026-09-10 | 모델 미준비로 백엔드 컨테이너 기동 실패 | 수동 모델 준비 절차 누락 | 해결 |
| 2 | 2026-09-10 | migrate Job의 Postgres 연결 실패 | Kubernetes 기동 순서 미보장 | 해결 |
| 3 | 2026-09-14 | 콜드부트 시 backend 반복 재시작 | 의존 서비스 준비 전 애플리케이션 시작 | 해결 |
| 4 | 2026-09-10, 2026-09-15 | HTTPS 요청의 same-origin 검사 실패 | 전달 프로토콜 헤더 유실·불신 | 해결 |
| 5 | 2026-09-15 | web Pod가 자원 압박에 취약 | resources 미지정으로 BestEffort QoS 적용 | 해결 |
| 6 | 2026-09-15 | Longhorn의 과도한 상시 자원 점유 | 작은 고정 모델에 비해 복잡한 스토리지 구성 | 임시 해결, 최종 구조 전환 예정 |

---

## 1. 모델 준비 절차 누락으로 인한 백엔드 컨테이너 기동 실패

- 발생 일시: 2026-09-10 조치 완료
- 영향 범위: 로컬 Mac의 Docker Compose 환경. 백엔드가 기동되지 않아 전체 서비스 실행 및 기능 테스트가 중단됨.

### 문제 상황

- 최초 실행에서 이미지 빌드가 누락되었고, 이미지를 다시 빌드한 뒤에도 백엔드 컨테이너가 종료되었다.
- 백엔드가 준비되지 않아 이를 의존하는 web 컨테이너까지 정상 서비스 상태로 전환되지 못했다.
- 확인된 메시지는 `dependency failed to start`, `exited (3)`, `Model artifact size mismatch`였다.
- 조사 중 `.pt` 모델 경로가 파일이 아니라 빈 디렉터리로 생성된 상태도 확인되었다. 존재하지 않는 개별 파일을 bind mount하면 Docker가 같은 이름의 디렉터리를 만들 수 있어 원인 파악을 어렵게 했다.

### 원인 분석

- 직접 원인: 감정 인식 및 얼굴 검출에 필요한 모델 파일이 지정 경로에 없거나 올바른 파일이 아니어서 백엔드 startup 검증이 실패했다.
- 근본 원인: `docker compose up` 외에 `scripts/prepare_models.py`를 수동 실행해야 했으나, 실행 절차가 README에만 분리되어 있어 쉽게 누락될 수 있었다. 모델 파일을 각각 mount하던 구성도 파일 부재를 빈 디렉터리로 가려 문제를 악화시켰다.
- 확인 방법: 백엔드 종료 코드와 로그를 확인하고, 호스트의 `.models` 경로 및 컨테이너 내부 모델 경로의 파일 유형·크기·체크섬을 비교했다.

### 해결 과정

1. `.models` 디렉터리를 준비하고 필요한 모델 파일을 수동으로 내려받아 백엔드가 정상 기동하는지 확인했다.
2. `prepare-models` 서비스를 Compose 구성에 추가해 모델 다운로드와 SHA-256 검증이 백엔드보다 먼저 실행되도록 했다.
3. 모델 파일별 bind mount를 `.models` 디렉터리 단위의 읽기 전용 mount로 변경했다.
4. 백엔드가 `prepare-models`의 성공 완료를 의존하도록 `service_completed_successfully` 조건을 추가했다.

### 해결 결과

- 빈 `.models` 상태에서 최초 다운로드, 재실행 시 체크섬 검증, 백엔드 health check 및 실제 추론까지 정상 동작했다.
- 이후에는 `docker compose up --build`만 실행해도 모델 준비가 선행되므로 수동 명령 누락으로 같은 문제가 재발하지 않도록 했다.

### 재발 방지 방안

- 설정 또는 코드 변경 사항: Compose에 멱등적인 `prepare-models` 서비스와 완료 조건을 추가했다.
- 운영 점검 항목 추가 여부: 모델 파일의 존재 여부뿐 아니라 파일 유형, 크기, 체크섬을 함께 확인한다.
- 문서 업데이트 내용: README의 “모델을 먼저 수동 준비” 절차를 자동 준비 방식으로 수정하고 캐시 위치를 명시했다.

---

## 2. migrate Job이 Postgres 준비 전에 실행되어 연결 실패

- 발생 일시: 2026-09-10
- 영향 범위: Kubernetes 콜드부트 및 재배포 환경. DB migration 완료가 지연되고 실패 한도 초과 시 backend 배포가 중단될 수 있었음.

### 문제 상황

- 클러스터 전체를 동시에 기동하면 migrate Job이 Postgres보다 먼저 시작해 DNS 조회 또는 5432 포트 연결에 실패했다.
- `backoffLimit: 3` 중 두 번을 소진한 뒤 세 번째 Pod에서만 migration이 성공했다. 실패가 한 번 더 발생했다면 Job이 영구 실패 상태가 될 수 있었다.
- 당시 관찰 결과는 다음과 같았다.

```text
postgres 대기 중 -> postgres:5432 - no response
postgres 대기 중 -> postgres:5432 - no response
postgres 대기 중 -> postgres:5432 - accepting connections

변경 전: migrate Pod 3개 (Error, Error, Completed)
```

### 원인 분석

- 직접 원인: migrate 컨테이너가 Postgres Service의 DNS와 DB 포트가 준비되기 전에 Alembic을 실행했다.
- 근본 원인: Kubernetes는 리소스 선언 순서대로 애플리케이션의 준비 완료를 보장하지 않는데도 Job 재시도에 기동 순서를 맡겼다.
- 확인 방법: Postgres StatefulSet·PVC와 migrate Job을 삭제한 뒤 동시에 다시 배포해 경합을 재현하고, Job Pod 수·종료 상태와 Postgres readiness 상태를 비교했다.

### 해결 과정

1. migrate Job에 `wait-postgres` initContainer를 추가했다.
2. 처음에는 `pg_isready`를 사용했으나 이미지 크기와 다른 노드에서의 추가 pull 비용을 줄이기 위해 `busybox:1.37`과 `nc -z postgres 5432` 폴링으로 변경했다.
3. Postgres의 `readinessProbe`는 계속 `pg_isready`를 사용하도록 유지했다.
4. headless Service가 Ready인 Pod만 DNS 응답에 포함하므로, `postgres` 이름 해석 및 포트 연결 성공을 migration 시작 조건으로 사용했다.

### 해결 결과

- Postgres StatefulSet·PVC와 Job을 동시에 다시 생성한 검증에서 initContainer가 세 차례 대기한 뒤 통과했다.
- 변경 후 migrate Job은 첫 실행 Pod에서 완료됐고 실패 Pod가 남지 않았다.

### 재발 방지 방안

- 설정 또는 코드 변경 사항: migrate Job에 고정 간격 의존성 대기 initContainer를 적용했다.
- 운영 점검 항목 추가 여부: `kubectl get pods`, `kubectl logs job/migrate -c wait-postgres`, Job condition과 `backoffLimit` 소진 횟수를 확인한다.
- 문서 업데이트 내용: 재배포 절차와 “Job 재시도는 기동 순서 보장이 아니다”라는 원칙을 Kubernetes README에 기록했다.

---

## 3. 의존 서비스 미준비로 인한 backend 콜드부트 반복 재시작

- 발생 일시: 2026-09-14
- 영향 범위: 3노드 k3d 콜드부트 환경의 모든 backend Pod. API와 실시간 통신의 준비 시간이 불필요하게 길어짐.

### 문제 상황

- 클러스터를 처음 기동할 때 backend가 Postgres 또는 Redis보다 먼저 시작하면 의존성 검사에서 실패했다.
- 애플리케이션의 `dependency_checks()`가 연결 실패 시 `RuntimeError`를 발생시켜 프로세스가 종료됐고, Pod가 `CrashLoopBackOff`/`Init:Error` 상태에서 재시작을 반복했다.
- 의존 서비스가 뒤늦게 정상화되어도 지수 백오프 때문에 backend의 다음 재시작까지 추가 지연이 발생했다.

### 원인 분석

- 직접 원인: backend가 `postgres:5432`, `redis-sentinel:26379`, `redis-media:6379`가 준비되기 전에 애플리케이션 프로세스를 시작했다.
- 근본 원인: 기동 순서가 보장되지 않는 Kubernetes에서 애플리케이션 실패와 Pod 재시작을 의존성 대기 수단으로 사용했다.
- 확인 방법: 3노드 k3d 클러스터를 콜드부트하고 backend Pod 상태, restart count, 의존성 검사 로그를 관찰했다.

### 해결 과정

1. backend Pod에 `wait-dependencies` initContainer를 추가했다.
2. `busybox:1.37`에서 Postgres, Redis Sentinel, Redis Media 포트를 2초 간격으로 순차 확인했다.
3. 세 의존 서비스가 모두 연결 가능한 경우에만 모델 준비 initContainer와 backend 본 컨테이너가 실행되도록 순서를 구성했다.

### 해결 결과

- 변경 전에는 backend가 반복 재시작했으나, 변경 후 동일한 3노드 k3d 콜드부트에서 재시작 0회로 정상 기동했다.
- 의존 서비스가 늦게 준비되는 상황을 restart backoff가 아닌 예측 가능한 고정 간격 대기로 흡수했다.

### 재발 방지 방안

- 설정 또는 코드 변경 사항: backend 매니페스트에 의존성 대기 initContainer를 추가했다.
- 운영 점검 항목 추가 여부: 콜드부트 테스트에서 Ready 전환 시간과 restart count가 0인지 확인하고, `wait-dependencies` 로그를 수집한다.
- 문서 업데이트 내용: 운영 가이드에 `Init:Error`, `CrashLoopBackOff`, 의존성별 점검 명령을 추가했다.

---

## 4. X-Forwarded-Proto 유실로 인한 HTTPS same-origin 403

- 발생 일시: 2026-09-10 최초 확인, 2026-09-15 k3d HTTPS 검증 환경에서 재확인
- 영향 범위: Cloudflare Tunnel·edge nginx·ALB처럼 애플리케이션 앞단에서 TLS를 종료하는 환경. API 변경 요청, WebSocket 연결, Secure 쿠키에 영향.

### 문제 상황

- 브라우저는 HTTPS로 접속했지만 backend는 요청 scheme을 HTTP로 인식했다.
- Origin의 `https`와 backend가 인식한 `http`가 달라 same-origin 검사에서 HTTP 403 `FORBIDDEN_ORIGIN`이 발생했다.
- 초기 nginx 구성에서는 `proxy_set_header X-Forwarded-Proto $scheme`이 앞단의 `https` 값을 `http`로 덮어썼고 Secure 쿠키 플래그도 제거됐다.
- k3d HTTPS 검증에서는 Traefik이 신뢰하지 않는 edge의 전달 헤더를 다시 `http`로 덮어써 같은 문제가 재현됐다.

### 원인 분석

- 직접 원인: TLS 종료 지점이 전달한 `X-Forwarded-Proto: https`가 프록시 체인 중간에서 유실되거나 신뢰되지 않았다.
- 근본 원인: 각 프록시가 보는 로컬 연결 scheme과 사용자가 실제로 사용한 외부 scheme을 구분하지 않았고, 전달 헤더의 신뢰 범위도 배포 환경에 맞게 선언되지 않았다.
- 확인 방법: 브라우저 Origin, nginx/Traefik의 전달 헤더, Uvicorn의 `scope["scheme"]`, backend의 same-origin 판정 결과를 순서대로 비교했다.

### 해결 과정

1. nginx에 `$http_x_forwarded_proto`가 있으면 보존하고, 없을 때만 `$scheme`으로 대체하는 `map`을 추가했다.
2. backend로 전달하는 모든 API·Socket.IO·media 경로가 보존된 `$forwarded_proto`를 사용하도록 수정했다.
3. Uvicorn에 `--proxy-headers`와 허용 프록시 설정을 적용했다.
4. Traefik에는 무제한 `forwardedHeaders.insecure: true` 대신 k3s Pod CIDR과 edge 네트워크만 `trustedIPs`로 등록했다.
5. 로컬 HTTP와 운영 HTTPS의 sticky cookie `Secure` 값을 overlay에서 명시적으로 분리했다.

### 해결 결과

- nginx 설정은 `nginx -t`를 통과했다.
- 3노드 k3d `https-check` 환경에서 API, 쿠키, 실시간 연결을 포함한 `smoke_https.py` 검증이 통과했다.
- HTTPS 요청이 backend까지 HTTPS로 인식되어 same-origin 403과 Secure 쿠키 유실이 해소됐다.

### 재발 방지 방안

- 설정 또는 코드 변경 사항: 전달 헤더 보존 map, Uvicorn proxy header 처리, Traefik `trustedIPs`, 환경별 cookie overlay를 적용했다.
- 운영 점검 항목 추가 여부: TLS 종료 지점이 바뀔 때 `X-Forwarded-Proto`, Origin, Host, WebSocket upgrade, Set-Cookie의 `Secure`를 함께 확인한다.
- 문서 업데이트 내용: k3d HTTPS 재현 절차와 운영 trusted IP 점검 절차를 Kubernetes README 및 운영 가이드에 추가했다.

---

## 5. resources 미지정으로 인한 web Pod의 BestEffort QoS 문제

- 발생 일시: 2026-09-15
- 영향 범위: Kubernetes의 web DaemonSet. 노드 메모리 압박 시 정적 파일 제공 계층이 우선 축출될 수 있었음.

### 문제 상황

- web 컨테이너에 CPU·메모리 request와 limit이 없어 QoS가 `BestEffort`로 분류됐다.
- backend와 web의 역할을 분리했음에도 노드 자원이 부족해지면 web이 먼저 축출되어 사용자가 정적 페이지에 접근하지 못할 수 있었다.
- 애플리케이션 오류 로그가 아니라 `kubectl describe pod`의 QoS 및 resources 부재로 확인한 운영 구성 문제였다.

### 원인 분석

- 직접 원인: web Pod의 `resources.requests`와 `resources.limits`가 정의되지 않았다.
- 근본 원인: nginx가 가벼운 정적 파일 서버라는 이유로 자원 보장을 생략했으며, Kubernetes의 메모리 압박 시 축출 우선순위를 고려하지 않았다.
- 확인 방법: 렌더링된 Pod spec의 resources와 `status.qosClass`를 확인하고 backend의 `Guaranteed` 설정과 비교했다.

### 해결 과정

1. 실제 역할에 맞는 작은 고정 자원값으로 CPU `50m`, 메모리 `32Mi`를 선정했다.
2. request와 limit을 동일하게 지정해 web Pod가 `Guaranteed` QoS를 받도록 했다.
3. base 매니페스트에 적용해 모든 overlay가 같은 안전한 기본값을 상속하도록 했다.

### 해결 결과

- web DaemonSet이 `BestEffort`에서 `Guaranteed` QoS로 전환됐다.
- 메모리 압박 시 무보장 Pod라는 이유로 web이 우선 축출되는 구성상 위험을 제거했다.

### 재발 방지 방안

- 설정 또는 코드 변경 사항: web 컨테이너에 request와 limit을 동일하게 지정했다.
- 운영 점검 항목 추가 여부: 배포 후 `kubectl get pod -o jsonpath` 또는 `kubectl describe pod`로 QoS가 `Guaranteed`인지 확인한다.
- 문서 업데이트 내용: 배포 체크리스트에 모든 운영 컨테이너의 requests·limits·QoS 확인을 추가한다.

---

## 6. 고정 모델 공유를 위한 Longhorn 도입으로 노드 자원 과다 점유

- 발생 일시: 2026-09-15
- 영향 범위: Kubernetes 전체 노드. Longhorn control plane과 데이터 plane이 94MB 고정 모델 하나를 공유하기 위해 상시 실행됨.

### 문제 상황

- 모델 가중치를 한 번만 내려받아 여러 backend Pod가 공유하도록 Longhorn RWX 볼륨을 도입했다.
- 모델은 약 94MB이며 자주 변경되지 않는데도 Longhorn 구성 요소가 각 노드의 메모리를 지속적으로 점유했다.
- 직접적인 오류 메시지보다 노드 자원 사용량과 운영 구성 복잡도 증가가 핵심 증상이었다. 당시 측정한 정확한 노드별 메모리 수치는 기록에 남아 있지 않다.

### 원인 분석

- 직접 원인: 모델 파일 공유만을 위해 Longhorn 전체 스토리지 스택을 운영했다.
- 근본 원인: “모델을 이미지에 포함하지 않는다”는 초기 결정을 유지한 채 공유 다운로드 횟수 최소화에 집중해, 모델 크기·변경 빈도에 비해 과도한 기술을 선택했다.
- 확인 방법: 모델 용량과 변경 주기, Longhorn의 노드별 상시 프로세스 및 메모리 비용, ECR 이미지 비용, 장애 지점과 운영 절차를 비교했다.

### 해결 과정

1. 단기적으로 모델 볼륨을 Longhorn PVC에서 노드별 `hostPath`로 전환했다.
2. Ansible 설치 절차에서 Longhorn을 제거하고 Postgres는 `local-path`에 고정했다.
3. 각 노드가 모델을 처음 사용할 때 한 번 내려받고 이후 로컬 캐시를 재사용하도록 기존 initContainer를 유지했다.
4. 장기적으로 모델을 backend 이미지에 포함해 PVC·hostPath·모델 준비 initContainer를 모두 제거하는 전환 계획을 수립했다.

### 해결 결과

- Longhorn의 노드별 상시 메모리 오버헤드와 운영 구성 요소를 제거했다.
- 현재 `hostPath` 방식은 발표 일정에 맞춘 임시 조치다. 새 노드에서는 모델을 다시 내려받아야 하며, 최종적인 이미지 내장 전환은 아직 후속 작업으로 남아 있다.

### 재발 방지 방안

- 설정 또는 코드 변경 사항: Longhorn PVC를 제거하고 `hostPath`로 전환했으며 Ansible의 Longhorn 설치 단계를 제거했다.
- 운영 점검 항목 추가 여부: 새로운 인프라 구성 요소를 도입하기 전에 대상 데이터 크기·변경 빈도·장애 복구 요구·노드별 상시 비용을 검토한다.
- 문서 업데이트 내용: Longhorn 제거 계획, 임시 hostPath의 제약, 최종 이미지 내장 전환 순서를 별도 문서로 남겼다.

---

## 근거 자료

- 모델 자동 준비: INFRA 커밋 `567ce25`
- migrate 기동 순서 수정: INFRA 커밋 `c8c1886`, `e3efd74`
- backend 의존성 대기: INFRA 커밋 `d564c22`
- 전달 프로토콜 보존 및 HTTPS 검증: INFRA 커밋 `343170e`, `5fd13e3`
- web QoS 보장: INFRA 커밋 `5fd13e3`
- Longhorn 제거 계획 및 적용: INFRA 커밋 `cee261c`, `605dc2a`, `e346196`

## 공통 운영 점검 항목

1. 배포 전 `kubectl kustomize`로 최종 매니페스트를 렌더링하고 이미지, 환경변수, probe, resources, volume을 확인한다.
2. 콜드부트 검증은 준비된 클러스터에 재배포하는 방식이 아니라 의존 서비스와 애플리케이션을 동시에 시작해 수행한다.
3. Pod 장애 시 본 컨테이너뿐 아니라 initContainer 로그, event, restart count, probe 결과, Service endpoint를 함께 수집한다.
4. 프록시가 둘 이상이면 각 hop의 Host, Origin, `X-Forwarded-Proto`, client IP 신뢰 범위를 끝까지 추적한다.
5. 외부 스토리지나 operator를 도입할 때는 저장 데이터의 크기보다 상시 자원 비용과 장애 복구 복잡도를 우선 검토한다.
