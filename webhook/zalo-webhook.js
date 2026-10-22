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
    // Phải bỏ tên bot (có dấu cách) khỏi tin nên cần đọc zaloBotName từ Firestore.
    if (mayBeDrinkListRequest(text)) {
      const r = await replyDrinkList(env, teamId, String(chatId), text);
      if (r) return r;
    }

    // Tin không phải vote / lệnh nước (không có chữ số, không có từ vote) → hỏi ChatGPT
    // trả lời người chơi (nếu đã cấu hình OPENAI_API_KEY). Vote/nước vẫn vào hộp thư cho app.
    if ((env.GEMINI_API_KEY || env.OPENAI_API_KEY) && text.trim()) {
      const r = await maybeChatReply(env, teamId, String(chatId), text, msg.from?.display_name || '');
      if (r) return r;
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
  '• Nhập hộ: "@An N1 2 @Bình N2 1" (nhiều người một tin)',
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

function classify(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  t = t.replace(/@\S*/g, ' ');
  const hasQuestionMark = t.includes('?');
  t = t.replace(/[?!.,:;]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!t) return 'empty';
  if (/\d/.test(t)) return 'command'; // vote "1"/"0", lệnh nước "N1 2"
  if (hasQuestionMark || QUESTION_RE.test(t)) return 'chat'; // câu hỏi → ChatGPT/Gemini
  const words = t.split(' ').length;
  if (words <= 3 && (VOTE_NO_RE.test(t) || VOTE_YES_RE.test(t))) return 'command'; // "đi", "không đi"
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
  const kind = classify(text, botName);
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
    '- Vote đi chơi: reply tin vote của bot với "1" (đi) hoặc "0" (không đi); đổi ý thì reply lại.',
    '- Xem danh sách nước và mã: gõ "nước". Ghi nước: "N1 2" hoặc "revive 2, suối 1"; "+1 N1" để cộng; nhập hộ: "@Tên N1 2".',
    '- "help" để xem hướng dẫn. Số dư quỹ, tiền sân, tiền nước chi tiết: xem trong app ' + APP_URL,
    'Chỉ dựa vào ngữ cảnh dưới đây; không biết thì nói không biết và chỉ sang app hoặc quản lý nhóm. Không bịa số liệu.',
    'Ngữ cảnh nhóm:',
    context,
  ].join('\n');

  const llm = await askLLM(env, system, `${fromName ? fromName + ': ' : ''}${text}`);
  let answer = llm.answer || '';
  if (!answer && llm.quota) {
    // Hết hạn mức miễn phí → báo vui vẻ, kèm lúc có thể hỏi lại.
    answer = `😅 Bot hỏi hơi nhiều, hết lượt miễn phí rồi. ${llm.quota} Trong lúc chờ, các lệnh vote, ghi nước, "nước", "help" vẫn chạy bình thường nhé!`;
  }
  if (!answer) return null; // lỗi → để tin đi tiếp vào hộp thư như cũ

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
    return 'Hết lượt của hôm nay, hỏi lại sau 15:00 (giờ Việt Nam) khi Google reset nhé.';
  }
  if (!secs) secs = 60;
  if (secs >= 3600) return 'Hỏi lại sau 15:00 (giờ Việt Nam) khi Google reset lượt nhé.';
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
          quotaMsg = 'Google đang quá tải một chút, thử lại sau 1 phút nhé.';
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
