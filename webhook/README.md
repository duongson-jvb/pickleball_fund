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
     Mẫu mặc định `gemini-2.5-flash`, tự lùi về `gemini-2.0-flash` / `gemini-1.5-flash` nếu không có; đổi bằng `GEMINI_MODEL`.
   - Dự phòng **OpenAI** nếu đặt `OPENAI_API_KEY` (có phí; mẫu `OPENAI_MODEL`, mặc định `gpt-4o-mini`).
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
npx vercel deploy --prod
```

Xem log request: https://vercel.com → project → **Logs**.

## Vì sao không dùng Firebase Functions hay Cloudflare

- Firebase Functions cần gói Blaze (phải nhập thẻ).
- Cloudflare Workers / Pages chặn request của máy chủ Zalo (User-Agent `Java/...`, lỗi 1010
  Browser Integrity Check) trên tên miền `*.workers.dev` và `*.pages.dev`; chỉ tắt được khi có tên miền riêng.
  Đã kiểm chứng ngày 22/10/2026 bằng log trực tiếp: không request nào của Zalo tới được Worker.

## Lưu ý kỹ thuật

- Catch-all `api/[...path].js` của Vercel không khớp đường dẫn nhiều đoạn sau rewrite, nên proxy dùng query `?zalo=<method>`.
- Khi webhook đang bật, Zalo không trả tin qua `getUpdates`. App chỉ bật chế độ webhook khi Zalo xác minh thành công.
