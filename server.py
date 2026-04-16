#!/usr/bin/env python3
import json, time, threading, gzip, os, mimetypes
from http.server import HTTPServer, SimpleHTTPRequestHandler
from collections import defaultdict

# ── 정적 파일 gzip 캐시 (서버 시작 시 미리 압축) ──────────────────────────────
_gz_cache: dict = {}   # path -> (compressed_bytes, mime)

def _precompress():
    """build/web 의 큰 파일들 미리 gzip 압축"""
    targets = ['.js', '.wasm', '.css', '.html', '.json']
    base = 'build/web'
    for root, _, files in os.walk(base):
        for fname in files:
            if any(fname.endswith(ext) for ext in targets):
                fpath = os.path.join(root, fname)
                url   = '/' + os.path.relpath(fpath, base).replace('\\', '/')
                try:
                    data  = open(fpath, 'rb').read()
                    _gz_cache[url] = (gzip.compress(data, compresslevel=6), data)
                except Exception:
                    pass
    print(f"[서버] {len(_gz_cache)}개 파일 gzip 압축 완료")

# ── 보안 설정 ──────────────────────────────────────────────────────────────────
ADMIN_TOKEN = "tbchan_9x2kL8mP_secret"   # admin API 인증 토큰
_rate_data  = defaultdict(list)            # ip -> [timestamp, ...]

# ── Web Push (VAPID) ───────────────────────────────────────────────────────────
VAPID_PUBLIC  = "BAi0LZJZwc6pSv9-PocK2b7vcvgELRl_1Lh2BO0yxp6QQgaeUwQ4pXuxCsVuDA0OLrnHCYovZzBy6OFGyHdcjfc"
VAPID_PRIVATE = "EU_tIUVoW9YlH3TEYJ9n9P8DWS5SQnqPixuONZcyH40"
VAPID_CLAIMS  = {"sub": "mailto:tabangchan@tabangchan.site"}

_push_subs = {}   # room -> subscription_info dict

def _send_push(room, title, body):
    """room에 등록된 구독에 푸시 전송 (별도 스레드)"""
    sub = _push_subs.get(room)
    if not sub: return
    def _do():
        try:
            from pywebpush import webpush, WebPushException
            webpush(
                subscription_info=sub,
                data=json.dumps({"title": title, "body": body}),
                vapid_private_key=VAPID_PRIVATE,
                vapid_claims=VAPID_CLAIMS,
            )
        except Exception as e:
            print(f"push 실패 ({room}): {e}")
    threading.Thread(target=_do, daemon=True).start()

def _rate_ok(ip, limit=60, window=60):
    """60초에 60회 초과 시 차단"""
    now = time.time()
    times = [t for t in _rate_data[ip] if now - t < window]
    _rate_data[ip] = times
    if len(times) >= limit:
        return False
    times.append(now)
    return True

ROOM_IDS = [
    "201","202","203","204","205","206","207","208","209","210",
    "211","212","213","214","215","세탁실",
    "216","217","218","219","220","221","222","223","224","225","226","227"
]

def _init_laundry():
    machines = []
    for group in ['A', 'B']:
        for slot in range(1, 5):
            for mtype in ['dryer', 'washer']:
                machines.append({
                    "id": f"{group}{slot}{'D' if mtype=='dryer' else 'W'}",
                    "type": mtype, "group": group, "slot": slot,
                    "status": "idle", "end_time": None, "room": None, "name": None,
                })
    return machines

state = {
    "rooms": {id: {"occupancy": 0 if id == "세탁실" else 2} for id in ROOM_IDS},
    "requests": [],
    "messages": [],
    "history": [],
    "scores": {},
    "tier_requests": [],
    "laundry": _init_laundry(),
    "streak_dates": {},   # room -> ["YYYY-MM-DD", ...]
    "laundry_schedule": {"월":[],"화":[],"수":[],"목":[],"금":[],"토":[],"일":[]},
    "trade_items": [],    # [{id, room, name, item_name, want_item, status, time}]
    "trade_requests": [], # [{id, item_id, from_room, from_name, offer_item, status, meet_place, time}]
}

def _update_laundry():
    now = time.time()
    for m in state["laundry"]:
        if m["status"] == "running" and m["end_time"] and now >= m["end_time"]:
            m["status"] = "done"
_nid = [0]

def _id():
    _nid[0] += 1
    return _nid[0]

