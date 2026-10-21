# Quỹ Pickleball

Ứng dụng quản lý quỹ cho team pickleball, viết bằng Flutter, dữ liệu realtime trên Firebase Firestore.
Chạy được trên iOS, Android và Web (bản web được deploy tự động lên GitHub Pages).

## Tính năng

- **Người chơi**: thêm / sửa / xoá, tạm ngưng hoạt động.
- **Nộp quỹ**: nộp cho một người, hoặc nộp một khoản cho tất cả (tự chia đều theo đầu người).
- **Quỹ chung**: nộp tiền vào quỹ chung; quỹ chung được ưu tiên trả tiền sân và các chi phí tính cho tất cả mọi người.
- **Buổi chơi**
  - Vote người chơi trong app, tạo nội dung vote gửi lên Zalo, dán kết quả vote từ Zalo để app tự khớp tên.
  - Chốt danh sách từ vote, vẫn sửa được người chơi thực tế (thêm người không vote, thêm khách) – tiền tự tính lại.
  - Nhập tiền sân: trừ quỹ chung trước, hết quỹ chung thì chia đều phần thiếu cho người chơi trong buổi.
  - Tiền nước: nhiều loại nước, giá khác nhau, mỗi người tự trả theo số lượng. Giá nước theo ngày: buổi chơi lấy giá của lần sửa gần nhất, có thể sửa riêng cho từng buổi.
  - Gắn ảnh xác nhận đặt sân vào từng buổi.
- **Chi phí khác** (mua bóng, quần áo...): không chọn ai = chia cho tất cả (ưu tiên quỹ chung); chọn người = chia cho những người đó.
- **Cảnh báo sắp hết quỹ**: mặc định dưới 50.000đ (sửa được trong Cài đặt), hiện ở Tổng quan và có nút nhắc lên Zalo.
- **QR chuyển khoản**: gắn ảnh QR + thông tin tài khoản, chia sẻ ảnh QR.
- **Chia sẻ lên Zalo**: chọn nội dung (số dư, danh sách sắp hết quỹ, quỹ chung, tổng kết buổi, thông tin chuyển khoản, ảnh QR), xem trước, chia sẻ qua share sheet hoặc sao chép.

## Cách dùng

1. Mở app, nhập **mã nhóm** (tự đặt, ≥ 6 ký tự). Cả team dùng chung một mã → thấy cùng dữ liệu.
2. Vào **Cài đặt → Loại nước & giá** để tạo các loại nước.
3. Thêm người chơi, nộp quỹ, tạo buổi chơi.

Mã nhóm hoạt động như mật khẩu của nhóm: chỉ ai biết mã mới xem / sửa được dữ liệu (xem `firestore.rules`).

## Chạy dự án

```bash
flutter pub get
flutter run            # iOS / Android / Chrome
flutter test           # unit test logic chia tiền
flutter build web --release --base-href /pickleball_fund/
```

Firebase project: `pickleball-fund-phm` (cấu hình đã có sẵn trong `lib/firebase_options.dart`).
Để đổi sang Firebase project khác:

```bash
dart pub global activate flutterfire_cli
flutterfire configure --project=<project-id> --platforms=ios,android,web
firebase deploy --only firestore:rules
```

## Cấu trúc dữ liệu Firestore

```
teams/{teamId}                 # tên nhóm, ngưỡng cảnh báo, ảnh QR (base64), thông tin CK
  players/{id}                 # người chơi
  ledger/{id}                  # sổ quỹ: mọi khoản cộng/trừ (playerId = null → quỹ chung)
  drinkTypes/{id}              # loại nước + lịch sử giá theo ngày
  sessions/{id}                # buổi chơi: vote, người chơi, tiền sân, nước, ảnh sân, kết quả tính
  expenses/{id}                # chi phí khác
```

Số dư = tổng các dòng trong `ledger`. Khi sửa buổi chơi / chi phí, app xoá các dòng cũ của buổi đó và ghi lại, nên có thể sửa bao nhiêu lần cũng được.

## Zalo

Zalo không có API công khai để tạo / đọc bình chọn trong nhóm chat. App hỗ trợ hai cách:

### Cách 1: Zalo Bot (tự động, miễn phí, không cần server)

1. Trong Zalo, nhắn cho OA **Zalo Bot Manager** → *Tạo bot* → nhận Bot Token.
2. App → Cài đặt → **Zalo Bot** → dán token → *Kiểm tra & lưu*.
3. Bot Creator → *Mời Bot vào nhóm* → gửi link vào nhóm, trưởng nhóm bấm link.
4. App → *Tìm nhóm*, rồi vào nhóm gõ `@tên bot` để app nhận ra `chat_id` nhóm.
5. Ở buổi chơi → tab Vote → **Gửi vote qua bot**. Thành viên **Reply** tin của bot: `1` = đi, `0` = không đi.
   App gọi `getUpdates` (long polling) khi đang mở tab Vote hoặc bấm *Đồng bộ ngay*, khớp người gửi với người chơi
   (lần đầu theo tên hiển thị, sau đó nhớ Zalo id). Tin không khớp được tên hiện ở mục "chưa khớp" để gán tay.

Giới hạn của Zalo Bot API: bot chỉ thấy tin **reply** hoặc **@mention** bot, không sửa/xoá tin, không có nút bấm,
tính năng bot trong nhóm đang ở giai đoạn thử nghiệm. Token lưu trong tài liệu nhóm trên Firestore (ai có mã nhóm đều đọc được).

**Nhận vote mọi lúc (webhook, miễn phí)**: deploy Cloudflare Worker trong thư mục [`worker/`](worker/README.md),
rồi App → Cài đặt → Zalo Bot → mục *Webhook* → dán URL Worker + secret → *Bật webhook*.
Zalo đẩy tin về Worker → Firestore `teams/{teamId}/zaloInbox` → app tự biến thành vote ngay khi mở.

### Cách 2: thủ công
- **Tạo vote**: sinh sẵn nội dung vote → chia sẻ sang Zalo.
- **Dán kết quả**: copy danh sách người đã vote trên Zalo → dán vào app → app khớp tên (không dấu, không phân biệt hoa thường).
