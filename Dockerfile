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

# 커스텀 아이콘 강제 덮어쓰기 (Flutter 빌드와 완전히 분리된 전용 폴더)
COPY custom_icons/Icon-192.png         ./build/web/icons/Icon-192.png
COPY custom_icons/Icon-maskable-192.png ./build/web/icons/Icon-maskable-192.png
COPY custom_icons/Icon-512.png         ./build/web/icons/Icon-512.png
COPY custom_icons/Icon-maskable-512.png ./build/web/icons/Icon-maskable-512.png
COPY custom_icons/favicon.png          ./build/web/favicon.png

RUN pip install --no-cache-dir pywebpush

EXPOSE 8080

CMD ["python3", "server.py"]
