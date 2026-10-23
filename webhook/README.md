# Zalo webhook + proxy (Vercel)

Một hàm duy nhất `webhook/zalo-webhook.js`, deploy lên Vercel qua `api/` ở gốc repo. Miễn phí, không cần thẻ.

| Việc | Đường dẫn |
|---|---|
| Webhook Zalo gọi vào khi có tin | `POST https://pickleball-zalo-webhook.vercel.app/<mã nhóm>` |
| Proxy cho bản web gọi Zalo Bot API | `POST https://pickleball-zalo-webhook.vercel.app/<mã nhóm>?zalo=<method>` với body `{token, params}` |
| Kiểm tra sống | `GET https://pickleball-zalo-webhook.vercel.app/<mã nhóm>` |

Cả hai đường POST đều yêu cầu header `X-Bot-Api-Secret-Token` = biến `ZALO_SECRET`
(trừ request kiểm tra không có JSON của Zalo lúc `setWebhook`).

## Luồng

1. Thành viên reply tin của bot hoặc @bot trong nhóm → Zalo POST tới webhook.
2. Lệnh `help` / `hướng dẫn` / `?` → trả lời ngay. `nước` → danh sách nước kèm mã và giá.
3. Tin là vote (ngắn, có từ khoá 1/0/đi/không...) hoặc lệnh nước (có chữ số) → ghi vào
   `teams/{mã nhóm}/zaloInbox/{messageId}` → app (máy quản trị) xử lý.
4. Tin khác (câu hỏi có dấu "?", từ để hỏi, hoặc câu dài) → **AI trả lời ngay**:
   - Ưu tiên **Google Gemini** (miễn phí, không cần thẻ): biến `GEMINI_API_KEY`, lấy tại https://aistudio.google.com/apikey.
     Thứ tự mẫu: `gemini-3.5-flash-lite` → `gemini-3.1-flash-lite` → `gemini-flash-lite-latest` → `gemini-3.8-flash` → `gemini-flash-latest` → `gemma-4-31b-it`
     (Flash-Lite có hạn mức ngày miễn phí cao hơn Flash nhiều lần; mỗi mẫu một hạn mức riêng nên hết mẫu này tự sang mẫu khác).
     Đặt `GEMINI_MODEL` để ưu tiên một mẫu khác. Xem hạn mức thật của dự án tại https://aistudio.google.com/rate-limit.
   - Dự phòng **Groq** (miễn phí, không cần thẻ, ~1.000 lượt/ngày với Llama 3.3 70B): đặt `GROQ_API_KEY` (lấy tại https://console.groq.com/keys),
     tuỳ chọn `GROQ_MODEL`.
   - Dự phòng **OpenAI** hoặc API tương thích nếu đặt `OPENAI_API_KEY` (có phí; `OPENAI_MODEL`, `OPENAI_BASE_URL`).
   - Bot được cấp ngữ cảnh: tên nhóm, buổi sắp tới (giờ, sân, số vote, hạn, tiền sân, người tạo), buổi gần nhất,
     bảng giá nước, các lệnh; trả lời tiếng Việt tối đa 3 câu, không bịa số liệu, không sửa được dữ liệu.
   - **Hết hạn mức**: bot báo vui vẻ kèm thời gian hỏi lại (lấy từ `retryDelay` của Google; hết lượt ngày thì
     "hỏi lại sau 15:00 giờ Việt Nam"). Không có key hoặc AI lỗi → tin đi vào hộp thư như cũ.

## Deploy / cập nhật

```bash
npx vercel login              # một lần, mở trình duyệt
npx vercel link --project pickleball-zalo-webhook
npx vercel env add ZALO_SECRET production
npx vercel env add FIREBASE_PROJECT_ID production   # pickleball-fund-phm
npx vercel env add FIREBASE_API_KEY production      # Web API key của Firebase
npx vercel env add BOT_REFRESH_TOKEN production     # xem bên dưới - thiếu thì bot không ghi vote ngay
npx vercel deploy --prod
```

### `BOT_REFRESH_TOKEN` — để bot ghi vote thẳng vào buổi

Webhook cần một tài khoản Firebase để ghi vote (Firestore rules không cho ghi khi chưa đăng nhập).
**Thiếu biến này bot vẫn chạy**, nhưng không ghi vote ngay được: tin vào `zaloInbox` và app ghi hộ
khi quản lý mở, người vote nhận câu "đã nhận vote, sẽ cập nhật khi quản lý mở app" thay vì xác nhận
"đã có N suất".

Lấy giá trị một lần rồi đặt vào biến (tài khoản ẩn danh này dùng lại mãi):

```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=<FIREBASE_API_KEY>" \
  -H 'Content-Type: application/json' -d '{"returnSecureToken":true}' | python3 -m json.tool
```

Lấy trường `refreshToken` trong kết quả.

Xem log request: https://vercel.com → project → **Logs**.

## Vì sao không dùng Firebase Functions hay Cloudflare

- Firebase Functions cần gói Blaze (phải nhập thẻ).
- Cloudflare Workers / Pages chặn request của máy chủ Zalo (User-Agent `Java/...`, lỗi 1010
  Browser Integrity Check) trên tên miền `*.workers.dev` và `*.pages.dev`; chỉ tắt được khi có tên miền riêng.
  Đã kiểm chứng ngày 22/10/2026 bằng log trực tiếp: không request nào của Zalo tới được Worker.

## Lưu ý kỹ thuật

- Catch-all `api/[...path].js` của Vercel không khớp đường dẫn nhiều đoạn sau rewrite, nên proxy dùng query `?zalo=<method>`.
- Khi webhook đang bật, Zalo không trả tin qua `getUpdates`. App chỉ bật chế độ webhook khi Zalo xác minh thành công.
- Route cho app/cron (ngoài webhook Zalo):
  - `GET /cron-weekly` (Vercel Cron, Thứ 6 8:00 VN, `Authorization: Bearer CRON_SECRET`): báo quỹ tuần, kèm QR nếu có người dưới ngưỡng.
  - `GET /cron-votes` (GitHub Actions mỗi 10 phút, cùng secret): buổi đã gửi vote qua bot mà vừa hết hạn → gửi kết quả + nhắc bỏ ghim, ghi dấu `zaloVoteState/<buổi>`.
  - `POST /<teamId>?action=remind` (header `X-Bot-Api-Secret-Token`): nút "Giục nạp quỹ" trong app → danh sách sắp hết quỹ + QR.
- Zalo Bot API không có pin/unpin/edit/delete/reply_to (đã thử, 404): bot trích tin đang trả lời ở dòng đầu (`↩️ Tên: "..."`) và nhắc ghim/bỏ ghim bằng chữ.
