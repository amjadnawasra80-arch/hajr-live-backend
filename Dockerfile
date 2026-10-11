# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM golang:1.25-alpine AS builder
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

# ---- Runtime stage ----
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S app && adduser -S -G app app

COPY --from=builder /out/api /usr/local/bin/api

USER app
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/api"]
