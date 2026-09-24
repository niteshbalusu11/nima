FROM node:22-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

FROM golang:1.26.1-alpine AS build
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /uploadvideo .

FROM alpine:3.23
RUN apk add --no-cache ca-certificates su-exec && adduser -D -u 10001 app && mkdir /data && chown app /data
COPY --from=build /uploadvideo /usr/local/bin/uploadvideo
COPY --from=web /src/web/dist /usr/share/witness
COPY --chmod=755 server/entrypoint.sh /usr/local/bin/entrypoint.sh
ENV DATABASE_PATH=/data/app.sqlite LISTEN_ADDR=0.0.0.0:8080 WEB_DIR=/usr/share/witness
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
