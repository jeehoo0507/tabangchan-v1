import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

String get _base => Uri.base.origin;
// 관리자 계정: {id: password}
const _admins = {
  'admin223': 'admin223@1',
  'admin212': 'admin212@1',
};

const allRoomIds = [
  "201","202","203","204","205","206","207","208","209","210",
  "211","212","213","214","215","세탁실",
  "216","217","218","219","220","221","222","223","224","225","226","227",
];

// ── 티어 ──────────────────────────────────────────────────────────────────────
const _tiers = [
  (10000, '관리자',  Color(0xFF1A1A1A)),
  (1000,  '마스터',  Color(0xFF6A1B9A)),
  (500,   '다이아',  Color(0xFF00838F)),
  (200,   '플래티넘',Color(0xFF00897B)),
  (100,   '골드',   Color(0xFFF9A825)),
  (50,    '실버',   Color(0xFF757575)),
  (10,    '브론즈', Color(0xFF6D4C41)),
];

String tierName(int p) {
  for (final (t, n, _) in _tiers) { if (p >= t) return n; }
  return '언랭';
}
Color tierColor(int p) {
  for (final (t, _, c) in _tiers) { if (p >= t) return c; }
  return Colors.grey;
}
int nextTierPts(int p) {
  for (final (t, _, _) in _tiers.reversed) { if (p < t) return t; }
  return -1;
}

// ─────────────────────────────────────────────────────────────────────────────

void main() => runApp(const TabangChanApp());

