// Logic vote nằm ở CẢ app (Dart) lẫn webhook (JS). Test này sinh hàng nghìn
// tình huống ngẫu nhiên (hạt giống cố định), tính bằng bản Dart rồi gọi
// webhook/parity-check.mjs để bản JS tính lại và so từng kết quả: đọc tin vote
// (có mã buổi, tên bot, câu chữ lẫn lộn), vote hộ, và đếm suất.
// Máy không có Node thì bỏ qua (CI GitHub Actions có sẵn Node).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickleball_fund/models/models.dart';
import 'package:pickleball_fund/services/zalo_vote_sync.dart';

const _ids = ['a', 'b', 'c', 'd', 'e', 'f'];

const _textParts = [
  '0', '1', '2', '3', '4', '5', '10', '01', '+1', '-1', '1.', '0.1', '1,0', '1,2,3',
  '2 người', '3 suất', 'đi 2', 'ok 3', 'đi 10', 'đi', 'không', 'ko', 'k', 'ok', 'oke', 'có',
  'chốt', 'nghỉ', 'pass', 'x', 'yes', 'no', 'tham', 'gia', 'tham gia', 'đăng ký', 'B1', 'B2',
  'b3', 'B10', 'B 2', 'b12', 'em', 'nhé', 'ạ', 'anh', 'mai', 'sân', 'đá bóng', 'mấy người',
  'chơi', 'được không', '?', '!', '@An', '@Tuấn B', '@Bot PickleBall JVB', 'Bot', 'không đi',
];

const _proxyParts = [
  '@An', '@Tuấn B', '@Bình', '@Binh Dep Trai', '@Lạ', '1', '0', '2', '5', 'đi',
  'không', 'B2', 'ok', 'tham', 'đi không?', 'nhé', 'x',
];

void main() {
  test('app và webhook đọc vote, đếm suất giống hệt nhau', () async {
    final r = Random(31103);
    T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];

    final seats = [];
    for (var i = 0; i < 1500; i++) {
      final votes = <String, bool>{};
      final times = <String, DateTime>{};
      final comp = <String, int>{};
      final pids = <String>[];
      for (final p in _ids) {
        final roll = r.nextInt(4);
        if (roll == 1) votes[p] = true;
        if (roll == 2) votes[p] = false;
        // Có cả mốc giờ trùng nhau để kiểm thứ tự khi bằng giờ.
        if (votes.containsKey(p) && r.nextInt(4) > 0) {
          times[p] = DateTime.utc(2026, 11, 1, 8, r.nextInt(5));
        }
        if (r.nextInt(3) == 0) pids.add(p);
        if (r.nextInt(3) == 0) comp[p] = 1 + r.nextInt(3);
      }
      pids.shuffle(r);
      final s = Session(
        id: 's$i', title: '', date: DateTime(2026, 11, 9),
        status: r.nextBool() ? SessionStatus.voting : SessionStatus.closed,
        votes: votes, voteTimes: times, companions: comp, playerIds: pids,
        createdAt: DateTime(2026, 10, 1),
      );
      seats.add({
        'id': s.id, 'status': s.status.name, 'votes': votes, 'companions': comp, 'playerIds': pids,
        'voteTimes': times.map((k, v) => MapEntry(k, v.millisecondsSinceEpoch)),
        'dart': {
          'holders': s.seatHolders,
          'seats': s.seatsTaken,
          'holds': {for (final p in _ids) p: s.holdsSeat(p)},
        },
      });
    }

    final texts = [];
    for (var i = 0; i < 3000; i++) {
      final n = 1 + r.nextInt(r.nextInt(3) == 0 ? 6 : 3);
      final text = [for (var k = 0; k < n; k++) pick(_textParts)].join(' ');
      final bot = r.nextBool() ? 'Bot PickleBall JVB' : '';
      final v = ZaloVoteSync.readVote(text, botName: bot);
      texts.add({
        'text': text, 'bot': bot,
        'dart': {
          'err': v.isError, 'vote': v.isError ? null : v.vote, 'seats': v.seats,
          'code': ZaloVoteSync.sessionCodeIn(text),
        },
      });
    }

    final players = [
      Player(id: 'a', name: 'An', createdAt: DateTime(2026)),
      Player(id: 'tb', name: 'Tuấn B', createdAt: DateTime(2026)),
      Player(id: 'b', name: 'Bình', zaloName: 'Binh Dep Trai', createdAt: DateTime(2026)),
    ];
    final proxyTexts = [];
    for (var i = 0; i < 2000; i++) {
      final n = 2 + r.nextInt(4);
      final text = [for (var k = 0; k < n; k++) pick(_proxyParts)].join(' ');
      proxyTexts.add({
        'text': text,
        'dart': ZaloVoteSync.parseProxyVotes(text, players)?.map((a) => {
              'id': a.player?.id,
              'self': a.isSelf,
              'err': a.reading.isError,
              'vote': a.reading.isError ? null : a.reading.vote,
              'seats': a.reading.isError || a.reading.vote != true ? 0 : a.reading.seats,
            }).toList(),
      });
    }

    final dir = Directory.systemTemp.createTempSync('parity');
    final file = File('${dir.path}/cases.json')
      ..writeAsStringSync(jsonEncode({
        'seats': seats,
        'texts': texts,
        'proxies': {
          'players': [
            for (final p in players) {'id': p.id, 'name': p.name, 'zaloName': p.zaloName},
          ],
          'texts': proxyTexts,
        },
      }));
    ProcessResult res;
    try {
      res = await Process.run('node', ['webhook/parity-check.mjs', file.path]);
    } on ProcessException {
      markTestSkipped('Không có Node trên máy này');
      return;
    } finally {
      dir.deleteSync(recursive: true);
    }
    expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
  });
}
