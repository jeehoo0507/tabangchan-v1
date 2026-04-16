#!/usr/bin/env python3
import json, time, threading, gzip, os
from http.server import HTTPServer, SimpleHTTPRequestHandler
from collections import defaultdict

# ── main.dart.js gzip 캐시 ────────────────────────────────────────────────────
_main_js_gz = b""

def _load_main_js():
    global _main_js_gz
    path = "build/web/main.dart.js"
    if os.path.exists(path):
        raw = open(path, "rb").read()
        _main_js_gz = gzip.compress(raw, compresslevel=6)
        print(f"[서버] main.dart.js: {len(raw)//1024}KB → {len(_main_js_gz)//1024}KB ({100-len(_main_js_gz)*100//len(raw)}% 압축)")

# ── 보안 설정 ──────────────────────────────────────────────────────────────────
ADMIN_TOKEN = "tbchan_9x2kL8mP_secret"
_rate_data  = defaultdict(list)

def _rate_ok(ip, limit=60, window=60):
    now = time.time()
    times = [t for t in _rate_data[ip] if now - t < window]
    _rate_data[ip] = times
    if len(times) >= limit:
        return False
    times.append(now)
    return True

# ── Web Push (VAPID) ───────────────────────────────────────────────────────────
VAPID_PUBLIC  = "BAi0LZJZwc6pSv9-PocK2b7vcvgELRl_1Lh2BO0yxp6QQgaeUwQ4pXuxCsVuDA0OLrnHCYovZzBy6OFGyHdcjfc"
VAPID_PRIVATE = "EU_tIUVoW9YlH3TEYJ9n9P8DWS5SQnqPixuONZcyH40"
VAPID_CLAIMS  = {"sub": "mailto:tabangchan@tabangchan.site"}
_push_subs = {}

def _send_push(room, title, body):
    sub = _push_subs.get(room)
    if not sub: return
    def _do():
        try:
            from pywebpush import webpush
            webpush(subscription_info=sub,
                    data=json.dumps({"title": title, "body": body}),
                    vapid_private_key=VAPID_PRIVATE, vapid_claims=VAPID_CLAIMS)
        except Exception as e:
            print(f"push 실패 ({room}): {e}")
    threading.Thread(target=_do, daemon=True).start()

# ── 데이터 영속성 ──────────────────────────────────────────────────────────────
DATA_DIR   = "data"
STATE_FILE = os.path.join(DATA_DIR, "state.json")
PUSH_FILE  = os.path.join(DATA_DIR, "push_subs.json")
_save_timer = None
_save_lock  = threading.Lock()

def _schedule_save():
    """2초 디바운스 후 저장 (요청마다 즉시 저장하지 않도록)"""
    global _save_timer
    if _save_timer:
        _save_timer.cancel()
    _save_timer = threading.Timer(2.0, _do_save)
    _save_timer.start()

def _do_save():
    os.makedirs(DATA_DIR, exist_ok=True)
    with _save_lock:
        # state 저장 (atomic: tmp → rename)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=None)
        os.replace(tmp, STATE_FILE)
        # push 구독 저장
        tmp2 = PUSH_FILE + ".tmp"
        with open(tmp2, "w", encoding="utf-8") as f:
            json.dump(_push_subs, f, ensure_ascii=False)
        os.replace(tmp2, PUSH_FILE)

def _load_saved():
    global _push_subs
    # push 구독 복원
    if os.path.exists(PUSH_FILE):
        try:
            _push_subs = json.load(open(PUSH_FILE, encoding="utf-8"))
            print(f"[서버] push 구독 {len(_push_subs)}개 복원")
        except Exception as e:
            print(f"[서버] push 복원 실패: {e}")
    # state 복원
    if not os.path.exists(STATE_FILE):
        print("[서버] 저장된 상태 없음 — 새로 시작")
        return
    try:
        saved = json.load(open(STATE_FILE, encoding="utf-8"))
        for k, v in saved.items():
            if k in state:
                state[k] = v
        # _nid를 저장된 최대 ID로 설정 (중복 방지)
        max_id = 0
        for lst in [state["requests"], state["messages"], state["history"],
                    state["tier_requests"], state["trade_items"], state["trade_requests"]]:
            for item in lst:
                if isinstance(item.get("id"), int):
                    max_id = max(max_id, item["id"])
        _nid[0] = max_id
        print(f"[서버] 상태 복원 완료 — 메시지 {len(state['messages'])}개, 점수 {len(state['scores'])}개, ID={max_id}")
    except Exception as e:
        print(f"[서버] 상태 복원 실패: {e}")

