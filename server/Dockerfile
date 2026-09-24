FROM golang:1.26.1-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /uploadvideo .

FROM alpine:3.23
RUN apk add --no-cache ca-certificates su-exec && adduser -D -u 10001 app && mkdir /data && chown app /data
COPY --from=build /uploadvideo /usr/local/bin/uploadvideo
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV DATABASE_PATH=/data/app.sqlite LISTEN_ADDR=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
