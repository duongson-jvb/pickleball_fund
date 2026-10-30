import 'package:cloud_firestore/cloud_firestore.dart' show FieldValue, Timestamp;

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

  /// Từ để hỏi: câu chứa chúng là câu hỏi, không phải vote (khớp QUESTION_RE bên webhook).
  static final _questionPattern = RegExp(
      r'(^|\s)(gi|dau|khi nao|luc nao|may gio|bao nhieu|bao gio|sao|the nao|tai sao|ai|nao|co ai|phai khong|duoc khong|chua)(\s|$)');

  /// Số suất tối đa một người được đăng ký (bản thân + người đính kèm).
  /// Gõ số lớn hơn bị coi là nhập sai, bot báo lại thay vì tính bừa.
  static const maxVoteSeats = 4;

  /// Câu dài hơn số từ này mà chỉ có từ khoá vote (không phải con số) thì
  /// KHÔNG tự tính thành vote - đưa vào mục "chưa khớp" để quản lý quyết định,
  /// tránh câu nói thường như "mai mình đi đá bóng nhé" bị tính là đi.
  static const _maxWordsForKeywordVote = 5;

  /// Kết quả đọc một tin vote.
  static VoteReading readVote(String text, {String botName = ''}) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    t = t.replaceAll('@', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return const VoteReading(null);

    // Tin chỉ gồm chữ số và dấu phân cách (không có chữ cái): bắt buộc phải là
    // MỘT số nguyên hợp lệ. "10", "01", "0.1", "1,0", "1,2,3" là nhập sai.
    final numericOnly = RegExp(r'^[+\-\d.,\s]+$').hasMatch(t);
    if (numericOnly) {
      final cleaned = t.replaceAll(RegExp(r'\.+$'), '').trim(); // bỏ dấu chấm cuối câu
      if (cleaned == '-1') return const VoteReading(false, seats: 0);
      final m = RegExp(r'^\+?(\d+)$').firstMatch(cleaned);
      if (m == null) return VoteReading(null, error: _numberError(text));
      return _fromNumber(m.group(1)!, text);
    }

    // "2 người", "3 suất".
    final withUnit =
        RegExp(r'^\+?(\d+)\s+(nguoi|ng|suat|slot)$').firstMatch(t);
    if (withUnit != null) return _fromNumber(withUnit.group(1)!, text);

    final words = t.replaceAll(RegExp(r'[.,!?()\[\]:;]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (_noPattern.hasMatch(words) || _yesPattern.hasMatch(words)) {
      // Câu hỏi ("sân mấy người chơi em?", "có đi không?") không phải vote.
      if (text.contains('?') || _questionPattern.hasMatch(words)) {
        return const VoteReading(null);
      }
      // Câu quá dài thì không chắc là vote → để quản lý quyết định.
      if (words.split(' ').length > _maxWordsForKeywordVote) {
        return const VoteReading(null);
      }
      if (_noPattern.hasMatch(words)) return const VoteReading(false, seats: 0);
      // "đi 2", "ok 3": từ khoá kèm số suất.
      final n = RegExp(r'(^|\s)\+?(\d+)(\s|$)').firstMatch(words);
      if (n != null) {
        final fromNumber = _fromNumber(n.group(2)!, text);
        if (fromNumber.isError) return fromNumber;
        return VoteReading(true, seats: fromNumber.seats < 1 ? 1 : fromNumber.seats);
      }
      return const VoteReading(true, seats: 1);
    }
    return const VoteReading(null);
  }

  static VoteReading _fromNumber(String digits, String original) {
    // "01", "007" - số 0 đứng đầu là gõ nhầm.
    if (digits.length > 1 && digits.startsWith('0')) {
      return VoteReading(null, error: _numberError(original));
    }
    final n = int.parse(digits);
    if (n > maxVoteSeats) return VoteReading(null, error: _numberError(original));
    if (n == 0) return const VoteReading(false, seats: 0);
    return VoteReading(true, seats: n);
  }

  static String _numberError(String original) =>
      '🙏 Dạ em chưa hiểu "${original.trim()}" ạ.\nAnh/chị reply giúp em: 0 = không đi · 1 = đi · '
      '2 = đi 2 người (kèm 1) · tối đa $maxVoteSeats ạ.';

  /// Hiểu nội dung reply: true = đi, false = không đi, null = không rõ.
  /// [botName] để bỏ phần @mention bot trước khi phân tích.
  static bool? parseVote(String text, {String botName = ''}) =>
      readVote(text, botName: botName).vote;

  /// Số suất khi vote "đi": "1"/"đi" = 1 (một mình), "2" = 2 (kèm 1 người),
  /// "3 người", "đi 2" = số tương ứng. Tối đa 10. Không phải vote đi → null.
  static int? parseVoteCount(String text, {String botName = ''}) {
    final r = readVote(text, botName: botName);
    return r.vote == true ? r.seats : null;
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

  /// Các từ được phép trong một "đuôi vote" ("di", "khong di", "ok 2"...). Dùng để
  /// tách tên người với phần vote trong tin vote hộ khi tên chưa có trong danh sách.
  static const _voteVocab = {
    'di', 'co', 'ok', 'oke', 'okie', 'okay', 'yes', 'y', 'tham', 'gia', 'join', 'choi',
    'dk', 'dang', 'ky', 'chot', 'len', 'vao', 'count', 'me', 'khong', 'khg', 'hok',
    'hong', 'hem', 'ko', 'k', 'no', 'nope', 'ban', 'nghi', 'bo', 'qua', 'huy', 'pass',
    'x', 'nguoi', 'ng', 'suat', 'slot',
  };

  /// Phần [rest] (đã bỏ dấu) có phải là một vote gọn ("1", "0", "+1", "2 người",
  /// "đi", "không đi", "ok 2") không. Câu dài hơn không được tính để tránh ghi
  /// nhầm vote hộ từ câu nói thường.
  static bool isVoteToken(String rest) {
    final t = rest.trim();
    if (t.isEmpty) return false;
    if (RegExp(r'^[+\-\d.,\s]+$').hasMatch(t)) return true;
    final words = t.split(' ');
    if (words.length > 3) return false;
    return words.every((w) => _voteVocab.contains(w) || RegExp(r'^\+?\d+$').hasMatch(w));
  }

  /// Tin còn @mention người khác (ngoài bot) không.
  static bool mentionsOther(String text, {String botName = ''}) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    // Sau khi bỏ tên bot còn "@ 1" → không tính; chỉ tính "@" dính liền tên.
    return RegExp(r'@\S').hasMatch(t);
  }

  /// Tách tin vote hộ: "@An 1 @Nguyễn Văn Bình 0" → [An: đi], [Bình: không đi];
  /// "1 @An 2" → [tự mình: đi], [An: đi 2 suất]. Tên khớp dài nhất với danh sách
  /// (không dấu, không phân biệt hoa thường). Trả null nếu KHÔNG phải tin vote hộ:
  /// không có @tên kèm vote gọn, hoặc là câu hỏi ("@An đi không?").
  static List<ProxyVote>? parseProxyVotes(String text, List<Player> players,
      {String botName = ''}) {
    var t = normalizeVi(text);
    if (botName.isNotEmpty) t = t.replaceAll(normalizeVi(botName), ' ');
    if (t.contains('?')) return null;
    t = t.replaceAll(RegExp(r'[.!:;]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!t.contains('@')) return null;
    final parts = t.split('@');
    final out = <ProxyVote>[];
    final head = parts.first.trim();
    if (head.isNotEmpty) {
      if (!isVoteToken(head)) return null; // phần đầu là câu nói → không phải vote hộ
      out.add(ProxyVote(null, '', readVote(head)));
    }
    var valid = 0;
    for (final raw in parts.skip(1)) {
      final seg = raw.trim();
      if (seg.isEmpty) continue;
      // Khớp dài nhất theo tên trong app HOẶC tên hiển thị Zalo đã nhớ (Zalo chèn
      // @mention bằng tên hiển thị, thường khác tên trong app).
      Player? best;
      var bestLen = 0;
      for (final p in players) {
        for (final n in {normalizeVi(p.name), normalizeVi(p.zaloName)}) {
          if (n.isEmpty) continue;
          if ((seg == n || seg.startsWith('$n ')) && n.length > bestLen) {
            best = p;
            bestLen = n.length;
          }
        }
      }
      String nameText;
      String rest;
      if (best != null) {
        nameText = best.name;
        rest = seg.substring(bestLen).trim();
      } else {
        // Tên = các từ đứng trước đuôi vote gọn đầu tiên.
        final tokens = seg.split(' ');
        var i = 1;
        while (i < tokens.length && !isVoteToken(tokens.skip(i).join(' '))) {
          i++;
        }
        nameText = tokens.take(i).join(' ');
        rest = tokens.skip(i).join(' ');
        // "@bot 1" (tên bot chưa lưu trong cài đặt) → vote của chính người gửi.
        if (nameText == 'bot' || nameText.startsWith('bot ')) {
          if (isVoteToken(rest)) {
            out.add(ProxyVote(null, '', readVote(rest)));
            valid++;
          }
          continue;
        }
        // "@Nguyễn Văn An" với người chơi tên "An": khớp trọn từ, duy nhất.
        best = matchPlayer(zaloId: '', zaloName: nameText, players: players);
        if (best != null) nameText = best.name;
      }
      if (!isVoteToken(rest)) {
        out.add(ProxyVote(best, nameText,
            VoteReading(null, error: 'chưa hiểu "$seg". Gõ "@Tên 1" (đi), "@Tên 0" (không đi), "@Tên 2" (đi 2 người).')));
        continue;
      }
      out.add(ProxyVote(best, nameText, readVote(rest)));
      valid++;
    }
    return valid == 0 ? null : out;
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
    // Không có buổi nào đang mở vote thì VẪN xử lý lệnh (ghi nước, quỹ, help) -
    // ghi nước là việc làm sau buổi chơi, lúc đó buổi đã chốt từ lâu. Chỉ riêng
    // tin vote là không ghi được, và được báo lại cho người gửi.
    // Chỉ nhận tin gửi SAU khi buổi chơi được tạo (trừ 1 phút lệch giờ).
    final openedAt =
        session?.createdAt.subtract(const Duration(minutes: 1)) ?? DateTime(2100);
    final settings = store.settings;
    final groupId = settings.zaloGroupId;

    final votes = {...?session?.votes};
    final voteTimes = {...?session?.voteTimes};
    final companions = {...?session?.companions};
    final pending = {
      for (final p in session?.zaloPending ?? const <ZaloPendingVote>[]) p.zaloId: p
    };
    final applied = <String>[];
    final created = <String, Player>{}; // zaloId -> người chơi vừa tự tạo
    final createdNames = <String>[];
    final fullNames = <String>[]; // vote "đi" bị từ chối vì đã đủ người
    final drinkNotes = <String>[]; // kết quả lệnh ghi nước
    final confirmations = <String, List<String>>{}; // chatId -> các dòng xác nhận vote
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

      // "@bot vote" → các buổi đang mở vote (chế độ app tự hỏi Zalo; webhook đã tự trả lời).
      if (ZaloCommands.isVoteList(u.text, botName: settings.zaloBotName)) {
        ignored++;
        if (!settings.zaloWebhookMode && settings.hasZaloBot) {
          final open = store.sessions.where((s) => s.status == SessionStatus.voting).toList()
            ..sort((a, b) => a.date.compareTo(b.date));
          final text = open.isEmpty
              ? '📭 Hiện không có vote nào đang mở. Quản lý tạo buổi mới trong app là em gửi vote ngay.'
              : open.take(3).map((s) => ShareService.voteText(store, s)).join('\n\n');
          await _reply(store, u.chatId, text);
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

      // Không có buổi nào đang mở vote: tin vote không ghi được → báo lại.
      if (session == null) {
        ignored++;
        final r = readVote(u.text, botName: settings.zaloBotName);
        if (r.isError) {
          await _reply(store, u.chatId, r.error!);
        } else if (r.vote != null) {
          await _reply(store, u.chatId, noOpenVoteText);
        }
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
      var sender = matchPlayer(
          zaloId: u.fromId, zaloName: u.fromName, players: store.activePlayers);
      // Người vừa được tự tạo trong cùng đợt (stream chưa kịp cập nhật).
      if (sender == null && u.fromId.isNotEmpty && created.containsKey(u.fromId)) {
        sender = created[u.fromId];
      }
      // Vote hộ: "@An 1 @Bình 0" (phần trước @ đầu tiên là của chính người gửi).
      // Không phải vote hộ → một phần duy nhất: vote của người gửi.
      final proxy =
          parseProxyVotes(u.text, store.activePlayers, botName: settings.zaloBotName);
      // Có @người khác mà không phải vote hộ ("@An đi không?") → câu nói với người
      // đó, không phải vote của người gửi.
      if (proxy == null && mentionsOther(u.text, botName: settings.zaloBotName)) {
        ignored++;
        continue;
      }
      final parts = proxy ??
          [ProxyVote(null, '', readVote(u.text, botName: settings.zaloBotName))];
      final lines = <String>[]; // trả lời cho tin này
      final label = session.title.isEmpty ? 'buổi chơi' : '"${session.title}"';
      final cap = session.maxPlayers != null ? '/${session.maxPlayers}' : '';
      // Đếm cả người quản lý đã thêm thẳng vào danh sách chơi: họ cũng chiếm
      // chỗ. Chỉ đếm theo `votes` thì app tưởng còn chỗ, nhận thừa vote rồi
      // lúc chốt lại cắt mất người đã được bot xác nhận.
      int seatsNow() {
        final held = <String>{
          for (final e in votes.entries)
            if (e.value) e.key,
          ...session.playerIds,
        };
        return held.fold(0, (n, pid) => n + 1 + (companions[pid] ?? 0));
      }

      for (final a in parts) {
        final reading = a.reading;
        final who = a.isSelf ? (sender?.name ?? u.fromName) : (a.player?.name ?? a.nameText);
        // Gõ số sai ("10", "01", "1,2,3"...) → báo lại, không tính vote.
        if (reading.isError) {
          ignored++;
          if (proxy == null) {
            await _reply(store, u.chatId, reading.error!);
          } else {
            lines.add('❓ $who: ${reading.error}');
          }
          continue;
        }
        final vote = reading.vote;
        if (vote == null) {
          // Câu nói thường ("anh Sơn bảo anh oke rồi em") → không phải vote, bỏ qua.
          ignored++;
          continue;
        }
        var player = a.isSelf ? sender : a.player;
        if (!a.isSelf && player == null) {
          ignored++;
          lines.add('❓ Không tìm thấy người chơi "${a.nameText}". Thêm họ trong app rồi vote hộ lại nhé.');
          continue;
        }

        // Số suất: "2" = đi kèm 1 người đính kèm. Kiểm tra chỗ còn trống (tính cả
        // đính kèm). Người đã "đi" chỉ bị chặn nếu xin THÊM suất mà không còn chỗ.
        final count = vote ? reading.seats : 0;
        if (vote && session.maxPlayers != null) {
          final seats = seatsNow();
          // Suất người này ĐANG giữ: đã vote đi, hoặc đã nằm trong danh sách
          // chơi. Thiếu vế sau thì người được quản lý thêm tay bị đếm hai lần
          // khi chính họ vote, và bị báo hết chỗ oan.
          final mine = (player != null &&
                  (votes[player.id] == true ||
                      session.playerIds.contains(player.id)))
              ? 1 + (companions[player.id] ?? 0)
              : 0;
          if (seats - mine + count > session.maxPlayers!) {
            fullNames.add('$who${count > 1 ? ' ($count suất)' : ''}');
            ignored++;
            final left = session.maxPlayers! - (seats - mine);
            lines.add('😢 $who: HẾT CHỖ · $label\n👥 Còn $left/${session.maxPlayers} chỗ, chưa ghi được $count suất.'
                '${left > 0 ? ' Reply "$left" để giữ $left chỗ nhé.' : ' Cần thêm chỗ thì báo quản lý nhé.'}');
            continue;
          }
        }

        // Người reply vote rõ nghĩa nhưng chưa có trong danh sách → tự thêm người chơi.
        if (player == null && u.fromId.isNotEmpty) {
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
          sender = player;
        }
        if (player == null) {
          // Chỉ xếp vào "chờ gán" khi tin thật sự là vote mà chưa khớp được người.
          pending[u.fromId.isEmpty ? u.messageId : u.fromId] = ZaloPendingVote(
            zaloId: u.fromId,
            name: u.fromName,
            text: u.text,
            vote: vote,
            date: u.date,
          );
          continue;
        }

        votes[player.id] = vote;
        voteTimes[player.id] = u.date;
        // Người đính kèm: "2" → 1 đính kèm; vote không đi hoặc "1" → bỏ đính kèm.
        if (vote && count > 1) {
          companions[player.id] = count - 1;
        } else {
          companions.remove(player.id);
        }
        if (a.isSelf) pending.remove(u.fromId);
        if (!applied.contains(player.name)) applied.add(player.name);
        // Xác nhận cho người vote (ở chế độ webhook, chỉ người mới được tự thêm
        // hoặc tin webhook ghi lỗi mới tới đây; còn lại webhook đã xác nhận ngay).
        // Cùng bố cục với webhook: dòng 1 = ai, đi/không, buổi nào; dòng 2 = số suất.
        final by = a.isSelf ? '' : ' · ${sender?.name ?? u.fromName} vote hộ';
        final left = session.maxPlayers != null ? ' · còn ${(session.maxPlayers! - seatsNow()).clamp(0, 999)} chỗ' : '';
        lines.add(vote
            ? '✅ ${player.name}${count > 1 ? ' +${count - 1} đính kèm' : ''} ĐI $label$by\n👥 ${seatsNow()}$cap suất$left'
                '${createdNames.contains(player.name) ? '\n🆕 Đã thêm vào danh sách người chơi.' : ''}'
            : '👌 ${player.name} KHÔNG ĐI $label$by\n👥 ${seatsNow()}$cap suất$left');
        // Ghi nhớ Zalo id để lần sau khớp chính xác.
        if (a.isSelf && player.zaloId != u.fromId && u.fromId.isNotEmpty) {
          await store.repo.updatePlayer(player.id, {
            'zaloId': u.fromId,
            'zaloName': u.fromName,
          });
        }
      }
      if (lines.isNotEmpty) {
        // Trích lại tin đang trả lời (API không reply vào tin cụ thể được).
        final quoted = u.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        final quote = '↩️ ${u.fromName.isEmpty ? 'Bạn' : u.fromName}: "${quoted.length > 40 ? '${quoted.substring(0, 38)}…' : quoted}"';
        confirmations.putIfAbsent(u.chatId, () => []).add('$quote\n\n${lines.join('\n\n')}');
      }
    }

    if (session != null &&
        (applied.isNotEmpty || pending.length != session.zaloPending.length)) {
      // companions ghi theo từng khoá (xoá khoá đã bỏ) để chắc chắn khoá cũ biến mất.
      final companionUpdates = <String, dynamic>{
        for (final k in {...session.companions.keys, ...companions.keys})
          'companions.$k': companions.containsKey(k) ? companions[k] : FieldValue.delete(),
      };
      await store.repo.updateSessionFields(session.id, {
        'votes': votes,
        'voteTimes': voteTimes.map((k, v) => MapEntry(k, Timestamp.fromDate(v))),
        ...companionUpdates,
        'zaloPending': pending.values.map((e) => e.toMap()).toList(),
      });
    }
    // Báo lại cho người vote: điểm danh thành công thì không được im lặng.
    // Gửi cả ở chế độ webhook, vì webhook mới chỉ báo "đã nhận" (người chưa có
    // tên / ghi lỗi) chứ chưa xác nhận đã ghi vote.
    for (final e in confirmations.entries) {
      await _send(store, e.key, e.value.join('\n\n'));
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
    // Người đính kèm của các buổi gần đây cũng @ được: "@An đính kèm 1 N1 2"
    // (id ảo "<host>#1", tiền trừ vào người vote).
    final virtual = <Player>[];
    for (final s in store.sessions) {
      if (u.date.difference(s.date).abs() > const Duration(hours: 36)) continue;
      for (final cid in s.companionIds) {
        if (virtual.any((p) => p.id == cid)) continue;
        virtual.add(Player(id: cid, name: store.playerName(cid), createdAt: s.createdAt));
      }
    }
    final assignments = ZaloDrinks.parseMulti(
        u.text, store.drinkTypes, [...store.activePlayers, ...virtual], botName: settings.zaloBotName);

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
      final notInSession = Session.isCompanionId(target.id)
          ? !(s.playerIds.contains(Session.hostOf(target.id)) &&
              Session.companionIndex(target.id) <= s.companionsOf(Session.hostOf(target.id)))
          : !s.playerIds.contains(target.id);
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

  /// Câu báo khi có người vote lúc chưa có buổi nào đang mở vote.
  static const noOpenVoteText =
      '📭 Dạ hiện chưa có buổi nào đang mở vote ạ.\nAnh/chị chờ quản lý tạo buổi rồi vote giúp em nhé ạ.';

  /// Trả lời người gửi trong chat Zalo. Ở chế độ webhook thì webhook đã trả
  /// lời ngay rồi, app không nhắn lại nữa cho khỏi trùng.
  static Future<void> _reply(TeamStore store, String chatId, String text) async {
    if (store.settings.zaloWebhookMode) return;
    await _send(store, chatId, text);
  }

  /// Gửi tin vào chat bất kể chế độ (dùng khi webhook chưa trả lời dứt điểm).
  static Future<void> _send(TeamStore store, String chatId, String text) async {
    final s = store.settings;
    if (!s.hasZaloBot || chatId.isEmpty) return;
    try {
      await ZaloBotService.forTeam(s, store.repo.teamId).sendMessage(chatId, text);
    } catch (_) {
      // Không gửi được thì thôi, không chặn việc xử lý các tin còn lại.
    }
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

/// Kết quả đọc một tin nhắn vote từ Zalo.
class VoteReading {
  /// true = đi, false = không đi, null = không hiểu.
  final bool? vote;

  /// Số suất khi "đi" (1 = đi một mình, 2 = kèm 1 người đính kèm...).
  final int seats;

  /// Tin có dạng con số nhưng sai cú pháp ("10", "01", "1,2,3"...).
  /// Có giá trị thì bot báo lại cho người gửi thay vì im lặng bỏ qua.
  final String? error;

  const VoteReading(this.vote, {this.seats = 0, this.error});

  bool get isError => error != null;
}

/// Một phần của tin vote (hộ): "@An 1" → người An, đi 1 suất.
class ProxyVote {
  /// Người được vote; null = không tìm thấy (xem [nameText]) hoặc chính người gửi.
  final Player? player;

  /// Tên gõ trong tin; rỗng = vote của chính người gửi.
  final String nameText;
  final VoteReading reading;
  const ProxyVote(this.player, this.nameText, this.reading);
  bool get isSelf => nameText.isEmpty;
}
