# Quỹ Pickleball – Tổng hợp tính năng

Cập nhật: 22/10/2026. Ứng dụng Flutter (iOS, Android, Web) + Firebase Firestore/Auth + webhook Zalo trên Vercel + Gemini.

| Thành phần | Địa chỉ |
|---|---|
| Web app | https://duongson-jvb.github.io/pickleball_fund/ |
| Mã nguồn | https://github.com/duongson-jvb/pickleball_fund |
| Webhook / proxy Zalo | https://pickleball-zalo-webhook.vercel.app/<mã nhóm> |
| Firebase project | `pickleball-fund-phm` (Firestore asia-southeast1, Auth Email/Password + Ẩn danh) |

Mọi dịch vụ đều ở gói miễn phí, không cần thẻ.

---

## 1. Nhóm và phân quyền

| Tính năng | Mô tả |
|---|---|
| Mã nhóm | Tự đặt khi vào app (≥ 6 ký tự). Cả team dùng chung một mã để thấy cùng dữ liệu. Ai biết mã thì **xem** và **vote**. |
| Mã bảo mật quản trị | Mọi thao tác **sửa** (người chơi, quỹ, buổi chơi, nước, chi phí, cài đặt, Zalo Bot) cần mở khoá bằng mã này. Người đặt mã đầu tiên là quản trị viên. Đổi mã, khoá lại trong Cài đặt; ổ khoá ở Tổng quan. |
| Bảo vệ phía server | Firestore rules chỉ cho uid quản trị ghi. Người thường chỉ đổi được ô vote của buổi đang mở vote và còn hạn. Webhook chỉ được tạo tin trong hộp thư Zalo. Không liệt kê được danh sách nhóm. |
| Kỹ thuật | Tài khoản quản trị = `admin-<mã nhóm>@team.pickleball.app`, mật khẩu = mã bảo mật; `teams/{id}.adminUid`. App đăng nhập ẩn danh cho mọi người. |

## 2. Người chơi

- Thêm, sửa, xoá; tắt "Đang hoạt động" khi tạm nghỉ (không bị chia tiền chung).
- Xoá người thì xoá luôn lịch sử giao dịch của người đó, gỡ họ khỏi mọi buổi chơi và chi phí rồi tính lại
  (phần tiền họ đang gánh chia lại cho người còn lại, không để "tiền ma").
- Chi tiết người chơi: số dư, đã nộp, đã chi, lịch sử, nộp quỹ, điều chỉnh thủ công (+/−), chia sẻ số dư.
- Người reply vote trên Zalo mà chưa có trong danh sách được **tự thêm** (tên theo Zalo, ghi chú "Tự thêm từ Zalo", nhớ Zalo id).

## 3. Quỹ

| Tính năng | Mô tả |
|---|---|
| Nộp quỹ một người | Chọn người, số tiền (hiểu `50k`, `1tr`, `50.000`), ghi chú, ngày. |
| Nộp cho tất cả | Một khoản chia đều theo đầu người đang hoạt động; phần dư dồn cho người đầu danh sách, tổng khớp tuyệt đối. |
| Quỹ chung | Nộp vào quỹ chung; được ưu tiên trả tiền sân và chi phí tính cho tất cả. Lịch sử sử dụng riêng. |
| Sổ quỹ | Mọi khoản cộng/trừ là một dòng `ledger`; số dư = tổng dòng. Sửa buổi/chi phí → xoá dòng cũ ghi lại, không trùng. |
| Cảnh báo sắp hết quỹ | Mặc định dưới 50.000đ (sửa trong Cài đặt): thẻ cảnh báo ở Tổng quan, huy hiệu số người, nút nhắc lên Zalo. |

## 4. Buổi chơi