def _now():
    return time.strftime("%m/%d %H:%M")

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="build/web", **kwargs)

    def _ip(self):
        return self.headers.get("CF-Connecting-IP") or \
               self.headers.get("X-Forwarded-For", "").split(",")[0].strip() or \
               self.client_address[0]

    def _admin_ok(self):
        return self.headers.get("X-Admin-Token", "") == ADMIN_TOKEN

    def do_OPTIONS(self):
        self.send_response(200); self._cors(); self.end_headers()

    def do_GET(self):
        ip = self._ip()
        if not _rate_ok(ip):
            self.send_response(429); self._cors(); self.end_headers(); return
        if self.path == "/api/state":
            _update_laundry()
            self._json(state)
        elif self.path == "/push_sw.js":
            # push SW: 스코프 헤더 + no-cache
            self._serve_static("/push_sw.js", extra_headers={
                "Service-Worker-Allowed": "/push-scope/",
                "Cache-Control": "no-cache",
            })
        else:
            # SPA: 파일 없으면 index.html 서빙
            self._serve_static(self.path)

    def do_POST(self):
        ip = self._ip()
        if not _rate_ok(ip):
            self.send_response(429); self._cors(); self.end_headers(); return

        # admin 엔드포인트 토큰 검증
        if self.path.startswith("/api/admin/") and not self._admin_ok():
            self._json({"ok": False, "error": "unauthorized"}); return

        n = int(self.headers.get("Content-Length", 0))
        if n > 10240:  # 10KB 초과 요청 차단
            self._json({"ok": False, "error": "too_large"}); return
        try:
            raw  = self.rfile.read(n) if n else b''
            body = json.loads(raw) if raw.strip() else {}
        except Exception:
            self._json({"ok": False, "error": "bad_request"})
            return

        if self.path == "/api/push/subscribe":
            room = body.get("room", "")
            sub  = body.get("subscription")
            if room and sub:
                _push_subs[room] = sub
            self._json({"ok": True}); return

        elif self.path == "/api/push/unsubscribe":
            room = body.get("room", "")
            _push_subs.pop(room, None)
            self._json({"ok": True}); return

        elif self.path == "/api/request":
            fr, to = body["from"], body["to"]
            if not any(r["from_room"] == fr and r["status"] == "pending" for r in state["requests"]):
                state["requests"].append({
                    "id": _id(), "from_room": fr, "to_room": to,
                    "status": "pending", "name": body.get("name",""), "reason": body.get("reason",""),
                })
                # 방문 대상 방에 push 알림
                name = body.get("name", fr)
                _send_push(to, "🚪 타방 신청 도착!", f"{fr}호 {name}님이 방문 신청했습니다.")

        elif self.path == "/api/approve":
            for r in state["requests"]:
                if r["id"] == body["id"] and r["status"] == "pending":
                    r["status"] = "approved"
                    # 신청자 방에 push 알림
                    _send_push(r["from_room"], "✅ 타방 승인됨!", f"{r['to_room']}호 방문이 승인되었습니다.")
                    break

        elif self.path == "/api/complete_move":
            req_id = body["id"]
            fr, to = body["from"], body["to"]
            name = body.get("name", "")
            req = next((r for r in state["requests"] if r["id"] == req_id), None)
            reason = req.get("reason", "") if req else ""
            # from 방 인원이 있을 때만 감소 (음수 방지), to 방은 제한 없이 증가
            if state["rooms"][fr]["occupancy"] > 0:
                state["rooms"][fr]["occupancy"] -= 1
            state["rooms"][to]["occupancy"] += 1
            state["history"].append({
                "id": _id(), "from_room": fr, "to_room": to,
                "name": name, "reason": reason, "time": _now(), "type": "visit",
            })
            state["requests"] = [r for r in state["requests"] if r["id"] != req_id]

        elif self.path in ("/api/reject", "/api/cancel", "/api/delete_request"):
            state["requests"] = [r for r in state["requests"] if r["id"] != body["id"]]

        elif self.path == "/api/return":
            fr, to = body["from"], body["to"]
            name = body.get("name", "")
            if state["rooms"][fr]["occupancy"] > 0:
                state["rooms"][fr]["occupancy"] -= 1
                state["rooms"][to]["occupancy"] += 1
                state["history"].append({
                    "id": _id(), "from_room": fr, "to_room": to,
                    "name": name, "reason": "", "time": _now(), "type": "return",
                })

        elif self.path == "/api/chat":
            state["messages"].append({"id": _id(), "room": body["room"], "msg": body["msg"]})
            if len(state["messages"]) > 100:
                state["messages"] = state["messages"][-100:]

        elif self.path == "/api/tier_request":
            if not any(r["room"] == body["room"] and r["status"] == "pending" for r in state["tier_requests"]):
                state["tier_requests"].append({
                    "id": _id(), "room": body["room"], "name": body.get("name",""),
                    "visited_room": body.get("visited_room",""), "time": _now(), "status": "pending",
                })

        elif self.path == "/api/admin/set_occupancy":
            room, val = body["room"], max(0, int(body["value"]))
            if room in state["rooms"]:
                state["rooms"][room]["occupancy"] = val

        elif self.path == "/api/admin/reset_rooms":
            for id in ROOM_IDS:
                state["rooms"][id]["occupancy"] = 0 if id == "세탁실" else 2

        elif self.path == "/api/admin/set_score":
            state["scores"][body["room"]] = max(0, int(body["points"]))

        elif self.path == "/api/admin/approve_tier":
            for r in state["tier_requests"]:
                if r["id"] == body["id"]:
                    pts = max(0, int(body["points"]))
                    room = r["room"]
                    state["scores"][room] = state["scores"].get(room, 0) + pts
                    # 스트릭: 인증 날짜 기록
                    today = time.strftime("%Y-%m-%d")
                    if room not in state["streak_dates"]:
                        state["streak_dates"][room] = []
                    if today not in state["streak_dates"][room]:
                        state["streak_dates"][room].append(today)
                    break
            state["tier_requests"] = [r for r in state["tier_requests"] if r["id"] != body["id"]]

        elif self.path == "/api/admin/reject_tier":
            state["tier_requests"] = [r for r in state["tier_requests"] if r["id"] != body["id"]]

        elif self.path == "/api/laundry/start":
            mid     = body["id"]
            minutes = int(body["minutes"])
            room    = body.get("room", "")
            # 해당 기기의 type 파악
            mtype = next((m["type"] for m in state["laundry"] if m["id"] == mid), None)
            # 1인 1기기 체크 (같은 타입이 이미 running)
            already = any(
                m["room"] == room and m["type"] == mtype and m["status"] == "running"
                for m in state["laundry"]
            )
            if already:
                self._json({"ok": False, "error": "already_running"})
                return
            for m in state["laundry"]:
                if m["id"] == mid and m["status"] == "idle":
                    m["status"]   = "running"
                    m["end_time"] = time.time() + minutes * 60
                    m["room"]     = room
                    m["name"]     = body.get("name", "")
                    break

        elif self.path in ("/api/laundry/pickup", "/api/laundry/cancel"):
            for m in state["laundry"]:
                if m["id"] == body["id"]:
                    m["status"] = "idle"
                    m["end_time"] = None
                    m["room"] = None
                    m["name"] = None
                    break

        elif self.path == "/api/admin/laundry/reset":
            for m in state["laundry"]:
                if m["id"] == body["id"]:
                    m["status"] = "idle"
                    m["end_time"] = None
                    m["room"] = None
                    m["name"] = None
                    break

        elif self.path == "/api/laundry_schedule/reserve":
            day, room = body["day"], body["room"]
            name = body.get("name", "")
            sched = state["laundry_schedule"].setdefault(day, [])
            # 같은 방이 이미 예약했으면 무시
            if not any(e["room"] == room for e in sched):
                sched.append({"room": room, "name": name})

        elif self.path == "/api/laundry_schedule/cancel":
            day, room = body["day"], body["room"]
            sched = state["laundry_schedule"].get(day, [])
            state["laundry_schedule"][day] = [e for e in sched if e["room"] != room]

        elif self.path == "/api/admin/laundry_schedule/reset":
            state["laundry_schedule"] = {"월":[],"화":[],"수":[],"목":[],"금":[],"토":[],"일":[]}

        elif self.path == "/api/admin/laundry/reset_all":
            for m in state["laundry"]:
                m["status"] = "idle"
                m["end_time"] = None
                m["room"] = None
                m["name"] = None

        elif self.path == "/api/admin/laundry/set":
            minutes = int(body.get("minutes", 60))
            for m in state["laundry"]:
                if m["id"] == body["id"]:
                    m["status"] = "running"
                    m["end_time"] = time.time() + minutes * 60
                    m["room"] = body.get("room", "")
                    m["name"] = body.get("room", "")
                    break

        # ── 물물찬 ──────────────────────────────────────────────────────────────

        elif self.path == "/api/trade/post":
            room = body.get("room", "")
            item_name = body.get("item_name", "").strip()
            want_item = body.get("want_item", "").strip()
            if room and item_name and want_item:
                state["trade_items"].append({
                    "id": _id(), "room": room, "name": body.get("name", ""),
                    "item_name": item_name, "want_item": want_item,
                    "status": "available", "time": _now(),
                })

        elif self.path == "/api/trade/delete_item":
            iid = body["item_id"]
            room = body.get("room", "")
            state["trade_items"] = [
                t for t in state["trade_items"]
                if not (t["id"] == iid and t["room"] == room)
            ]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["item_id"] != iid]

        elif self.path == "/api/trade/request":
            iid = body["item_id"]
            fr = body["from_room"]
            # 이미 신청한 경우 무시
            if not any(r["item_id"] == iid and r["from_room"] == fr for r in state["trade_requests"]):
                req = {
                    "id": _id(), "item_id": iid, "from_room": fr,
                    "from_name": body.get("from_name", ""),
                    "offer_item": body.get("offer_item", "").strip(),
                    "status": "pending", "meet_place": "", "time": _now(),
                }
                state["trade_requests"].append(req)
                # 물건 주인에게 push 알림
                item = next((t for t in state["trade_items"] if t["id"] == iid), None)
                if item:
                    _send_push(item["room"], "🔄 물물 교환 신청!", f"{fr}호 {req['from_name']}님이 교환을 신청했습니다.")

        elif self.path == "/api/trade/accept":
            rid = body["request_id"]
            meet = body.get("meet_place", "").strip()
            for r in state["trade_requests"]:
                if r["id"] == rid and r["status"] == "pending":
                    r["status"] = "accepted"
                    r["meet_place"] = meet
                    # 물건 상태 traded로
                    for t in state["trade_items"]:
                        if t["id"] == r["item_id"]:
                            t["status"] = "traded"
                            break
                    # 신청자에게 push 알림
                    _send_push(r["from_room"], "✅ 교환 승인됨!", f"교환이 승인되었습니다. {meet or '장소 미정'}")
                    break
            # 나머지 pending 신청 거절
            item_id = next((r["item_id"] for r in state["trade_requests"] if r["id"] == rid), None)
            if item_id:
                for r in state["trade_requests"]:
                    if r["item_id"] == item_id and r["id"] != rid and r["status"] == "pending":
                        r["status"] = "rejected"

        elif self.path == "/api/trade/reject":
            rid = body["request_id"]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["id"] != rid]

        elif self.path == "/api/trade/cancel":
            rid = body["request_id"]
            fr = body.get("from_room", "")
            state["trade_requests"] = [
                r for r in state["trade_requests"]
                if not (r["id"] == rid and r["from_room"] == fr)
            ]

        elif self.path == "/api/trade/complete":
            iid = body["item_id"]
            state["trade_items"] = [t for t in state["trade_items"] if t["id"] != iid]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["item_id"] != iid]

        elif self.path == "/api/admin/trade/delete":
            iid = body["item_id"]
            state["trade_items"] = [t for t in state["trade_items"] if t["id"] != iid]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["item_id"] != iid]

        elif self.path == "/api/admin/trade/reset":
            state["trade_items"] = []
            state["trade_requests"] = []

        self._json({"ok": True})

    def _serve_static(self, url_path, extra_headers=None):
        """gzip 압축 + 캐시 헤더로 정적 파일 서빙"""
        # URL 정리 (쿼리스트링 제거)
        clean = url_path.split('?')[0]
        if clean == '/': clean = '/index.html'

        # 캐시에서 찾기
        entry = _gz_cache.get(clean)
        if entry is None:
            # 파일이 없으면 index.html (SPA 라우팅)
            entry = _gz_cache.get('/index.html')
            if entry is None:
                self.send_response(404); self.end_headers(); return
            clean = '/index.html'

        gz_data, raw_data = entry
        mime, _ = mimetypes.guess_type(clean)
        mime = mime or 'application/octet-stream'

        # 서비스워커 파일은 no-cache, 나머지 JS/WASM은 장기 캐시
        no_cache_paths = {'/index.html', '/flutter_service_worker.js',
                          '/flutter_bootstrap.js', '/push_sw.js', '/manifest.json'}
        if clean in no_cache_paths:
            cache = 'no-cache, no-store, must-revalidate'
        elif clean.endswith(('.wasm', '.js', '.css', '.png', '.ico')):
            cache = 'public, max-age=31536000, immutable'
        else:
            cache = 'public, max-age=3600'

        accept_enc = self.headers.get('Accept-Encoding', '')
        use_gzip = 'gzip' in accept_enc and len(raw_data) > 512

        body = gz_data if use_gzip else raw_data
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', cache)
        if use_gzip:
            self.send_header('Content-Encoding', 'gzip')
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, data):
        b = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self._cors(); self.end_headers(); self.wfile.write(b)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, *a): pass

class TabangServer(HTTPServer):
    def handle_error(self, request, client_address):
        import sys
        if sys.exc_info()[0] in (BrokenPipeError, ConnectionResetError): pass
        else: super().handle_error(request, client_address)

if __name__ == "__main__":
    _precompress()   # 서버 시작 시 정적 파일 미리 gzip 압축
    server = TabangServer(("0.0.0.0", 8080), Handler)
    print("타방찬 서버 실행 중: http://localhost:8080")
    server.serve_forever()
