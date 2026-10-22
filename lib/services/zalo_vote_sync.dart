import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import '../models/models.dart';
import '../utils/format.dart';
import '../utils/text.dart';
import 'share_service.dart';
import 'team_store.dart';
import 'zalo_bot_service.dart';
import 'zalo_commands.dart';
import 'zalo_drinks.dart';

/// Kết quả một lần đồng bộ vote từ Zalo.
class ZaloSyncResult {
  final Session? target;
  final List<String> appliedNames; // người đã cập nhật vote
  final List<String> createdNames; // người chơi vừa tự tạo từ Zalo
  final List<String> fullNames; // vote "đi" bị từ chối vì đã đủ người
  final List<String> drinkNotes; // kết quả các lệnh ghi nước
  final int lateCount; // tin gửi sau hạn vote
  final int pendingCount; // tin chưa khớp được tên
  final int ignoredCount; // tin không thuộc nhóm / gửi trước khi tạo buổi / không phải vote
  const ZaloSyncResult({
    required this.target,
    this.appliedNames = const [],
    this.createdNames = const [],
    this.fullNames = const [],
    this.drinkNotes = const [],
    this.lateCount = 0,
    this.pendingCount = 0,
    this.ignoredCount = 0,
  });

  bool get isEmpty => appliedNames.isEmpty && pendingCount == 0;
}

/// Logic khớp tin nhắn Zalo thành vote cho buổi chơi.
class ZaloVoteSync {
  ZaloVoteSync._();

  static final _noPattern = RegExp(
      r'(^|\s)(0|-1|khong|khg|hok|hong|hem|ko|k|no|nope|ban|nghi|bo qua|huy|pass|x)(\s|$)');
  static final _yesPattern = RegExp(
      r'(^|\s)(1|\+1|di|co|ok|oke|okie|okay|yes|y|tham gia|join|choi|dk|dang ky|chot|len|vao|count me)(\s|$)');

