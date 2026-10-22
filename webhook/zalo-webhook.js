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

    // ---- Cron báo quỹ hằng tuần (Vercel Cron gọi GET /cron/weekly với Authorization: Bearer CRON_SECRET)
    // Đường dẫn một đoạn (catch-all của Vercel không khớp nhiều đoạn): /cron-weekly
    if ((parts[0] === 'cron-weekly' || parts[0] === 'cron') && request.method === 'GET') {
      const authz = request.headers.get('Authorization') || '';
      const qsSecret = url.searchParams.get('secret') || '';
      if (env.CRON_SECRET && authz !== `Bearer ${env.CRON_SECRET}` && qsSecret !== env.CRON_SECRET) {
        return json({ ok: false, error: 'Forbidden' }, 403);
      }
      const teams = String(env.TEAM_IDS || env.TEAM_ID || '').split(',').map((x) => x.trim()).filter(Boolean);
      const results = [];
      for (const t of teams) results.push({ team: t, ...(await sendFundReport(env, t, null, { weekly: true })) });
      return json({ ok: true, results });
    }

    // ---- Ảnh QR chuyển khoản (để Zalo tải về khi bot gửi ảnh): GET /<teamId>?qr=1
    if (request.method === 'GET' && teamId && (url.searchParams.has('qr') || parts[1] === 'qr.jpg')) {
      const team = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=qrImage`);
      const b64 = team?.fields?.qrImage?.stringValue || '';
      if (!b64) return json({ ok: false, error: 'Chưa có ảnh QR' }, 404);
      const bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      return new Response(bin, { status: 200, headers: { 'Content-Type': 'image/jpeg', 'Cache-Control': 'public, max-age=300', ...CORS } });
    }

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

    // Nội dung tin (ảnh kèm chú thích thì nằm ở caption).
    const text = String(msg.text ?? msg.caption ?? '');
    const chat = String(chatId);
    const fromName = msg.from?.display_name || '';
    const fromId = String(msg.from?.id || '');

    // Lệnh "@bot help": trả lời hướng dẫn ngay, không ghi vào hộp thư vote.
    if (isHelpCommand(text)) {
      return replyHelp(env, teamId, chat);
    }

    // Đọc một lần thông tin nhóm (token bot, tên bot) cho các bước sau.
    const teamDoc = await fsGet(env,
      `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloBotName&mask.fieldPaths=name`);
    const tf = teamDoc?.fields || {};
    const token = tf.zaloBotToken?.stringValue || '';
    const botName = tf.zaloBotName?.stringValue || '';

    // "@bot quỹ" → bảng số dư cả nhóm ngay.
    if (isFundRequest(text, botName)) {
      return json({ ok: true, fund: await sendFundReport(env, teamId, chat, { weekly: false }) });
    }
    // "@bot nước" (không kèm số) → danh sách nước kèm mã và giá ngay.
    if (isDrinkListRequest(text, botName)) {
      const r = await replyDrinkList(env, teamId, chat, text);
      if (r) return r;
    }
    // "@bot vote" → các buổi đang mở vote (hoặc báo không có).
    if (isVoteListRequest(text, botName)) {
      return replyVoteList(env, teamId, chat, token);
    }

    const cleaned = cleanForCommand(text, botName);
    // Chỉ @bot mà không nói gì → nhắc cách dùng, không im lặng.
    if (!cleaned) {
      return replyText(env, teamId, chat, EMPTY_MENTION_TEXT, token);
    }

    const voteShape = readVoteShape(text, botName);
    // Lệnh ghi nước cũng chứa từ khoá vote ("+1 N1", "N1 0") → không phải vote.
    const isDrinkCommand = /\d/.test(cleaned) && hasDrinkMarker(cleaned, await drinkAliases(env, teamId));

    // Gõ số sai ("10", "01", "0.1", "1,2,3"...) → báo lại ngay, không tính vote.
    if (!isDrinkCommand && voteShape.error) {
      console.log(`vote sai cu phap: "${text.slice(0, 40)}"`);
      return replyText(env, teamId, chat, voteShape.error, token);
    }

    const messageId = String(msg.message_id || crypto.randomUUID());
    const dateMs = typeof msg.date === 'number'
      ? (msg.date > 1e11 ? msg.date : msg.date * 1000)
      : Date.now();
    const inboxFields = {
      eventName: s(result.event_name ?? ''),
      messageId: s(messageId),
      fromId: s(fromId),
      fromName: s(fromName),
      chatId: s(chat),
      chatType: s(msg.chat?.chat_type ?? 'PRIVATE'),
      text: s(text),
      date: { timestampValue: new Date(dateMs).toISOString() },
      receivedAt: { timestampValue: new Date().toISOString() },
    };

    // ---- Lệnh ghi nước: app (máy quản trị) mới ghi được → vào hộp thư + báo đã nhận.
    if (isDrinkCommand) {
      const saved = await saveInbox(env, teamId, messageId, inboxFields);
      if (!saved.ok) return saved.response;
      return replyText(env, teamId, chat,
        `📝 Em đã nhận lệnh nước của ${fromName || 'bạn'}, sẽ ghi vào sổ và báo lại ngay khi quản lý mở app.`, token);
    }

    // ---- Vote chắc chắn ("1", "2", "0", "đi", "không đi"...): ghi THẲNG vào buổi và xác nhận.
    if (voteShape.definite) {
      const open = await openVoteSession(env, teamId);
      if (!open) return replyText(env, teamId, chat, NO_OPEN_VOTE_TEXT, token);
      if (open.expired) {
        return replyText(env, teamId, chat,
          `⏰ ${open.title ? `Buổi "${open.title}"` : 'Buổi chơi'} đã hết hạn vote lúc ` +
          `${fmtDateTime(open.deadline)}, vote này không được tính. Báo quản lý nếu cần nhé!`, token);
      }
      const players = await loadPlayers(env, teamId);
      const player = matchPlayerJs(players, fromId, fromName);
      if (!player) {
        // Người chưa có trong danh sách: app sẽ tự thêm rồi ghi vote → báo đã nhận.
        const saved = await saveInbox(env, teamId, messageId, inboxFields);
        if (!saved.ok) return saved.response;
        return replyText(env, teamId, chat,
          `📝 Em đã nhận vote của ${fromName || 'bạn'}. Tên chưa có trong danh sách, quản lý mở app là em thêm và ghi vote ngay.`, token);
      }
      const r = await recordVote(env, teamId, open, player, voteShape, dateMs, players);
      console.log(`vote → ${player.name}: ${r.status}`);
      return replyText(env, teamId, chat, r.text, token);
    }

    // ---- Còn lại là câu hỏi / trò chuyện → AI trả lời (không ghi hộp thư). AI lỗi vẫn trả lời.
    if (env.GEMINI_API_KEY || env.OPENAI_API_KEY) {
      const r = await maybeChatReply(env, teamId, chat, text, fromName);
      if (r) return r;
    }
    return replyText(env, teamId, chat, FALLBACK_TEXT, token);
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
  '• Vote: reply tin vote → 1 = đi, 2 = đi 2 người (kèm 1), 0 = không, tối đa 4 · gõ "vote" xem buổi đang mở',
  '• Nước: "nước" xem mã & giá · "N1 2" ghi · "+1 N1" cộng · "@An N1 2" nhập hộ',
  '• Quỹ: "quỹ" xem số dư cả nhóm',
  '• Hỏi gì cứ @bot, em trả lời',
  `• App: ${APP_URL}`,
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

const DRINK_LIST_RE = /^(nuoc|drink|menu nuoc|danh sach nuoc|nuoc menu|gia nuoc|bang gia|bang gia nuoc|list nuoc|ds nuoc)$/;

/** Sàng nhanh: có từ "nuoc"/"gia"/... và không có chữ số (tin ghi nước luôn có số). */
function mayBeDrinkListRequest(text) {
  const t = normalizeVi(text).replace(/[?!.,:]+/g, ' ').replace(/\s+/g, ' ').trim();
  return !/\d/.test(t) && /(^|\s)(nuoc|drink|bang gia|gia nuoc)(\s|$)/.test(t);
}

/** Bỏ tên bot, @mention, dấu câu rồi so với các mẫu "nước". */
function isDrinkListRequest(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  t = t.replace(/@\S*/g, ' ').replace(/[?!.,:]+/g, ' ').replace(/\s+/g, ' ').trim();
  return DRINK_LIST_RE.test(t);
}

function fmtVnd(v) {
  return String(v).replace(/\B(?=(\d{3})+(?!\d))/g, '.') + 'đ';
}

/** Đọc token + danh sách nước của nhóm từ Firestore, trả lời danh sách kèm mã và giá. */
async function replyDrinkList(env, teamId, chatId, text) {
  const base = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}` +
    `/databases/(default)/documents/teams/${encodeURIComponent(teamId)}`;
  const teamRes = await fetch(`${base}?key=${env.FIREBASE_API_KEY}&mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloBotName`);
  if (!teamRes.ok) return null;
  const tf = (await teamRes.json())?.fields || {};
  const token = tf.zaloBotToken?.stringValue || '';
  const botName = tf.zaloBotName?.stringValue || '';
  // Không đúng là lệnh xem danh sách → trả null để xử lý như tin thường.
  if (!isDrinkListRequest(text, botName)) return null;
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

  let reply;
  if (!items.length) {
    reply = '🥤 Nhóm chưa có loại nước nào. Quản lý thêm trong app → Cài đặt → Loại nước & giá.';
  } else {
    reply = '🥤 DANH SÁCH NƯỚC\n' +
      items.map((x) => `${x.code ? 'N' + x.code : '•'} · ${x.name} · ${fmtVnd(x.price)}`).join('\n') +
      `\nGhi nước: "N1 2" hoặc "${items[0].name} 2"; nhiều loại: "N1 2, N2 1"; cộng thêm: "+1 N1"`;
  }
  const sent = await fetch(`${ZALO_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: reply }),
  });
  let zalo = {};
  try { zalo = await sent.json(); } catch { /* bỏ qua */ }
  return json({ ok: true, drinks: zalo?.ok === true ? 'sent' : 'failed', count: items.length });
}

// ---------------------------------------------------------- ChatGPT (OpenAI)
const VOTE_NO_RE = /(^|\s)(0|-1|khong|khg|hok|hong|hem|ko|k|no|nope|ban|nghi|bo qua|huy|pass|x)(\s|$)/;
const VOTE_YES_RE = /(^|\s)(1|\+1|di|co|ok|oke|okie|okay|yes|y|tham gia|join|choi|dk|dang ky|chot|len|vao|count me)(\s|$)/;

/**
 * Phân loại tin: 'empty' (chỉ @bot, không nội dung), 'command' (vote / lệnh nước → để app
 * xử lý), 'chat' (câu hỏi, trò chuyện → ChatGPT). Vote là tin ngắn (≤ 4 từ) có từ khoá;
 * câu dài có chữ "đi", "chơi", "có"... là câu nói thường, không phải vote.
 */
const QUESTION_RE = /(^|\s)(gi|dau|khi nao|luc nao|may gio|bao nhieu|bao gio|sao|the nao|tai sao|ai|nao|co ai|phai khong|duoc khong|chua)(\s|$)/;

function escapeRe(x) { return x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

// ----------------------------------------------------------- đọc tin vote
/** Số suất tối đa một người được đăng ký (phải khớp với maxVoteSeats trong app). */
const MAX_VOTE_SEATS = 4;

const NO_OPEN_VOTE_TEXT =
  '📭 Hiện chưa có buổi nào đang mở vote. Chờ quản lý tạo buổi rồi vote nhé!';

function voteNumberErrorText(original) {
  return `🤔 Em chưa hiểu "${String(original).trim()}". Reply "0" = không đi, "1" = đi, ` +
    `"2" = đi 2 người (kèm 1)... tối đa "${MAX_VOTE_SEATS}".`;
}

/**
 * Đọc hình dạng tin vote, khớp với ZaloVoteSync.readVote bên app:
 *  - error: tin chỉ gồm số/dấu phân cách nhưng không phải một số hợp lệ
 *    ("10", "01", "0.1", "1,0", "1,2,3").
 *  - definite: chắc chắn là vote (một con số hợp lệ, hoặc câu ngắn có từ khoá).
 *  - maybe: có từ khoá vote nhưng câu dài → vẫn đưa về app cho quản lý quyết định.
 */
function readVoteShape(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  t = t.replace(/@/g, ' ').replace(/\s+/g, ' ').trim();
  if (!t) return { definite: false, maybe: false, error: null, original: text, botName };
  const shape = readVoteShapeInner(t, text);
  return { ...shape, original: text, botName };
}

function readVoteShapeInner(t, text) {
  if (/^[+\-\d.,\s]+$/.test(t)) {
    const cleaned = t.replace(/\.+$/, '').trim();
    if (cleaned === '-1') return { definite: true, maybe: true, error: null };
    const m = /^\+?(\d+)$/.exec(cleaned);
    if (!m) return { definite: false, maybe: true, error: voteNumberErrorText(text) };
    const digits = m[1];
    if ((digits.length > 1 && digits.startsWith('0')) || parseInt(digits, 10) > MAX_VOTE_SEATS) {
      return { definite: false, maybe: true, error: voteNumberErrorText(text) };
    }
    return { definite: true, maybe: true, error: null };
  }

  const words = t.replace(/[.,!?()\[\]:;]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (/^\+?\d+\s+(nguoi|ng|suat|slot)$/.test(words)) {
    const n = parseInt(words, 10);
    return n > MAX_VOTE_SEATS
      ? { definite: false, maybe: true, error: voteNumberErrorText(text) }
      : { definite: true, maybe: true, error: null };
  }
  const hasKeyword = VOTE_NO_RE.test(words) || VOTE_YES_RE.test(words);
  if (!hasKeyword) return { definite: false, maybe: false, error: null };
  const definite = words.split(' ').length <= 5;
  // "đi 2" = đi 2 người; "đi 10" là gõ sai, phải báo giống bên app.
  if (definite && !VOTE_NO_RE.test(words)) {
    const n = /(^|\s)\+?(\d+)(\s|$)/.exec(words);
    if (n) {
      const digits = n[2];
      if ((digits.length > 1 && digits.startsWith('0')) || parseInt(digits, 10) > MAX_VOTE_SEATS) {
        return { definite: false, maybe: true, error: voteNumberErrorText(text) };
      }
    }
  }
  return { definite, maybe: true, error: null };
}

/** Đọc một buổi chơi từ document Firestore. */
function parseSessionDoc(d) {
  const f = d.fields || {};
  const date = Date.parse(f.date?.timestampValue || 0) || 0;
  const deadline = f.voteDeadline?.timestampValue ? Date.parse(f.voteDeadline.timestampValue) : date;
  const votes = {};
  for (const [k, v] of Object.entries(f.votes?.mapValue?.fields || {})) votes[k] = v.booleanValue === true;
  const companions = {};
  for (const [k, v] of Object.entries(f.companions?.mapValue?.fields || {})) {
    const n = parseInt(v.integerValue || '0', 10) || 0;
    if (n > 0) companions[k] = n;
  }
  return {
    id: String(d.name || '').split('/').pop(),
    title: f.title?.stringValue || '',
    location: f.location?.stringValue || '',
    status: f.status?.stringValue || '',
    date, deadline,
    expired: Date.now() > deadline,
    maxPlayers: f.maxPlayers?.integerValue ? parseInt(f.maxPlayers.integerValue, 10) : null,
    votes, companions,
    playerIds: (f.playerIds?.arrayValue?.values || []).map((v) => v.stringValue),
  };
}

function seatsTaken(sess) {
  let n = 0;
  for (const [pid, v] of Object.entries(sess.votes)) if (v) n += 1 + (sess.companions[pid] || 0);
  return n;
}

/** Các buổi đang ở trạng thái vote, buổi còn hạn xếp trước, rồi theo ngày. */
async function votingSessions(env, teamId) {
  const docs = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/sessions?pageSize=50`))?.documents || [];
  return docs.map(parseSessionDoc).filter((x) => x.status === 'voting')
    .sort((a, b) => (a.expired === b.expired ? a.date - b.date : (a.expired ? 1 : -1)));
}