class TabangChanApp extends StatelessWidget {
  const TabangChanApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '타방찬',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      scaffoldBackgroundColor: Colors.white,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white, elevation: 0.5, centerTitle: true,
        titleTextStyle: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: Colors.black,
        unselectedItemColor: Colors.grey,
      ),
    ),
    home: const MainScreen(),
  );
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  bool   isAdmin = false;
  String? myRoom, myName, currentPosition;

  Map<String, int> roomOccupancy = {};
  List requests = [], messages = [], history = [], tierRequests = [];
  Map<String, int> scores = {};
  Map<String, List<String>> streakDates = {};
  Map<String, List> laundrySchedule = {};
  int _lastMsgCount = 0;

  int _navIndex = 0;
  int _tabangTab = 0;  // 0=내역 1=신청/채팅
  int _histMode  = 0;  // 0=내 내역 1=전체 내역

  final _roomCtrl  = TextEditingController();
  final _nameCtrl  = TextEditingController();
  final _chatCtrl  = TextEditingController();
  final _chatScroll = ScrollController();
  Timer? _timer;

  Map<String, dynamic>? _pendingMove;
  final _roomKeys = <String, GlobalKey>{};

  // 알림 추적용
  Set<int> _notifiedRequestIds = {};   // 이미 알림 보낸 incoming request id
  bool _approvalNotified = false;       // 승인 알림 보냈는지

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  // ── localStorage 세션 ──────────────────────────────────────────────────────

  void _loadSession() {
    try {
      final storage = html.window.localStorage;
      final room = storage['tb_room'];
      final name = storage['tb_name'];
      final pos  = storage['tb_pos'];
      final admin = storage['tb_admin'];
      if (room != null && room.isNotEmpty) {
        if (admin == '1') {
          setState(() { isAdmin = true; myRoom = 'admin'; myName = '관리자'; });
        } else {
          setState(() { myRoom = room; myName = name ?? ''; currentPosition = pos ?? room; });
        }
        _startPolling();
      }
    } catch (_) {}
  }

  void _saveSession() {
    try {
      final storage = html.window.localStorage;
      if (isAdmin) {
        storage['tb_room']  = 'admin';
        storage['tb_name']  = '관리자';
        storage['tb_admin'] = '1';
      } else {
        storage['tb_room']  = myRoom ?? '';
        storage['tb_name']  = myName ?? '';
        storage['tb_pos']   = currentPosition ?? myRoom ?? '';
        storage['tb_admin'] = '0';
      }
    } catch (_) {}
  }

  void _clearSession() {
    try {
      html.window.localStorage.remove('tb_room');
      html.window.localStorage.remove('tb_name');
      html.window.localStorage.remove('tb_pos');
      html.window.localStorage.remove('tb_admin');
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _roomCtrl.dispose(); _nameCtrl.dispose(); _chatCtrl.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  // ── 폴링 ───────────────────────────────────────────────────────────────────

  void _startPolling() {
    try {
      if (html.Notification.supported) html.Notification.requestPermission();
    } catch (_) {}
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void _showNotification(String title, String body) {
    try {
      if (html.Notification.supported && html.Notification.permission == 'granted') {
        html.Notification(title, body: body);
      }
    } catch (_) {}
  }

  Future<void> _poll() async {
    try {
      final res = await http.get(Uri.parse('$_base/api/state'));
      if (res.statusCode != 200 || !mounted) return;
      final d = jsonDecode(utf8.decode(res.bodyBytes));

      if (!isAdmin && myRoom != null) {
        final allReqs = d['requests'] as List;

        // ── 내 방에 오는 신청 알림 (새 pending)
        final incomingReqs = allReqs.where((r) =>
            r['to_room'] == myRoom && r['status'] == 'pending').toList();
        for (final r in incomingReqs) {
          final rid = r['id'] as int;
          if (!_notifiedRequestIds.contains(rid)) {
            _notifiedRequestIds.add(rid);
            _showNotification(
              '🚪 타방 신청 도착!',
              '${r['from_room']}호 ${r['name']}님이 방문 신청했습니다.',
            );
          }
        }
        // 사라진 요청은 추적 목록에서 제거
        final currentIds = allReqs.map((r) => r['id'] as int).toSet();
        _notifiedRequestIds.removeWhere((id) => !currentIds.contains(id));

        // ── 내 신청 승인 알림
        final approved = allReqs.where((r) =>
            r['from_room'] == myRoom && r['status'] == 'approved').toList();
        if (approved.isNotEmpty && _pendingMove == null) {
          final doc = approved.first;
          setState(() {
            _pendingMove = {
              'id':   doc['id'],
              'from': doc['from_room'] as String,
              'to':   doc['to_room']   as String,
              'name': doc['name']      ?? myName ?? '',
            };
          });
          if (!_approvalNotified) {
            _approvalNotified = true;
            _showNotification(
              '✅ 타방 승인됨!',
              '${doc['to_room']}호 방문이 승인되었습니다. 이동해주세요.',
            );
          }
        } else if (_pendingMove != null) {
          final stillExists = allReqs.any((r) => r['id'] == _pendingMove!['id']);
          if (!stillExists) {
            setState(() { _pendingMove = null; _approvalNotified = false; });
          }
        } else {
          _approvalNotified = false;
        }
      }

      final newMsgs = d['messages'] as List;
      setState(() {
        roomOccupancy = (d['rooms'] as Map).map((k, v) => MapEntry(k as String, (v['occupancy'] as num).toInt()));
        requests     = d['requests'] as List;
        messages     = newMsgs;
        history      = d['history'] as List;
        scores       = (d['scores'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
        tierRequests = d['tier_requests'] as List;
        streakDates     = (d['streak_dates'] as Map? ?? {}).map(
            (k, v) => MapEntry(k as String, List<String>.from(v as List)));
        laundrySchedule = (d['laundry_schedule'] as Map? ?? {}).map(
            (k, v) => MapEntry(k as String, List.from(v as List)));

        _laundryData = (d['laundry'] as List?) ?? [];
      });

      if (newMsgs.length > _lastMsgCount) {
        _lastMsgCount = newMsgs.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_chatScroll.hasClients) {
            _chatScroll.animateTo(_chatScroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          }
        });
      }
    } catch (_) {}
  }

  static const _adminToken = 'tbchan_9x2kL8mP_secret';

  Future<void> _rawPost(String path, Map body) async =>
      http.post(Uri.parse('$_base$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));

  Future<void> _rawAdminPost(String path, Map body) async =>
      http.post(Uri.parse('$_base$path'),
        headers: {'Content-Type': 'application/json', 'X-Admin-Token': _adminToken},
        body: jsonEncode(body));

  Future<void> _post(String path, Map body) async {
    try {
      if (path.startsWith('/api/admin/')) {
        await _rawAdminPost(path, body);
      } else {
        await _rawPost(path, body);
      }
      await _poll();
    } catch (_) {}
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── 로그인 ─────────────────────────────────────────────────────────────────

  void _handleLogin() {
    final room = _roomCtrl.text.trim();
    if (_admins.containsKey(room) && _admins[room] == _nameCtrl.text.trim()) {
      setState(() { isAdmin = true; myRoom = 'admin'; myName = '관리자'; });
      _saveSession();
      _startPolling(); return;
    }
    if (!allRoomIds.contains(room) || room == '세탁실') { _snack('존재하지 않는 호수입니다.'); return; }
    if (_nameCtrl.text.trim().isEmpty) { _snack('이름을 입력해주세요.'); return; }
    setState(() { myRoom = room; myName = _nameCtrl.text.trim(); currentPosition = room; });
    _saveSession();
    _startPolling();
  }

  // ── 유저 액션 ──────────────────────────────────────────────────────────────

  Future<void> _sendTabangRequest(String target) async {
    if (currentPosition != myRoom) { _snack('현재 $currentPosition호 방문 중입니다. 먼저 복귀해주세요.'); return; }
    if (_pendingMove != null) { _snack('승인된 이동이 있습니다. 먼저 이동을 완료해주세요.'); return; }
    if (requests.any((r) => r['from_room'] == myRoom &&
        (r['status'] == 'pending' || r['status'] == 'approved'))) {
      _snack('이미 신청 중인 타방이 있습니다.'); return;
    }
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$target호에 타방 신청'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('이름: $myName', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: reasonCtrl,
            decoration: InputDecoration(
              labelText: '방문 사유 (선택)', hintText: '예: 과제 같이 하러요',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            maxLines: 2,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
            child: const Text('신청하기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _post('/api/request', {'from': myRoom, 'to': target, 'name': myName, 'reason': reasonCtrl.text.trim()});
    _snack('$target호에 신청했습니다.');
  }

  Future<void> _returnToMyRoom() async {
    if (currentPosition == myRoom) return;
    final from = currentPosition!;
    try {
      await _rawPost('/api/return', {'from': from, 'to': myRoom, 'name': myName});
      if (!mounted) return;
      setState(() => currentPosition = myRoom);
      _saveSession();
      _snack('내 방으로 복귀했습니다.');
      _poll();
    } catch (_) {
      if (mounted) _snack('복귀 실패. 네트워크를 확인해주세요.');
    }
  }

  String _roomTier(String room) {
    if (room == 'admin') return '관리자';
    return tierName(scores[room] ?? 0);
  }

  Color _roomTierColor(String room) {
    if (room == 'admin') return const Color(0xFF1A1A1A);
    return tierColor(scores[room] ?? 0);
  }

  Future<void> _sendTierRequest() async {
    if (tierRequests.any((r) => r['room'] == myRoom && r['status'] == 'pending')) {
      _snack('이미 인증 요청 중입니다.'); return;
    }
    await _post('/api/tier_request', {'room': myRoom, 'name': myName, 'visited_room': currentPosition});
    _snack('타방인증 요청을 보냈습니다!');
  }

  void _sendMessage() {
    final t = _chatCtrl.text.trim();
    if (t.isEmpty) return;
    _chatCtrl.clear();
    _post('/api/chat', {'room': myRoom, 'msg': t});
  }

  // ── 이동완료 ───────────────────────────────────────────────────────────────

  Future<void> _completeMove() async {
    final move = _pendingMove;
    if (move == null) return;
    try {
      await _rawPost('/api/complete_move', {
        'id':   move['id'],
        'from': move['from'],
        'to':   move['to'],
        'name': move['name'],
      });
      if (!mounted) return;
      setState(() { currentPosition = move['to'] as String; _pendingMove = null; _approvalNotified = false; });
      _saveSession();
      _snack('${move["to"]}호로 이동 완료!');
      _poll();
    } catch (_) {
      if (mounted) _snack('이동 완료 실패. 다시 시도해주세요.');
    }
  }

  // ── 관리자 액션 ────────────────────────────────────────────────────────────

  Future<void> _editOccupancy(String room, int cur) async {
    final ctrl = TextEditingController(text: '$cur');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$room호 인원 수정'),
        content: TextField(
          controller: ctrl, keyboardType: TextInputType.number, autofocus: true,
          decoration: InputDecoration(labelText: '인원 수', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final val = int.tryParse(ctrl.text.trim());
    if (val != null) await _post('/api/admin/set_occupancy', {'room': room, 'value': val});
  }

  Future<void> _editScore(String room, int cur) async {
    final ctrl = TextEditingController(text: '$cur');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$room호 점수 수정'),
        content: TextField(
          controller: ctrl, keyboardType: TextInputType.number, autofocus: true,
          decoration: InputDecoration(labelText: '점수', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final val = int.tryParse(ctrl.text.trim());
    if (val != null) await _post('/api/admin/set_score', {'room': room, 'points': val});
  }

  Future<void> _approveTier(int id) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('점수 입력 후 승인'),
        content: TextField(
          controller: ctrl, keyboardType: TextInputType.number, autofocus: true,
          decoration: InputDecoration(labelText: '부여할 점수', hintText: '예: 10', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
            child: const Text('승인'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final pts = int.tryParse(ctrl.text.trim());
    if (pts != null) await _post('/api/admin/approve_tier', {'id': id, 'points': pts});
  }

  // ── 빌드 ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (myRoom == null) return _buildLogin();
    if (isAdmin) return _buildAdmin();
    return _buildUserApp();
  }

  // ────────────────────────────── 로그인 ─────────────────────────────────────

  Widget _buildLogin() => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('타방찬', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('기숙사 방문 관리', style: TextStyle(color: Colors.grey[500])),
          const SizedBox(height: 40),
          TextField(
            controller: _roomCtrl,
            decoration: InputDecoration(
              labelText: '호수', hintText: '예: 227',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: (_) => _handleLogin(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: '이름', hintText: '예: 홍길동',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: (_) => _handleLogin(),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 50,
            child: ElevatedButton(
              onPressed: _handleLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('시작하기'),
            ),
          ),
        ],
      ),
    ),
  );

  // ────────────────────────────── 관리자 ─────────────────────────────────────

  Widget _buildAdmin() {
    final pendingTier = tierRequests.where((r) => r['status'] == 'pending').length;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('관리자'),
          actions: [
            TextButton(
              onPressed: () { _timer?.cancel(); setState(() { myRoom = null; isAdmin = false; }); },
              child: const Text('로그아웃', style: TextStyle(color: Colors.red)),
            ),
          ],
          bottom: TabBar(
            labelColor: Colors.black,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: '방 관리'),
              const Tab(text: '점수 관리'),
              Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('인증 요청'),
                if (pendingTier > 0) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                    child: Text('$pendingTier', style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ],
              ])),
              const Tab(text: '세탁 관리'),
            ],
          ),
        ),
        body: TabBarView(children: [_adminRoomTab(), _adminScoreTab(), _adminTierTab(), _adminLaundryTab()]),
      ),
    );
  }

  Widget _adminRoomTab() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('전체 초기화'),
                  content: const Text('모든 방을 2명으로 초기화할까요?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      child: const Text('초기화'),
                    ),
                  ],
                ),
              );
              if (ok == true) await _post('/api/admin/reset_rooms', {});
            },
            icon: const Icon(Icons.refresh, color: Colors.red),
            label: const Text('전체 초기화 (2명)', style: TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          itemCount: allRoomIds.length,
          itemBuilder: (ctx, i) {
            final room = allRoomIds[i];
            final count = roomOccupancy[room] ?? 0;
            return ListTile(
              title: Text('$room호', style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: count > 0
                        ? () => _post('/api/admin/set_occupancy', {'room': room, 'value': count - 1})
                        : null,
                  ),
                  SizedBox(
                    width: 36,
                    child: Text('$count', textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => _post('/api/admin/set_occupancy', {'room': room, 'value': count + 1}),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _editOccupancy(room, count),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _adminScoreTab() {
    final sorted = allRoomIds.where((r) => r != '세탁실').toList()
      ..sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));
    return ListView.builder(
      itemCount: sorted.length,
      itemBuilder: (ctx, i) {
        final room = sorted[i];
        final pts = scores[room] ?? 0;
        final color = tierColor(pts);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withOpacity(0.15),
            child: Text('${i + 1}', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ),
          title: Text('$room호'),
          subtitle: Text(tierName(pts), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$pts점', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(width: 4),
              IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editScore(room, pts)),
            ],
          ),
        );
      },
    );
  }

  Widget _adminTierTab() {
    final pending = tierRequests.where((r) => r['status'] == 'pending').toList();
    if (pending.isEmpty) return const Center(child: Text('인증 요청이 없습니다.'));
    return ListView.builder(
      itemCount: pending.length,
      itemBuilder: (ctx, i) {
        final r = pending[i];
        final id = r['id'] as int;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.person, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text('${r['room']}호 · ${r['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text(r['time'] ?? '', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ]),
                const SizedBox(height: 4),
                Text('${r['visited_room']}호 방문 인증 요청'),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  OutlinedButton(
                    onPressed: () => _post('/api/admin/reject_tier', {'id': id}),
                    child: const Text('거절'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _approveTier(id),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
                    icon: const Icon(Icons.star, size: 16),
                    label: const Text('점수 입력 후 승인'),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 관리자 세탁 탭 ─────────────────────────────────────────────────────────

  Widget _adminLaundryTab() {
    // 폴링된 세탁 데이터 가져오기 (없으면 빈 리스트)
    final machines = (state_['laundry'] as List?) ?? [];

    String _label(Map m) {
      final group = m['group'] == 'A' ? '왼쪽' : '오른쪽';
      final type  = m['type'] == 'washer' ? '세탁기' : '건조기';
      return '$group ${m['slot']}번 $type';
    }

    Color _statusColor(String s) => s == 'idle' ? Colors.grey : s == 'running' ? Colors.blue : Colors.orange;
    String _statusText(String s) => s == 'idle' ? '비어있음' : s == 'running' ? '사용 중' : '완료';

    Future<void> resetOne(String id) async =>
        await _post('/api/admin/laundry/reset', {'id': id});

    Future<void> resetAll() async =>
        await _post('/api/admin/laundry/reset_all', {});

    Future<void> setMachine(Map m) async {
      final roomCtrl = TextEditingController(text: m['room'] ?? '');
      final customCtrl = TextEditingController();
      int? minutes;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${_label(m)} 설정'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: roomCtrl,
              decoration: InputDecoration(
                labelText: '호실', hintText: '예: 203',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            const Text('시간 선택', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [30, 45, 60, 75, 90].map((min) =>
              OutlinedButton(
                onPressed: () { minutes = min; Navigator.pop(ctx); },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                ),
                child: Text('$min분'),
              ),
            ).toList()),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: customCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '직접 입력 (분)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  final v = int.tryParse(customCtrl.text.trim());
                  if (v != null && v > 0) { minutes = v; Navigator.pop(ctx); }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                child: const Text('확인'),
              ),
            ]),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소'))],
        ),
      );
      if (minutes == null) return;
      await _post('/api/admin/laundry/set', {
        'id': m['id'], 'room': roomCtrl.text.trim(), 'minutes': minutes,
      });
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('세탁기 전체 초기화'),
                    content: const Text('모든 세탁기/건조기를 초기화할까요?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                        child: const Text('초기화'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await resetAll();
              },
              icon: const Icon(Icons.refresh, color: Colors.red, size: 16),
              label: const Text('세탁기 초기화', style: TextStyle(color: Colors.red, fontSize: 13)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('세탁 예약 초기화'),
                    content: const Text('모든 요일 예약을 초기화할까요?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                        child: const Text('초기화'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await _post('/api/admin/laundry_schedule/reset', {});
              },
              icon: const Icon(Icons.calendar_month, color: Colors.orange, size: 16),
              label: const Text('예약 초기화', style: TextStyle(color: Colors.orange, fontSize: 13)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.orange)),
            ),
          ),
        ]),
      ),
      const Divider(height: 1),
      if (machines.isEmpty)
        const Expanded(child: Center(child: Text('데이터 로딩 중...')))
      else
        Expanded(
          child: ListView.builder(
            itemCount: machines.length,
            itemBuilder: (ctx, i) {
              final m = machines[i] as Map;
              final status = m['status'] as String;
              final sColor = _statusColor(status);
              final endTime = (m['end_time'] as num?)?.toDouble();
              final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
              final remaining = (endTime != null && status == 'running')
                  ? (endTime - now).clamp(0.0, double.infinity).toInt()
                  : null;
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: sColor.withOpacity(0.15),
                  child: Icon(
                    m['type'] == 'washer' ? Icons.local_laundry_service : Icons.dry,
                    size: 16, color: sColor,
                  ),
                ),
                title: Text(_label(m), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(
                  status == 'idle' ? '비어있음'
                    : status == 'running' && remaining != null
                        ? '${m['room']}호 · 남은 시간 ${remaining ~/ 60}분 ${remaining % 60}초'
                        : '${m['room']}호 · 완료',
                  style: TextStyle(fontSize: 11, color: sColor),
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    tooltip: '설정',
                    onPressed: () => setMachine(m),
                  ),
                  if (status != 'idle')
                    IconButton(
                      icon: const Icon(Icons.restart_alt, size: 18, color: Colors.red),
                      tooltip: '초기화',
                      onPressed: () => resetOne(m['id'] as String),
                    ),
                ]),
              );
            },
          ),
        ),
    ]);
  }

  // state_ getter: 폴링된 전체 상태 (세탁 탭에서 사용)
  Map<String, dynamic> get state_ => {
    'laundry': _laundryData,
  };
  List _laundryData = [];

  // ────────────────────────────── 유저 앱 ────────────────────────────────────

  Widget _buildUserApp() => Scaffold(
    appBar: AppBar(title: const Text('타방찬')),
    body: IndexedStack(
      index: _navIndex,
      children: [_buildMapPage(), _buildTabangPage(), _buildProfilePage()],
    ),
    bottomNavigationBar: BottomNavigationBar(
      currentIndex: _navIndex,
      onTap: (i) => setState(() => _navIndex = i),
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.grid_view_rounded), label: '배치도'),
        BottomNavigationBarItem(icon: Icon(Icons.forum_outlined), label: '타방/톡'),
        BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: '프로필'),
      ],
    ),
  );

  // ── 배치도 ─────────────────────────────────────────────────────────────────

  Widget _buildMapPage() {
    final isVisiting = currentPosition != myRoom;
    final hasPendingTier = tierRequests.any((r) => r['room'] == myRoom && r['status'] == 'pending');
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          // ── 타방 승인 배너 ─────────────────────────────────────────────────
          if (_pendingMove != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green[300]!),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('타방 승인됨!', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                      Text('${_pendingMove!["from"]}호 → ${_pendingMove!["to"]}호',
                          style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _completeMove,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                    child: const Text('이동완료'),
                  ),
                ]),
              ),
            ),
          // ── 방문 중 배너 ────────────────────────────────────────────────────
          if (isVisiting && _pendingMove == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    Expanded(child: Text('현재 위치: $currentPosition호', style: const TextStyle(fontWeight: FontWeight.bold))),
                    if (!hasPendingTier)
                      TextButton.icon(
                        onPressed: _sendTierRequest,
                        icon: const Icon(Icons.verified, size: 16, color: Colors.purple),
                        label: const Text('타방인증', style: TextStyle(color: Colors.purple, fontSize: 13)),
                      ),
                    TextButton.icon(
                      onPressed: _returnToMyRoom,
                      icon: const Icon(Icons.home_rounded, size: 16),
                      label: const Text('복귀', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
          Row(mainAxisAlignment: MainAxisAlignment.center,
            children: ["206","207","208","209","210"].map((id) => _roomTile(id, width: 60)).toList()),
          Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(children: ["205","204","203","202","201"].map((id) => _roomTile(id)).toList()),
              Container(width: 180, height: 260, margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(8)),
                child: const Center(child: Text('중앙 정원', style: TextStyle(color: Colors.black12)))),
              Column(children: ["211","212","213","214","215","세탁실"].map((id) => _roomTile(id)).toList()),
            ]),
          const SizedBox(height: 30),
          Row(mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(children: ["222","223","224","225","226","227"].map((id) => _roomTile(id)).toList()),
              Container(width: 40, height: 310, alignment: Alignment.center,
                child: const VerticalDivider(thickness: 1.5, color: Colors.orangeAccent)),
              Column(children: ["216","217","218","219","220","221"].map((id) => _roomTile(id)).toList()),
            ]),
        ],
      ),
    );
  }

  Widget _roomTile(String id, {double width = 75}) {
    _roomKeys[id] ??= GlobalKey();
    final count = roomOccupancy[id] ?? 0;
    final isOver = count >= 5;
    final isCur = id == currentPosition;
    final isHome = id == myRoom;
    // 나의 이동 대기 중 방 (초록)
    final isMyMove = _pendingMove != null &&
        (id == _pendingMove!['from'] || id == _pendingMove!['to']);
    // 다른 유저의 활성 요청 관련 방 (주황) - 전체에게 표시
    final hasGlobalReq = !isMyMove && requests.any((r) =>
        (r['from_room'] == id || r['to_room'] == id) &&
        (r['status'] == 'pending' || r['status'] == 'approved'));

    Color tileColor;
    Color borderColor;
    double borderWidth;
    if (isCur) {
      tileColor = Colors.black; borderColor = Colors.black; borderWidth = 1;
    } else if (isMyMove) {
      tileColor = Colors.green[50]!; borderColor = Colors.green; borderWidth = 2.5;
    } else if (hasGlobalReq) {
      tileColor = Colors.orange[50]!; borderColor = Colors.orange; borderWidth = 2;
    } else if (isOver) {
      tileColor = Colors.red[50]!; borderColor = Colors.red; borderWidth = 1;
    } else {
      tileColor = Colors.white; borderColor = isHome ? Colors.blue : Colors.grey[300]!;
      borderWidth = isHome ? 2 : 1;
    }

    return GestureDetector(
      onTap: () {
        if (id == '세탁실') {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => LaundryPage(
              myRoom: myRoom!, myName: myName!, base: _base,
              laundrySchedule: laundrySchedule,
            ),
          ));
          return;
        }
        if (isCur || isOver) return;
        _sendTabangRequest(id);
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            key: _roomKeys[id],
            width: width, height: 50, margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: tileColor,
              border: Border.all(color: borderColor, width: borderWidth),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (id == '세탁실') ...[
                const Icon(Icons.local_laundry_service, size: 18, color: Colors.blueGrey),
                const Text('세탁실', style: TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
              ] else ...[
                Text(id, style: TextStyle(fontSize: 12, color: isCur ? Colors.white : Colors.black,
                    fontWeight: isCur ? FontWeight.bold : FontWeight.normal)),
                Text('$count명', style: TextStyle(fontSize: 10, color: isCur ? Colors.white70 : Colors.grey[600])),
              ],
            ]),
          ),
          // 다른 유저 활성 요청 표시 점
          if (hasGlobalReq)
            Positioned(
              top: 0, right: 2,
              child: Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
    );
  }

  // ── 타방/톡 ────────────────────────────────────────────────────────────────

  Widget _buildTabangPage() {
    final isVisiting = currentPosition != myRoom;
    final myOutgoing = requests.where((r) => r['from_room'] == myRoom && r['status'] == 'pending').toList();
    final incoming   = requests.where((r) => r['to_room'] == myRoom && r['status'] == 'pending').toList();
    final hasPendingTier = tierRequests.any((r) => r['room'] == myRoom && r['status'] == 'pending');

    return Column(
      children: [
        // ── 타방 승인 배너 ──────────────────────────────────────────────────
        if (_pendingMove != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green[300]!),
            ),
            child: Row(children: [
              const Icon(Icons.check_circle_outline, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('타방 승인됨!',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                  Text('${_pendingMove!["from"]}호 → ${_pendingMove!["to"]}호',
                      style: const TextStyle(fontSize: 12)),
                ]),
              ),
              ElevatedButton(
                onPressed: _completeMove,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green, foregroundColor: Colors.white,
                ),
                child: const Text('이동완료'),
              ),
            ]),
          ),
        if (isVisiting || myOutgoing.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            decoration: BoxDecoration(
              color: Colors.grey[50], borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(children: [
              if (myOutgoing.isNotEmpty)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.send, color: Colors.orange, size: 20),
                  title: Text('${myOutgoing.first['to_room']}호에 타방 신청 중'),
                  subtitle: const Text('승인 대기 중'),
                  trailing: TextButton(
                    onPressed: () => _post('/api/reject', {'id': myOutgoing.first['id']}),
                    child: const Text('취소', style: TextStyle(color: Colors.red)),
                  ),
                ),
              if (isVisiting) ...[
                if (myOutgoing.isNotEmpty) const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_on, color: Colors.blue, size: 20),
                  title: Text('현재 $currentPosition호 방문 중'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (!hasPendingTier)
                      TextButton.icon(
                        onPressed: _sendTierRequest,
                        icon: const Icon(Icons.verified, size: 14, color: Colors.purple),
                        label: const Text('인증', style: TextStyle(color: Colors.purple, fontSize: 12)),
                      ),
                    TextButton(onPressed: _returnToMyRoom, child: const Text('복귀')),
                  ]),
                ),
              ],
            ]),
          ),
        // ── 들어오는 타방 신청 (항상 표시) ─────────────────────────────────
        if (incoming.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              color: Colors.amber[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber[300]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                  child: Row(children: [
                    const Icon(Icons.notifications_active, color: Colors.orange, size: 16),
                    const SizedBox(width: 6),
                    Text('타방 신청 ${incoming.length}건', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ]),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: incoming.length,
                    itemBuilder: (ctx, i) {
                      final req = incoming[i];
                      final fromRoom = req['from_room'] as String;
                      final reason = req['reason'] as String? ?? '';
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                          child: Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                const Icon(Icons.person, size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text('$fromRoom호 · ${req['name']}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              ]),
                              if (reason.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(reason, style: const TextStyle(fontSize: 12)),
                                ),
                            ])),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: () => _post('/api/reject', {'id': req['id']}),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('거절', style: TextStyle(fontSize: 12)),
                            ),
                            const SizedBox(width: 6),
                            ElevatedButton(
                              onPressed: () => _post('/api/approve', {'id': req['id']}),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black, foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('승인', style: TextStyle(fontSize: 12)),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        // ── 탭 전환 ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: SegmentedButton<int>(
                segments: [
                  const ButtonSegment(value: 0, label: Text('타방 내역')),
                  ButtonSegment(value: 1, label: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('신청/채팅'),
                  ])),
                ],
                selected: {_tabangTab},
                onSelectionChanged: (s) => setState(() => _tabangTab = s.first),
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: Colors.black, selectedForegroundColor: Colors.white,
                ),
              ),
            ),
          ]),
        ),
        Expanded(child: _tabangTab == 0 ? _buildHistoryTab() : _buildChatTab()),
      ],
    );
  }

  Widget _buildHistoryTab() {
    final myHist = history.reversed.where((h) => h['from_room'] == myRoom || h['to_room'] == myRoom).toList();
    final allHist = history.reversed.toList();
    final shown = _histMode == 0 ? myHist : allHist;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('내 내역')),
              ButtonSegment(value: 1, label: Text('전체 내역')),
            ],
            selected: {_histMode},
            onSelectionChanged: (s) => setState(() => _histMode = s.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: Colors.black, selectedForegroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('내역이 없습니다.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: shown.length,
                  itemBuilder: (ctx, i) {
                    final h = shown[i];
                    final isReturn = (h['type'] as String?) == 'return';
                    final reason = h['reason'] as String? ?? '';
                    final from = h['from_room'] as String;
                    final to = h['to_room'] as String;
                    final name = h['name'] as String? ?? '';

                    // 내 내역 모드: 나 기준 라벨
                    // 전체 내역 모드: 누가 어디로
                    String title;
                    IconData icon;
                    Color iconColor;

                    if (_histMode == 0) {
                      // 내 내역
                      if (isReturn) {
                        if (to == myRoom) {
                          title = '$from호에서 복귀'; icon = Icons.home_rounded; iconColor = Colors.orange;
                        } else {
                          title = '$name이 $to호로 복귀 (내 방 방문 종료)'; icon = Icons.logout; iconColor = Colors.grey;
                        }
                      } else {
                        if (from == myRoom) {
                          title = '$to호 방문'; icon = Icons.arrow_forward_rounded; iconColor = Colors.blue;
                        } else {
                          title = '$from호 $name 방문'; icon = Icons.arrow_back_rounded; iconColor = Colors.green;
                        }
                      }
                    } else {
                      // 전체 내역
                      if (isReturn) {
                        title = '$name ($from호 → $to호 복귀)'; icon = Icons.home_rounded; iconColor = Colors.orange;
                      } else {
                        title = '$name ($from호 → $to호 방문)'; icon = Icons.arrow_forward_rounded; iconColor = Colors.blue;
                      }
                    }

                    return ListTile(
                      leading: Icon(icon, color: iconColor),
                      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: reason.isNotEmpty ? Text(reason) : null,
                      trailing: Text(h['time'] ?? '', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(alignment: Alignment.centerLeft,
              child: Text('기숙사 전체 톡', style: TextStyle(fontWeight: FontWeight.bold))),
        ),
        Expanded(
          child: messages.isEmpty
              ? const Center(child: Text('아직 메시지가 없습니다.'))
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: messages.length,
                  itemBuilder: (ctx, i) {
                    final msg = messages[i];
                    final isMine = msg['room'] == myRoom;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(color: Colors.black, fontSize: 14),
                          children: [
                            TextSpan(
                              text: '[${msg['room']}]',
                              style: TextStyle(fontWeight: FontWeight.bold,
                                  color: isMine ? Colors.blue : Colors.black87),
                            ),
                            TextSpan(
                              text: '[${_roomTier(msg['room'] as String)}] ',
                              style: TextStyle(fontWeight: FontWeight.bold,
                                  color: _roomTierColor(msg['room'] as String)),
                            ),
                            TextSpan(text: msg['msg'] as String),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey[200]!))),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _chatCtrl,
                decoration: InputDecoration(
                  hintText: '메시지를 입력하세요...',
                  filled: true, fillColor: Colors.grey[100],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onSubmitted: (_) => _sendMessage(),
                textInputAction: TextInputAction.send,
              ),
            ),
            IconButton(onPressed: _sendMessage, icon: const Icon(Icons.send_rounded, color: Colors.blue)),
          ]),
        ),
      ],
    );
  }

  // ── 스트릭 위젯 ────────────────────────────────────────────────────────────

  Widget _buildStreakWidget() {
    final myDates = Set<String>.from(streakDates[myRoom ?? ''] ?? []);
    final today   = DateTime.now();

    String toDateStr(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    // 현재 연속 스트릭 계산
    int streak = 0;
    DateTime check = today;
    if (!myDates.contains(toDateStr(today))) {
      check = today.subtract(const Duration(days: 1));
    }
    while (myDates.contains(toDateStr(check))) {
      streak++;
      check = check.subtract(const Duration(days: 1));
    }

    // 최장 스트릭 계산
    int maxStreak = 0, cur = 0;
    final sortedDates = myDates.toList()..sort();
    for (int i = 0; i < sortedDates.length; i++) {
      if (i == 0) {
        cur = 1;
      } else {
        final prev = DateTime.parse(sortedDates[i - 1]);
        final curr = DateTime.parse(sortedDates[i]);
        final diff = curr.difference(prev).inDays;
        cur = diff == 1 ? cur + 1 : 1;
      }
      if (cur > maxStreak) maxStreak = cur;
    }

    // 그리드: 15주, 월요일 기준 정렬
    const weeks = 15;
    final daysSinceMonday = today.weekday - 1; // 0=Mon
    final thisMonday = today.subtract(Duration(days: daysSinceMonday));
    final gridStart  = thisMonday.subtract(const Duration(days: (weeks - 1) * 7));

    const cellSize = 13.0;
    const gap      = 2.5;

    final todayStr = toDateStr(today);
    final monthLabels = ['1월','2월','3월','4월','5월','6월','7월','8월','9월','10월','11월','12월'];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                const Icon(Icons.local_fire_department, color: Colors.orange, size: 17),
                const SizedBox(width: 5),
                const Text('타방인증 스트릭', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ]),
              Row(children: [
                if (streak > 0) ...[
                  Text('🔥 $streak일 연속',
                      style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(width: 8),
                ],
                Text('총 ${myDates.length}회',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12)),
              ]),
            ],
          ),
          const SizedBox(height: 10),

          // 스트릭 그리드 (가로 스크롤)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 월 레이블
                Row(
                  children: List.generate(weeks, (wi) {
                    final weekStart = gridStart.add(Duration(days: wi * 7));
                    final showMonth = weekStart.day <= 7;
                    return SizedBox(
                      width: cellSize + gap,
                      child: showMonth
                          ? Text(monthLabels[weekStart.month - 1],
                              style: TextStyle(fontSize: 9, color: Colors.grey[500]))
                          : null,
                    );
                  }),
                ),
                const SizedBox(height: 3),

                // 셀 그리드
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(weeks, (wi) {
                    return Padding(
                      padding: EdgeInsets.only(right: wi < weeks - 1 ? gap : 0),
                      child: Column(
                        children: List.generate(7, (di) {
                          final date   = gridStart.add(Duration(days: wi * 7 + di));
                          final ds     = toDateStr(date);
                          final isFut  = date.isAfter(today);
                          final isToday= ds == todayStr;
                          final has    = !isFut && myDates.contains(ds);
                          return Container(
                            width: cellSize, height: cellSize,
                            margin: di < 6 ? EdgeInsets.only(bottom: gap) : EdgeInsets.zero,
                            decoration: BoxDecoration(
                              color: isFut
                                  ? Colors.transparent
                                  : has
                                      ? const Color(0xFF2EA043)
                                      : Colors.grey[200],
                              borderRadius: BorderRadius.circular(2),
                              border: isToday && !has
                                  ? Border.all(color: Colors.blue[300]!, width: 1)
                                  : null,
                            ),
                          );
                        }),
                      ),
                    );
                  }),
                ),

                const SizedBox(height: 6),
                // 범례 + 최장 스트릭
                Row(
                  children: [
                    if (maxStreak > 0) ...[
                      Icon(Icons.emoji_events, size: 13, color: Colors.amber[700]),
                      const SizedBox(width: 3),
                      Text('최장 $maxStreak일',
                          style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      const Spacer(),
                    ] else
                      const Spacer(),
                    Text('없음', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                    const SizedBox(width: 4),
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(color: const Color(0xFF2EA043), borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(width: 4),
                    Text('인증', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 세탁 예약 위젯 ─────────────────────────────────────────────────────────

  static const _weekDays = ['월','화','수','목','금','토','일'];

  String _todayKorDay() => _weekDays[DateTime.now().weekday - 1];

  Future<void> _toggleLaundryDay(String day) async {
    final already = (laundrySchedule[day] ?? []).any((e) => e['room'] == myRoom);
    if (already) {
      await _post('/api/laundry_schedule/cancel',  {'room': myRoom, 'day': day});
    } else {
      await _post('/api/laundry_schedule/reserve', {'room': myRoom, 'name': myName, 'day': day});
    }
  }

  Future<void> _showDayPickerDialog() async {
    final already = _weekDays.where((d) =>
        (laundrySchedule[d] ?? []).any((e) => e['room'] == myRoom)).toSet();
    Map<String, bool> sel = {for (final d in _weekDays) d: already.contains(d)};

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('세탁 요일 예약'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: _weekDays.map((day) {
              final entries = laundrySchedule[day] ?? [];
              final othersCount = entries.where((e) => e['room'] != myRoom).length;
              return CheckboxListTile(
                dense: true,
                title: Row(children: [
                  SizedBox(
                    width: 24,
                    child: Text(day, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  if (othersCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.blue[50], borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$othersCount명', style: TextStyle(fontSize: 11, color: Colors.blue[700])),
                    ),
                  ],
                ]),
                value: sel[day],
                activeColor: Colors.black,
                onChanged: (v) => setSt(() => sel[day] = v ?? false),
              );
            }).toList(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                for (final day in _weekDays) {
                  final wasIn  = already.contains(day);
                  final wantIn = sel[day] ?? false;
                  if (!wasIn && wantIn) {
                    await _post('/api/laundry_schedule/reserve',
                        {'room': myRoom, 'name': myName, 'day': day});
                  } else if (wasIn && !wantIn) {
                    await _post('/api/laundry_schedule/cancel',
                        {'room': myRoom, 'day': day});
                  }
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLaundryScheduleWidget() {
    final today = _todayKorDay();

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 14, 13, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Row(children: [
            const Icon(Icons.local_laundry_service, color: Colors.blueGrey, size: 16),
            const SizedBox(width: 5),
            const Expanded(
              child: Text('세탁 예약', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ),
          ]),
          const SizedBox(height: 10),

          // 요일별 목록
          ..._weekDays.map((day) {
            final entries  = laundrySchedule[day] ?? [];
            final isMyDay  = entries.any((e) => e['room'] == myRoom);
            final isToday  = day == today;
            final others   = entries.where((e) => e['room'] != myRoom).toList();

            return GestureDetector(
              onTap: () => _toggleLaundryDay(day),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: isMyDay
                      ? Colors.green[50]
                      : isToday
                          ? Colors.blue[50]
                          : Colors.grey[50],
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: isMyDay
                        ? Colors.green[300]!
                        : isToday
                            ? Colors.blue[200]!
                            : Colors.grey[200]!,
                    width: isMyDay || isToday ? 1.5 : 1,
                  ),
                ),
                child: Row(children: [
                  // 요일
                  SizedBox(
                    width: 18,
                    child: Text(day,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                          color: isToday ? Colors.blue[700] : Colors.black87,
                        )),
                  ),
                  // 예약 방 목록
                  Expanded(
                    child: entries.isEmpty
                        ? Text('없음',
                            style: TextStyle(fontSize: 10, color: Colors.grey[400]))
                        : Wrap(
                            spacing: 2, runSpacing: 1,
                            children: [
                              if (isMyDay)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.green[200],
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text('나', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                                ),
                              ...others.map((e) => Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[200],
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text('${e["room"]}',
                                        style: const TextStyle(fontSize: 9)),
                                  )),
                            ],
                          ),
                  ),
                  // 체크 표시
                  if (isMyDay)
                    const Icon(Icons.check_circle, size: 13, color: Colors.green),
                ]),
              ),
            );
          }),

          const SizedBox(height: 8),

          // 예약 버튼
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _showDayPickerDialog,
              icon: const Icon(Icons.edit_calendar, size: 14),
              label: const Text('예약 관리', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 7),
                minimumSize: Size.zero,
                side: BorderSide(color: Colors.grey[400]!),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 프로필 ─────────────────────────────────────────────────────────────────

  Widget _buildProfilePage() {
    final pts   = scores[myRoom] ?? 0;
    final color = tierColor(pts);
    final next  = nextTierPts(pts);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // 티어 카드
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color.withOpacity(0.12), color.withOpacity(0.04)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
                child: Text(tierName(pts), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(myName ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('$myRoom호', style: TextStyle(color: Colors.grey[600])),
              ]),
            ]),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$pts점', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: color)),
                if (next > 0)
                  Text('다음 티어까지 ${next - pts}점', style: TextStyle(color: Colors.grey[500], fontSize: 12))
                else
                  Text('최고 티어 달성!', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              ],
            ),
            if (next > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (pts / next).clamp(0.0, 1.0),
                  backgroundColor: Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation(color),
                  minHeight: 8,
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 16),

        // 티어 기준표
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[50], borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('티어 기준', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ..._tiers.reversed.map((t) {
                final (threshold, name, tColor) = t;
                final active = pts >= threshold;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        color: active ? tColor : Colors.grey[300], shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(name, style: TextStyle(
                        color: active ? tColor : Colors.grey,
                        fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                    const Spacer(),
                    Text('$threshold점', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  ]),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 스트릭 + 세탁 예약 (좌우 배치)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildStreakWidget()),
            const SizedBox(width: 8),
            Expanded(child: _buildLaundryScheduleWidget()),
          ],
        ),
        const SizedBox(height: 16),

        // 티어 순위표
        Builder(builder: (_) {
          final allRooms = allRoomIds.where((r) => r != '세탁실' && r != 'admin').toList()
            ..sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));
          final top20 = allRooms.take(20).toList();
          final adminPts = scores['admin'] ?? 0;

          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(children: [
                    const Icon(Icons.emoji_events, color: Color(0xFFFFB300), size: 20),
                    const SizedBox(width: 6),
                    const Text('전체 순위', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ]),
                ),
                // 관리자 행 (항상 최상단, 점수 없음)
                Container(
                  margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    const Icon(Icons.shield, color: Color(0xFFFFD700), size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('223호', style: TextStyle(
                        color: Color(0xFFFFD700), fontWeight: FontWeight.bold, fontSize: 14,
                      )),
                    ),
                    const Text('관리자', style: TextStyle(
                      color: Color(0xFFFFD700), fontSize: 12,
                    )),
                  ]),
                ),
                if (top20.isNotEmpty) ...[
                  Divider(height: 1, color: Colors.grey[200]),
                  ...top20.asMap().entries.map((entry) {
                    final rank = entry.key + 1;
                    final room = entry.value;
                    final rPts = scores[room] ?? 0;
                    final rColor = tierColor(rPts);
                    final isMe = room == myRoom;
                    return Container(
                      color: isMe ? rColor.withOpacity(0.08) : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      child: Row(children: [
                        SizedBox(
                          width: 28,
                          child: Text(
                            rank <= 3 ? ['🥇','🥈','🥉'][rank-1] : '$rank',
                            style: TextStyle(
                              fontSize: rank <= 3 ? 16 : 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[700],
                            ),
                          ),
                        ),
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(color: rColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$room호${isMe ? '  (나)' : ''}',
                            style: TextStyle(
                              fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                              color: isMe ? rColor : Colors.black87,
                            ),
                          ),
                        ),
                        Text(tierName(rPts), style: TextStyle(color: rColor, fontSize: 12)),
                        const SizedBox(width: 8),
                        Text('$rPts점', style: TextStyle(
                          color: Colors.grey[700], fontSize: 13, fontWeight: FontWeight.bold,
                        )),
                      ]),
                    );
                  }),
                ] else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Text('아직 점수 데이터가 없습니다', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                  ),
                const SizedBox(height: 6),
              ],
            ),
          );
        }),
        const SizedBox(height: 16),

        // 내 정보
        ListTile(
          leading: const Icon(Icons.home), title: const Text('내 방'), trailing: Text('$myRoom호'),
          tileColor: Colors.grey[50], shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.location_on), title: const Text('현재 위치'), trailing: Text('$currentPosition호'),
          tileColor: Colors.grey[50], shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        const SizedBox(height: 20),

        // 로그아웃
        OutlinedButton.icon(
          onPressed: () {
            _timer?.cancel();
            _clearSession();
            setState(() {
              myRoom = null; currentPosition = null; myName = null; isAdmin = false;
              messages = []; requests = []; history = []; _lastMsgCount = 0;
              _pendingMove = null; _notifiedRequestIds = {}; _approvalNotified = false;
            });
          },
          icon: const Icon(Icons.logout, color: Colors.red),
          label: const Text('로그아웃', style: TextStyle(color: Colors.red)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Colors.red),
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      ],
    );
  }
}

