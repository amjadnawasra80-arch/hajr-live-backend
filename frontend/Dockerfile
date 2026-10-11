# syntax=docker/dockerfile:1

# ---- Build stage: Flutter web ----
FROM ghcr.io/cirruslabs/flutter:stable AS builder
WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .
# "origin" = call the API on the same origin as the page (nginx proxies /api and /ws to the backend).
ARG API_BASE_URL=origin
RUN flutter build web --release --dart-define=API_BASE_URL=${API_BASE_URL}

# ---- Runtime stage: nginx ----
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/build/web /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
