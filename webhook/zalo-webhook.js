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

    // ---- Cron kết quả vote: GET /cron-votes (GitHub Actions gọi mỗi 10 phút) → buổi vừa
    // hết hạn vote thì báo kết quả lên nhóm + nhắc bỏ ghim (Zalo Bot API không tự ghim/bỏ ghim được).
    if (parts[0] === 'cron-votes' && request.method === 'GET') {
      const authz = request.headers.get('Authorization') || '';
      const qsSecret = url.searchParams.get('secret') || '';
      if (env.CRON_SECRET && authz !== `Bearer ${env.CRON_SECRET}` && qsSecret !== env.CRON_SECRET) {
        return json({ ok: false, error: 'Forbidden' }, 403);
      }
      const teams = String(env.TEAM_IDS || env.TEAM_ID || '').split(',').map((x) => x.trim()).filter(Boolean);
      const results = [];
      for (const t of teams) results.push({ team: t, ...(await announceExpiredVotes(env, t)) });
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
    // ---- Lệnh từ app (bắt buộc đúng secret): ?action=remind → giục nạp quỹ kèm QR;
    // ?action=vote-result → báo kết quả vote của một buổi (&session=<id>).
    const action = url.searchParams.get('action') || '';
    if (action) {
      if (!secretOk) return json({ ok: false, error: 'Forbidden: sai X-Bot-Api-Secret-Token' }, 403);
      if (action === 'remind') return json({ ok: true, remind: await sendFundReport(env, teamId, null, { weekly: false, remind: true }) });
      if (action === 'vote-result') return json({ ok: true, result: await announceExpiredVotes(env, teamId, url.searchParams.get('session') || '', true) });
      return json({ ok: false, error: 'Bad action' }, 400);
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
    // Zalo Bot API không reply vào tin cụ thể được → mỗi câu trả lời trích lại tin đang
    // trả lời ở dòng đầu ("↩️ Tùng: "1"") cho rõ bot đang nói với ai, về tin nào.
    let quote = '';

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
    quote = quoteLine(fromName, text, botName);

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

    let voteShape = readVoteShape(text, botName);
    // Lệnh ghi nước cũng chứa từ khoá vote ("+1 N1", "N1 0") → không phải vote.
    const isDrinkCommand = /\d/.test(cleaned) && hasDrinkMarker(cleaned, await drinkAliases(env, teamId));

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

    // ---- Vote hộ: "@An 1 @Bình 0" (phần trước @ đầu tiên là của chính người gửi).
    if (!isDrinkCommand && hasOtherMention(text, botName)) {
      const players = await loadPlayers(env, teamId);
      const proxy = parseProxyVotesJs(text, botName, players);
      if (proxy) {
        const open = await openVoteSession(env, teamId);
        if (!open) return replyText(env, teamId, chat, NO_OPEN_VOTE_TEXT, token, quote);
        if (open.expired) return replyText(env, teamId, chat, expiredText(open), token, quote);
        const sender = matchPlayerJs(players, fromId, fromName);
        const lines = [];
        const entries = [];
        let selfUnknown = null;
        for (const a of proxy) {
          const who = a.isSelf ? (sender?.name || fromName || 'bạn') : (a.player?.name || a.nameText);
          if (a.error) { lines.push(a.isSelf ? a.error : `❓ ${who}: ${a.error}`); continue; }
          if (a.isSelf) {
            if (!sender) { selfUnknown = a; continue; }
            entries.push({ player: sender, vote: a.vote, seats: a.seats, by: '' });
          } else if (!a.player) {
            lines.push(`❓ Không tìm thấy người chơi "${a.nameText}". Thêm họ trong app rồi vote hộ lại nhé.`);
          } else {
            entries.push({ player: a.player, vote: a.vote, seats: a.seats, by: sender?.name || fromName });
          }
        }
        let r = { status: 'none', lines: [] };
        if (entries.length) r = await recordVotes(env, teamId, open, entries, dateMs);
        lines.push(...r.lines);
        console.log(`vote hộ (${entries.length}) → ${r.status}`);
        const writeFailed = !['recorded', 'full', 'none'].includes(r.status);
        if (writeFailed) {
          const saved = await saveInbox(env, teamId, messageId, inboxFields); // app ghi hộ toàn bộ
          if (!saved.ok) return saved.response;
        } else if (selfUnknown) {
          // Chỉ phần vote của chính người gửi (chưa có tên) vào hộp thư, tránh ghi lặp.
          const saved = await saveInbox(env, teamId, messageId, { ...inboxFields, text: s(selfUnknown.rawText) });
          if (!saved.ok) return saved.response;
          lines.push(`📝 Đã nhận vote của ${fromName || 'bạn'}\nTên chưa có trong danh sách, quản lý mở app là em thêm và ghi vote ngay.`);
        }
        return replyText(env, teamId, chat, lines.join('\n\n'), token, quote);
      }
      // Có @người khác mà không phải vote hộ ("@An đi không?") → câu nói với người
      // đó, không phải vote của người gửi → để AI trả lời.
      voteShape = { ...voteShape, definite: false, error: null };
    }

    // Gõ số sai ("10", "01", "0.1", "1,2,3"...) → báo lại ngay, không tính vote.
    if (!isDrinkCommand && voteShape.error) {
      console.log(`vote sai cu phap: "${text.slice(0, 40)}"`);
      return replyText(env, teamId, chat, voteShape.error, token, quote);
    }

    // ---- Lệnh ghi nước: app (máy quản trị) mới ghi được → vào hộp thư + báo đã nhận.
    if (isDrinkCommand) {
      const saved = await saveInbox(env, teamId, messageId, inboxFields);
      if (!saved.ok) return saved.response;
      return replyText(env, teamId, chat,
        `📝 Đã nhận lệnh nước của ${fromName || 'bạn'}\nEm sẽ ghi vào sổ và báo lại ngay khi quản lý mở app.`, token, quote);
    }

    // ---- Vote chắc chắn ("1", "2", "0", "đi", "không đi"...): ghi THẲNG vào buổi và xác nhận.
    if (voteShape.definite) {
      const open = await openVoteSession(env, teamId);
      if (!open) return replyText(env, teamId, chat, NO_OPEN_VOTE_TEXT, token, quote);
      if (open.expired) return replyText(env, teamId, chat, expiredText(open), token, quote);
      const players = await loadPlayers(env, teamId);
      const player = matchPlayerJs(players, fromId, fromName);
      if (!player) {
        // Người chưa có trong danh sách: app sẽ tự thêm rồi ghi vote → báo đã nhận.
        const saved = await saveInbox(env, teamId, messageId, inboxFields);
        if (!saved.ok) return saved.response;
        return replyText(env, teamId, chat,
          `📝 Đã nhận vote của ${fromName || 'bạn'}\nTên chưa có trong danh sách, quản lý mở app là em thêm và ghi vote ngay.`, token, quote);
      }
      const r = await recordVote(env, teamId, open, player, voteShape, dateMs);
      console.log(`vote → ${player.name}: ${r.status}`);
      // Không ghi được ngay (lỗi token/Firestore) → đưa vào hộp thư để app ghi hộ.
      if (r.status !== 'recorded' && r.status !== 'full') {
        const saved = await saveInbox(env, teamId, messageId, inboxFields);
        if (!saved.ok) return saved.response;
      }
      return replyText(env, teamId, chat, r.text, token, quote);
    }

    // ---- Còn lại là câu hỏi / trò chuyện → AI trả lời (không ghi hộp thư). AI lỗi vẫn trả lời.
    if (env.GEMINI_API_KEY || env.GROQ_API_KEY || env.OPENAI_API_KEY) {
      const r = await maybeChatReply(env, teamId, chat, text, fromName, quote);
      if (r) return r;
    }
    return replyText(env, teamId, chat, FALLBACK_TEXT, token, quote);
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
  '🏓 BOT QUỸ PICKLEBALL',
  '',
  '🗳 VOTE · reply tin vote: 1 = đi · 2 = đi 2 người · 0 = không',
  '   "@An 1" vote hộ · "vote" xem buổi đang mở',
  '🥤 NƯỚC · "nước" xem mã & giá · "N1 2" ghi · "+1 N1" cộng · "@An N1 2" nhập hộ',
  '💰 QUỸ · "quỹ" xem số dư cả nhóm',
  '💬 Hỏi gì cứ @bot, em trả lời',
  `📱 App: ${APP_URL}`,
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
    reply = '🥤 BẢNG GIÁ NƯỚC\n\n' +
      items.map((x) => `${x.code ? 'N' + x.code : '•'} · ${x.name} · ${fmtVnd(x.price)}`).join('\n') +
      `\n\n👉 Ghi nước: "N1 2" hoặc "${items[0].name} 2"\nNhiều loại: "N1 2, N2 1" · cộng thêm: "+1 N1" · nhập hộ: "@An N1 2"`;
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
  '📭 Dạ hiện chưa có buổi nào đang mở vote ạ.\nAnh/chị chờ quản lý tạo buổi rồi vote giúp em nhé ạ.';

function voteNumberErrorText(original) {
  return `🙏 Dạ em chưa hiểu "${String(original).trim()}" ạ.\nAnh/chị reply giúp em: 0 = không đi · 1 = đi · 2 = đi 2 người (kèm 1) · tối đa ${MAX_VOTE_SEATS} ạ.`;
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
  // Câu hỏi ("sân mấy người chơi em?", "có đi không?") không phải vote → để AI trả lời.
  if (/\?/.test(text) || QUESTION_RE.test(words)) return { definite: false, maybe: false, error: null };
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
  const docs = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/sessions?pageSize=50&orderBy=date%20desc`))?.documents || [];
  return docs.map(parseSessionDoc).filter((x) => x.status === 'voting')
    .sort((a, b) => (a.expired === b.expired ? a.date - b.date : (a.expired ? 1 : -1)));
}

/** Buổi đang mở vote gần nhất, hoặc null. Trả cả buổi đã quá hạn để báo cho đúng. */
async function openVoteSession(env, teamId) {
  const list = await votingSessions(env, teamId);
  return list.length ? list[0] : null;
}

// ----------------------------------------------------- ghi vote trực tiếp
const EMPTY_MENTION_TEXT = '👋 Dạ em đây ạ!\nAnh/chị gõ giúp em: "help" xem cách dùng · "vote" buổi đang mở · "nước" giá nước · "quỹ" số dư ạ.';
const FALLBACK_TEXT = '🙏 Dạ em xin lỗi, em chưa hiểu ý anh/chị ạ.\nAnh/chị gõ "help" để xem các lệnh, hoặc hỏi lại em bằng câu khác giúp em ạ.';

/** Token đăng nhập (ẩn danh) để webhook ghi vote vào Firestore theo rules. */
/**
 * Token đăng nhập để webhook ghi vote thẳng vào Firestore.
 *
 * CHỈ dùng BOT_REFRESH_TOKEN. Trước đây có đường dự phòng gọi `accounts:signUp`
 * khi thiếu biến này, nhưng nó tạo một tài khoản ẩn danh MỚI cho MỖI lượt vote:
 * tài khoản rác tích luỹ vĩnh viễn trong Firebase Auth, và `accounts:signUp`
 * bị giới hạn tần suất theo IP (Vercel dùng IP chung) nên đủ nhiều là vote lặng
 * lẽ rơi xuống đường hộp thư. Thiếu biến thì thà không ghi: tin vào hộp thư và
 * app ghi hộ khi quản lý mở - người vote vẫn nhận được lời báo đã nhận.
 *
 * Lấy giá trị cho BOT_REFRESH_TOKEN (chạy một lần, rồi đặt vào biến môi trường
 * Vercel; tài khoản ẩn danh này dùng lại mãi):
 *   curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=<FIREBASE_API_KEY>" \
 *     -H 'Content-Type: application/json' -d '{"returnSecureToken":true}' | python3 -m json.tool
 */
let cachedBotToken = null; // { token, refreshToken, expiresAt } - dùng lại trong cùng một instance

async function getBotIdToken(env) {
  const now = Date.now();
  if (!env.BOT_REFRESH_TOKEN) {
    cachedBotToken = null;
    console.log('BOT_REFRESH_TOKEN chưa đặt → không ghi vote thẳng được, tin vào hộp thư cho app xử lý.');
    return '';
  }
  // Đệm theo đúng refresh token đang dùng: đổi/thu hồi biến môi trường là
  // token đệm hết hiệu lực ngay, không phải chờ hết hạn.
  if (cachedBotToken && cachedBotToken.refreshToken === env.BOT_REFRESH_TOKEN &&
      cachedBotToken.expiresAt > now + 60_000) {
    return cachedBotToken.token;
  }
  const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${env.FIREBASE_API_KEY}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: env.BOT_REFRESH_TOKEN }),
  });
  const data = await res.json();
  if (res.ok && data.id_token) {
    const ttl = (parseInt(data.expires_in || '3600', 10) || 3600) * 1000;
    cachedBotToken = {
      token: data.id_token,
      refreshToken: env.BOT_REFRESH_TOKEN,
      expiresAt: now + ttl,
    };
    return data.id_token;
  }
  cachedBotToken = null;
  console.log('refresh token failed', res.status, JSON.stringify(data).slice(0, 200));
  return '';
}

async function loadPlayers(env, teamId) {
  const docs = await fsList(env, `teams/${encodeURIComponent(teamId)}/players`);
  return docs.map((d) => ({
    id: String(d.name || '').split('/').pop(),
    name: d.fields?.name?.stringValue || '',
    zaloId: d.fields?.zaloId?.stringValue || '',
    zaloName: d.fields?.zaloName?.stringValue || '',
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

function expiredText(open) {
  return `⏰ Dạ buổi ${open.title || 'chơi'} đã hết hạn vote lúc ${fmtDateTime(open.deadline)} ạ.\nEm xin phép không tính vote này. Anh/chị cần thêm chỗ thì nhắn quản lý giúp em nhé ạ.`;
}

function fieldSeg(pid) {
  // Đoạn id trong field path bọc backtick để id có ký tự lạ ("-", ":") vẫn hợp lệ.
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(pid) ? pid : '`' + pid.replace(/`/g, '\\`') + '`';
}

/** Ghi vote vào buổi bằng Firestore REST (token ẩn danh, rules cho phép votes/voteTimes/companions). */
async function recordVote(env, teamId, sess, player, voteShape, dateMs) {
  const { vote, seats } = readVoteValue(voteShape.original || '', voteShape.botName || '');
  const r = await recordVotes(env, teamId, sess, [{ player, vote, seats, by: '' }], dateMs);
  return { status: r.status, text: r.lines.join('\n\n') };
}

/**
 * Ghi một loạt vote (của người gửi và/hoặc vote hộ) trong MỘT lần PATCH.
 * entries: [{ player, vote, seats, by }] – by = tên người vote hộ ('' = tự vote).
 * Trả { status, lines }: status 'recorded' | 'full' (không ai ghi được vì hết chỗ)
 * | 'no-auth' | 'error-<mã>'.
 */
async function recordVotes(env, teamId, sess, entries, dateMs) {
  const label = sess.title ? `"${sess.title}"` : 'buổi chơi';
  const cap = sess.maxPlayers != null ? `/${sess.maxPlayers}` : '';
  const votes = { ...sess.votes };
  const companions = { ...sess.companions };
  const lines = [];
  const accepted = [];
  for (const e of entries) {
    const pid = e.player.id;
    const mine = votes[pid] ? 1 + (companions[pid] || 0) : 0;
    if (e.vote && sess.maxPlayers != null) {
      const taken = seatsTaken({ votes, companions });
      if (taken - mine + e.seats > sess.maxPlayers) {
        const left = Math.max(0, sess.maxPlayers - (taken - mine));
        lines.push(`😢 ${e.player.name}: HẾT CHỖ · ${label}\n👥 Còn ${left}/${sess.maxPlayers} chỗ, chưa ghi được ${e.seats} suất. ` +
          (left > 0 ? `Reply "${left}" để giữ ${left} chỗ nhé.` : 'Cần thêm chỗ thì báo quản lý nhé.'));
        continue;
      }
    }
    votes[pid] = e.vote;
    if (e.vote && e.seats > 1) companions[pid] = e.seats - 1; else delete companions[pid];
    const after = seatsTaken({ votes, companions });
    const by = e.by ? ` · ${e.by} vote hộ` : '';
    const who = `${e.player.name}${e.vote && e.seats > 1 ? ` +${e.seats - 1} đính kèm` : ''}`;
    const left = sess.maxPlayers != null ? ` · còn ${Math.max(0, sess.maxPlayers - after)} chỗ` : '';
    accepted.push({ ...e, text: e.vote
      ? `✅ ${who} ĐI ${label}${by}\n👥 ${after}${cap} suất${left}${e.by ? '' : ' · đổi ý thì reply lại'}`
      : `👌 ${e.player.name} KHÔNG ĐI ${label}${by}\n👥 ${after}${cap} suất${left}` });
  }
  if (!accepted.length) return { status: 'full', lines };

  const idToken = await getBotIdToken(env);
  const names = accepted.map((e) => e.player.name).join(', ');
  if (!idToken) {
    return { status: 'no-auth', lines: [...lines, `📝 Em đã nhận vote của ${names}, sẽ cập nhật khi quản lý mở app.`] };
  }
  const fields = { votes: { mapValue: { fields: {} } }, voteTimes: { mapValue: { fields: {} } }, companions: { mapValue: { fields: {} } } };
  const mask = [];
  for (const e of accepted) {
    const pid = e.player.id;
    fields.votes.mapValue.fields[pid] = { booleanValue: e.vote };
    fields.voteTimes.mapValue.fields[pid] = { timestampValue: new Date(dateMs).toISOString() };
    if (e.vote && e.seats > 1) fields.companions.mapValue.fields[pid] = { integerValue: String(e.seats - 1) };
    const seg = fieldSeg(pid);
    mask.push(`votes.${seg}`, `voteTimes.${seg}`, `companions.${seg}`);
  }
  if (!Object.keys(fields.companions.mapValue.fields).length) delete fields.companions;
  const qs = mask.map((m) => `updateMask.fieldPaths=${encodeURIComponent(m)}`).join('&');
  const url = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents` +
    `/teams/${encodeURIComponent(teamId)}/sessions/${encodeURIComponent(sess.id)}?${qs}`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}` },
    body: JSON.stringify({ fields }),
  });
  if (!res.ok) {
    console.log('recordVotes failed', res.status, (await res.text()).slice(0, 300));
    return { status: `error-${res.status}`, lines: [...lines,
      `📝 Em đã nhận vote của ${names} nhưng chưa ghi được ngay, quản lý mở app là em cập nhật.`] };
  }
  return { status: 'recorded', lines: [...lines, ...accepted.map((e) => e.text)] };
}

