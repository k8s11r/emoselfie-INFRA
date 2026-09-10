# emoselfie-INFRA

로컬에서 전체 스택을 한 번에 띄우는 구성이다.

```bash
docker compose up --build
```

→ **http://localhost:8080**

## 전제

세 저장소가 같은 상위 디렉터리에 있어야 한다. compose가 `../emoselfie-BE`, `../emoselfie-FE`를 빌드 컨텍스트로 쓴다.

```
project/
├── emoselfie-INFRA/   ← 여기서 실행
├── emoselfie-BE/
└── emoselfie-FE/
```

모델 가중치(94MB)는 저장소에 없지만 **따로 준비할 필요는 없다.** `prepare-models` 서비스가 백엔드보다 먼저 실행되어 내려받고 sha256을 검증한다. 이미 있으면 검증만 하고 1초 안에 끝난다.

받아둔 파일은 `emoselfie-BE/.models/`에 남으므로 네이티브 개발과 캐시를 공유한다. 같은 스크립트를 직접 돌려도 된다.

```bash
cd ../emoselfie-BE && uv run python scripts/prepare_models.py
```

## 구성

```
                         http://localhost:8080
                                  │
                        ┌─────────▼─────────┐
                        │   web (nginx)     │
                        │   FE 정적 빌드     │
                        └─────────┬─────────┘
                                  │ 경로 분기
              ┌───────────────────┼───────────────────┐
              │                   │                   │
        /api/*  /socket.io/*  /media/*            그 외 전부
              │                   │                   │
              └─────────┬─────────┘                   ▼
                        ▼                        정적 자산
                 ┌─────────────┐                 (SPA fallback)
                 │   backend   │
                 │  linux/amd64│
                 └──┬───┬───┬──┘
                    │   │   └──────────┐
             ┌──────▼┐ ┌▼──────┐ ┌─────▼──────┐
             │postgres│ │ redis │ │redis-media │
             └────────┘ └───────┘ └────────────┘
```

| 서비스 | 역할 |
|---|---|
| `web` | nginx. 경로를 갈라 보내고 FE 정적 빌드를 서빙한다 |
| `backend` | FastAPI + Socket.IO + 추론 |
| `prepare-models` | 백엔드보다 먼저 모델을 내려받고 검증한다. K8s의 init container와 같은 역할 |
| `migrate` | 백엔드보다 먼저 한 번 돌고 끝나는 alembic 마이그레이션 |
| `postgres` | 복원과 무결성 |
| `redis` | 실시간 조율. `noeviction` |
| `redis-media` | 결과 이미지 캐시. `allkeys-lru` |

### 왜 nginx가 앞에 있나

사용자 식별 쿠키가 `SameSite=Lax`라(PRD ID-02) 다른 오리진으로는 전송되지 않는다. FE와 BE가 다른 포트에 있으면 브라우저가 별개 사이트로 보고 쿠키를 보내지 않아, 로그인이 없는 이 게임에서 사용자를 식별할 수 없다. spec D-3이 동일 오리진으로 확정한 이유이며, nginx가 그것을 구현한다.

`emoselfie-FE/vite.config.ts`의 dev 프록시가 같은 일을 한다. 네이티브 개발에서는 그쪽을, 도커에서는 이쪽을 쓴다.

## 알아둘 것

**백엔드는 linux/amd64 전용이다.** MediaPipe가 linux/aarch64 휠을 배포하지 않는다. 배포 대상인 EC2가 amd64이므로 로컬과 운영이 같은 이미지를 쓴다. Apple Silicon에서는 Rosetta로 실행되며 추론이 네이티브보다 느리다. Graviton 계열로 옮기면 같은 문제가 생긴다.

**첫 기동은 오래 걸린다.** 백엔드 이미지가 torch를 포함해 크고, 컨테이너가 뜬 뒤에도 모델 로드와 warmup이 끝나야 `/health/ready`가 통과한다. `web`은 그때까지 기다린다.

**시크릿은 로컬 전용 기본값이다.** compose에 박힌 값은 운영에 쓰면 안 된다. 바꾸려면 `.env`에 넣거나 환경변수로 덮는다.

```bash
COOKIE_SECRET=$(python3 -c 'import secrets;print(secrets.token_urlsafe(48))') docker compose up
```

**DB·Redis 포트는 호스트로 열지 않았다.** `emoselfie-BE/compose.yaml`이 같은 포트를 쓰고 있어 충돌하기 때문이다. 직접 붙으려면:

```bash
docker compose exec postgres psql -U emoselfie -d emoselfie
docker compose exec redis redis-cli
```

**Safari 대응으로 nginx가 쿠키의 `Secure`를 떼낸다.** 백엔드는 항상 `secure=True`로 발급하는데(`app/api/middleware.py:62`) Safari는 http 오리진에 Secure 쿠키를 저장하지 않는다. localhost도 예외가 아니다. TLS를 붙이면 `nginx/default.conf`의 `proxy_cookie_flags` 세 줄을 지운다.

## 자주 쓰는 명령

```bash
docker compose up --build          # 빌드하고 실행
docker compose up -d               # 백그라운드
docker compose logs -f backend     # 백엔드 로그
docker compose ps                  # 상태와 healthcheck
docker compose down                # 정지
docker compose down -v             # DB까지 삭제
```

## 미해결

- 이미지 크기 — `uv.lock`이 x86_64 linux에서 torch의 CUDA 휠과 nvidia 패키지를 함께 해석한다. 서버는 CPU만 쓰므로 `download.pytorch.org/whl/cpu` 인덱스를 고정하고 lock을 재생성해야 한다. `emoselfie-BE`의 `BE-063`.
- TLS — 현재 http다. `PM-14`는 전 구간 HTTPS를 전제하므로 카메라 API 검증에는 터널(`emoselfie-FE/scripts/dev-tunnel.sh`)이나 로컬 인증서가 필요하다. `BE-064`.
- 추론 속도 — Rosetta에서 `SC-07`의 5초 타임아웃 안에 드는지 측정이 필요하다.