  /// Hiểu nội dung reply: true = đi, false = không đi, null = không rõ.
  /// [botName] để bỏ phần @mention bot trước khi phân tích.
  static bool? parseVote(String text, {String botName = ''}) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    t = t.replaceAll('@', ' ').replaceAll(RegExp(r'[.,!?()\[\]:;]+'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;
    if (_noPattern.hasMatch(t)) return false;
    if (_yesPattern.hasMatch(t)) return true;
    return null;
  }

  /// Tìm người chơi tương ứng với người gửi Zalo.
  /// Ưu tiên zaloId đã lưu, sau đó khớp tên (chỉ nhận khi khớp duy nhất).
  static Player? matchPlayer(
      {required String zaloId, required String zaloName, required List<Player> players}) {
    if (zaloId.isNotEmpty) {
      for (final p in players) {
        if (p.zaloId == zaloId) return p;
      }
    }
    final n = normalizeVi(zaloName);
    if (n.isEmpty) return null;
    final exact = players.where((p) => normalizeVi(p.name) == n).toList();
    if (exact.length == 1) return exact.first;
    // Khớp một phần nhưng phải TRỌN CỤM TỪ, nếu không người lạ tên "Lan"
    // sẽ bị khớp thành người chơi "An" và ghi nhầm vote / tiền nước.
    final partial = players.where((p) {
      final pn = normalizeVi(p.name);
      if (pn.isEmpty) return false;
      return containsWholeWord(n, pn) || containsWholeWord(pn, n);
    }).toList();
    if (partial.length == 1) return partial.first;
    return null;
  }

  /// Chọn buổi để nhận vote: buổi đang vote gần nhất trong tương lai,
  /// nếu không có thì buổi đang vote mới nhất.
  static Session? pickTarget(List<Session> sessions) {
    // Ưu tiên buổi còn hạn vote; buổi đã quá hạn vẫn được chọn để tin
    // trễ hạn được ghi nhận là "trễ" (bỏ qua) thay vì rơi vào buổi khác.
    var voting = sessions.where((s) => s.isVoteOpen).toList();
    if (voting.isEmpty) {
      voting = sessions.where((s) => s.status == SessionStatus.voting).toList();
    }
    if (voting.isEmpty) return null;
    final now = DateTime.now().subtract(const Duration(hours: 6));
    final upcoming = voting.where((s) => s.date.isAfter(now)).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (upcoming.isNotEmpty) return upcoming.first;
    voting.sort((a, b) => b.date.compareTo(a.date));
    return voting.first;
  }

  /// Áp dụng danh sách tin nhắn mới vào buổi [target] (hoặc tự chọn).
  static Future<ZaloSyncResult> apply(
    TeamStore store,
    List<ZaloUpdate> updates, {
    Session? target,
  }) async {
    await rememberChats(store, updates);
    final session = target ?? pickTarget(store.sessions);
    // Chưa có buổi nào đang mở vote → tin vote không được tính (bỏ qua).
    if (session == null) {
      return ZaloSyncResult(target: null, ignoredCount: updates.length);
    }
    // Chỉ nhận tin gửi SAU khi buổi chơi được tạo (trừ 1 phút lệch giờ).
    final openedAt = session.createdAt.subtract(const Duration(minutes: 1));
    final settings = store.settings;
    final groupId = settings.zaloGroupId;

    final votes = {...session.votes};
    final voteTimes = {...session.voteTimes};
    final pending = {for (final p in session.zaloPending) p.zaloId: p};
    final applied = <String>[];
    final created = <String, Player>{}; // zaloId -> người chơi vừa tự tạo
    final createdNames = <String>[];
    final fullNames = <String>[]; // vote "đi" bị từ chối vì đã đủ người
    final drinkNotes = <String>[]; // kết quả lệnh ghi nước
    var ignored = 0;
    var lateCount = 0; // tin gửi sau hạn vote

    // Sắp xếp theo thời gian để tin sau ghi đè tin trước.
    final sorted = [...updates]..sort((a, b) => a.date.compareTo(b.date));
    for (final u in sorted) {
      // Lệnh "@bot help": trả lời hướng dẫn (khi app tự hỏi Zalo), không tính vote.
      if (ZaloCommands.isCommand(u.text)) {
        ignored++;
        if (!settings.zaloWebhookMode && settings.hasZaloBot) {
          try {
            await ZaloBotService.forTeam(settings, store.repo.teamId)
                .sendMessage(u.chatId, ZaloCommands.helpText);
          } catch (_) {
            // Không gửi được thì bỏ qua, không chặn việc nhận vote.
          }
        }
        continue;
      }
      final inScope = u.chatId == groupId || !u.isGroup || groupId.isEmpty;
      if (!inScope || u.text.trim().isEmpty) {
        ignored++;
        continue;
      }

      // "@bot quỹ" → bảng số dư cả nhóm (chế độ app tự hỏi Zalo; webhook đã tự trả lời).
      if (ZaloCommands.isFund(u.text, botName: settings.zaloBotName)) {
        ignored++;
        if (!settings.zaloWebhookMode && settings.hasZaloBot) {
          try {
            await ZaloBotService.forTeam(settings, store.repo.teamId)
                .sendMessage(u.chatId, ShareService.balanceReport(store));
          } catch (_) {}
        }
        continue;
      }

      // "@bot nước" → gửi danh sách nước (mã, tên, giá). Ở chế độ webhook thì
      // Worker đã trả lời ngay; ở đây xử lý cho chế độ app tự hỏi Zalo.
      if (ZaloDrinks.isListRequest(u.text, botName: settings.zaloBotName)) {
        ignored++;
        if (!settings.zaloWebhookMode && settings.hasZaloBot) {
          try {
            await ZaloBotService.forTeam(settings, store.repo.teamId)
                .sendMessage(u.chatId, ZaloDrinks.listText(store.drinkTypes, on: u.date));
          } catch (_) {}
        }
        continue;
      }

      // Lệnh ghi nước ("nước 2", "N1 2", "revive 2, suối 1", "+1 revive") → ghi vào
      // buổi gần nhất người đó tham gia, tính lại tiền, bot trả lời xác nhận.
      if (ZaloDrinks.looksLikeDrink(u.text, store.drinkTypes, botName: settings.zaloBotName)) {
        ignored++;
        final note = await _handleDrink(store, u);
        if (note != null) drinkNotes.add(note);
        continue;
      }

      if (u.date.isBefore(openedAt)) {
        ignored++;
        continue;
      }
      // Quá hạn vote → bỏ qua.
      if (u.date.isAfter(session.effectiveVoteDeadline)) {
        ignored++;
        lateCount++;
        continue;
      }
      final vote = parseVote(u.text, botName: settings.zaloBotName);
      var player = matchPlayer(
          zaloId: u.fromId, zaloName: u.fromName, players: store.activePlayers);
      // Người vừa được tự tạo trong cùng đợt (stream chưa kịp cập nhật).
      if (player == null && u.fromId.isNotEmpty && created.containsKey(u.fromId)) {
        player = created[u.fromId];
      }

      // Đã đủ số người: không nhận thêm vote "đi" (người đã "đi" vẫn được đổi ý).
      final yesCount = votes.values.where((v) => v).length;
      final alreadyYes = player != null && votes[player.id] == true;
      if (vote == true && session.maxPlayers != null && yesCount >= session.maxPlayers! && !alreadyYes) {
        fullNames.add(player?.name ?? u.fromName);
        ignored++;
        continue;
      }

      // Người reply vote rõ nghĩa nhưng chưa có trong danh sách → tự thêm người chơi.
      if (player == null && vote != null && u.fromId.isNotEmpty) {
        final id = await store.repo.addPlayerFromZalo(zaloId: u.fromId, zaloName: u.fromName);
        player = Player(
          id: id,
          name: u.fromName.trim().isEmpty ? 'Zalo ${u.fromId}' : u.fromName.trim(),
          zaloId: u.fromId,
          zaloName: u.fromName,
          createdAt: DateTime.now(),
        );
        created[u.fromId] = player;
        createdNames.add(player.name);
      }

      if (player != null && vote != null) {
        votes[player.id] = vote;
        voteTimes[player.id] = u.date;
        pending.remove(u.fromId);
        if (!applied.contains(player.name)) applied.add(player.name);
        // Ghi nhớ Zalo id để lần sau khớp chính xác.
        if (player.zaloId != u.fromId && u.fromId.isNotEmpty) {
          await store.repo.updatePlayer(player.id, {
            'zaloId': u.fromId,
            'zaloName': u.fromName,
          });
        }
      } else {
        pending[u.fromId.isEmpty ? u.messageId : u.fromId] = ZaloPendingVote(
          zaloId: u.fromId,
          name: u.fromName,
          text: u.text,
          vote: vote,
          date: u.date,
        );
      }
    }

    if (applied.isNotEmpty || pending.length != session.zaloPending.length) {
      await store.repo.updateSessionFields(session.id, {
        'votes': votes,
        'voteTimes': voteTimes.map((k, v) => MapEntry(k, Timestamp.fromDate(v))),
        'zaloPending': pending.values.map((e) => e.toMap()).toList(),
      });
    }
    return ZaloSyncResult(
      target: session,
      appliedNames: applied,
      createdNames: createdNames,
      fullNames: fullNames,
      drinkNotes: drinkNotes,
      lateCount: lateCount,
      pendingCount: pending.length,
      ignoredCount: ignored,
    );
  }

  /// Xử lý lệnh ghi nước từ một tin Zalo (cho mình hoặc nhập hộ nhiều người
  /// bằng @tên). Trả về dòng mô tả kết quả (hoặc null).
  static Future<String?> _handleDrink(TeamStore store, ZaloUpdate u) async {
    final settings = store.settings;
    final sender = matchPlayer(
        zaloId: u.fromId, zaloName: u.fromName, players: store.activePlayers);
    final assignments = ZaloDrinks.parseMulti(
        u.text, store.drinkTypes, store.activePlayers, botName: settings.zaloBotName);

    final lines = <String>[];
    final notes = <String>[];
    // Gom thay đổi theo buổi để mỗi buổi chỉ lưu + tính tiền một lần.
    final touched = <String, Session>{};

    for (final a in assignments) {
      final target = a.isSelf ? sender : a.player;
      final who = a.isSelf ? (sender?.name ?? u.fromName) : (a.player?.name ?? a.nameText);
      if (target == null) {
        lines.add(a.isSelf
            ? '❓ ${u.fromName}: chưa có tên trong danh sách, báo quản lý thêm trước nhé.'
            : '❓ Không tìm thấy người chơi "${a.nameText}".');
        notes.add('$who: không tìm thấy');
        continue;
      }
      if (!a.command.isValid) {
        lines.add('❓ $who: ${a.command.error ?? 'chưa hiểu'}. Ví dụ: "N1 2" hoặc "revive 2, suối 1".');
        notes.add('$who: lệnh không hiểu');
        continue;
      }
      // Buổi của người được ghi; không có thì dùng buổi của người gửi (nhập hộ).
      var session = ZaloDrinks.pickSession(store.sessions, target.id, u.date);
      session ??= sender == null ? null : ZaloDrinks.pickSession(store.sessions, sender.id, u.date);
      if (session == null) {
        lines.add('❓ $who: không tìm thấy buổi chơi gần đây để ghi nước.');
        notes.add('$who: không có buổi');
        continue;
      }
      var s = touched[session.id] ?? session;
      // KHÔNG tự thêm người vào danh sách chơi (sẽ làm tiền sân của người khác
      // đổi). Chỉ ghi nước; quản lý thêm họ vào buổi nếu họ có chơi.
      final notInSession = !s.playerIds.contains(target.id);
      // Đóng băng giá nước cho các loại chưa có giá trong buổi.
      final prices = {...s.drinkPrices};
      for (final c in a.command.changes) {
        prices.putIfAbsent(
            c.drinkTypeId, () => store.drinkTypeById(c.drinkTypeId)?.priceOn(s.date) ?? 0);
      }
      final drinks = ZaloDrinks.applyChanges(s.drinks, target.id, a.command.changes);
      s = s.copyWith(drinks: drinks, drinkPrices: prices);
      touched[s.id] = s;

      final mine = drinks[target.id] ?? {};
      var total = 0;
      final parts = <String>[];
      mine.forEach((id, q) {
        total += q * (prices[id] ?? 0);
        parts.add('$q ${store.drinkTypeById(id)?.name ?? 'nước'}');
      });
      final label = s.title.isEmpty ? fmtDate(s.date) : s.title;
      lines.add(parts.isEmpty
          ? '✅ ${target.name}: đã xoá nước ở "$label".'
          : '✅ ${target.name} ($label): ${parts.join(', ')} = ${vnd(total)}'
              '${notInSession ? ' · chưa có trong danh sách chơi buổi này, quản lý thêm nếu có chơi' : ''}.');
      notes.add('${target.name}: ${parts.isEmpty ? 'xoá nước' : parts.join(', ')}');
    }

    for (final s in touched.values) {
      await store.repo.saveAndSettleSession(s);
    }

    if (lines.isEmpty) return null;
    // Trả lời trong chat (nếu gửi được).
    if (settings.hasZaloBot) {
      try {
        await ZaloBotService.forTeam(settings, store.repo.teamId)
            .sendMessage(u.chatId, lines.join('\n'));
      } catch (_) {
        // Không gửi được thì thôi, dữ liệu đã ghi.
      }
    }
    return notes.join('; ');
  }

  /// Ghi nhớ các chat (nhóm / riêng) bot từng nhận tin để người dùng chọn nhóm.
  static Future<void> rememberChats(TeamStore store, List<ZaloUpdate> updates) async {
    if (updates.isEmpty) return;
    final known = store.settings.zaloChats;
    final chats = <String, Map<String, dynamic>>{};
    for (final u in updates) {
      final old = known[u.chatId];
      // Bỏ qua nếu đã lưu đúng tin này rồi (tránh ghi lặp khi xử lý lại).
      if (old != null && old.lastText == u.text && !u.date.isAfter(old.lastDate)) continue;
      chats[u.chatId] = ZaloChat(
        chatId: u.chatId,
        isGroup: u.isGroup,
        lastFromName: u.fromName,
        lastText: u.text,
        lastDate: u.date,
      ).toMap();
    }
    if (chats.isEmpty) return;
    await store.repo.updateSettings({'zaloChats': chats});
  }

  /// Gán thủ công một vote đang chờ cho người chơi, và nhớ Zalo id.
  static Future<void> resolvePending(
    TeamStore store,
    Session session,
    ZaloPendingVote p,
    Player player, {
    bool? voteOverride,
  }) async {
    final vote = voteOverride ?? p.vote ?? true;
    final votes = {...session.votes, player.id: vote};
    final remaining = session.zaloPending
        .where((e) => !(e.zaloId == p.zaloId && e.name == p.name))
        .map((e) => e.toMap())
        .toList();
    if (p.zaloId.isNotEmpty) {
      await store.repo.updatePlayer(player.id, {'zaloId': p.zaloId, 'zaloName': p.name});
    }
    await store.repo.updateSessionFields(session.id, {
      'votes': votes,
      'zaloPending': remaining,
    });
  }

  static Future<void> dismissPending(
      TeamStore store, Session session, ZaloPendingVote p) {
    final remaining = session.zaloPending
        .where((e) => !(e.zaloId == p.zaloId && e.name == p.name))
        .map((e) => e.toMap())
        .toList();
    return store.repo.updateSessionFields(session.id, {'zaloPending': remaining});
  }
}