/** Buổi đang mở vote gần nhất, hoặc null. Trả cả buổi đã quá hạn để báo cho đúng. */
async function openVoteSession(env, teamId) {
  const list = await votingSessions(env, teamId);
  return list.length ? list[0] : null;
}

// ----------------------------------------------------- ghi vote trực tiếp
const EMPTY_MENTION_TEXT = '👋 Em đây! Gõ "help" để xem cách dùng, "vote" xem buổi đang mở, "nước" xem giá nước, "quỹ" xem số dư.';
const FALLBACK_TEXT = '😅 Em chưa hiểu ý anh/chị. Gõ "help" để xem các lệnh, hoặc hỏi lại em bằng câu khác nhé.';

/** Token đăng nhập (ẩn danh) để webhook ghi vote vào Firestore theo rules. */
async function getBotIdToken(env) {
  if (env.BOT_REFRESH_TOKEN) {
    const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${env.FIREBASE_API_KEY}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: env.BOT_REFRESH_TOKEN }),
    });
    const data = await res.json();
    if (res.ok && data.id_token) return data.id_token;
    console.log('refresh token failed', res.status, JSON.stringify(data).slice(0, 200));
  }
  // Dự phòng: tạo phiên ẩn danh mới.
  const res = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${env.FIREBASE_API_KEY}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ returnSecureToken: true }),
  });
  const data = await res.json();
  if (res.ok && data.idToken) {
    console.log('anonymous signUp used; set BOT_REFRESH_TOKEN to', data.refreshToken ? 'the printed refresh token' : '?');
    return data.idToken;
  }
  return '';
}