# ── 초기 상태 ──────────────────────────────────────────────────────────────────
ROOM_IDS = [
    "201","202","203","204","205","206","207","208","209","210",
    "211","212","213","214","215","세탁실",
    "216","217","218","219","220","221","222","223","224","225","226","227"
]
VALID_ROOMS = set(ROOM_IDS)

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
    "rooms":    {id: {"occupancy": 0 if id == "세탁실" else 2} for id in ROOM_IDS},
    "requests": [],
    "messages": [],
    "history":  [],
    "scores":   {},
    "tier_requests": [],
    "laundry":  _init_laundry(),
    "streak_dates": {},
    "laundry_schedule": {"월":[],"화":[],"수":[],"목":[],"금":[],"토":[],"일":[]},
    "trade_items":    [],
    "trade_requests": [],
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

def _clean(s, max_len=200):
    """문자열 길이 제한 + 기본 정제"""
    return str(s).strip()[:max_len]

# ── HTTP 핸들러 ────────────────────────────────────────────────────────────────
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="build/web", **kwargs)

    def _ip(self):
        return (self.headers.get("CF-Connecting-IP") or
                self.headers.get("X-Forwarded-For", "").split(",")[0].strip() or
                self.client_address[0])

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
        elif self.path == "/main.dart.js" and _main_js_gz:
            use_gz = "gzip" in self.headers.get("Accept-Encoding", "")
            body = _main_js_gz if use_gz else open("build/web/main.dart.js", "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
            if use_gz: self.send_header("Content-Encoding", "gzip")
            self.end_headers(); self.wfile.write(body)
        elif self.path == "/push_sw.js":
            fpath = "build/web/push_sw.js"
            if os.path.exists(fpath):
                self.send_response(200)
                self.send_header("Content-Type", "application/javascript")
                self.send_header("Service-Worker-Allowed", "/push-scope/")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                self.wfile.write(open(fpath, "rb").read())
            else:
                self.send_response(404); self.end_headers()
        elif self.path == "/flutter_service_worker.js":
            # 서비스 워커는 항상 최신 버전 확인하도록 no-cache 강제
            fpath = "build/web/flutter_service_worker.js"
            if os.path.exists(fpath):
                body = open(fpath, "rb").read()
                self.send_response(200)
                self.send_header("Content-Type", "application/javascript")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.send_header("Pragma", "no-cache")
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404); self.end_headers()
        elif self.path in ("/flutter.js", "/manifest.json"):
            # flutter.js, manifest도 캐시 금지
            fpath = f"build/web{self.path}"
            if os.path.exists(fpath):
                ctype = "application/javascript" if self.path.endswith(".js") else "application/json"
                body = open(fpath, "rb").read()
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404); self.end_headers()
        else:
            super().do_GET()

    def do_POST(self):
        ip = self._ip()
        if not _rate_ok(ip):
            self.send_response(429); self._cors(); self.end_headers(); return

        if self.path.startswith("/api/admin/") and not self._admin_ok():
            self._json({"ok": False, "error": "unauthorized"}); return

        n = int(self.headers.get("Content-Length", 0))
        if n > 10240:
            self._json({"ok": False, "error": "too_large"}); return
        try:
            raw  = self.rfile.read(n) if n else b''
            body = json.loads(raw) if raw.strip() else {}
        except Exception:
            self._json({"ok": False, "error": "bad_request"}); return

        # ── push 구독 ─────────────────────────────���───────────────────────────
        if self.path == "/api/push/subscribe":
            room = body.get("room", "")
            sub  = body.get("subscription")
            if room in VALID_ROOMS and sub:
                _push_subs[room] = sub
                _schedule_save()
            self._json({"ok": True}); return

        elif self.path == "/api/push/unsubscribe":
            _push_subs.pop(body.get("room", ""), None)
            _schedule_save()
            self._json({"ok": True}); return

        # ── 타방 ──────────────────────────────────────────────────────────────
        elif self.path == "/api/request":
            fr = _clean(body.get("from", ""), 10)
            to = _clean(body.get("to", ""), 10)
            if fr not in VALID_ROOMS or to not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid_room"}); return
            if not any(r["from_room"] == fr and r["status"] == "pending" for r in state["requests"]):
                name = _clean(body.get("name", fr), 20)
                state["requests"].append({
                    "id": _id(), "from_room": fr, "to_room": to,
                    "status": "pending", "name": name,
                    "reason": _clean(body.get("reason", ""), 100),
                })
                _send_push(to, "🚪 타방 신청 도착!", f"{fr}호 {name}님이 방문 신청했습니다.")

        elif self.path == "/api/approve":
            for r in state["requests"]:
                if r["id"] == body.get("id") and r["status"] == "pending":
                    r["status"] = "approved"
                    _send_push(r["from_room"], "✅ 타방 승인됨!", f"{r['to_room']}호 방문이 승인되었습니다.")
                    break

        elif self.path == "/api/complete_move":
            req_id = body.get("id")
            fr = _clean(body.get("from", ""), 10)
            to = _clean(body.get("to", ""), 10)
            if fr not in VALID_ROOMS or to not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid_room"}); return
            name   = _clean(body.get("name", ""), 20)
            req    = next((r for r in state["requests"] if r["id"] == req_id), None)
            reason = req.get("reason", "") if req else ""
            if state["rooms"][fr]["occupancy"] > 0:
                state["rooms"][fr]["occupancy"] -= 1
            state["rooms"][to]["occupancy"] += 1
            state["history"].append({
                "id": _id(), "from_room": fr, "to_room": to,
                "name": name, "reason": reason, "time": _now(), "type": "visit",
            })
            state["requests"] = [r for r in state["requests"] if r["id"] != req_id]

        elif self.path in ("/api/reject", "/api/cancel", "/api/delete_request"):
            state["requests"] = [r for r in state["requests"] if r["id"] != body.get("id")]

        elif self.path == "/api/return":
            fr = _clean(body.get("from", ""), 10)
            to = _clean(body.get("to", ""), 10)
            if fr not in VALID_ROOMS or to not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid_room"}); return
            name = _clean(body.get("name", ""), 20)
            if state["rooms"][fr]["occupancy"] > 0:
                state["rooms"][fr]["occupancy"] -= 1
                state["rooms"][to]["occupancy"] += 1
                state["history"].append({
                    "id": _id(), "from_room": fr, "to_room": to,
                    "name": name, "reason": "", "time": _now(), "type": "return",
                })

        # ── 채팅 ──────────────────────────────────────────────────────────────
        elif self.path == "/api/chat":
            room = _clean(body.get("room", ""), 10)
            msg  = _clean(body.get("msg", ""), 300)  # 채팅 최대 300자
            if room not in VALID_ROOMS or not msg:
                self._json({"ok": False, "error": "invalid"}); return
            state["messages"].append({"id": _id(), "room": room, "msg": msg, "time": _now()})
            if len(state["messages"]) > 200:  # 최근 200개만 유지
                state["messages"] = state["messages"][-200:]

        # ── 티어 ──────────────────────────────────────────────────────────────
        elif self.path == "/api/tier_request":
            room = _clean(body.get("room", ""), 10)
            if room not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid_room"}); return
            if not any(r["room"] == room and r["status"] == "pending" for r in state["tier_requests"]):
                state["tier_requests"].append({
                    "id": _id(), "room": room, "name": _clean(body.get("name", ""), 20),
                    "visited_room": _clean(body.get("visited_room", ""), 10),
                    "time": _now(), "status": "pending",
                })

        # ── admin: 방/점수 ─────────────────────────────────────────────────────
        elif self.path == "/api/admin/set_occupancy":
            room = body.get("room", "")
            if room in state["rooms"]:
                state["rooms"][room]["occupancy"] = max(0, min(99, int(body.get("value", 0))))

        elif self.path == "/api/admin/reset_rooms":
            for id in ROOM_IDS:
                state["rooms"][id]["occupancy"] = 0 if id == "세탁실" else 2

        elif self.path == "/api/admin/set_score":
            room = body.get("room", "")
            if room in VALID_ROOMS:
                state["scores"][room] = max(0, int(body.get("points", 0)))

        elif self.path == "/api/admin/approve_tier":
            for r in state["tier_requests"]:
                if r["id"] == body.get("id"):
                    pts  = max(0, int(body.get("points", 0)))
                    room = r["room"]
                    state["scores"][room] = state["scores"].get(room, 0) + pts
                    today = time.strftime("%Y-%m-%d")
                    state["streak_dates"].setdefault(room, [])
                    if today not in state["streak_dates"][room]:
                        state["streak_dates"][room].append(today)
                    break
            state["tier_requests"] = [r for r in state["tier_requests"] if r["id"] != body.get("id")]

        elif self.path == "/api/admin/reject_tier":
            state["tier_requests"] = [r for r in state["tier_requests"] if r["id"] != body.get("id")]

        # ── 세탁 ──────────────────────────────────────────────────────────────
        elif self.path == "/api/laundry/start":
            mid     = body.get("id", "")
            minutes = max(1, min(180, int(body.get("minutes", 60))))  # 1~180분 제한
            room    = _clean(body.get("room", ""), 10)
            if room not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid_room"}); return
            mtype = next((m["type"] for m in state["laundry"] if m["id"] == mid), None)
            already = any(m["room"] == room and m["type"] == mtype and m["status"] == "running"
                         for m in state["laundry"])
            if already:
                self._json({"ok": False, "error": "already_running"}); return
            for m in state["laundry"]:
                if m["id"] == mid and m["status"] == "idle":
                    m["status"]   = "running"
                    m["end_time"] = time.time() + minutes * 60
                    m["room"]     = room
                    m["name"]     = _clean(body.get("name", ""), 20)
                    break

        elif self.path in ("/api/laundry/pickup", "/api/laundry/cancel"):
            for m in state["laundry"]:
                if m["id"] == body.get("id"):
                    m.update({"status": "idle", "end_time": None, "room": None, "name": None})
                    break

        elif self.path == "/api/admin/laundry/reset":
            for m in state["laundry"]:
                if m["id"] == body.get("id"):
                    m.update({"status": "idle", "end_time": None, "room": None, "name": None})
                    break

        elif self.path == "/api/laundry_schedule/reserve":
            day  = body.get("day", "")
            room = _clean(body.get("room", ""), 10)
            if day not in state["laundry_schedule"] or room not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid"}); return
            sched = state["laundry_schedule"][day]
            if not any(e["room"] == room for e in sched):
                sched.append({"room": room, "name": _clean(body.get("name", ""), 20)})

        elif self.path == "/api/laundry_schedule/cancel":
            day  = body.get("day", "")
            room = _clean(body.get("room", ""), 10)
            if day in state["laundry_schedule"]:
                state["laundry_schedule"][day] = [
                    e for e in state["laundry_schedule"][day] if e["room"] != room
                ]

        elif self.path == "/api/admin/laundry_schedule/reset":
            state["laundry_schedule"] = {"월":[],"화":[],"수":[],"목":[],"금":[],"토":[],"일":[]}

        elif self.path == "/api/admin/laundry/reset_all":
            for m in state["laundry"]:
                m.update({"status": "idle", "end_time": None, "room": None, "name": None})

        elif self.path == "/api/admin/laundry/set":
            minutes = max(1, min(180, int(body.get("minutes", 60))))
            for m in state["laundry"]:
                if m["id"] == body.get("id"):
                    m["status"]   = "running"
                    m["end_time"] = time.time() + minutes * 60
                    m["room"]     = _clean(body.get("room", ""), 10)
                    m["name"]     = _clean(body.get("room", ""), 10)
                    break

        # ── 물물찬 ────────────────────────────────────────────────────────────
        elif self.path == "/api/trade/post":
            room      = _clean(body.get("room", ""), 10)
            item_name = _clean(body.get("item_name", ""), 50)
            want_item = _clean(body.get("want_item", ""), 50)
            if room not in VALID_ROOMS or not item_name or not want_item:
                self._json({"ok": False, "error": "invalid"}); return
            state["trade_items"].append({
                "id": _id(), "room": room, "name": _clean(body.get("name", ""), 20),
                "item_name": item_name, "want_item": want_item,
                "status": "available", "time": _now(),
            })

        elif self.path == "/api/trade/delete_item":
            iid  = body.get("item_id")
            room = _clean(body.get("room", ""), 10)
            state["trade_items"]    = [t for t in state["trade_items"]
                                       if not (t["id"] == iid and t["room"] == room)]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["item_id"] != iid]

        elif self.path == "/api/trade/request":
            iid  = body.get("item_id")
            fr   = _clean(body.get("from_room", ""), 10)
            if fr not in VALID_ROOMS:
                self._json({"ok": False, "error": "invalid_room"}); return
            if not any(r["item_id"] == iid and r["from_room"] == fr for r in state["trade_requests"]):
                req = {
                    "id": _id(), "item_id": iid, "from_room": fr,
                    "from_name": _clean(body.get("from_name", ""), 20),
                    "offer_item": _clean(body.get("offer_item", ""), 50),
                    "status": "pending", "meet_place": "", "time": _now(),
                }
                state["trade_requests"].append(req)
                item = next((t for t in state["trade_items"] if t["id"] == iid), None)
                if item:
                    _send_push(item["room"], "🔄 물물 교환 신청!", f"{fr}호 {req['from_name']}님이 교환을 신청했습니다.")

        elif self.path == "/api/trade/accept":
            rid  = body.get("request_id")
            meet = _clean(body.get("meet_place", ""), 50)
            for r in state["trade_requests"]:
                if r["id"] == rid and r["status"] == "pending":
                    r["status"] = "accepted"; r["meet_place"] = meet
                    for t in state["trade_items"]:
                        if t["id"] == r["item_id"]: t["status"] = "traded"; break
                    _send_push(r["from_room"], "✅ 교환 승인됨!", f"교환이 승인되었습니다. {meet or '장소 미정'}")
                    break
            item_id = next((r["item_id"] for r in state["trade_requests"] if r["id"] == rid), None)
            if item_id:
                for r in state["trade_requests"]:
                    if r["item_id"] == item_id and r["id"] != rid and r["status"] == "pending":
                        r["status"] = "rejected"

        elif self.path == "/api/trade/reject":
            state["trade_requests"] = [r for r in state["trade_requests"]
                                        if r["id"] != body.get("request_id")]

        elif self.path == "/api/trade/cancel":
            rid = body.get("request_id")
            fr  = _clean(body.get("from_room", ""), 10)
            state["trade_requests"] = [r for r in state["trade_requests"]
                                        if not (r["id"] == rid and r["from_room"] == fr)]

        elif self.path == "/api/trade/complete":
            iid = body.get("item_id")
            state["trade_items"]    = [t for t in state["trade_items"]    if t["id"] != iid]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["item_id"] != iid]

        elif self.path == "/api/admin/trade/delete":
            iid = body.get("item_id")
            state["trade_items"]    = [t for t in state["trade_items"]    if t["id"] != iid]
            state["trade_requests"] = [r for r in state["trade_requests"] if r["item_id"] != iid]

        elif self.path == "/api/admin/trade/reset":
            state["trade_items"] = []; state["trade_requests"] = []

        # ── admin: 채팅 관리 ──────────────────────────────────────────────────
        elif self.path == "/api/admin/chat/delete":
            mid = body.get("id")
            state["messages"] = [m for m in state["messages"] if m["id"] != mid]

        elif self.path == "/api/admin/chat/reset":
            state["messages"] = []

        # 변경사항 저장 예약
        _schedule_save()
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
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token")

    def log_message(self, *a): pass

class TabangServer(HTTPServer):
    def handle_error(self, request, client_address):
        import sys
        if sys.exc_info()[0] in (BrokenPipeError, ConnectionResetError): pass
        else: super().handle_error(request, client_address)

if __name__ == "__main__":
    _load_main_js()
    _load_saved()
    server = TabangServer(("0.0.0.0", 8080), Handler)
    print("타방찬 서버 실행 중: http://localhost:8080")
    server.serve_forever()