// ------------------------------------------------------------ vote hộ
const VOTE_VOCAB = new Set(['di', 'co', 'ok', 'oke', 'okie', 'okay', 'yes', 'y', 'tham', 'gia', 'join', 'choi',
  'dk', 'dang', 'ky', 'chot', 'len', 'vao', 'count', 'me', 'khong', 'khg', 'hok', 'hong', 'hem', 'ko', 'k',
  'no', 'nope', 'ban', 'nghi', 'bo', 'qua', 'huy', 'pass', 'x', 'nguoi', 'ng', 'suat', 'slot']);

/** Đuôi vote gọn: "1", "0", "+1", "2 người", "đi", "không đi", "ok 2" (≤ 3 từ, toàn từ khoá). */
function isVoteToken(rest) {
  const t = rest.trim();
  if (!t) return false;
  if (/^[+\-\d.,\s]+$/.test(t)) return true;
  const words = t.split(' ');
  if (words.length > 3) return false;
  return words.every((w) => VOTE_VOCAB.has(w) || /^\+?\d+$/.test(w));
}

/** Tin còn @mention người khác (ngoài bot) không. */
function hasOtherMention(text, botName) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  return /@\S/.test(t); // bỏ tên bot còn "@ 1" → không tính
}

/**
 * Tách tin vote hộ (khớp ZaloVoteSync.parseProxyVotes bên app):
 * "@An 1 @Nguyễn Văn Bình 0" → [{player An, vote true, seats 1}, {player Bình, vote false}];
 * phần trước @ đầu tiên (nếu có) là vote của chính người gửi (isSelf).
 * Trả null nếu không phải vote hộ (không có @tên kèm vote gọn, hoặc là câu hỏi).
 */