async function loadPlayers(env, teamId) {
  const docs = await fsList(env, `teams/${encodeURIComponent(teamId)}/players`);
  return docs.map((d) => ({
    id: String(d.name || '').split('/').pop(),
    name: d.fields?.name?.stringValue || '',
    zaloId: d.fields?.zaloId?.stringValue || '',
    active: d.fields?.active?.booleanValue !== false,
  })).filter((p) => p.active);
}

/** Khớp người gửi: Zalo id đã lưu → tên chính xác → trọn cụm từ (duy nhất). */
function matchPlayerJs(players, fromId, fromName) {
  if (fromId) {
    const byId = players.find((p) => p.zaloId === fromId);
    if (byId) return byId;
  }
  const n = normalizeVi(fromName);
  if (!n) return null;
  const exact = players.filter((p) => normalizeVi(p.name) === n);
  if (exact.length === 1) return exact[0];
  const whole = (hay, needle) => new RegExp(`(^|\\s)${escapeRe(needle)}(\\s|$)`).test(hay);
  const partial = players.filter((p) => {
    const pn = normalizeVi(p.name);
    return pn && (whole(n, pn) || whole(pn, n));
  });
  return partial.length === 1 ? partial[0] : null;
}

/** Giá trị vote từ tin đã được readVoteShape coi là chắc chắn: { vote, seats }. */
function readVoteValue(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  t = t.replace(/@/g, ' ').replace(/[.,!?()\[\]:;]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (t === '-1') return { vote: false, seats: 0 };
  const num = /^\+?(\d+)(\s+(nguoi|ng|suat|slot))?$/.exec(t);
  if (num) {
    const n = parseInt(num[1], 10);
    return n > 0 ? { vote: true, seats: Math.min(n, MAX_VOTE_SEATS) } : { vote: false, seats: 0 };
  }
  if (VOTE_NO_RE.test(t)) return { vote: false, seats: 0 };
  const inline = /(^|\s)\+?(\d+)(\s|$)/.exec(t);
  const seats = inline ? Math.max(1, Math.min(parseInt(inline[2], 10), MAX_VOTE_SEATS)) : 1;
  return { vote: true, seats };
}

/** Ghi vote vào buổi bằng Firestore REST (token ẩn danh, rules cho phép votes/voteTimes/companions). */
async function recordVote(env, teamId, sess, player, voteShape, dateMs, players) {
  const { vote, seats } = readVoteValue(voteShape.original || '', voteShape.botName || '');
  const pid = player.id;
  const label = sess.title ? `"${sess.title}"` : 'buổi chơi';
  // Kiểm tra chỗ (tính cả đính kèm).
  if (vote && sess.maxPlayers != null) {
    const taken = seatsTaken(sess);
    const mine = sess.votes[pid] ? 1 + (sess.companions[pid] || 0) : 0;
    if (taken - mine + seats > sess.maxPlayers) {
      const left = Math.max(0, sess.maxPlayers - (taken - mine));
      return { status: 'full', text: `😢 ${player.name}: ${label} chỉ còn ${left} chỗ (giới hạn ${sess.maxPlayers}), em chưa ghi được ${seats} suất. ` +
        (left > 0 ? `Reply "${left}" để giữ ${left} chỗ nhé.` : 'Báo quản lý nếu cần thêm chỗ nhé.') };
    }
  }
  const idToken = await getBotIdToken(env);
  if (!idToken) return { status: 'no-auth', text: `📝 Em đã nhận vote của ${player.name}, sẽ cập nhật khi quản lý mở app.` };

  const fields = {
    votes: { mapValue: { fields: { [pid]: { booleanValue: vote } } } },
    voteTimes: { mapValue: { fields: { [pid]: { timestampValue: new Date(dateMs).toISOString() } } } },
  };
  if (vote && seats > 1) fields.companions = { mapValue: { fields: { [pid]: { integerValue: String(seats - 1) } } } };
  const mask = [`votes.${pid}`, `voteTimes.${pid}`, `companions.${pid}`]
    .map((m) => `updateMask.fieldPaths=${encodeURIComponent(m)}`).join('&');
  const url = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents` +
    `/teams/${encodeURIComponent(teamId)}/sessions/${encodeURIComponent(sess.id)}?${mask}`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}` },
    body: JSON.stringify({ fields }),
  });
  if (!res.ok) {
    console.log('recordVote failed', res.status, (await res.text()).slice(0, 300));
    return { status: `error-${res.status}`, text: `📝 Em đã nhận vote của ${player.name} nhưng chưa ghi được ngay, quản lý mở app là em cập nhật.` };
  }
  // Tính lại số chỗ sau khi ghi.
  const votes = { ...sess.votes, [pid]: vote };
  const companions = { ...sess.companions };
  if (vote && seats > 1) companions[pid] = seats - 1; else delete companions[pid];
  const after = seatsTaken({ votes, companions });
  const cap = sess.maxPlayers != null ? `/${sess.maxPlayers}` : '';
  const who = `${player.name}${vote && seats > 1 ? ` (+${seats - 1} đính kèm)` : ''}`;
  const text = vote
    ? `✅ ${who}: đi ${label} · đã có ${after}${cap} suất. Đổi ý thì reply lại nhé!`
    : `👌 ${player.name}: không đi ${label} · còn ${after}${cap} suất.`;
  return { status: 'recorded', text };
}

