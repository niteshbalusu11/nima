FROM node:22-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm test && npm run build

FROM golang:1.26.1-alpine AS build
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /uploadvideo .

FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gosu \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir opencv-python-headless==4.11.0.86 numpy==2.5.3 \
    && useradd -u 10001 -m app && mkdir /data /usr/local/share/nima && chown app:app /data
RUN curl -fsSL https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx -o /usr/local/share/nima/face_detection_yunet_2023mar.onnx \
    && curl -fsSL https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx -o /usr/local/share/nima/face_recognition_sface_2021dec.onnx \
    && echo '8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4  /usr/local/share/nima/face_detection_yunet_2023mar.onnx' | sha256sum -c - \
    && echo '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79  /usr/local/share/nima/face_recognition_sface_2021dec.onnx' | sha256sum -c -
COPY --from=build /uploadvideo /usr/local/bin/uploadvideo
COPY --from=web /src/web/dist /usr/share/witness
COPY server/face_detector.py /usr/local/lib/nima/face_detector.py
COPY --chmod=755 server/entrypoint.sh /usr/local/bin/entrypoint.sh
ENV DATABASE_PATH=/data/app.sqlite LISTEN_ADDR=0.0.0.0:8080 WEB_DIR=/usr/share/witness \
    FACE_DETECTOR_SCRIPT=/usr/local/lib/nima/face_detector.py FACE_MODEL_DIR=/usr/local/share/nima
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
