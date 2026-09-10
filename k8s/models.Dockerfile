# 모델 가중치를 백엔드 이미지에 굽는다.
#
# emoselfie-BE의 Dockerfile은 가중치를 이미지에 넣지 않고 런타임 마운트를
# 전제한다. compose는 호스트 파일을 bind mount하면 되지만 k8s는 노드가 여러
# 대라 파일을 수동으로 뿌리고 동기화해야 한다. BE 저장소를 건드리지 않고
# 레이어 하나만 얹는다.
#
#   cd ../emoselfie-BE && uv run python scripts/prepare_models.py   # 최초 1회
#   docker build -f k8s/models.Dockerfile \
#     --build-arg BASE=emoselfie-backend:local \
#     -t emoselfie-backend:with-models ../emoselfie-BE
ARG BASE=emoselfie-backend:local
FROM ${BASE}

COPY .models/FER_static_ResNet50_AffectNet.pt /models/emotion/v1/FER_static_ResNet50_AffectNet.pt
COPY .models/blaze_face_short_range.tflite    /models/face/v1/blaze_face_short_range.tflite