// --------------------------------------------------------- "@bot vote"
function isVoteListRequest(text, botName) {
  const t = cleanForCommand(text, botName);
  return /^(vote|ds vote|danh sach vote|list vote|vote nao|lich vote|buoi vote|dang vote|vote dang mo|xem vote|vote di)$/.test(t);
}

async function replyVoteList(env, teamId, chatId, token) {
  const list = await votingSessions(env, teamId);
  if (!list.length) {
    return replyText(env, teamId, chatId,
      '📭 Hiện không có vote nào đang mở. Quản lý tạo buổi mới trong app là em gửi vote ngay.', token);
  }
  const players = await loadPlayers(env, teamId);
  const nameOf = (id) => players.find((p) => p.id === id)?.name || 'Ẩn danh';
  const lines = ['📊 VOTE ĐANG MỞ'];
  for (const x of list.slice(0, 3)) {
    const yes = Object.entries(x.votes).filter(([, v]) => v).map(([pid]) =>
      `${nameOf(pid)}${x.companions[pid] ? ` (+${x.companions[pid]})` : ''}`);
    lines.push(`🏓 ${x.title || 'Buổi chơi'} · ${fmtDateTime(x.date)}${x.location ? ` · ${x.location}` : ''}`);
    lines.push(`   ${x.expired ? '⏰ Đã hết hạn vote, chờ chốt' : `⏰ Hạn vote ${fmtDateTime(x.deadline)}`}` +
      ` · ${seatsTaken(x)}${x.maxPlayers != null ? '/' + x.maxPlayers : ''} suất`);
    lines.push(`   ${yes.length ? '✅ ' + yes.join(', ') : 'Chưa ai vote'}`);
  }
  if (list.some((x) => !x.expired)) lines.push('👉 Reply 1 = đi, 2 = đi 2 người, 0 = không.');
  return replyText(env, teamId, chatId, lines.join('\n'), token);
}

