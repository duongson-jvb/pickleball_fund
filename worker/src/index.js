/**
 * Cloudflare Worker cho app Quỹ Pickleball.
 *
 * 1) Webhook Zalo:   POST https://<worker>.workers.dev/<teamId>
 *    Nhận tin từ Zalo Bot, ghi vào Firestore teams/{teamId}/zaloInbox/{messageId}.
 * 2) Proxy Zalo API: POST https://<worker>.workers.dev/<teamId>/zalo/<method>
 *    Body: { "token": "<bot token>", "params": {...} }  → chuyển tiếp tới Zalo.
 *    Cần cho bản web vì bot-api.zaloplatforms.com không bật CORS.
 *
 * Cả hai đều yêu cầu header  X-Bot-Api-Secret-Token = ZALO_SECRET.
 *
 * Biến môi trường (Settings → Variables and Secrets):
 *   FIREBASE_PROJECT_ID  = pickleball-fund-phm
 *   FIREBASE_API_KEY     = Web API key của Firebase
 *   ZALO_SECRET          = chuỗi bí mật 8-256 ký tự (chữ không dấu + số)
 *   TEAM_ID (tuỳ chọn)   = mã nhóm mặc định nếu URL không có /<teamId>
 */

const ZALO_API = 'https://bot-api.zaloplatforms.com';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Bot-Api-Secret-Token',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }

    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);
    const teamId = parts[0] || env.TEAM_ID || '';

    if (request.method === 'GET') {
      return json({ ok: true, service: 'zalo-webhook', teamId: teamId || null });
    }
    if (request.method !== 'POST') {
      return json({ ok: false, error: 'Method Not Allowed' }, 405);
    }

    // Xác thực secret (Zalo gửi kèm khi webhook, app gửi kèm khi proxy).
    const secret = request.headers.get('X-Bot-Api-Secret-Token') || '';
    if (env.ZALO_SECRET && secret !== env.ZALO_SECRET) {
      return json({ ok: false, error: 'Forbidden: sai X-Bot-Api-Secret-Token' }, 403);
    }
    if (!teamId || teamId.length < 6) {
      return json({ ok: false, error: 'Thiếu teamId trong URL (/<teamId>)' }, 400);
    }

    // ---- Proxy: /<teamId>/zalo/<method>
    if (parts[1] === 'zalo' && parts[2]) {
      return proxyZalo(parts[2], request);
    }

    // ---- Webhook từ Zalo
    let body;
    try {
      body = await request.json();
    } catch {
      // Request kiểm tra của Zalo lúc setWebhook có thể không có JSON.
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

/** Chuyển tiếp lời gọi Zalo Bot API cho app (vượt CORS). */
async function proxyZalo(method, request) {
  if (!/^[a-zA-Z]+$/.test(method)) return json({ ok: false, error: 'Bad method' }, 400);
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, error: 'Body phải là JSON {token, params}' }, 400);
  }
  const token = String(body?.token || '');
  if (!token.includes(':')) return json({ ok: false, error: 'Thiếu token bot' }, 400);
  const params = body?.params && typeof body.params === 'object' ? body.params : {};

  const upstream = await fetch(`${ZALO_API}/bot${token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(params),
  });
  const text = await upstream.text();
  return new Response(text, {
    status: upstream.status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function s(v) {
  return { stringValue: String(v) };
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}
