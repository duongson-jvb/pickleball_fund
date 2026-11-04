import 'package:cloud_firestore/cloud_firestore.dart';

/// Chuyển giá trị Firestore (Timestamp / DateTime / null) về DateTime.
DateTime _toDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return DateTime.now();
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// Thông tin chung của nhóm.
class TeamSettings {
  final String id;
  final String name;
  final int lowBalanceThreshold;
  final String? qrImageBase64;
  final String bankInfo;
  final String zaloBotToken;
  final String zaloBotName;
  final String zaloGroupId; // chat_id của nhóm Zalo đã chọn
  final String zaloGroupName;
  final String zaloWebhookUrl; // URL Worker/host webhook, cũng là proxy cho bản web
  final String zaloWebhookSecret;
  final bool zaloWebhookEnabled; // true = Zalo đẩy tin về webhook; false = app tự hỏi (getUpdates)
  final Map<String, ZaloChat> zaloChats; // các chat bot từng nhận tin
  final String adminUid; // uid tài khoản quản trị (rỗng = chưa đặt mã bảo mật)

  const TeamSettings({
    required this.id,
    required this.name,
    this.lowBalanceThreshold = 50000,
    this.qrImageBase64,
    this.bankInfo = '',
    this.zaloBotToken = '',
    this.zaloBotName = '',
    this.zaloGroupId = '',
    this.zaloGroupName = '',
    this.zaloWebhookUrl = '',
    this.zaloWebhookSecret = '',
    this.zaloWebhookEnabled = false,
    this.zaloChats = const {},
    this.adminUid = '',
  });

  bool get hasZaloBot => zaloBotToken.isNotEmpty;
  bool get zaloWebhookMode => zaloWebhookEnabled && zaloWebhookUrl.isNotEmpty;
  bool get hasAdmin => adminUid.isNotEmpty;

  factory TeamSettings.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final chats = <String, ZaloChat>{};
    ((d['zaloChats'] as Map?) ?? {}).forEach((k, v) {
      if (v is Map) chats[k.toString()] = ZaloChat.fromMap(Map<String, dynamic>.from(v));
    });
    return TeamSettings(
      id: doc.id,
      name: (d['name'] as String?) ?? 'Team Pickleball',
      lowBalanceThreshold: _toInt(d['lowBalanceThreshold'] ?? 50000),
      qrImageBase64: d['qrImage'] as String?,
      bankInfo: (d['bankInfo'] as String?) ?? '',
      zaloBotToken: (d['zaloBotToken'] as String?) ?? '',
      zaloBotName: (d['zaloBotName'] as String?) ?? '',
      zaloGroupId: (d['zaloGroupId'] as String?) ?? '',
      zaloGroupName: (d['zaloGroupName'] as String?) ?? '',
      zaloWebhookUrl: (d['zaloWebhookUrl'] as String?) ?? '',
      zaloWebhookSecret: (d['zaloWebhookSecret'] as String?) ?? '',
      zaloWebhookEnabled: d['zaloWebhookEnabled'] == true,
      zaloChats: chats,
      adminUid: (d['adminUid'] as String?) ?? '',
    );
  }
}

/// Một cuộc trò chuyện (nhóm / riêng) mà bot đã nhận tin, để chọn nhóm nhận vote.
class ZaloChat {
  final String chatId;
  final bool isGroup;
  final String lastFromName;
  final String lastText;
  final DateTime lastDate;

  const ZaloChat({
    required this.chatId,
    required this.isGroup,
    required this.lastFromName,
    required this.lastText,
    required this.lastDate,
  });

  Map<String, dynamic> toMap() => {
        'chatId': chatId,
        'isGroup': isGroup,
        'lastFromName': lastFromName,
        'lastText': lastText,
        'lastDate': Timestamp.fromDate(lastDate),
      };

  factory ZaloChat.fromMap(Map<String, dynamic> m) => ZaloChat(
        chatId: (m['chatId'] as String?) ?? '',
        isGroup: m['isGroup'] == true,
        lastFromName: (m['lastFromName'] as String?) ?? '',
        lastText: (m['lastText'] as String?) ?? '',
        lastDate: _toDate(m['lastDate']),
      );
}

/// Người chơi trong nhóm.
class Player {
  final String id;
  final String name;
  final String phone;
  final String note;
  final bool active;
  final String zaloId; // id người dùng Zalo (từ bot), dùng để tự khớp vote
  final String zaloName; // tên hiển thị trên Zalo lúc khớp
  final DateTime createdAt;