/** Ghi tin vào hộp thư cho app xử lý. */
async function saveInbox(env, teamId, messageId, fields) {
  const docPath = `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents` +
    `/teams/${encodeURIComponent(teamId)}/zaloInbox/${encodeURIComponent(messageId)}`;
  const res = await fetch(`https://firestore.googleapis.com/v1/${docPath}?key=${env.FIREBASE_API_KEY}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ fields }),
  });
  if (!res.ok) {
    const err = await res.text();
    console.log('Firestore error', res.status, err);
    return { ok: false, response: json({ ok: false, firestore: res.status, error: err.slice(0, 500) }) };
  }
  return { ok: true };
}

/** Gửi một tin trả lời vào chat (đọc token của nhóm từ Firestore). */
async function replyText(env, teamId, chatId, text, knownToken) {
  let token = knownToken || '';
  if (!token) {
    const team = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=zaloBotToken`);
    token = team?.fields?.zaloBotToken?.stringValue || '';
  }
  if (!token) return json({ ok: true, reply: 'no-token' });
  const sent = await fetch(`${ZALO_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: text.slice(0, 2000) }),
  });
  let zalo = {};
  try { zalo = await sent.json(); } catch { /* bỏ qua */ }
  return json({ ok: true, reply: zalo?.ok === true ? 'sent' : 'failed' });
}

/** Các tên gọi (không dấu) của loại nước: tên đầy đủ, tên bỏ "nuoc", mã n<code>. */
async function drinkAliases(env, teamId) {
  const docs = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/drinkTypes?pageSize=100`))?.documents || [];
  const out = [];
  for (const d of docs) {
    const f = d.fields || {};
    if (f.active?.booleanValue === false) continue;
    const full = normalizeVi(f.name?.stringValue || '');
    if (full) out.push(full);
    const short = full.replace(/^nuoc\s+/, '').trim();
    if (short && short !== full) out.push(short);
    const code = parseInt(f.code?.integerValue || '0', 10) || 0;
    if (code) out.push(`n${code}`, `#${code}`);
  }
  return out;
}

/** Chuẩn hoá tin để so khớp lệnh: bỏ tên bot, bỏ @mention, bỏ dấu câu. */
function cleanForCommand(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  return t.replace(/@\S*/g, ' ').replace(/[?!.,:;]+/g, ' ').replace(/\s+/g, ' ').trim();
}

/**
 * Tin có dấu hiệu của lệnh ghi nước: chữ "nước", mã ngắn N1/#1, hoặc tên một
 * loại nước của nhóm. Phải kiểm trước khi coi là vote, vì "+1 N1" và "N1 0"
 * chứa đúng những từ khoá vote ("+1", "0").
 */