| Tính năng | Mô tả |
|---|---|
| Tạo buổi | Tiêu đề, ngày giờ, địa điểm, tiền sân (nhập sau được), ảnh đặt sân, ghi chú. **Người tạo** (bắt buộc, gợi ý từ danh sách). **Hạn vote** (mặc định = giờ chơi, không muộn hơn giờ chơi, cách lúc tạo ≥ 30 phút). **Giới hạn số người** (trống = không giới hạn). |
| Vote trong app | Tick đi/không cho từng người. Người thường chỉ vote khi còn hạn và chưa đủ người. |
| Vote qua Zalo | "Gửi vote qua bot" → thành viên reply `1`/`0`. Đổi ý reply lại. Chỉ tính tin gửi **sau khi tạo buổi** và **trước hạn vote**. Đủ người thì không nhận thêm "đi" (người đã đi vẫn đổi ý được). |
| Người đính kèm | Reply `2` = đi 2 người (kèm 1), `3` = kèm 2... Người đính kèm hiện trong buổi với tên "An đính kèm 1, 2..."; **tiền sân và tiền nước của họ trừ vào người vote**. Giới hạn số người tính cả đính kèm; khi phải cắt thì giảm đính kèm của người vào sau. Trong app chỉnh số đính kèm bằng nút +/− cạnh người đã vote đi; ghi nước cho đính kèm qua Zalo: `@An đính kèm 1 N1 2`. |
| Tự chốt | Hết hạn vote → máy quản trị tự chốt danh sách, tính tiền. Kiểm tra mỗi phút. Khi phải cắt theo giới hạn, **ai vote trước được ưu tiên** (app lưu thời điểm vote). |
| Chốt tay / sửa danh sách | Chốt danh sách từ vote; sau đó vẫn thêm/bớt người thực tế, thêm **khách** (chia tiền sân, trả tiền mặt, không trừ quỹ). Tiền tự tính lại. |
| Tiền sân | Chia theo đầu người (người chơi + khách). Phần của người chơi: **trừ quỹ chung trước**, hết thì **chia đều phần thiếu**. |
| Tiền nước | Nhiều loại, giá khác nhau, mỗi người tự trả theo số lượng × giá của buổi. +/− trong tab Nước. |
| Giá nước theo ngày | Buổi lấy giá của lần sửa gần nhất **trước ngày chơi**; sửa riêng trong buổi được, tuỳ chọn lưu làm giá mặc định từ ngày đó. Giá được "đóng băng" vào buổi khi bắt đầu dùng. |
| Ảnh đặt sân | Gắn ảnh vào buổi (nén, lưu Firestore), xem ở tab Người chơi và Tổng kết. |
| Tổng kết | Tiền sân, số người, quỹ chung trả, khách trả, tổng nước, từng người bị trừ bao nhiêu, còn bao nhiêu; cảnh báo người sắp hết quỹ; gửi tổng kết lên Zalo. |
| An toàn dữ liệu | Thao tác nhanh liên tiếp xếp hàng, áp dụng lên bản mới nhất; sửa form không ghi đè vote vừa về. |

## 5. Chi phí khác

- Mua bóng, quần áo...: không chọn ai = chia cho **tất cả** người đang hoạt động, **ưu tiên quỹ chung**; chọn người = chia đều cho những người đó, không dùng quỹ chung.
- Xem trước phần mỗi người trước khi lưu; sửa → tính lại; xoá → hoàn tiền.

## 6. QR và chia sẻ

- Gắn ảnh QR ngân hàng + thông tin tài khoản (sao chép nhanh). Chia sẻ ảnh QR.
- Màn hình Chia sẻ: chọn nội dung (số dư mọi người, danh sách sắp hết quỹ, quỹ chung, tổng kết một buổi, thông tin chuyển khoản, đính kèm QR, lời nhắn), xem trước, chia sẻ qua share sheet (Zalo...) hoặc sao chép. Trình duyệt máy tính không có share sheet thì tự sao chép.

## 7. Zalo Bot

Bot `Bot PickleBall JVB` trong nhóm. Bot chỉ thấy tin **reply** bot hoặc **@bot** (giới hạn của Zalo).

