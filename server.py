#!/usr/bin/env python3
import json, time, threading
from http.server import HTTPServer, SimpleHTTPRequestHandler
from collections import defaultdict

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
        else:
            super().do_GET()

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

        self._json({"ok": True})

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
    server = TabangServer(("0.0.0.0", 8080), Handler)
    print("타방찬 서버 실행 중: http://localhost:8080")
    server.serve_forever()