function hasDrinkMarker(t, aliases) {
  if (/(^|\s)(nuoc|drink)(\s|$)/.test(t)) return true;
  if (/(^|\s|,)(n\d+|#\d+)(\s|,|$)/.test(t)) return true;
  for (const a of aliases) {
    if (new RegExp(`(^|\\s|,)${escapeRe(a)}(\\s|,|$)`).test(t)) return true;
  }
  return false;
}

/**
 * Phân loại tin: 'empty' (chỉ @bot), 'command' (vote / lệnh nước → app xử lý), 'chat' (→ AI).
 * - Chỉ số ("1", "0", "+1") → vote.
 * - Có dấu "?" hoặc từ để hỏi → chat (kể cả có số).
 * - Có số kèm "nước" / mã N1 / tên loại nước → lệnh nước. Có số nhưng không kèm → chat
 *   (ví dụ "tăng cho anh Tiến 100k tiền quỹ" là câu nói, không phải lệnh).
 * - Ngắn (≤ 3 từ) có từ khoá vote → vote. Còn lại → chat.
 */
async function classify(env, teamId, text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  t = t.replace(/@\S*/g, ' ');
  const hasQuestionMark = t.includes('?');
  t = t.replace(/[?!.,:;]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!t) return 'empty';
  if (/^[+-]?\d+$/.test(t)) return 'command';
  if (hasQuestionMark || QUESTION_RE.test(t)) return 'chat';
  if (/\d/.test(t)) {
    return hasDrinkMarker(t, await drinkAliases(env, teamId)) ? 'command' : 'chat';
  }
  const words = t.split(' ').length;
  if (words <= 3 && (VOTE_NO_RE.test(t) || VOTE_YES_RE.test(t))) return 'command';
  return 'chat';
}

async function fsGet(env, path) {
  const base = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/`;
  const res = await fetch(base + path + (path.includes('?') ? '&' : '?') + `key=${env.FIREBASE_API_KEY}`);
  return res.ok ? res.json() : null;
}

const fmtDateTime = (ms) => {
  const d = new Date(ms + 7 * 3600 * 1000); // giờ Việt Nam
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getUTCHours())}:${p(d.getUTCMinutes())} ${p(d.getUTCDate())}/${p(d.getUTCMonth() + 1)}/${d.getUTCFullYear()}`;
};

/** Ngữ cảnh nhóm cho ChatGPT: buổi sắp tới, bảng giá nước. */
async function buildContext(env, teamId, teamName) {
  const lines = [`Tên nhóm: ${teamName || teamId}.`];
  try {
    const sess = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/sessions?pageSize=50`))?.documents || [];
    const now = Date.now();
    const parsed = sess.map((d) => {
      const f = d.fields || {};
      const date = Date.parse(f.date?.timestampValue || 0);
      const votes = f.votes?.mapValue?.fields || {};
      const yes = Object.values(votes).filter((v) => v.booleanValue === true).length;
      const deadline = f.voteDeadline?.timestampValue ? Date.parse(f.voteDeadline.timestampValue) : date;
      return {
        title: f.title?.stringValue || '', date, location: f.location?.stringValue || '',
        status: f.status?.stringValue || '', yes, deadline,
        max: f.maxPlayers?.integerValue ? parseInt(f.maxPlayers.integerValue, 10) : null,
        players: (f.playerIds?.arrayValue?.values || []).length,
        fee: parseInt(f.courtFee?.integerValue || '0', 10) || 0,
        creator: f.createdByName?.stringValue || '',
      };
    }).sort((a, b) => a.date - b.date);
    const upcoming = parsed.filter((x) => x.date >= now - 3 * 3600 * 1000).slice(0, 2);
    const last = parsed.filter((x) => x.date < now - 3 * 3600 * 1000).slice(-1);
    for (const x of upcoming) {
      lines.push(`Buổi sắp tới: ${x.title || 'buổi chơi'} lúc ${fmtDateTime(x.date)}` +
        `${x.location ? ' tại ' + x.location : ''}; ${x.status === 'voting' ? `đang vote, ${x.yes}${x.max ? '/' + x.max : ''} người đi, hạn vote ${fmtDateTime(x.deadline)}` : `đã chốt ${x.players} người`}` +
        `${x.fee ? `; tiền sân ${fmtVnd(x.fee)}` : ''}${x.creator ? `; người tạo ${x.creator}` : ''}.`);
    }
    for (const x of last) {
      lines.push(`Buổi gần nhất đã chơi: ${x.title || 'buổi chơi'} ${fmtDateTime(x.date)}, ${x.players} người.`);
    }
    if (!upcoming.length) lines.push('Chưa có buổi chơi nào sắp tới.');
  } catch { /* bỏ qua */ }
  try {
    const docs = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/drinkTypes?pageSize=100`))?.documents || [];
    const now = Date.now();
    const items = docs.map((d) => {
      const f = d.fields || {};
      if (f.active?.booleanValue === false) return null;
      const prices = (f.prices?.arrayValue?.values || []).map((v) => ({
        date: Date.parse(v.mapValue?.fields?.date?.timestampValue || 0),
        price: parseInt(v.mapValue?.fields?.price?.integerValue || '0', 10) || 0,
      })).sort((a, b) => a.date - b.date);
      let price = prices.length ? prices[0].price : 0;
      for (const p of prices) if (p.date <= now) price = p.price;
      const code = parseInt(f.code?.integerValue || '0', 10) || 0;
      return `${code ? 'N' + code + ' ' : ''}${f.name?.stringValue || ''} ${fmtVnd(price)}`;
    }).filter(Boolean);
    if (items.length) lines.push('Bảng giá nước: ' + items.join('; ') + '.');
  } catch { /* bỏ qua */ }
  return lines.join('\n');
}

