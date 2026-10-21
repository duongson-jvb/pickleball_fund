/**
 * Cloudflare Worker: nhận webhook từ Zalo Bot và ghi vào Firestore
 * teams/{teamId}/zaloInbox/{messageId}. App Quỹ Pickleball sẽ đọc hộp thư
 * này và biến reply thành vote.
 *
 * URL webhook: https://<worker>.workers.dev/<teamId>
 * Biến môi trường (Settings → Variables):
 *   FIREBASE_PROJECT_ID  = pickleball-fund-phm
 *   FIREBASE_API_KEY     = Web API key của Firebase (xem lib/firebase_options.dart)
 *   ZALO_SECRET          = chuỗi bí mật 8-256 ký tự, trùng với secret_token lúc setWebhook
 *   TEAM_ID (tuỳ chọn)   = mã nhóm mặc định nếu URL không có /<teamId>
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const teamId = url.pathname.replace(/^\/+|\/+$/g, '') || env.TEAM_ID || '';

    if (request.method === 'GET') {
      return json({ ok: true, service: 'zalo-webhook', teamId: teamId || null });
    }
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }

    // Xác thực secret từ Zalo.
    const secret = request.headers.get('X-Bot-Api-Secret-Token') || '';
    if (env.ZALO_SECRET && secret !== env.ZALO_SECRET) {
      return new Response('Forbidden', { status: 403 });
    }
    if (!teamId || teamId.length < 6) {
      return json({ ok: false, error: 'Thiếu teamId trong URL (/<teamId>)' }, 400);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      // Zalo gửi request kiểm tra khi setWebhook; trả 200 để xác minh thành công.
      return json({ ok: true, note: 'no json body' });
    }

    const result = body?.result ?? body ?? {};
    const msg = result.message ?? result;
    const chatId = msg?.chat?.id;
    if (!chatId) return json({ ok: true, ignored: true });

    const messageId = String(msg.message_id || crypto.randomUUID());
    const dateMs = typeof msg.date === 'number'
      ? (msg.date > 1e11 ? msg.date : msg.date * 1000)
      : Date.now();

    const fields = {
      eventName: s(result.event_name ?? ''),
      messageId: s(messageId),
      fromId: s(msg.from?.id ?? ''),
      fromName: s(msg.from?.display_name ?? ''),
      chatId: s(chatId),
      chatType: s(msg.chat?.chat_type ?? 'PRIVATE'),
      text: s(msg.text ?? msg.caption ?? ''),
      date: { timestampValue: new Date(dateMs).toISOString() },
      receivedAt: { timestampValue: new Date().toISOString() },
    };

    const docPath =
      `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents` +
      `/teams/${encodeURIComponent(teamId)}/zaloInbox/${encodeURIComponent(messageId)}`;
    const fsUrl = `https://firestore.googleapis.com/v1/${docPath}?key=${env.FIREBASE_API_KEY}`;

    const res = await fetch(fsUrl, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ fields }),
    });

    if (!res.ok) {
      const err = await res.text();
      console.log('Firestore error', res.status, err);
      // Vẫn trả 200 để Zalo không gửi lại liên tục; lỗi xem trong log Worker.
      return json({ ok: false, firestore: res.status, error: err.slice(0, 500) });
    }
    return json({ ok: true, saved: messageId });
  },
};

function s(v) {
  return { stringValue: String(v) };
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