// ── 세탁찬 페이지 ─────────────────────────────────────────────────────────────

class LaundryPage extends StatefulWidget {
  final String myRoom, myName, base;
  final Map<String, List> laundrySchedule;
  const LaundryPage({
    required this.myRoom, required this.myName, required this.base,
    required this.laundrySchedule, super.key,
  });
  @override
  State<LaundryPage> createState() => _LaundryPageState();
}

class _LaundryPageState extends State<LaundryPage> {
  List   _machines = [];
  Map<String, List> _schedule = {};
  Timer? _timer;
  int    _tick = 0;
  // 알람 중복 방지: 이미 알림 보낸 기기 ID 집합
  final  _notified = <String>{};

  @override
  void initState() {
    super.initState();
    _requestNotificationPermission();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _tick++;
      if (_tick % 3 == 0) {
        _poll();
      } else {
        // 사용 중인 기기가 있을 때만 rebuild (카운트다운 갱신)
        final hasRunning = _machines.any((m) => m['status'] == 'running');
        if (hasRunning) {
          _checkClientSideDone();
          setState(() {});
        }
      }
    });
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  // ── 알람 ──────────────────────────────────────────────────────────────────

  void _requestNotificationPermission() {
    try {
      if (html.Notification.supported) {
        html.Notification.requestPermission();
      }
    } catch (_) {}
  }

  void _showNotification(String title, String body) {
    try {
      if (html.Notification.supported &&
          html.Notification.permission == 'granted') {
        html.Notification(title, body: body);
      }
    } catch (_) {}
  }

  // remaining이 0에 도달한 내 기기 감지 (서버 업데이트 기다리지 않고 즉시 알람)
  void _checkClientSideDone() {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    for (final m in _machines) {
      if (m['room'] != widget.myRoom) continue;
      if (m['status'] != 'running') continue;
      final endTime = (m['end_time'] as num?)?.toDouble();
      if (endTime == null) continue;
      final remaining = (endTime - now);
      if (remaining <= 0 && !_notified.contains(m['id'])) {
        _notified.add(m['id'] as String);
        final type = m['type'] == 'washer' ? '세탁기' : '건조기';
        _showNotification(
          '🧺 $type 완료!',
          '${widget.myRoom}호 $type가 끝났습니다. 세탁물을 가져가주세요.',
        );
      }
    }
  }

  // ── 서버 통신 ──────────────────────────────────────────────────────────────

  Future<void> _poll() async {
    try {
      final res = await http.get(Uri.parse('${widget.base}/api/state'));
      if (!mounted || res.statusCode != 200) return;
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      final newMachines = (d['laundry'] as List?) ?? [];

      // 서버에서 done으로 바뀐 내 기기 알람 (폴링 시점 감지)
      for (final m in newMachines) {
        if (m['room'] != widget.myRoom) continue;
        if (m['status'] != 'done') continue;
        if (!_notified.contains(m['id'])) {
          _notified.add(m['id'] as String);
          final type = m['type'] == 'washer' ? '세탁기' : '건조기';
          _showNotification(
            '🧺 $type 완료!',
            '${widget.myRoom}호 $type가 끝났습니다. 세탁물을 가져가주세요.',
          );
        }
      }
      // idle로 돌아간 기기는 notified에서 제거 (다음 사용을 위해)
      final idleIds = newMachines
          .where((m) => m['status'] == 'idle')
          .map((m) => m['id'] as String)
          .toSet();
      _notified.removeAll(idleIds);

      final newSched = (d['laundry_schedule'] as Map? ?? {})
          .map((k, v) => MapEntry(k as String, List.from(v as List)));
      setState(() { _machines = newMachines; _schedule = newSched; });
    } catch (_) {}
  }

  Future<void> _post(String path, Map body) async {
    try {
      await http.post(Uri.parse('${widget.base}$path'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
      await _poll();
    } catch (_) {}
  }

  // ── 기기 조작 ──────────────────────────────────────────────────────────────

  Future<void> _startMachine(Map m) async {
    // 1인 1기기 체크
    final mtype = m['type'] as String;
    final alreadyRunning = _machines.any((x) =>
        x['room'] == widget.myRoom && x['type'] == mtype && x['status'] == 'running');
    if (alreadyRunning) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(mtype == 'washer'
            ? '이미 세탁기를 사용 중입니다. (1인 1대)'
            : '이미 건조기를 사용 중입니다. (1인 1대)'),
        backgroundColor: Colors.red[400],
      ));
      return;
    }

    int? minutes;
    final customCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${mtype == 'washer' ? '세탁기' : '건조기'} 시작'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('시간을 선택하세요', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [30, 45, 60, 75, 90].map((min) =>
            ElevatedButton(
              onPressed: () { minutes = min; Navigator.pop(ctx); },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              child: Text('$min분'),
            ),
          ).toList()),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                controller: customCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '직접 입력 (분)',
                  hintText: '예: 55',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                final v = int.tryParse(customCtrl.text.trim());
                if (v != null && v > 0) { minutes = v; Navigator.pop(ctx); }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueGrey, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              child: const Text('확인'),
            ),
          ]),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소'))],
      ),
    );
    if (minutes == null) return;
    await _post('/api/laundry/start', {
      'id': m['id'], 'minutes': minutes,
      'room': widget.myRoom, 'name': widget.myName,
    });
  }

  Future<void> _cancelMachine(Map m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('사용 취소'),
        content: const Text('정말 취소할까요? 타이머가 초기화됩니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('아니요')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('취소하기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _notified.remove(m['id']); // 취소 시 알람 상태도 리셋
    await _post('/api/laundry/cancel', {'id': m['id']});
  }

  Future<void> _pickup(Map m) async {
    _notified.remove(m['id']);
    await _post('/api/laundry/pickup', {'id': m['id']});
  }

  // ── UI 빌드 ───────────────────────────────────────────────────────────────

  Map? _machine(String group, int slot, String type) {
    try {
      return _machines.firstWhere(
        (m) => m['group'] == group && m['slot'] == slot && m['type'] == type,
      ) as Map;
    } catch (_) { return null; }
  }

  Widget _machineCard(Map? m, {double width = 76}) {
    if (m == null) return SizedBox(width: width, height: 110);
    final status      = m['status'] as String;
    final endTime     = (m['end_time'] as num?)?.toDouble();
    final now         = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final rawRemaining = endTime != null
        ? (endTime - now).clamp(0.0, double.infinity).toInt() : null;

    final isIdle    = status == 'idle';
    final isRunning = status == 'running' && (rawRemaining == null || rawRemaining > 0);
    final isDone    = status == 'done' || (status == 'running' && rawRemaining == 0);
    final isWasher  = m['type'] == 'washer';
    final machineRoom = (m['room'] as String?) ?? '';
    final isOwner   = machineRoom == widget.myRoom;

    Color bgColor     = isIdle ? Colors.white : isRunning ? Colors.blue[50]! : Colors.orange[50]!;
    Color borderColor = isIdle ? Colors.grey[300]! : isRunning ? Colors.blue[300]! : Colors.orange[400]!;

    return Container(
      width: width, height: 110,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor, width: isIdle ? 1 : 2),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        GestureDetector(
          onTap: isIdle ? () => _startMachine(m) : null,
          child: Icon(
            isWasher ? Icons.local_laundry_service : Icons.dry,
            size: 24,
            color: isIdle ? Colors.grey[400] : (isRunning ? Colors.blue : Colors.orange),
          ),
        ),
        const SizedBox(height: 3),

        // 비어있음
        if (isIdle)
          GestureDetector(
            onTap: () => _startMachine(m),
            child: Text(isWasher ? '세탁기' : '건조기',
                style: TextStyle(fontSize: 10, color: Colors.grey[500])),
          ),

        // 사용 중
        if (isRunning && rawRemaining != null) ...[
          Text(
            '${rawRemaining ~/ 60}:${(rawRemaining % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
          Text(machineRoom.isNotEmpty ? '$machineRoom호' : '',
              style: TextStyle(fontSize: 9, color: Colors.grey[500])),
          if (isOwner) ...[
            const SizedBox(height: 3),
            SizedBox(
              height: 22, width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _cancelMachine(m),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[400], foregroundColor: Colors.white,
                  padding: EdgeInsets.zero, minimumSize: Size.zero,
                  textStyle: const TextStyle(fontSize: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                ),
                child: const Text('취소'),
              ),
            ),
          ],
        ],

        // 완료
        if (isDone) ...[
          const SizedBox(height: 2),
          if (isOwner)
            SizedBox(
              height: 26, width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _pickup(m),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange, foregroundColor: Colors.white,
                  padding: EdgeInsets.zero, minimumSize: Size.zero,
                  textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text('가져가기'),
              ),
            )
          else ...[
            Text('완료', style: TextStyle(fontSize: 10, color: Colors.orange[700], fontWeight: FontWeight.bold)),
            Text(machineRoom.isNotEmpty ? '$machineRoom호' : '',
                style: TextStyle(fontSize: 9, color: Colors.grey[500])),
          ],
        ],
      ]),
    );
  }

  Widget _buildGroup(String group, String label) {
    return LayoutBuilder(builder: (_, constraints) {
      // 화면 너비에 맞게 카드 크기 자동 계산 (overflow 방지)
      final cardW = ((constraints.maxWidth - 24) / 4).clamp(60.0, 90.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(4, (i) => _machineCard(_machine(group, i + 1, 'dryer'), width: cardW))),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(4, (i) => _machineCard(_machine(group, i + 1, 'washer'), width: cardW))),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = _machines.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('세탁찬'),
        actions: [
          IconButton(onPressed: _poll, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _legendItem(Colors.grey[300]!, '비어있음'),
              const SizedBox(width: 12),
              _legendItem(Colors.blue[300]!, '사용 중'),
              const SizedBox(width: 12),
              _legendItem(Colors.orange[400]!, '완료'),
            ]),
            const SizedBox(height: 6),
            Text('세탁기·건조기 각 1대씩만 사용 가능', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            const SizedBox(height: 16),
            _buildGroup('A', '🔵 왼쪽'),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            _buildGroup('B', '🟢 오른쪽'),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber[50], borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber[200]!),
              ),
              child: const Row(children: [
                Icon(Icons.notifications_active_outlined, color: Colors.amber, size: 18),
                SizedBox(width: 8),
                Expanded(child: Text(
                  '타이머가 끝나면 브라우저 알람이 울립니다.\n세탁물을 가져간 후 "가져가기"를 눌러주세요.',
                  style: TextStyle(fontSize: 12),
                )),
              ]),
            ),
            const SizedBox(height: 20),
            _buildScheduleSection(),
          ],
        ),
      ),
    );
  } // end build

  Widget _legendItem(Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
  ]);

  // ── 요일별 예약 현황 ────────────────────────────────────────────────────────

  static const _weekDays = ['월','화','수','목','금','토','일'];

  Widget _buildScheduleSection() {
    final sched   = _schedule.isNotEmpty ? _schedule : widget.laundrySchedule;
    final today   = _weekDays[DateTime.now().weekday - 1];
    final myDays  = _weekDays.where((d) =>
        (sched[d] ?? []).any((e) => e['room'] == widget.myRoom)).toSet();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.calendar_month, size: 16, color: Colors.blueGrey),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('요일별 세탁 예약 현황',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            Text('탭해서 예약/취소', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
          ]),
          const SizedBox(height: 10),
          ..._weekDays.map((day) {
            final entries = sched[day] ?? [];
            final isMyDay = myDays.contains(day);
            final isToday = day == today;
            final others  = entries.where((e) => e['room'] != widget.myRoom).toList();

            return GestureDetector(
              onTap: () async {
                if (isMyDay) {
                  await _post('/api/laundry_schedule/cancel',
                      {'room': widget.myRoom, 'day': day});
                } else {
                  await _post('/api/laundry_schedule/reserve',
                      {'room': widget.myRoom, 'name': widget.myName, 'day': day});
                }
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 5),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: isMyDay
                      ? Colors.green[50]
                      : isToday
                          ? Colors.blue[50]
                          : Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isMyDay
                        ? Colors.green[300]!
                        : isToday
                            ? Colors.blue[200]!
                            : Colors.grey[200]!,
                    width: isMyDay || isToday ? 1.5 : 1,
                  ),
                ),
                child: Row(children: [
                  SizedBox(
                    width: 22,
                    child: Text(day,
                        style: TextStyle(
                          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                          fontSize: 13,
                          color: isToday ? Colors.blue[700] : Colors.black87,
                        )),
                  ),
                  Expanded(
                    child: entries.isEmpty
                        ? Text('예약 없음',
                            style: TextStyle(fontSize: 11, color: Colors.grey[400]))
                        : Wrap(
                            spacing: 4, runSpacing: 2,
                            children: [
                              if (isMyDay)
                                _schedTag('나', Colors.green[200]!, Colors.green[800]!),
                              ...others.map((e) =>
                                  _schedTag('${e["room"]}호', Colors.grey[200]!, Colors.grey[700]!)),
                            ],
                          ),
                  ),
                  if (isMyDay)
                    const Icon(Icons.check_circle, size: 15, color: Colors.green)
                  else
                    Icon(Icons.add_circle_outline, size: 15, color: Colors.grey[400]),
                ]),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _schedTag(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
  );
}