/** Tin "lạ" → hỏi OpenAI và trả lời trong chat. Trả null nếu tin là vote/lệnh (để app xử lý). */
async function maybeChatReply(env, teamId, chatId, text, fromName) {
  const team = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloBotName&mask.fieldPaths=name`);
  const tf = team?.fields || {};
  const token = tf.zaloBotToken?.stringValue || '';
  const botName = tf.zaloBotName?.stringValue || '';
  if (!token) return null;
  const kind = await classify(env, teamId, text, botName);
  if (kind === 'empty') return json({ ok: true, ignored: 'empty-mention' });
  if (kind === 'command') return null;

  const work = chatReplyWork(env, teamId, chatId, text, fromName, token, botName, tf.name?.stringValue || '');
  if (typeof env.waitUntil === 'function') {
    // Zalo chờ phản hồi ngắn; AI có thể mất 10–30 giây → trả lời Zalo ngay, xử lý nền.
    env.waitUntil(work.catch((e) => console.log('chat work failed', String(e))));
    return json({ ok: true, chat: 'queued' });
  }
  return work;
}

async function chatReplyWork(env, teamId, chatId, text, fromName, token, botName, teamName) {
  const context = await buildContext(env, teamId, teamName);
  const system = [
    `Bạn là "${botName || 'Bot'}", trợ lý trong nhóm chat Zalo của một team pickleball, trả lời bằng tiếng Việt, thân thiện, NGẮN GỌN (tối đa 3 câu, không markdown).`,
    'Bạn không tự sửa được dữ liệu quỹ; việc ghi nhận chỉ qua các lệnh sau (hướng dẫn người chơi dùng khi phù hợp):',
    '- Vote đi chơi: reply tin vote của bot với "1" (đi), "2" (đi 2 người, kèm 1 người đính kèm, tiền tính vào người vote) hoặc "0" (không đi); đổi ý thì reply lại.',
    '- Xem danh sách nước và mã: gõ "nước". Ghi nước: "N1 2" hoặc "revive 2, suối 1"; "+1 N1" để cộng; nhập hộ: "@Tên N1 2".',
    '- Xem số dư cả nhóm: gõ "quỹ". "help" để xem hướng dẫn. Chi tiết tiền sân, tiền nước: app ' + APP_URL,
    'Xưng "em", gọi người chơi là "anh/chị" hoặc tên. Không nhắc tới Google/Gemini/OpenAI.',
    'Chỉ dựa vào ngữ cảnh dưới đây; không biết thì nói không biết và chỉ sang app hoặc quản lý nhóm. Không bịa số liệu.',
    'Ngữ cảnh nhóm:',
    context,
  ].join('\n');

  const llm = await askLLM(env, system, `${fromName ? fromName + ': ' : ''}${text}`);
  let answer = llm.answer || '';
  if (!answer && llm.quota) {
    // Hết hạn mức miễn phí → báo vui vẻ, kèm lúc có thể hỏi lại.
    answer = `😅 Em bị hỏi hơi nhiều, hết lượt rồi. ${llm.quota} Trong lúc chờ, vote, ghi nước, "nước", "quỹ", "help" vẫn chạy bình thường nhé!`;
  }
  if (!answer) answer = FALLBACK_TEXT; // AI lỗi vẫn phải trả lời người hỏi

  const sent = await fetch(`${ZALO_API}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: answer.slice(0, 2000) }),
  });
  let zalo = {};
  try { zalo = await sent.json(); } catch { /* bỏ qua */ }
  console.log(`chat → ${chatId}: ${zalo?.ok === true ? 'sent' : 'failed ' + (zalo?.description || '')} | q="${text.slice(0, 60)}" | a="${answer.slice(0, 80)}"`);
  return json({ ok: true, chat: zalo?.ok === true ? 'sent' : 'failed' });
}

/** Đổi retryDelay của Google ("37s", "1h2m") hoặc thông điệp quota thành câu hướng dẫn thời gian. */
function quotaHint(retryDelay, message) {
  let secs = 0;
  if (retryDelay) {
    const m = String(retryDelay).match(/(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?/);
    if (m) secs = (parseInt(m[1] || '0', 10) * 3600) + (parseInt(m[2] || '0', 10) * 60) + Math.ceil(parseFloat(m[3] || '0'));
  }
  const msg = String(message || '').toLowerCase();
  if (!secs && /(per day|daily|ngay|requests per day|generaterequestsperday)/.test(msg)) {
    return 'Em hết lượt của hôm nay rồi, hỏi lại sau 15:00 (giờ Việt Nam) nhé.';
  }
  if (!secs) secs = 60;
  if (secs >= 3600) return 'Hỏi lại em sau 15:00 (giờ Việt Nam) nhé.';
  if (secs >= 120) return `Thử lại sau khoảng ${Math.ceil(secs / 60)} phút nhé.`;
  return `Thử lại sau khoảng ${Math.max(secs, 10)} giây nhé.`;
}

/**
 * Hỏi mô hình ngôn ngữ: ưu tiên Gemini (miễn phí), dự phòng OpenAI nếu có key.
 * Trả về { answer } hoặc { quota: 'câu báo thời gian' } hoặc { error }.
 */
async function askLLM(env, system, user) {
  let quotaMsg = null;
  if (env.GEMINI_API_KEY) {
    const models = [...new Set([env.GEMINI_MODEL, 'gemini-3.8-flash', 'gemini-flash-latest', 'gemini-2.5-flash'].filter(Boolean))];
    for (const model of models) {
      try {
        const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${env.GEMINI_API_KEY}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            system_instruction: { parts: [{ text: system }] },
            contents: [{ role: 'user', parts: [{ text: user }] }],
            generationConfig: { temperature: 0.4, maxOutputTokens: 1024 },
          }),
        });
        const data = await res.json();
        if (res.ok) {
          const parts = data?.candidates?.[0]?.content?.parts || [];
          const answer = parts.map((p) => p.text || '').join('').trim();
          if (answer) return { answer };
          console.log('Gemini empty answer', JSON.stringify(data).slice(0, 300));
          return { error: 'empty' };
        }
        if (res.status === 404) { console.log('Gemini model not found', model); continue; }
        if (res.status === 503) {
          quotaMsg = 'Em đang quá tải một chút, thử lại sau 1 phút nhé.';
          console.log('Gemini 503 high demand', model);
          continue; // thử mẫu khác
        }
        if (res.status === 429) {
          const details = data?.error?.details || [];
          const retry = details.find((d) => d.retryDelay)?.retryDelay;
          quotaMsg = quotaHint(retry, data?.error?.message);
          console.log('Gemini quota', data?.error?.message, retry);
          break;
        }
        console.log('Gemini error', res.status, JSON.stringify(data).slice(0, 300));
        break;
      } catch (e) {
        console.log('Gemini fetch failed', String(e));
        break;
      }
    }
  }
  if (env.OPENAI_API_KEY) {
    try {
      const res = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.OPENAI_API_KEY}` },
        body: JSON.stringify({
          model: env.OPENAI_MODEL || 'gpt-4o-mini',
          temperature: 0.4,
          max_tokens: 220,
          messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
        }),
      });
      const data = await res.json();
      const answer = (data?.choices?.[0]?.message?.content || '').trim();
      if (res.ok && answer) return { answer };
      if (res.status === 429) quotaMsg = quotaMsg || quotaHint(null, data?.error?.message);
      console.log('OpenAI error', res.status, JSON.stringify(data).slice(0, 300));
    } catch (e) {
      console.log('OpenAI fetch failed', String(e));
    }
  }
  return quotaMsg ? { quota: quotaMsg } : { error: 'unavailable' };
}

// ------------------------------------------------------------- báo quỹ
const LOW_BALANCE = 10000; // dưới mức này → đánh dấu nạp thêm

function mayBeFundRequest(text) {
  const t = normalizeVi(text).replace(/[?!.,:;]+/g, ' ');
  return !/\d/.test(t) && /(^|\s)(quy|so du|bao quy|tien quy)(\s|$)/.test(t);
}
function isFundRequest(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  t = t.replace(/@\S*/g, ' ').replace(/[?!.,:;]+/g, ' ').replace(/\s+/g, ' ').trim();
  return /^(quy|so du|bao quy|tien quy|quy nhom|xem quy|quy team)$/.test(t);
}

async function fsList(env, path) {
  const out = [];
  let token = '';
  for (let i = 0; i < 20; i++) {
    const page = await fsGet(env, `${path}?pageSize=1000${token ? `&pageToken=${encodeURIComponent(token)}` : ''}`);
    if (!page) break;
    out.push(...(page.documents || []));
    token = page.nextPageToken || '';
    if (!token) break;
  }
  return out;
}

/** Dựng bảng số dư từ players + ledger. */
async function buildFundReport(env, teamId) {
  const teamDoc = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=name&mask.fieldPaths=bankInfo&mask.fieldPaths=qrImage&mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloGroupId`);
  const tf = teamDoc?.fields || {};
  const players = (await fsList(env, `teams/${encodeURIComponent(teamId)}/players`))
    .map((d) => ({ id: d.name.split('/').pop(), name: d.fields?.name?.stringValue || '', active: d.fields?.active?.booleanValue !== false }))
    .filter((p) => p.active);
  const ledger = await fsList(env, `teams/${encodeURIComponent(teamId)}/ledger`);
  const bal = {}; let common = 0;
  for (const d of ledger) {
    const f = d.fields || {};
    const amount = parseInt(f.amount?.integerValue || '0', 10) || 0;
    const pid = f.playerId?.stringValue;
    if (!pid) common += amount; else bal[pid] = (bal[pid] || 0) + amount;
  }
  const rows = players.map((p) => ({ ...p, balance: bal[p.id] || 0 })).sort((a, b) => a.balance - b.balance);
  const low = rows.filter((r) => r.balance < LOW_BALANCE);
  return {
    teamName: tf.name?.stringValue || teamId,
    bankInfo: tf.bankInfo?.stringValue || '',
    hasQr: !!tf.qrImage?.stringValue,
    token: tf.zaloBotToken?.stringValue || '',
    groupId: tf.zaloGroupId?.stringValue || '',
    rows, low, common,
  };
}

