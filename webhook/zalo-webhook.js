/**
 * Webhook + proxy Zalo Bot cho app Quỹ Pickleball. Chạy trên Vercel (api/ ở gốc repo gọi vào đây).
 *
 * 1) Webhook Zalo:   POST https://pickleball-zalo-webhook.vercel.app/<teamId>
 *    Nhận tin từ Zalo Bot, trả lời lệnh help, hoặc ghi vào Firestore teams/{teamId}/zaloInbox/{messageId}
 *    để app biến reply thành vote.
 * 2) Proxy Zalo API: POST https://pickleball-zalo-webhook.vercel.app/<teamId>?zalo=<method>
 *    Body: { "token": "<bot token>", "params": {...} }  → chuyển tiếp tới Zalo.
 *    Cần cho bản web vì bot-api.zaloplatforms.com không bật CORS.
 *
 * Cả hai đều yêu cầu header  X-Bot-Api-Secret-Token = ZALO_SECRET.
 *
 * Biến môi trường (Vercel → Settings → Environment Variables):
 *   FIREBASE_PROJECT_ID  = pickleball-fund-phm
 *   FIREBASE_API_KEY     = Web API key của Firebase
 *   ZALO_SECRET          = chuỗi bí mật 8-256 ký tự (chữ không dấu + số)
 *   TEAM_ID (tuỳ chọn)   = mã nhóm mặc định nếu URL không có /<teamId>
 *
 * Không chạy trên Cloudflare (*.workers.dev / *.pages.dev): Cloudflare chặn máy chủ Zalo (lỗi 1010).
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
    const secretOk = !env.ZALO_SECRET || secret === env.ZALO_SECRET;
    // Log gọn để soi trong Logs của Vercel (không in giá trị secret).
    console.log(`POST ${url.pathname} ua="${request.headers.get('User-Agent') || ''}" ` +
      `secretHeader=${secret ? 'yes' : 'no'} secretOk=${secretOk}`);

    if (!teamId || teamId.length < 6) {
      return json({ ok: false, error: 'Thiếu teamId trong URL (/<teamId>)' }, 400);
    }

    // ---- Proxy: /<teamId>?zalo=<method>  hoặc  /<teamId>/zalo/<method>  (bắt buộc đúng secret)
    const proxyMethod = url.searchParams.get('zalo') || (parts[1] === 'zalo' ? parts[2] : '');
    if (proxyMethod) {
      if (!secretOk) return json({ ok: false, error: 'Forbidden: sai X-Bot-Api-Secret-Token' }, 403);
      return proxyZalo(proxyMethod, request);
    }

    // ---- Webhook từ Zalo
    let body;
    try {
      body = await request.json();
    } catch {
      // Request kiểm tra của Zalo lúc setWebhook không có JSON và có thể
      // không kèm secret → trả 200 để xác minh thành công (không có dữ liệu gì).
      return json({ ok: true, note: 'no json body' });
    }
    if (!secretOk) {
      console.log('Webhook bị từ chối: sai hoặc thiếu X-Bot-Api-Secret-Token');
      return json({ ok: false, error: 'Forbidden: sai X-Bot-Api-Secret-Token' }, 403);
    }

    const result = body?.result ?? body ?? {};
    const msg = result.message ?? result;
    const chatId = msg?.chat?.id;
    if (!chatId) return json({ ok: true, ignored: true });

    // Lệnh "@bot help": trả lời hướng dẫn ngay, không ghi vào hộp thư vote.
    const text = String(msg.text ?? '');
    if (isHelpCommand(text)) {
      return replyHelp(env, teamId, String(chatId));
    }
    // "@bot nước" (không kèm số) → trả danh sách nước kèm mã và giá ngay.
    if (isDrinkListRequest(text)) {
      return replyDrinkList(env, teamId, String(chatId));
    }

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

// ---------------------------------------------------------------- lệnh help
const APP_URL = 'https://duongson-jvb.github.io/pickleball_fund/';

const HELP_TEXT = [
  '🏓 Bot Quỹ Pickleball',
  '• Vote đi chơi: Reply tin vote của bot → 1 = đi, 0 = không',
  '• Đổi ý: reply lại là xong',
  '• Người mới cứ reply 1, bot tự thêm tên vào danh sách',
  '• Gõ "nước" để xem danh sách nước + mã (N1, N2...) và giá',
  '• Ghi nước: "N1 2" / "revive 2, suối 1" / "+1 N1" (cộng thêm)',
  `• Xem quỹ, tiền sân, tiền nước: ${APP_URL}`,
  '• Gõ @bot help để xem lại tin này',
].join('\n');

/** Bỏ dấu tiếng Việt + viết thường để so khớp lệnh. */
function normalizeVi(str) {
  return String(str)
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/đ/g, 'd')
    .replace(/Đ/g, 'd')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function isDrinkListRequest(text) {
  const t = normalizeVi(text).replace(/@\S+/g, ' ').replace(/[?!.,:]+/g, ' ').replace(/\s+/g, ' ').trim();
  return /^(nuoc|drink|menu nuoc|danh sach nuoc|nuoc menu|gia nuoc|bang gia|bang gia nuoc|list nuoc|ds nuoc)$/.test(t);
}

