# ─────────────────────────────────────────────
# Stage 1: Flutter 웹 빌드
# ─────────────────────────────────────────────
FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /app

# 의존성 먼저 캐시 (레이어 최적화)
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# 소스 복사 후 빌드
COPY lib/   lib/
COPY web/   web/

RUN flutter build web --release

# ─────────────────────────────────────────────
# Stage 2: Python 서버 실행
# ─────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# 빌드된 웹 파일 + 서버 복사
COPY server.py .
COPY --from=builder /app/build/web ./build/web

EXPOSE 8080

CMD ["python3", "server.py"]