| Gõ trong nhóm | Bot làm gì |
|---|---|
| Reply tin vote: `1` / `2` / `0` (`đi`, `không`, `ok`, `bận`...) | Webhook **ghi vote ngay** vào buổi đang mở và **xác nhận tức thì**: "✅ An: đi · đã có 3/8 suất". Không còn chỗ, hết hạn, chưa có buổi, gõ số sai → bot báo rõ. Người chưa có tên (hoặc ghi lỗi tạm thời) → vào hộp thư, app tự thêm/ghi rồi bot xác nhận lại. Chỉ câu **ngắn** (≤ 5 từ) có từ khoá mới tính là vote; câu nói dài như "anh Sơn bảo anh oke rồi em" chuyển sang AI. |
| `@An 1` / `@An 0` / `@An 2` | **Vote hộ** người khác (nhiều người trong một tin: `@Bình 0 @An 2`; phần trước @ đầu tiên là vote của chính người gửi). Tên khớp dài nhất với tên trong app hoặc tên hiển thị Zalo đã nhớ (không dấu, không phân biệt hoa thường; `@Nguyễn Văn An` vẫn ra người tên "An" nếu duy nhất); tên chưa có → bot báo "không tìm thấy", không tự thêm. Bot xác nhận từng người kèm "(Tùng vote hộ)"; đính kèm, giới hạn chỗ áp dụng như vote thường. Câu hỏi/câu nói có @tên ("@An đi không?") không bị tính là vote. |
| `vote`, `danh sách vote` | Các buổi đang mở vote: giờ, sân, hạn, số suất, ai đã vote. Không có thì báo "không có vote nào đang mở". |
| `help`, `hướng dẫn`, `?` | Hướng dẫn 6 dòng (trả lời tức thì). |
| Chỉ `@bot` không nội dung | Bot nhắc các lệnh. Mọi tin tag bot đều có phản hồi; AI lỗi cũng trả lời "em chưa hiểu, gõ help". |
| `nước`, `giá nước` | Danh sách nước kèm mã `N1, N2...` và giá hôm nay (tức thì). |
| `N1 2` · `revive 2, suối 1` · `+1 N1` · `N1 0` | Bot báo "đã nhận lệnh nước" ngay; app (máy quản trị) ghi vào buổi gần nhất mình tham gia, tính lại tiền, rồi bot xác nhận kèm tổng tiền nước. Không phân biệt hoa thường, dấu. |
| `@An N1 2 @Bình N2 1` | Nhập hộ nhiều người trong một tin; phần trước @ đầu tiên là của người gửi. Người chưa có trong buổi vẫn được ghi nước (trừ đúng người uống) nhưng **không** tự thêm vào danh sách chơi, bot nhắc quản lý thêm nếu họ có chơi. Thiếu số lượng ("N1 2 N2") thì bot báo lỗi rõ. |
| `quỹ`, `số dư` | Bảng số dư cả nhóm: quỹ chung → **khối "Cần nạp thêm"** (dưới ngưỡng cảnh báo đặt trong app, kèm thông tin CK) → số dư từng người; có người sắp hết thì gửi kèm **ảnh QR** (tức thì). |
| Câu hỏi khác | **AI trả lời** tức thì (Groq gpt-oss-120b → Gemini Flash-Lite/Flash, đều miễn phí, không nói trong chat mẫu nào trả lời), biết buổi sắp tới, bảng giá nước, các lệnh; xưng "em"; không bịa số liệu. Hết hạn mức → báo vui vẻ kèm lúc hỏi lại. |
| Báo quỹ tự động | Mỗi **Thứ 6 8:00** (giờ Việt Nam) bot gửi bảng quỹ vào nhóm; có người dưới ngưỡng cảnh báo thì kèm thông tin CK + QR, không thì không gửi QR. |
| Giục nạp quỹ | Nút **"Giục nạp quỹ qua Zalo (kèm QR)"** ở trang chính (cần mã bảo mật): bot gửi danh sách người sắp hết quỹ + cách chuyển khoản + ảnh QR lên nhóm. |
| Kết quả vote khi hết hạn | Buổi đã gửi vote qua bot mà hết hạn → bot tự gửi **kết quả** (ai đi, mấy suất, ai không đi, vượt giới hạn) và nhắc **bỏ ghim** tin vote. GitHub Actions gọi `/cron-votes` mỗi 10 phút (Vercel miễn phí chỉ cho cron mỗi ngày). Tin vote có dòng nhắc quản lý **ghim** vì Zalo Bot API không tự ghim/bỏ ghim được. |
| Bố cục tin nhắn | Mọi tin bot chia **khối cách dòng trống**, thông tin chính (ai, đi/không, mấy suất) ở dòng đầu; mỗi câu trả lời **trích lại tin đang trả lời** (`↩️ Tùng: "1"`) vì API không reply vào tin cụ thể được. |

Luồng kỹ thuật: Zalo → webhook Vercel → (help/nước/quỹ/AI trả lời ngay) hoặc ghi `zaloInbox` → app trên máy quản trị xử lý vote & nước. Webhook trả lời Zalo ngay, AI chạy nền (tối đa 60 giây). Bản web gọi Zalo qua webhook (proxy) vì Zalo không bật CORS.

Cài đặt trong app → Zalo Bot: token, tìm nhóm (@bot trong nhóm), webhook URL + secret, bật/tắt webhook, người đã liên kết Zalo, gỡ liên kết. Chế độ không webhook: app tự hỏi Zalo khi mở tab Vote.

## 8. Vận hành

| Việc | Cách |
|---|---|
| Deploy web | Push `main` → GitHub Actions → GitHub Pages. |
| Deploy webhook | Push `main` → Vercel tự deploy; hoặc `npx vercel deploy --prod`. |
| Biến môi trường Vercel | `ZALO_SECRET`, `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY`, `TEAM_ID`, `CRON_SECRET`, `PUBLIC_BASE_URL` (tuỳ chọn `GEMINI_MODEL`, `OPENAI_API_KEY`, `OPENAI_MODEL`). |
| Rules Firestore | `firebase deploy --only firestore:rules`. |
| Test | `flutter test`: test logic thuần (chia tiền, hạn vote/giới hạn/đính kèm, phân tích lệnh Zalo, nhập tiền). Không dùng Firestore giả lập. |

## 9. Giới hạn đã biết

- Zalo Bot không tạo được bình chọn gốc của Zalo, không có nút bấm, không sửa/xoá tin đã gửi, **không ghim/bỏ ghim, không reply vào tin cụ thể** (đã thử, API trả 404), chỉ thấy reply/@mention.
- Xử lý vote/nước từ Zalo chỉ chạy khi có máy đang mở khoá quản trị (tin chờ trong hộp thư, không mất). Help/nước/quỹ/AI thì trả lời ngay không cần app.
- Gói Vercel miễn phí có thể lệch giờ cron trong khung giờ đã đặt.
- Hạn mức Gemini miễn phí có giới hạn theo phút/ngày; bot dùng Groq trước (~1.000 lượt/ngày), rồi Gemini Flash-Lite/Flash/Gemma; hết sạch mới báo.
- Xoá hẳn người chơi sẽ chia lại tiền sân/chi phí họ đang gánh cho người còn lại; muốn giữ lịch sử thì tắt "Đang hoạt động" thay vì xoá.
