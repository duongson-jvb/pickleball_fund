# Zalo webhook + proxy trên Cloudflare Workers

Worker làm hai việc, miễn phí (gói Free của Cloudflare: 100.000 request/ngày):

1. **Webhook**: nhận tin từ Zalo Bot và ghi vào Firestore `teams/{teamId}/zaloInbox`. App đọc hộp thư này và biến reply thành vote.
2. **Proxy Zalo API** (`POST /<teamId>/zalo/<method>`): bản web của app gọi Zalo qua đây vì Zalo không bật CORS cho trình duyệt.
   Bản iOS/Android gọi thẳng Zalo, không cần proxy.

Worker hiện tại được Cloudflare **tự build từ repo GitHub** mỗi lần push lên `main` (Workers Builds).
File `wrangler.toml` ở **gốc repo** là cấu hình cho lần build đó (trỏ tới `worker/src/index.js`). Đừng xoá file này:
khi thiếu nó, build tự động sẽ deploy sai và mọi đường dẫn trả 404 (đã xảy ra ngày 21/10/2026).
`ZALO_SECRET` là Secret trên Cloudflare, không nằm trong repo; nếu sau một lần build mà `POST` không có header secret
vẫn trả 200 thì secret đã mất, đặt lại bằng `wrangler secret put ZALO_SECRET` trong thư mục `worker/`.

## Cách A: dùng giao diện web (không cần cài gì)

1. Tạo tài khoản tại https://dash.cloudflare.com (miễn phí, không cần thẻ).
2. Menu trái **Workers & Pages** → **Create** → **Create Worker** → đặt tên `pickleball-zalo-webhook` → **Deploy**.
3. Bấm **Edit code**, xoá hết, dán toàn bộ nội dung file `src/index.js` → **Deploy**.
4. Quay lại trang Worker → **Settings** → **Variables and Secrets** → thêm:
   | Tên | Kiểu | Giá trị |
   |---|---|---|
   | `FIREBASE_PROJECT_ID` | Text | `pickleball-fund-phm` |
   | `FIREBASE_API_KEY` | Text | `AIzaSyBFmd11fse6sjw_rWaHMwxWz3RrzvXnqR8` |
   | `ZALO_SECRET` | Secret | chuỗi bí mật 8–256 ký tự do bạn tự đặt |
   → **Deploy**.
5. Copy URL dạng `https://pickleball-zalo-webhook.<tên-bạn>.workers.dev`.
6. Trong app: Cài đặt → Zalo Bot → mục **Webhook** → dán URL (app tự thêm `/<mã nhóm>`), nhập đúng `ZALO_SECRET` → **Bật webhook**.
   App gọi `setWebhook` cho Zalo và hiện kết quả xác minh.

## Cách B: dùng dòng lệnh (wrangler)

```bash
cd worker
npm install -g wrangler
wrangler login                      # mở trình duyệt đăng nhập Cloudflare
wrangler secret put ZALO_SECRET     # nhập chuỗi bí mật
wrangler deploy                     # in ra URL *.workers.dev
```

## Kiểm tra

```bash
curl https://pickleball-zalo-webhook.<tên-bạn>.workers.dev/<mã-nhóm>
# → {"ok":true,"service":"zalo-webhook","teamId":"<mã-nhóm>"}
```

Xem log realtime: trang Worker → **Logs** → *Begin log stream*, rồi reply tin của bot trong nhóm Zalo.

## Lưu ý

- Khi webhook đang bật, Zalo **không** trả tin qua `getUpdates` nữa. App tự chuyển sang đọc `zaloInbox`.
- Một Worker phục vụ được nhiều nhóm: mỗi nhóm dùng URL `.../<mã nhóm>` riêng.
- Tắt webhook trong app (nút **Tắt webhook**) để quay lại chế độ app tự hỏi Zalo.