function fundReportText(r, { weekly }) {
  const d = new Date(Date.now() + 7 * 3600 * 1000);
  const today = `${String(d.getUTCDate()).padStart(2, '0')}/${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
  const lines = [`💰 ${weekly ? 'BÁO QUỸ TUẦN' : 'QUỸ'} – ${r.teamName} (${today})`];
  lines.push(`🏦 Quỹ chung: ${fmtVnd(r.common)}`);
  if (!r.rows.length) lines.push('Chưa có người chơi nào.');
  for (const x of r.rows) lines.push(`• ${x.name}: ${fmtVnd(x.balance)}${x.balance < LOW_BALANCE ? ' ⚠️ nạp thêm' : ''}`);
  if (r.low.length) {
    lines.push(`⚠️ ${r.low.length} bạn dưới ${fmtVnd(LOW_BALANCE)}: ${r.low.map((x) => x.name).join(', ')} – nạp quỹ giúp em nhé!`);
    if (r.bankInfo) lines.push(`🏦 ${r.bankInfo}`);
  } else if (weekly) {
    lines.push('✅ Ai cũng còn quỹ, tuần này êm!');
  }
  return lines.join('\n');
}

/** Gửi báo quỹ vào chat (chatId) hoặc nhóm mặc định; kèm ảnh QR nếu có người sắp hết quỹ. */
async function sendFundReport(env, teamId, chatId, { weekly }) {
  const r = await buildFundReport(env, teamId);
  const target = chatId || r.groupId;
  if (!r.token) return { status: 'no-token' };
  if (!target) return { status: 'no-group' };
  const text = fundReportText(r, { weekly });
  const sent = await fetch(`${ZALO_API}/bot${r.token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: target, text: text.slice(0, 2000) }),
  });
  let zalo = {};
  try { zalo = await sent.json(); } catch { /* bỏ qua */ }
  const out = { status: zalo?.ok === true ? 'sent' : `failed ${zalo?.description || ''}`, low: r.low.length, players: r.rows.length };
  // Có người sắp hết quỹ và có ảnh QR → gửi kèm QR (Zalo tải ảnh qua URL công khai của webhook).
  if (r.low.length && r.hasQr) {
    const photoUrl = `${env.PUBLIC_BASE_URL || 'https://pickleball-zalo-webhook.vercel.app'}/${encodeURIComponent(teamId)}?qr=1&v=${Date.now()}`;
    const ph = await fetch(`${ZALO_API}/bot${r.token}/sendPhoto`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: target, photo: photoUrl, caption: '📷 QR chuyển khoản nộp quỹ' }),
    });
    let pz = {};
    try { pz = await ph.json(); } catch { /* bỏ qua */ }
    out.qr = pz?.ok === true ? 'sent' : `failed ${pz?.description || ''}`;
    console.log('QR photo', out.qr);
  }
  console.log(`fund report → ${target}: ${out.status} (${out.players} người, ${out.low} sắp hết)`);
  return out;
}

function isHelpCommand(text) {
  const t = normalizeVi(text).replace(/@\S+/g, ' ').replace(/[?!.,]+/g, ' ');
  return (/(^|\s)(help|huong dan|tro giup|lenh|cach dung|hdsd)(\s|$)/.test(t) || /^menu$/.test(t.trim()))
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