  const Player({
    required this.id,
    required this.name,
    this.phone = '',
    this.note = '',
    this.active = true,
    this.zaloId = '',
    this.zaloName = '',
    required this.createdAt,
  });

  factory Player.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Player(
      id: doc.id,
      name: (d['name'] as String?) ?? '',
      phone: (d['phone'] as String?) ?? '',
      note: (d['note'] as String?) ?? '',
      active: (d['active'] as bool?) ?? true,
      zaloId: (d['zaloId'] as String?) ?? '',
      zaloName: (d['zaloName'] as String?) ?? '',
      createdAt: _toDate(d['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'phone': phone,
        'note': note,
        'active': active,
        'zaloId': zaloId,
        'zaloName': zaloName,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}

/// Một tin vote từ Zalo chưa khớp được với người chơi nào.
class ZaloPendingVote {
  final String zaloId;
  final String name;
  final String text;
  final bool? vote; // true đi, false không, null không hiểu
  final DateTime date;

  const ZaloPendingVote({
    required this.zaloId,
    required this.name,
    required this.text,
    required this.vote,
    required this.date,
  });

  Map<String, dynamic> toMap() => {
        'zaloId': zaloId,
        'name': name,
        'text': text,
        'vote': vote,
        'date': Timestamp.fromDate(date),
      };

  factory ZaloPendingVote.fromMap(Map<String, dynamic> m) => ZaloPendingVote(
        zaloId: (m['zaloId'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        text: (m['text'] as String?) ?? '',
        vote: m['vote'] as bool?,
        date: _toDate(m['date']),
      );
}

/// Loại giao dịch trong sổ quỹ.
enum LedgerType {
  deposit, // nộp quỹ cá nhân (+)
  commonIn, // nộp quỹ chung (+, playerId = null)
  commonOut, // quỹ chung chi cho sân / chi phí (-, playerId = null)
  court, // tiền sân trừ vào người chơi (-)
  drink, // tiền nước trừ vào người chơi (-)
  expense, // chi phí khác trừ vào người chơi (-)
  adjust, // điều chỉnh thủ công (+/-)
}

extension LedgerTypeX on LedgerType {
  String get key => name;
  String get label => switch (this) {
        LedgerType.deposit => 'Nộp quỹ',
        LedgerType.commonIn => 'Nộp quỹ chung',
        LedgerType.commonOut => 'Quỹ chung chi',
        LedgerType.court => 'Tiền sân',
        LedgerType.drink => 'Tiền nước',
        LedgerType.expense => 'Chi phí khác',
        LedgerType.adjust => 'Điều chỉnh',
      };

  static LedgerType parse(String? s) =>
      LedgerType.values.firstWhere((e) => e.name == s,
          orElse: () => LedgerType.adjust);
}

/// Một dòng trong sổ quỹ. `playerId == null` nghĩa là quỹ chung.
class LedgerEntry {
  final String id;
  final String? playerId;
  final int amount; // VND, dương = cộng, âm = trừ
  final LedgerType type;
  final String? refType; // 'session' | 'expense'
  final String? refId;
  final String note;
  final DateTime date;
  final DateTime createdAt;

  const LedgerEntry({
    required this.id,
    required this.playerId,
    required this.amount,
    required this.type,
    this.refType,
    this.refId,
    this.note = '',
    required this.date,
    required this.createdAt,
  });

  bool get isCommonFund => playerId == null;

  factory LedgerEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return LedgerEntry(
      id: doc.id,
      playerId: d['playerId'] as String?,
      amount: _toInt(d['amount']),
      type: LedgerTypeX.parse(d['type'] as String?),
      refType: d['refType'] as String?,
      refId: d['refId'] as String?,
      note: (d['note'] as String?) ?? '',
      date: _toDate(d['date']),
      createdAt: _toDate(d['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'playerId': playerId,
        'amount': amount,
        'type': type.key,
        'refType': refType,
        'refId': refId,
        'note': note,
        'date': Timestamp.fromDate(date),
        'createdAt': Timestamp.fromDate(createdAt),
      };
}

/// Giá nước tại một ngày.
class DrinkPrice {
  final DateTime date;
  final int price;
  const DrinkPrice({required this.date, required this.price});

  Map<String, dynamic> toMap() =>
      {'date': Timestamp.fromDate(date), 'price': price};

  factory DrinkPrice.fromMap(Map<String, dynamic> m) =>
      DrinkPrice(date: _toDate(m['date']), price: _toInt(m['price']));
}

/// Loại nước uống, kèm lịch sử giá theo ngày.
class DrinkType {
  final String id;
  final String name;
  final List<DrinkPrice> prices;
  final bool active;
  final int code; // mã ngắn để gõ trên Zalo: N1, N2... (0 = chưa gán)

  const DrinkType({
    required this.id,
    required this.name,
    this.prices = const [],
    this.active = true,
    this.code = 0,
  });

  /// Nhãn mã ngắn, ví dụ "N1".
  String get codeLabel => code > 0 ? 'N$code' : '';

  factory DrinkType.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final rawPrices = (d['prices'] as List?) ?? [];
    final prices = rawPrices
        .map((e) => DrinkPrice.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return DrinkType(
      id: doc.id,
      name: (d['name'] as String?) ?? '',
      prices: prices,
      active: (d['active'] as bool?) ?? true,
      code: _toInt(d['code']),
    );
  }

  /// Giá áp dụng cho một ngày: lấy giá có ngày hiệu lực gần nhất <= ngày đó.
  /// Nếu không có thì lấy giá được nhập sớm nhất (hoặc 0).
  int priceOn(DateTime day) {
    if (prices.isEmpty) return 0;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59);
    DrinkPrice? best;
    for (final p in prices) {
      if (!p.date.isAfter(endOfDay)) best = p;
    }
    return (best ?? prices.first).price;
  }

  /// Giá mới nhất đã nhập (theo ngày hiệu lực).
  int get latestPrice => prices.isEmpty ? 0 : prices.last.price;
}

enum SessionStatus { voting, closed }

/// Kết quả tính tiền của một buổi chơi (lưu lại để hiển thị).
class SessionSettlement {
  final int participants; // số người tính tiền sân (người chơi + khách)
  final int perHead; // tiền sân / đầu người
  final int guestCash; // phần tiền khách phải trả bằng tiền mặt
  final int commonUsed; // quỹ chung đã dùng
  final Map<String, int> courtPerPlayer; // phần thiếu chia cho từng người
  final Map<String, int> drinkPerPlayer; // tiền nước từng người

  const SessionSettlement({
    this.participants = 0,
    this.perHead = 0,
    this.guestCash = 0,
    this.commonUsed = 0,
    this.courtPerPlayer = const {},
    this.drinkPerPlayer = const {},
  });

  int get totalDrinks => drinkPerPlayer.values.fold(0, (a, b) => a + b);

  Map<String, dynamic> toMap() => {
        'participants': participants,
        'perHead': perHead,
        'guestCash': guestCash,
        'commonUsed': commonUsed,
        'courtPerPlayer': courtPerPlayer,
        'drinkPerPlayer': drinkPerPlayer,
      };

  factory SessionSettlement.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const SessionSettlement();
    Map<String, int> intMap(dynamic v) => (v is Map)
        ? v.map((k, val) => MapEntry(k.toString(), _toInt(val)))
        : {};
    return SessionSettlement(
      participants: _toInt(m['participants']),
      perHead: _toInt(m['perHead']),
      guestCash: _toInt(m['guestCash']),
      commonUsed: _toInt(m['commonUsed']),
      courtPerPlayer: intMap(m['courtPerPlayer']),
      drinkPerPlayer: intMap(m['drinkPerPlayer']),
    );
  }
}

/// Một buổi chơi.
class Session {
  final String id;
  final String title;
  final DateTime date;
  final String location;
  final int courtFee;
  final String? courtImageBase64;
  final SessionStatus status;
  final Map<String, bool> votes; // playerId -> đi / không
  final List<String> playerIds; // người thực tế chơi
  final int guestCount; // khách không có trong danh sách
  final Map<String, int> drinkPrices; // drinkTypeId -> giá áp dụng buổi này
  final Map<String, Map<String, int>> drinks; // playerId -> {drinkTypeId: sl}
  final String note;
  final SessionSettlement settlement;
  final String zaloVoteMessageId; // id tin vote bot đã gửi lên nhóm
  final List<ZaloPendingVote> zaloPending; // vote Zalo chưa khớp tên
  final String createdByName; // người tạo buổi (bắt buộc)
  final String createdById; // id người chơi nếu khớp
  final DateTime? voteDeadline; // hạn vote (mặc định = giờ bắt đầu chơi)
  final int? maxPlayers; // giới hạn số người chơi (null = không giới hạn)
  final Map<String, DateTime> voteTimes; // playerId -> lúc vote gần nhất (để ưu tiên ai vote trước)
  /// playerId -> số người đính kèm đi cùng (vote "2" = 1 đính kèm, "3" = 2...).
  /// Tiền sân / tiền nước của người đính kèm trừ vào người vote.
  final Map<String, int> companions;

  /// Mã ngắn của buổi, hiện trong tin vote để người trong nhóm nhắn đúng buổi
  /// khi có nhiều buổi cùng mở vote: "B1 1", "B2 0"... 0 = chưa gán mã.
  final int code;
  final DateTime createdAt;

  /// Nhãn mã ngắn, ví dụ "B1". Rỗng khi buổi chưa được gán mã.
  String get codeLabel => code > 0 ? 'B$code' : '';

  /// Hạn vote hiệu lực: nếu không đặt thì bằng giờ bắt đầu chơi.
  DateTime get effectiveVoteDeadline => voteDeadline ?? date;
  bool get voteExpired => DateTime.now().isAfter(effectiveVoteDeadline);
  bool get isVoteOpen => status == SessionStatus.voting && !voteExpired;

  /// Người này có đang giữ chỗ không.
  ///
  /// Buổi đã chốt: chỉ người trong danh sách chơi (`votes` lúc đó vẫn giữ cả
  /// người bị cắt vì hết chỗ). Đang vote: câu trả lời MỚI NHẤT của người đó
  /// quyết định - "đi" là có, "không" là không, kể cả khi trước đó quản lý đã
  /// thêm họ vào danh sách; chưa trả lời thì theo danh sách quản lý thêm.
  ///
  /// Không được để danh sách thắng vote "không": webhook chỉ ghi được `votes`
  /// (rules không cho đụng `playerIds`), nên người đã được thêm mà nhắn "0"
  /// sẽ vẫn bị giữ chỗ, bot vẫn đếm và lúc chốt vẫn bị trừ tiền.
  bool holdsSeat(String id) {
    if (status == SessionStatus.closed) return playerIds.contains(id);
    return votes[id] ?? playerIds.contains(id);
  }

  /// Những người đang giữ chỗ (xem [holdsSeat]): người quản lý thêm vào danh
  /// sách mà chưa báo không đi, rồi người vote "đi" theo giờ vote.
  ///
  /// Thứ tự giống [playersForClosing] để danh sách bot báo lên nhóm trùng với
  /// thứ tự ưu tiên khi phải cắt bớt vì hết chỗ.
  List<String> get seatHolders {
    if (status == SessionStatus.closed) return playerIds;
    final out = [
      for (final id in playerIds)
        if (votes[id] != false) id,
    ];
    for (final id in votedYesByTime) {
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }

  /// Người quản lý thêm thẳng vào danh sách, chưa tự trả lời vote.
  List<String> get addedWithoutVote =>
      [for (final id in playerIds) if (!votes.containsKey(id)) id];

  int get seatsTaken =>
      seatHolders.fold(0, (acc, id) => acc + 1 + (companions[id] ?? 0));

  /// Đã đủ số người (theo vote "đi" + đính kèm) chưa.
  bool get isFull => maxPlayers != null && seatsTaken >= maxPlayers!;

  /// Số đính kèm của một người trong danh sách chơi.
  int companionsOf(String playerId) => companions[playerId] ?? 0;

  /// Tổng người đính kèm của những người đang giữ chỗ.
  int get totalCompanions =>
      seatHolders.fold(0, (s, id) => s + companionsOf(id));

  /// Id ảo của người đính kèm: `playerId#1`, `playerId#2`... (dùng cho tiền nước).
  static String companionId(String hostId, int n) => '$hostId#$n';
  static bool isCompanionId(String id) => id.contains('#');
  static String hostOf(String id) => id.split('#').first;
  static int companionIndex(String id) => int.tryParse(id.split('#').last) ?? 0;

  /// Bỏ các mục nước của người đính kèm KHÔNG CÒN tồn tại (số đính kèm đã
  /// giảm hoặc người vote đã rời danh sách chơi).
  ///
  /// Tiền nước của người đính kèm tính vào người vote, nên nếu không dọn thì
  /// người vote vẫn bị trừ tiền của một người không còn đi buổi đó.
  Session pruneCompanionDrinks() {
    final kept = <String, Map<String, int>>{};
    var removed = false;
    drinks.forEach((pid, items) {
      if (!isCompanionId(pid)) {
        kept[pid] = items;
        return;
      }
      final idx = companionIndex(pid);
      if (idx >= 1 && idx <= companionsOf(hostOf(pid))) {
        kept[pid] = items;
      } else {
        removed = true;
      }
    });
    return removed ? copyWith(drinks: kept) : this;
  }

  /// Gỡ sạch dấu vết của một người khỏi buổi chơi: danh sách chơi, vote, mốc
  /// vote, số người đính kèm, nước của họ VÀ nước của người đính kèm của họ.
  Session withoutPlayer(String playerId) => copyWith(
        playerIds: playerIds.where((p) => p != playerId).toList(),
        votes: {...votes}..remove(playerId),
        voteTimes: {...voteTimes}..remove(playerId),
        companions: {...companions}..remove(playerId),
        drinks: {
          for (final e in drinks.entries)
            if (hostOf(e.key) != playerId) e.key: e.value,
        },
      );

  /// Gộp các vote mới hơn từ bản trên máy chủ vào bản đang cầm.
  ///
  /// Webhook ghi vote thẳng vào Firestore 24/7, không cần ai mở app. Nếu quản
  /// lý cầm một bản chụp cũ rồi lưu đè cả tài liệu thì những vote tới sau lúc
  /// chụp sẽ biến mất, dù người vote đã được bot xác nhận.
  ///
  /// Phân biệt bằng `voteTimes`: chỉ lấy lại mục nào máy chủ có mốc thời gian
  /// MỚI HƠN bản đang cầm (hoặc bản đang cầm chưa từng thấy người đó). Quản lý
  /// bật/tắt tên trên giao diện cũng ghi mốc giờ lúc bấm, nên thao tác mới
  /// nhất thắng - của quản lý hay của chính người vote.
  Session mergeNewerVotes(Session remote) {
    final votes = {...this.votes};
    final times = {...voteTimes};
    final comp = {...companions};
    var changed = false;
    remote.votes.forEach((pid, remoteVote) {
      final rt = remote.voteTimes[pid];
      final lt = times[pid];
      final newer =
          !votes.containsKey(pid) || (rt != null && (lt == null || rt.isAfter(lt)));
      if (!newer) return;
      votes[pid] = remoteVote;
      if (rt != null) times[pid] = rt;
      final rc = remote.companions[pid] ?? 0;
      if (rc > 0) {
        comp[pid] = rc;
      } else {
        comp.remove(pid);
      }
      changed = true;
    });
    return changed
        ? copyWith(votes: votes, voteTimes: times, companions: comp)
        : this;
  }

  /// Mã ngắn kế tiếp cho buổi mới (B1, B2...): số nhỏ nhất chưa dùng trong
  /// các buổi còn mở vote. Buổi đã chốt không nhận vote nữa nên mã của nó
  /// được dùng lại, mã luôn ngắn dù nhóm chơi cả năm.
  static int nextCode(Iterable<Session> sessions) {
    final used = {
      for (final s in sessions)
        if (s.status != SessionStatus.closed) s.code,
    };
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  /// Mã cho buổi [s] khi mở lại vote: giữ mã cũ nếu chưa buổi nào đang mở
  /// dùng, không thì lấy mã mới. Buổi đã chốt nhường mã cho buổi khác, nên mở
  /// lại mà giữ mã cũ có thể ra hai buổi cùng mã và "B1 1" không biết vào đâu.
  static int codeForReopen(Iterable<Session> sessions, Session s) {
    final others = [
      for (final x in sessions)
        if (x.id != s.id) x,
    ];
    final taken = {
      for (final x in others)
        if (x.status != SessionStatus.closed) x.code,
    };
    return s.code > 0 && !taken.contains(s.code) ? s.code : nextCode(others);
  }

  /// Buổi còn mở vote cần gán (lại) mã: id → mã mới. Gồm buổi chưa có mã và
  /// buổi trùng mã với buổi khác (máy cũ mở lại vote, hai máy tạo cùng lúc).
  ///
  /// Trùng mã thì buổi tạo SAU giữ mã - tin vote của nó mới gửi, mã đó đang
  /// được nhóm dùng - còn buổi tạo trước đổi sang mã nhỏ nhất còn trống.
  static Map<String, int> codeFixes(Iterable<Session> sessions) {
    final open = [
      for (final s in sessions)
        if (s.status != SessionStatus.closed) s,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final used = <int>{};
    final missing = <Session>[];
    for (final s in open) {
      if (s.code > 0 && used.add(s.code)) continue;
      missing.add(s);
    }
    missing.sort((a, b) => a.date.compareTo(b.date));
    final out = <String, int>{};
    var next = 1;
    for (final s in missing) {
      while (used.contains(next)) {
        next++;
      }
      used.add(next);
      out[s.id] = next;
    }
    return out;
  }

  /// Buổi như thể chốt ngay bây giờ: danh sách chơi lấy theo [playersForClosing]
  /// (cắt theo giới hạn), người đính kèm giảm cho vừa. Đã chốt thì là chính nó.
  ///
  /// Dùng cho cả lúc chốt thật lẫn số dự kiến lúc đang vote, để số dự kiến
  /// đúng bằng số sẽ trừ: người vượt giới hạn bị cắt khi chốt thì không được
  /// tính tiền sân, nước của người đính kèm bị bớt cũng không được tính.
  Session asClosed() {
    if (status == SessionStatus.closed) return this;
    final ids = playersForClosing();
    return copyWith(
      status: SessionStatus.closed,
      playerIds: ids,
      companions: companionsForClosing(ids),
    );
  }

  /// Quản lý bật/tắt một người trong danh sách người đi (một danh sách duy nhất).
  ///
  /// Ghi như câu trả lời của chính người đó (vote + mốc giờ [at]), nên sau đó
  /// họ nhắn "0"/"1" trên Zalo vẫn đổi được. Đang vote KHÔNG thêm vào danh sách
  /// chơi - người được tích muộn sẽ chen lên trước người vote sớm khi phải cắt
  /// vì hết chỗ; bỏ tích thì rời danh sách và bỏ người đính kèm. Đã chốt thì
  /// danh sách chơi chính là danh sách người đi.
  Session withAdminAnswer(String id, bool going, DateTime at) {
    final ids = [...playerIds];
    if (!going) {
      ids.remove(id);
    } else if (status == SessionStatus.closed && !ids.contains(id)) {
      ids.add(id);
    }
    final comp = {...companions};
    if (!going) comp.remove(id);
    return copyWith(
      votes: {...votes, id: going},
      voteTimes: {...voteTimes, id: at},
      playerIds: ids,
      companions: comp,
    );
  }

  /// Mở lại vote cho buổi đã chốt với mã buổi [code]: danh sách lúc mở lại
  /// đúng bằng danh sách đã chốt.
  ///
  /// Người đang trong danh sách chơi được tính là đã vote "đi" - đó là quyết
  /// định mới nhất về họ. Không làm vậy thì vote "không" cũ của họ (hoặc của
  /// người được quản lý thêm sau khi chốt) lại có hiệu lực và họ mất chỗ.
  /// Người vote "đi" mà bị cắt lúc chốt (hết chỗ) thì bỏ câu trả lời cũ: không
  /// bỏ thì họ tự quay lại danh sách, chiếm chỗ, bot báo hết chỗ oan với người
  /// khác. Còn muốn đi thì họ vote lại.
  ///
  /// Lưu bản này KHÔNG được gộp vote từ máy chủ (gộp sẽ đưa vote đã bỏ quay
  /// lại); lúc mở lại buổi đang chốt nên webhook không ghi được vote nào.
  Session reopened({required int code}) {
    final cut = {
      for (final e in votes.entries)
        if (e.value && !playerIds.contains(e.key)) e.key,
    };
    return copyWith(
      status: SessionStatus.voting,
      votes: {
        for (final e in votes.entries)
          if (!cut.contains(e.key)) e.key: e.value,
        for (final id in playerIds) id: true,
      },
      voteTimes: {...voteTimes}..removeWhere((k, _) => cut.contains(k)),
      companions: {...companions}..removeWhere((k, _) => cut.contains(k)),
      code: code,
    );
  }

  /// Người đó có để lại dấu vết gì trong buổi này không.
  bool mentions(String playerId) =>
      playerIds.contains(playerId) ||
      votes.containsKey(playerId) ||
      voteTimes.containsKey(playerId) ||
      companions.containsKey(playerId) ||
      drinks.keys.any((k) => hostOf(k) == playerId);

  /// Các id ảo của người đính kèm của những người đang giữ chỗ.
  List<String> get companionIds => [
        for (final id in seatHolders)
          for (var n = 1; n <= companionsOf(id); n++) companionId(id, n),
      ];

  /// Người vote "đi" xếp theo thời điểm vote (ai vote trước đứng trước;
  /// không có mốc thời gian thì xếp sau cùng, giữ thứ tự hiện có).
  List<String> get votedYesByTime {
    final yes = votedYes;
    final far = DateTime.fromMillisecondsSinceEpoch(8640000000000000);
    final indexed = [for (var i = 0; i < yes.length; i++) (yes[i], voteTimes[yes[i]] ?? far, i)];
    indexed.sort((a, b) {
      final c = a.$2.compareTo(b.$2);
      return c != 0 ? c : a.$3.compareTo(b.$3);
    });
    return [for (final e in indexed) e.$1];
  }

  /// Danh sách chơi khi chốt: người đã có trong danh sách + người vote "đi"
  /// theo thứ tự vote. Có giới hạn thì tính cả người đính kèm: ai vào không đủ
  /// chỗ cho cả nhóm thì giảm số đính kèm cho vừa, hết chỗ thì dừng.
  List<String> playersForClosing() {
    // Cùng một quy tắc với [seatHolders]: ai đã báo "không đi" thì không được
    // đưa vào danh sách chốt dù trước đó có tên trong danh sách.
    final ids = [...seatHolders];
    if (maxPlayers == null) return ids;
    final out = <String>[];
    var seats = 0;
    for (final id in ids) {
      if (seats >= maxPlayers!) break;
      out.add(id);
      seats += 1 + companionsOf(id);
    }
    return out;
  }

  /// Số đính kèm sau khi chốt: nếu nhóm cuối vượt giới hạn thì giảm đính kèm.
  Map<String, int> companionsForClosing(List<String> closingIds) {
    final out = <String, int>{};
    if (maxPlayers == null) {
      for (final id in closingIds) {
        if (companionsOf(id) > 0) out[id] = companionsOf(id);
      }
      return out;
    }
    var seats = 0;
    for (final id in closingIds) {
      seats += 1;
      final allowed = (maxPlayers! - seats).clamp(0, companionsOf(id));
      if (allowed > 0) out[id] = allowed;
      seats += allowed;
    }
    return out;
  }

  const Session({
    required this.id,
    required this.title,
    required this.date,
    this.location = '',
    this.courtFee = 0,
    this.courtImageBase64,
    this.status = SessionStatus.voting,
    this.votes = const {},
    this.playerIds = const [],
    this.guestCount = 0,
    this.drinkPrices = const {},
    this.drinks = const {},
    this.note = '',
    this.settlement = const SessionSettlement(),
    this.zaloVoteMessageId = '',
    this.zaloPending = const [],
    this.createdByName = '',
    this.createdById = '',
    this.voteDeadline,
    this.maxPlayers,
    this.voteTimes = const {},
    this.companions = const {},
    this.code = 0,
    required this.createdAt,
  });

  List<String> get votedYes =>
      votes.entries.where((e) => e.value).map((e) => e.key).toList();

  int drinkQty(String playerId, String drinkTypeId) =>
      drinks[playerId]?[drinkTypeId] ?? 0;

  factory Session.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final rawDrinks = (d['drinks'] as Map?) ?? {};
    final drinks = <String, Map<String, int>>{};
    rawDrinks.forEach((pid, m) {
      drinks[pid.toString()] = (m as Map)
          .map((k, v) => MapEntry(k.toString(), _toInt(v)))
        ..removeWhere((_, v) => v <= 0);
    });
    return Session(
      id: doc.id,
      title: (d['title'] as String?) ?? '',
      date: _toDate(d['date']),
      location: (d['location'] as String?) ?? '',
      courtFee: _toInt(d['courtFee']),
      courtImageBase64: d['courtImage'] as String?,
      status: d['status'] == 'closed' ? SessionStatus.closed : SessionStatus.voting,
      votes: ((d['votes'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), v == true)),
      playerIds: ((d['playerIds'] as List?) ?? []).map((e) => e.toString()).toList(),
      guestCount: _toInt(d['guestCount']),
      drinkPrices: ((d['drinkPrices'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), _toInt(v))),
      drinks: drinks,
      note: (d['note'] as String?) ?? '',
      settlement: SessionSettlement.fromMap(
          (d['settlement'] as Map?)?.cast<String, dynamic>()),
      zaloVoteMessageId: (d['zaloVoteMessageId'] as String?) ?? '',
      zaloPending: ((d['zaloPending'] as List?) ?? [])
          .map((e) => ZaloPendingVote.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      createdByName: (d['createdByName'] as String?) ?? '',
      createdById: (d['createdById'] as String?) ?? '',
      voteDeadline: d['voteDeadline'] == null ? null : _toDate(d['voteDeadline']),
      maxPlayers: d['maxPlayers'] == null ? null : _toInt(d['maxPlayers']),
      voteTimes: ((d['voteTimes'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), _toDate(v))),
      companions: ((d['companions'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), _toInt(v)))
        ..removeWhere((_, v) => v <= 0),
      code: _toInt(d['code']),
      createdAt: _toDate(d['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'title': title,
        'date': Timestamp.fromDate(date),
        'location': location,
        'courtFee': courtFee,
        'courtImage': courtImageBase64,
        'status': status.name,
        'votes': votes,
        'playerIds': playerIds,
        'guestCount': guestCount,
        'drinkPrices': drinkPrices,
        'drinks': drinks,
        'note': note,
        'settlement': settlement.toMap(),
        'zaloVoteMessageId': zaloVoteMessageId,
        'zaloPending': zaloPending.map((e) => e.toMap()).toList(),
        'createdByName': createdByName,
        'createdById': createdById,
        'voteDeadline': voteDeadline == null ? null : Timestamp.fromDate(voteDeadline!),
        'maxPlayers': maxPlayers,
        'voteTimes': voteTimes.map((k, v) => MapEntry(k, Timestamp.fromDate(v))),
        'companions': companions,
        'code': code,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  Session copyWith({
    String? title,
    DateTime? date,
    String? location,
    int? courtFee,
    String? courtImageBase64,
    bool clearCourtImage = false,
    SessionStatus? status,
    Map<String, bool>? votes,
    List<String>? playerIds,
    int? guestCount,
    Map<String, int>? drinkPrices,
    Map<String, Map<String, int>>? drinks,
    String? note,
    SessionSettlement? settlement,
    String? zaloVoteMessageId,
    List<ZaloPendingVote>? zaloPending,
    String? createdByName,
    String? createdById,
    DateTime? voteDeadline,
    bool clearVoteDeadline = false,
    int? maxPlayers,
    bool clearMaxPlayers = false,
    Map<String, DateTime>? voteTimes,
    Map<String, int>? companions,
    int? code,
  }) =>
      Session(
        id: id,
        title: title ?? this.title,
        date: date ?? this.date,
        location: location ?? this.location,
        courtFee: courtFee ?? this.courtFee,
        courtImageBase64:
            clearCourtImage ? null : (courtImageBase64 ?? this.courtImageBase64),
        status: status ?? this.status,
        votes: votes ?? this.votes,
        playerIds: playerIds ?? this.playerIds,
        guestCount: guestCount ?? this.guestCount,
        drinkPrices: drinkPrices ?? this.drinkPrices,
        drinks: drinks ?? this.drinks,
        note: note ?? this.note,
        settlement: settlement ?? this.settlement,
        zaloVoteMessageId: zaloVoteMessageId ?? this.zaloVoteMessageId,
        zaloPending: zaloPending ?? this.zaloPending,
        createdByName: createdByName ?? this.createdByName,
        createdById: createdById ?? this.createdById,
        voteDeadline: clearVoteDeadline ? null : (voteDeadline ?? this.voteDeadline),
        maxPlayers: clearMaxPlayers ? null : (maxPlayers ?? this.maxPlayers),
        voteTimes: voteTimes ?? this.voteTimes,
        companions: companions ?? this.companions,
        code: code ?? this.code,
        createdAt: createdAt,
      );
}

/// Chi phí khác (mua bóng, quần áo...).
class Expense {
  final String id;
  final String title;
  final int amount;
  final DateTime date;
  final List<String> playerIds; // rỗng = chia cho tất cả người chơi đang hoạt động
  final String note;
  final int commonUsed; // quỹ chung đã dùng (chỉ khi chia cho tất cả)
  final Map<String, int> perPlayer; // kết quả chia
  final DateTime createdAt;

  const Expense({
    required this.id,
    required this.title,
    required this.amount,
    required this.date,
    this.playerIds = const [],
    this.note = '',
    this.commonUsed = 0,
    this.perPlayer = const {},
    required this.createdAt,
  });

  bool get isForEveryone => playerIds.isEmpty;

  factory Expense.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Expense(
      id: doc.id,
      title: (d['title'] as String?) ?? '',
      amount: _toInt(d['amount']),
      date: _toDate(d['date']),
      playerIds: ((d['playerIds'] as List?) ?? []).map((e) => e.toString()).toList(),
      note: (d['note'] as String?) ?? '',
      commonUsed: _toInt(d['commonUsed']),
      perPlayer: ((d['perPlayer'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), _toInt(v))),
      createdAt: _toDate(d['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'title': title,
        'amount': amount,
        'date': Timestamp.fromDate(date),
        'playerIds': playerIds,
        'note': note,
        'commonUsed': commonUsed,
        'perPlayer': perPlayer,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  Expense copyWith({
    String? title,
    int? amount,
    DateTime? date,
    List<String>? playerIds,
    String? note,
    int? commonUsed,
    Map<String, int>? perPlayer,
  }) =>
      Expense(
        id: id,
        title: title ?? this.title,
        amount: amount ?? this.amount,
        date: date ?? this.date,
        playerIds: playerIds ?? this.playerIds,
        note: note ?? this.note,
        commonUsed: commonUsed ?? this.commonUsed,
        perPlayer: perPlayer ?? this.perPlayer,
        createdAt: createdAt,
      );
}
