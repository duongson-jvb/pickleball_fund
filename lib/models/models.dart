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
  final String zaloWebhookUrl; // URL Cloudflare Worker (rỗng = dùng getUpdates)
  final String zaloWebhookSecret;
  final Map<String, ZaloChat> zaloChats; // các chat bot từng nhận tin

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
    this.zaloChats = const {},
  });

  bool get hasZaloBot => zaloBotToken.isNotEmpty;
  bool get zaloWebhookMode => zaloWebhookUrl.isNotEmpty;

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
      zaloChats: chats,
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

  const DrinkType({
    required this.id,
    required this.name,
    this.prices = const [],
    this.active = true,
  });

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
  final DateTime createdAt;

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