function parseProxyVotesJs(text, botName, players) {
  let t = normalizeVi(text);
  if (botName) t = t.split(normalizeVi(botName)).join(' ');
  if (t.includes('?')) return null;
  t = t.replace(/[.!:;]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!t.includes('@')) return null;
  const parts = t.split('@');
  const out = [];
  const mk = (player, nameText, rest, rawText) => {
    const shape = readVoteShapeInner(rest, rest);
    if (shape.error) return { player, nameText, isSelf: !nameText, error: shape.error, rawText };
    const v = readVoteValue(rest, '');
    return { player, nameText, isSelf: !nameText, vote: v.vote, seats: v.seats, error: null, rawText };
  };
  const head = parts[0].trim();
  if (head) {
    if (!isVoteToken(head)) return null; // phần đầu là câu nói → không phải vote hộ
    out.push(mk(null, '', head, head));
  }
  let valid = 0;
  for (const raw of parts.slice(1)) {
    const seg = raw.trim();
    if (!seg) continue;
    // Khớp dài nhất theo tên trong app HOẶC tên hiển thị Zalo đã nhớ (Zalo chèn
    // @mention bằng tên hiển thị, thường khác tên trong app).
    let best = null, bestLen = 0;
    for (const p of players) {
      for (const n of new Set([normalizeVi(p.name), normalizeVi(p.zaloName || '')])) {
        if (n && (seg === n || seg.startsWith(n + ' ')) && n.length > bestLen) { best = p; bestLen = n.length; }
      }
    }
    let nameText, rest;
    if (best) {
      nameText = best.name; rest = seg.slice(bestLen).trim();
    } else {
      const tokens = seg.split(' ');
      let i = 1;
      while (i < tokens.length && !isVoteToken(tokens.slice(i).join(' '))) i++;
      nameText = tokens.slice(0, i).join(' ');
      rest = tokens.slice(i).join(' ');
      if (nameText === 'bot' || nameText.startsWith('bot ')) {
        if (isVoteToken(rest)) { out.push(mk(null, '', rest, rest)); valid++; }
        continue;
      }
      // "@Nguyễn Văn An" với người chơi tên "An": khớp trọn từ, duy nhất.
      best = matchPlayerJs(players, '', nameText);
      if (best) nameText = best.name;
    }
    if (!isVoteToken(rest)) {
      out.push({ player: best, nameText, isSelf: false, rawText: seg,
        error: `chưa hiểu "${seg}". Gõ "@Tên 1" (đi), "@Tên 0" (không đi), "@Tên 2" (đi 2 người).` });
      continue;
    }
    out.push(mk(best, nameText, rest, seg));
    valid++;
  }
  return valid ? out : null;
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
  const blocks = ['📊 VOTE ĐANG MỞ'];
  for (const x of list.slice(0, 3)) {
    const yes = Object.entries(x.votes).filter(([, v]) => v).map(([pid]) =>
      `${nameOf(pid)}${x.companions[pid] ? ` (+${x.companions[pid]})` : ''}`);
    const seats = `${seatsTaken(x)}${x.maxPlayers != null ? '/' + x.maxPlayers : ''} suất`;
    blocks.push([
      `🏓 ${x.title || 'Buổi chơi'}`,
      `🕕 ${fmtWeekday(x.date)}${x.location ? ` · 📍 ${x.location}` : ''}`,
      x.expired ? `⏰ Đã hết hạn vote · chờ chốt` : `⏰ Hạn vote: ${fmtDateTime(x.deadline)}`,
      `👥 ${seats}${yes.length ? ': ' + yes.join(', ') : ' · chưa ai vote'}`,
    ].join('\n'));
  }
  if (list.some((x) => !x.expired)) blocks.push('👉 Reply tin vote: 1 = đi · 2 = đi 2 người · 0 = không');
  return replyText(env, teamId, chatId, blocks.join('\n\n'), token);
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
async function replyText(env, teamId, chatId, text, knownToken, quote = '') {
  if (quote) text = `${quote}\n\n${text}`;
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
  // "@An đi nhé": nói với người khác, không phải vote của người gửi → chat.
  if (hasOtherMention(text, botName)) return 'chat';
  const words = t.split(' ').length;
  if (words <= 3 && (VOTE_NO_RE.test(t) || VOTE_YES_RE.test(t))) return 'command';
  return 'chat';
}

async function fsGet(env, path) {
  const base = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/`;
  const res = await fetch(base + path + (path.includes('?') ? '&' : '?') + `key=${env.FIREBASE_API_KEY}`);
  return res.ok ? res.json() : null;
}

/** Dòng trích tin đang trả lời: ↩️ Tùng: "1" (bỏ phần @bot, cắt ngắn). */
function quoteLine(fromName, text, botName) {
  let t = String(text || '');
  if (botName) t = t.split(botName).join(' ');
  t = t.replace(/@\s+/g, '').replace(/\s+/g, ' ').trim();
  if (!t) return '';
  if (t.length > 40) t = t.slice(0, 38) + '…';
  return `↩️ ${fromName || 'Bạn'}: "${t}"`;
}

const WEEKDAYS = ['Chủ nhật', 'Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7'];
/** "Thứ 7 24/10 · 12:00" (giờ Việt Nam). */
const fmtWeekday = (ms) => {
  const d = new Date(ms + 7 * 3600 * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${WEEKDAYS[d.getUTCDay()]} ${p(d.getUTCDate())}/${p(d.getUTCMonth() + 1)} · ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
};

/**
 * Buổi vừa hết hạn vote (trong 24 giờ qua, đã gửi vote qua bot) mà chưa báo kết quả →
 * gửi kết quả lên nhóm + nhắc bỏ ghim, rồi ghi dấu vào teams/{id}/zaloVoteState/{sessionId}.
 * [onlySession] + [force]: app gọi để báo kết quả một buổi ngay (kể cả chưa hết hạn).
 */
async function announceExpiredVotes(env, teamId, onlySession = '', force = false) {
  const team = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloGroupId`);
  const token = team?.fields?.zaloBotToken?.stringValue || '';
  const groupId = team?.fields?.zaloGroupId?.stringValue || '';
  if (!token || !groupId) return { status: 'no-bot', announced: [] };
  const docs = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/sessions?pageSize=50&orderBy=date%20desc`))?.documents || [];
  const now = Date.now();
  const due = docs.map((d) => ({ ...parseSessionDoc(d), voteMsg: d.fields?.zaloVoteMessageId?.stringValue || '' }))
    .filter((x) => onlySession ? x.id === onlySession
      : (x.voteMsg && x.expired && now - x.deadline < 24 * 3600e3 && (x.status === 'voting' || x.status === 'closed')));
  if (!due.length) return { status: 'nothing-due', announced: [] };
  const players = await loadPlayers(env, teamId);
  const nameOf = (id) => players.find((p) => p.id === id)?.name || 'Ẩn danh';
  const announced = [];
  for (const x of due) {
    const statePath = `teams/${encodeURIComponent(teamId)}/zaloVoteState/${encodeURIComponent(x.id)}`;
    if (!force) {
      const st = await fsGet(env, statePath);
      if (st?.fields?.announcedAt) continue; // đã báo rồi
    }
    const yes = Object.entries(x.votes).filter(([, v]) => v).map(([pid]) => pid);
    const no = Object.entries(x.votes).filter(([, v]) => !v).map(([pid]) => nameOf(pid));
    const seats = seatsTaken(x);
    const cap = x.maxPlayers != null ? `/${x.maxPlayers}` : '';
    const blocks = [
      `🔒 ${x.expired ? 'HẾT HẠN VOTE' : 'KẾT QUẢ VOTE'} · ${x.title || 'Buổi chơi'}`,
      `🕕 ${fmtWeekday(x.date)}${x.location ? `\n📍 ${x.location}` : ''}`,
      yes.length
        ? [`✅ ĐI (${seats}${cap} suất)`, ...yes.map((pid) => `• ${nameOf(pid)}${x.companions[pid] ? ` (+${x.companions[pid]} đính kèm)` : ''}`)].join('\n')
        : '😢 Chưa có ai vote đi.',
    ];
    if (no.length) blocks.push(`❌ Không đi: ${no.join(', ')}`);
    if (x.maxPlayers != null && seats > x.maxPlayers) blocks.push(`⚠️ Vượt ${seats - x.maxPlayers} suất so với giới hạn, quản lý chốt danh sách trong app.`);
    blocks.push('📌 Quản lý bỏ ghim tin vote giúp em nhé. Danh sách chính thức xem trong app.');
    const sent = await fetch(`${ZALO_API}/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: groupId, text: blocks.join('\n\n').slice(0, 2000) }),
    });
    let zalo = {};
    try { zalo = await sent.json(); } catch { /* bỏ qua */ }
    const ok = zalo?.ok === true;
    if (ok) {
      await fetch(`https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${statePath}?key=${env.FIREBASE_API_KEY}`, {
        method: 'PATCH', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fields: { announcedAt: { timestampValue: new Date().toISOString() }, seats: { integerValue: String(seats) } } }),
      });
    }
    console.log(`vote result → ${x.title}: ${ok ? 'sent' : 'failed ' + (zalo?.description || '')}`);
    announced.push({ session: x.id, title: x.title, sent: ok });
  }
  return { status: 'ok', announced };
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
    const sess = (await fsGet(env, `teams/${encodeURIComponent(teamId)}/sessions?pageSize=50&orderBy=date%20desc`))?.documents || [];
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
async function maybeChatReply(env, teamId, chatId, text, fromName, quote = '') {
  const team = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloBotName&mask.fieldPaths=name`);
  const tf = team?.fields || {};
  const token = tf.zaloBotToken?.stringValue || '';
  const botName = tf.zaloBotName?.stringValue || '';
  if (!token) return null;
  const kind = await classify(env, teamId, text, botName);
  if (kind === 'empty') return json({ ok: true, ignored: 'empty-mention' });
  if (kind === 'command') return null;

  const work = chatReplyWork(env, teamId, chatId, text, fromName, token, botName, tf.name?.stringValue || '', quote);
  if (typeof env.waitUntil === 'function') {
    // Zalo chờ phản hồi ngắn; AI có thể mất 10–30 giây → trả lời Zalo ngay, xử lý nền.
    env.waitUntil(work.catch((e) => console.log('chat work failed', String(e))));
    return json({ ok: true, chat: 'queued' });
  }
  return work;
}

async function chatReplyWork(env, teamId, chatId, text, fromName, token, botName, teamName, quote = '') {
  const context = await buildContext(env, teamId, teamName);
  const system = [
    `Bạn là "${botName || 'Bot'}", em út giúp việc trong nhóm chat Zalo của một team pickleball. Trả lời bằng tiếng Việt, NGẮN GỌN (tối đa 3 câu, không markdown).`,
    'PHONG CÁCH BẮT BUỘC: lịch sự, lễ phép, khiêm tốn như em nhỏ nói với anh chị lớn tuổi. Luôn xưng "em", gọi người hỏi là "anh/chị" (hoặc "anh Tên"/"chị Tên" nếu biết tên). Mở đầu bằng "Dạ" và kết câu bằng "ạ" khi hợp ngữ cảnh. Dùng "giúp em", "nhờ anh/chị", "em xin phép", "em cảm ơn ạ". Tuyệt đối không nói trống không, không ra lệnh ("làm đi", "gõ đi"), không trêu chọc, không mỉa mai, không nói tục, không dùng từ suồng sã ("ok", "ờ", "ừ", "nhé" đứng một mình). Khi không làm được hoặc không biết thì xin lỗi nhẹ nhàng rồi chỉ cách khác. Khi bị trách thì nhận lỗi, không cãi.',
    'Bạn không tự sửa được dữ liệu quỹ; việc ghi nhận chỉ qua các lệnh sau (hướng dẫn người chơi dùng khi phù hợp):',
    '- Vote đi chơi: reply tin vote của bot với "1" (đi), "2" (đi 2 người, kèm 1 người đính kèm, tiền tính vào người vote) hoặc "0" (không đi); đổi ý thì reply lại. Vote hộ người khác: "@Tên 1" hoặc "@Tên 0", nhiều người trong một tin.',
    '- Xem danh sách nước và mã: gõ "nước". Ghi nước: "N1 2" hoặc "revive 2, suối 1"; "+1 N1" để cộng; nhập hộ: "@Tên N1 2".',
    '- Xem số dư cả nhóm: gõ "quỹ". "help" để xem hướng dẫn. Chi tiết tiền sân, tiền nước: app ' + APP_URL,
    'Không bao giờ nhắc mình là AI/mô hình nào (Google, Gemini, OpenAI, Groq, Llama, Qwen...); trả lời như một thành viên nhỏ tuổi của nhóm.',
    'Chỉ dựa vào ngữ cảnh dưới đây; không biết thì nói "dạ em chưa rõ" và xin phép chỉ sang app hoặc nhờ quản lý nhóm. Không bịa số liệu.',
    'Ví dụ giọng điệu đúng: "Dạ anh Tùng ơi, buổi Thứ 7 hiện có 6/8 suất ạ. Anh reply 1 giúp em để em ghi tên anh nhé ạ." / "Dạ em xin lỗi, phần này em chưa có số liệu ạ. Anh chị xem giúp em trong app hoặc hỏi quản lý nhóm ạ."',
    'Ngữ cảnh nhóm:',
    context,
  ].join('\n');

  const llm = await askLLM(env, system, `${fromName ? fromName + ': ' : ''}${text}`);
  let answer = llm.answer || '';
  if (!answer && llm.quota) {
    // Hết hạn mức miễn phí → báo vui vẻ, kèm lúc có thể hỏi lại.
    answer = `🙏 Dạ em xin lỗi anh/chị, hôm nay em được hỏi hơi nhiều nên tạm hết lượt trả lời ạ. ${llm.quota} Trong lúc chờ, vote, ghi nước, "nước", "quỹ", "help" vẫn chạy bình thường ạ.`;
  }
  if (!answer) answer = FALLBACK_TEXT; // AI lỗi vẫn phải trả lời người hỏi
  if (quote) answer = `${quote}\n\n${answer}`;

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
    return 'Anh/chị hỏi lại em sau 15:00 (giờ Việt Nam) giúp em ạ.';
  }
  if (!secs) secs = 60;
  if (secs >= 3600) return 'Anh/chị hỏi lại em sau 15:00 (giờ Việt Nam) giúp em ạ.';
  if (secs >= 120) return `Anh/chị thử lại giúp em sau khoảng ${Math.ceil(secs / 60)} phút ạ.`;
  return `Anh/chị thử lại giúp em sau khoảng ${Math.max(secs, 10)} giây ạ.`;
}

/**
 * Hỏi mô hình ngôn ngữ: ưu tiên Gemini (miễn phí), dự phòng OpenAI nếu có key.
 * Trả về { answer } hoặc { quota: 'câu báo thời gian' } hoặc { error }.
 */
/**
 * Hỏi AI miễn phí, lần lượt theo hạn mức còn lại (người dùng chọn Gemini trước):
 *  1. Gemini: Flash-Lite (hạn mức ngày cao) → Flash → Gemma,
 *  2. Groq (GROQ_API_KEY, miễn phí không cần thẻ): gpt-oss-120b → qwen3.8-27b,
 *  3. OpenAI hoặc API tương thích (OPENAI_BASE_URL) nếu đặt OPENAI_API_KEY.
 * Mỗi mẫu có hạn mức riêng → hết hạn mức mẫu này thì thử mẫu kế, hết sạch mới báo.
 * Không bao giờ nói trong chat là mẫu nào trả lời (chỉ ghi log).
 */
const GROQ_MODELS_DEFAULT = ['openai/gpt-oss-120b', 'qwen/qwen3.8-27b'];
const GEMINI_MODELS_DEFAULT = ['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite', 'gemini-flash-lite-latest',
  'gemini-3.8-flash', 'gemini-flash-latest', 'gemma-4-31b-it'];

async function askLLM(env, system, user) {
  let quotaMsg = null;

  // Các API kiểu OpenAI (chat/completions): Groq trước, OpenAI/tương thích để cuối.
  const openaiLike = async (name, key, base, models) => {
    for (const model of models) {
      try {
        const res = await fetch(`${base}/chat/completions`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
          body: JSON.stringify({
            model,
            temperature: 0.4,
            // Mẫu có "suy nghĩ" (gpt-oss) tốn token trước khi trả lời → để dư.
            max_tokens: 700,
            messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
          }),
        });
        const data = await res.json();
        const answer = (data?.choices?.[0]?.message?.content || '').trim();
        if (res.ok && answer) { console.log(`AI answered by ${name}/${model}`); return answer; }
        if (res.status === 429) quotaMsg = quotaMsg || quotaHint(null, data?.error?.message);
        console.log(`${name} ${model} error`, res.status, JSON.stringify(data).slice(0, 200));
      } catch (e) {
        console.log(`${name} ${model} fetch failed`, String(e));
      }
    }
    return '';
  };

  if (env.GEMINI_API_KEY) {
    const models = [...new Set([env.GEMINI_MODEL, ...GEMINI_MODELS_DEFAULT].filter(Boolean))];
    for (const model of models) {
      try {
        const isGemma = model.startsWith('gemma');
        // Gemma qua Gemini API không nhận system_instruction → gộp vào tin người dùng.
        const body = isGemma
          ? { contents: [{ role: 'user', parts: [{ text: `${system}\n\nTin nhắn: ${user}` }] }],
              generationConfig: { temperature: 0.4, maxOutputTokens: 512 } }
          : { system_instruction: { parts: [{ text: system }] },
              contents: [{ role: 'user', parts: [{ text: user }] }],
              generationConfig: { temperature: 0.4, maxOutputTokens: 1024 } };
        const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${env.GEMINI_API_KEY}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        const data = await res.json();
        if (res.ok) {
          const parts = data?.candidates?.[0]?.content?.parts || [];
          const answer = parts.filter((p) => !p.thought).map((p) => p.text || '').join('').trim();
          if (answer) { console.log(`AI answered by ${model}`); return { answer }; }
          console.log('Gemini empty answer', model, JSON.stringify(data).slice(0, 300));
          continue;
        }
        if (res.status === 429) {
          const details = data?.error?.details || [];
          const retry = details.find((d) => d.retryDelay)?.retryDelay;
          quotaMsg = quotaMsg || quotaHint(retry, data?.error?.message);
          console.log('Gemini quota', model, data?.error?.message, retry);
          continue; // mẫu khác còn hạn mức riêng
        }
        if (res.status === 503) quotaMsg = quotaMsg || 'Dạ em đang hơi quá tải, anh/chị thử lại giúp em sau 1 phút ạ.';
        console.log('Gemini error', model, res.status, JSON.stringify(data).slice(0, 200));
        continue;
      } catch (e) {
        console.log('Gemini fetch failed', model, String(e));
        continue;
      }
    }
  }

  // Gemini hết hạn mức/lỗi → Groq (miễn phí) rồi mới tới OpenAI.
  if (env.GROQ_API_KEY) {
    const models = [...new Set([env.GROQ_MODEL, ...GROQ_MODELS_DEFAULT].filter(Boolean))];
    const a = await openaiLike('Groq', env.GROQ_API_KEY, 'https://api.groq.com/openai/v1', models);
    if (a) return { answer: a };
  }

  if (env.OPENAI_API_KEY) {
    const base = (env.OPENAI_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
    const a = await openaiLike('OpenAI', env.OPENAI_API_KEY, base, [env.OPENAI_MODEL || 'gpt-4o-mini']);
    if (a) return { answer: a };
  }
  return quotaMsg ? { quota: quotaMsg } : { error: 'unavailable' };
}

// ------------------------------------------------------------- báo quỹ
const LOW_BALANCE_DEFAULT = 10000; // dùng khi nhóm chưa đặt lowBalanceThreshold trong app

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
  const teamDoc = await fsGet(env, `teams/${encodeURIComponent(teamId)}?mask.fieldPaths=name&mask.fieldPaths=bankInfo&mask.fieldPaths=qrImage&mask.fieldPaths=zaloBotToken&mask.fieldPaths=zaloGroupId&mask.fieldPaths=lowBalanceThreshold`);
  const tf = teamDoc?.fields || {};
  // Ngưỡng "sắp hết quỹ" lấy theo cài đặt của nhóm trong app (Cài đặt → Ngưỡng cảnh báo).
  const threshold = parseInt(tf.lowBalanceThreshold?.integerValue || tf.lowBalanceThreshold?.doubleValue || '0', 10) || LOW_BALANCE_DEFAULT;
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
  const low = rows.filter((r) => r.balance < threshold);
  return {
    teamName: tf.name?.stringValue || teamId,
    bankInfo: tf.bankInfo?.stringValue || '',
    hasQr: !!tf.qrImage?.stringValue,
    token: tf.zaloBotToken?.stringValue || '',
    groupId: tf.zaloGroupId?.stringValue || '',
    rows, low, common, threshold,
  };
}

function fundReportText(r, { weekly, remind }) {
  const d = new Date(Date.now() + 7 * 3600 * 1000);
  const today = `${String(d.getUTCDate()).padStart(2, '0')}/${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
  const bank = r.bankInfo ? `🏦 ${r.bankInfo.trim().split(/\r?\n/).join(' · ')}` : '';
  const lowBlock = r.low.length
    ? [`⚠️ CẦN NẠP THÊM (dưới ${fmtVnd(r.threshold)})`, ...r.low.map((x) => `• ${x.name}: ${fmtVnd(x.balance)}`)].join('\n')
    : '✅ Ai cũng còn quỹ, chưa ai cần nạp.';
  if (remind) {
    // Nút "Giục nạp quỹ" trong app: chỉ người sắp hết + cách chuyển khoản (QR gửi kèm sau).
    return [`📣 NHẮC NẠP QUỸ · ${r.teamName} (${today})`, lowBlock,
      r.low.length ? `👉 Chuyển khoản rồi nhắn quản lý ghi nhận giúp em nhé!${bank ? '\n' + bank : ''}` : ''].filter(Boolean).join('\n\n');
  }
  const all = r.rows.length
    ? ['📋 SỐ DƯ TỪNG NGƯỜI', ...r.rows.map((x) => `• ${x.name}: ${fmtVnd(x.balance)}${x.balance < r.threshold ? ' ⚠️' : ''}`)].join('\n')
    : 'Chưa có người chơi nào.';
  return [
    `💰 ${weekly ? 'BÁO QUỸ TUẦN' : 'QUỸ NHÓM'} · ${r.teamName} (${today})`,
    `🏦 Quỹ chung: ${fmtVnd(r.common)}`,
    lowBlock + (r.low.length && bank ? '\n' + bank : ''),
    all,
  ].join('\n\n');
}

async function sendFundReport(env, teamId, chatId, { weekly, remind = false }) {
  const r = await buildFundReport(env, teamId);
  const target = chatId || r.groupId;
  if (!r.token) return { status: 'no-token' };
  if (!target) return { status: 'no-group' };
  const text = fundReportText(r, { weekly, remind });
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
      body: JSON.stringify({ chat_id: target, photo: photoUrl, caption: `📷 QR chuyển khoản nạp quỹ${r.bankInfo ? ' · ' + r.bankInfo.trim().split(/\r?\n/).join(' · ') : ''}` }),
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