function fmtVnd(v) {
  return String(v).replace(/\B(?=(\d{3})+(?!\d))/g, '.') + 'đ';
}

/** Đọc token + danh sách nước của nhóm từ Firestore, trả lời danh sách kèm mã và giá. */
async function replyDrinkList(env, teamId, chatId) {
  const base = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}` +
    `/databases/(default)/documents/teams/${encodeURIComponent(teamId)}`;
  const teamRes = await fetch(`${base}?key=${env.FIREBASE_API_KEY}&mask.fieldPaths=zaloBotToken`);
  if (!teamRes.ok) return json({ ok: true, drinks: 'team-not-found' });
  const token = (await teamRes.json())?.fields?.zaloBotToken?.stringValue || '';
  if (!token) return json({ ok: true, drinks: 'no-token' });

  const listRes = await fetch(`${base}/drinkTypes?key=${env.FIREBASE_API_KEY}&pageSize=100`);
  const docs = listRes.ok ? ((await listRes.json()).documents || []) : [];
  const now = Date.now();
  const items = docs.map((d) => {
    const f = d.fields || {};
    const active = f.active?.booleanValue !== false;
    const name = f.name?.stringValue || '';
    const code = parseInt(f.code?.integerValue || '0', 10) || 0;
    // Giá áp dụng: giá có ngày hiệu lực gần nhất <= hôm nay (không có thì giá sớm nhất).
    const prices = (f.prices?.arrayValue?.values || []).map((v) => ({
      date: Date.parse(v.mapValue?.fields?.date?.timestampValue || 0),
      price: parseInt(v.mapValue?.fields?.price?.integerValue || '0', 10) || 0,
    })).sort((a, b) => a.date - b.date);
    let price = prices.length ? prices[0].price : 0;
    for (const p of prices) if (p.date <= now) price = p.price;
    return { active, name, code, price };
  }).filter((x) => x.active).sort((a, b) => (a.code || 1e9) - (b.code || 1e9));

  let text;
  if (!items.length) {
    text = '🥤 Nhóm chưa có loại nước nào. Quản lý thêm trong app → Cài đặt → Loại nước & giá.';
  } else {
    text = '🥤 DANH SÁCH NƯỚC\n' +
      items.map((x) => `${x.code ? 'N' + x.code : '•'} · ${x.name} · ${fmtVnd(x.price)}`).join('\n') +
      `\nGhi nước: "N1 2" hoặc "${items[0].name} 2"; nhiều loại: "N1 2, N2 1"; cộng thêm: "+1 N1"`;
  }
  const sent = await fetch(`${ZALO_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
  let zalo = {};
  try { zalo = await sent.json(); } catch { /* bỏ qua */ }
  return json({ ok: true, drinks: zalo?.ok === true ? 'sent' : 'failed', count: items.length });
}

function isHelpCommand(text) {
  const t = normalizeVi(text).replace(/@\S+/g, ' ').replace(/[?!.,]+/g, ' ');
  return /(^|\s)(help|huong dan|tro giup|menu|lenh|cach dung|hdsd)(\s|$)/.test(t)
    || /^\s*\?\s*$/.test(normalizeVi(text).replace(/@\S+/g, ''));
}

/** Đọc bot token của nhóm từ Firestore rồi gửi hướng dẫn vào chat. */
async function replyHelp(env, teamId, chatId) {
  const docUrl =
    `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}` +
    `/databases/(default)/documents/teams/${encodeURIComponent(teamId)}` +
    `?key=${env.FIREBASE_API_KEY}&mask.fieldPaths=zaloBotToken`;
  const res = await fetch(docUrl);
  if (!res.ok) return json({ ok: true, help: 'team-not-found' });
  const doc = await res.json();
  const token = doc?.fields?.zaloBotToken?.stringValue || '';
  if (!token) return json({ ok: true, help: 'no-token' });

  const sent = await fetch(`${ZALO_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: HELP_TEXT }),
  });
  let zalo = {};
  try { zalo = await sent.json(); } catch { /* bỏ qua */ }
  const okSend = sent.ok && zalo?.ok === true;
  console.log(`help → chat ${chatId}: ${okSend ? 'sent' : 'failed'} ${zalo?.description || ''}`);
  return json({
    ok: true,
    help: okSend ? 'sent' : 'failed',
    zalo: okSend ? { message_id: zalo?.result?.message_id } : { error_code: zalo?.error_code, description: zalo?.description },
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
