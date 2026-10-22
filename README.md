# Quỹ Pickleball

Ứng dụng quản lý quỹ cho team pickleball, viết bằng Flutter, dữ liệu realtime trên Firebase Firestore.
Chạy được trên iOS, Android và Web (bản web được deploy tự động lên GitHub Pages).

## Tính năng

- **Người chơi**: thêm / sửa / xoá, tạm ngưng hoạt động.
- **Nộp quỹ**: nộp cho một người, hoặc nộp một khoản cho tất cả (tự chia đều theo đầu người).
- **Quỹ chung**: nộp tiền vào quỹ chung; quỹ chung được ưu tiên trả tiền sân và các chi phí tính cho tất cả mọi người.
- **Buổi chơi**
  - Khi tạo: **người tạo** (bắt buộc), **hạn vote** (mặc định = giờ bắt đầu chơi, không muộn hơn giờ chơi,
    cách lúc tạo ít nhất 30 phút), **giới hạn số người** (trống = không giới hạn).
    Hết hạn vote → máy quản trị tự chốt danh sách (cắt theo giới hạn). Đủ người → không nhận thêm vote "đi",
    người đã "đi" vẫn đổi ý được. Vote sau hạn bị bỏ qua (cả trong app lẫn từ Zalo; rules cũng chặn).
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

## Phân quyền

- **Mã nhóm**: ai biết mã thì **xem** toàn bộ và **vote** đi/không đi. App tự đăng nhập ẩn danh (Firebase Auth).
- **Mã bảo mật quản trị**: mọi sửa đổi khác (người chơi, nộp quỹ, quỹ chung, buổi chơi, tiền sân/nước, chi phí, cài đặt, Zalo Bot)
  cần mở khoá bằng mã này (biểu tượng ổ khoá ở Tổng quan hoặc Cài đặt → Mã bảo mật quản trị).
  Lần đầu, người đặt mã trở thành quản trị viên; có thể đổi mã, khoá lại trên máy.
- Kỹ thuật: mã bảo mật là mật khẩu của tài khoản Firebase Auth tổng hợp `admin-<mã nhóm>@team.pickleball.app`;
  `teams/{teamId}.adminUid` lưu uid đó và **Firestore rules** chỉ cho uid này ghi (xem `firestore.rules`).
  Người thường chỉ được đổi trường `votes` của buổi đang mở vote; webhook Vercel chỉ được tạo tin trong `zaloInbox`.
- Việc xử lý hộp thư Zalo (tạo người chơi, ghi vote) chỉ chạy trên máy đang mở khoá quản trị.

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
   App khớp người gửi với người chơi (lần đầu theo tên hiển thị, sau đó nhớ Zalo id).
   Người reply vote mà **chưa có trong danh sách sẽ được tự thêm** làm người chơi mới (tên theo Zalo, ghi chú "Tự thêm từ Zalo").
   Tin không rõ nghĩa (không phải 1/0/đi/không) hiện ở mục "chưa khớp" để gán tay.
   **Chỉ tính tin gửi sau khi buổi chơi được tạo**; tin gửi trước đó hoặc khi chưa có buổi nào đang vote thì bỏ qua.
6. **Ghi nước qua Zalo**: gõ `@bot nước` để bot liệt kê các loại nước kèm **mã ngắn** (N1, N2...) và giá hiện tại
   (webhook trả lời ngay). Rồi reply/@bot `N1 2`, `N1 2, N2 1`, `nước 2` (khi chỉ có một loại), `revive 2, suối 1`,
   `+1 N1` (cộng thêm), `N1 0` (xoá). Mã ngắn tự gán khi tạo loại nước, hiện trong Cài đặt → Loại nước & giá.
   Mã/tên không phân biệt hoa thường, có dấu hay không dấu.
   **Nhập hộ**: `@An N1 2 @Nguyễn Văn Bình N2 1, N1 1` — mỗi người sau dấu @ được ghi riêng, nhiều người trong một tin;
   phần trước dấu @ đầu tiên (nếu có) là của chính người gửi. Tên khớp dài nhất với danh sách, viết tắt duy nhất cũng được.
7. **Hỏi đáp bằng AI**: tin không phải vote hay lệnh (câu hỏi, trò chuyện) được **Gemini** (miễn phí) trả lời ngay tại webhook,
   biết lịch buổi sắp tới, bảng giá nước, các lệnh bot. Hết hạn mức thì bot báo vui vẻ kèm lúc hỏi lại được. Xem `webhook/README.md`.
   App ghi vào buổi gần nhất người đó tham gia (36 giờ trước → 6 giờ sau giờ chơi), tính lại tiền và bot trả lời xác nhận
   kèm tổng tiền nước. Người chưa có trong danh sách hoặc không tìm thấy buổi thì bot báo để quản lý xử lý.

Giới hạn của Zalo Bot API: bot chỉ thấy tin **reply** hoặc **@mention** bot, không sửa/xoá tin, không có nút bấm,
tính năng bot trong nhóm đang ở giai đoạn thử nghiệm. Token lưu trong tài liệu nhóm trên Firestore (ai có mã nhóm đều đọc được).

**Bản web**: trình duyệt không gọi trực tiếp được Zalo Bot API (không có CORS), nên bản web đi qua hàm trên Vercel
làm proxy (điền URL webhook + secret ở mục Webhook trước khi bấm *Kiểm tra & lưu*). Bản iOS/Android gọi thẳng Zalo.

**Nhận vote mọi lúc (webhook, miễn phí)**: hàm trong [`webhook/`](webhook/README.md) deploy lên Vercel
(`https://pickleball-zalo-webhook.vercel.app/<mã nhóm>`). App → Cài đặt → Zalo Bot → mục *Webhook* → dán URL + secret → *Bật webhook*.
Zalo đẩy tin về Vercel → Firestore `teams/{teamId}/zaloInbox` → app tự biến thành vote ngay khi mở.
Lệnh `@bot help` được trả lời ngay tại webhook. Không dùng Cloudflare vì Cloudflare chặn máy chủ Zalo (xem webhook/README.md).

### Cách 2: thủ công
- **Tạo vote**: sinh sẵn nội dung vote → chia sẻ sang Zalo.
- **Dán kết quả**: copy danh sách người đã vote trên Zalo → dán vào app → app khớp tên (không dấu, không phân biệt hoa thường).
