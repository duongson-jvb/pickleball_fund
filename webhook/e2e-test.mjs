/**
 * Kiểm thử webhook từ đầu đến cuối: gọi thẳng worker.fetch với Firestore, Firebase Auth
 * và Zalo giả lập. Nguyên tắc: AI CŨNG NHƯ NGƯỜI, ai @bot cũng phải được trả lời.
 *
 * Chạy:  node webhook/e2e-test.mjs      (không cần mạng; thoát mã 1 nếu có kịch bản sai)
 */
import worker from './zalo-webhook.js';

const TEAM = 'team-test-01';
const state = { sessions: [], players: [], sent: [], saved: [], patched: [], ai: 'ok', signUps: [], photos: [], voteState: [], announced: false };

const doc = (name, fields) => ({ name: `projects/p/databases/(default)/documents/${name}`, fields });
const priceField = (v) => ({
  arrayValue: { values: [{ mapValue: { fields: {
    date: { timestampValue: '2026-01-01T00:00:00Z' }, price: { integerValue: String(v) } } } }] },
});
const player = (id, name, zaloId = '', zaloName = '') => doc(`teams/${TEAM}/players/${id}`, {
  name: { stringValue: name }, active: { booleanValue: true },
  ...(zaloId ? { zaloId: { stringValue: zaloId } } : {}),
  ...(zaloName ? { zaloName: { stringValue: zaloName } } : {}),
});

function sessionDoc({ id = 's1', status = 'voting', dateOffsetH = 48, deadlineOffsetH = 24, title = 'Thứ 7',
  max = null, votes = {}, companions = {}, voteMsg = '', code = 0, players = [] } = {}) {
  const now = Date.now();
  const f = {
    status: { stringValue: status },
    title: { stringValue: title },
    date: { timestampValue: new Date(now + dateOffsetH * 3600e3).toISOString() },
    voteDeadline: { timestampValue: new Date(now + deadlineOffsetH * 3600e3).toISOString() },
    votes: { mapValue: { fields: Object.fromEntries(Object.entries(votes).map(([k, v]) => [k, { booleanValue: v }])) } },
    companions: { mapValue: { fields: Object.fromEntries(Object.entries(companions).map(([k, v]) => [k, { integerValue: String(v) }])) } },
  };
  if (max != null) f.maxPlayers = { integerValue: String(max) };
  if (code) f.code = { integerValue: String(code) };
  if (players.length) f.playerIds = { arrayValue: { values: players.map((p) => ({ stringValue: p })) } };
  if (voteMsg) f.zaloVoteMessageId = { stringValue: voteMsg };
  return doc(`teams/${TEAM}/sessions/${id}`, f);
}

globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  const ok = (body, status = 200) => new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json' } });
  if (u.includes('/sendMessage')) { state.sent.push(JSON.parse(opts.body).text); return ok({ ok: true, result: { message_id: 'x' } }); }
  if (u.includes('/sendPhoto')) { state.photos.push(JSON.parse(opts.body).photo); return ok({ ok: true, result: { message_id: 'p' } }); }
  if (u.includes('/zaloVoteState/')) {
    if (opts.method === 'PATCH') { state.voteState.push(u); return ok({}); }
    return state.announced ? ok({ fields: { announcedAt: { timestampValue: '2026-01-01T00:00:00Z' } } }) : ok({ error: { code: 404 } }, 404);
  }
  if (u.includes('/ledger')) return ok({ documents: [
    doc(`teams/${TEAM}/ledger/l1`, { playerId: { stringValue: 'p-an' }, amount: { integerValue: '5000' } }),
    doc(`teams/${TEAM}/ledger/l2`, { playerId: { stringValue: 'p-binh' }, amount: { integerValue: '90000' } }),
    doc(`teams/${TEAM}/ledger/l3`, { amount: { integerValue: '200000' } }),
  ] });
  if (u.includes('securetoken.googleapis.com')) return ok({ id_token: 'idtok' });
  if (u.includes('/drinkTypes')) {
    return ok({ documents: [
      doc(`teams/${TEAM}/drinkTypes/d1`, { name: { stringValue: 'Revive' }, code: { integerValue: '1' }, active: { booleanValue: true }, prices: priceField(15000) }),
      doc(`teams/${TEAM}/drinkTypes/d2`, { name: { stringValue: 'Nước suối' }, code: { integerValue: '2' }, active: { booleanValue: true }, prices: priceField(5000) }),
    ] });
  }
  if (u.includes('/players')) return ok({ documents: state.players });
  if (u.includes('/sessions/') && opts.method === 'PATCH') {
    if (!(opts.headers?.Authorization || '').startsWith('Bearer ')) return ok({ error: 'no auth' }, 403);
    if (state.patchFail) return ok({ error: { code: 403, message: 'PERMISSION_DENIED' } }, 403);
    state.patched.push({ url: u, body: JSON.parse(opts.body) });
    return ok({});
  }
  if (u.includes('/sessions')) return ok({ documents: state.sessions });
  if (u.includes('/zaloInbox/')) {
    const f = JSON.parse(opts.body).fields;
    state.saved.push(f.text.stringValue);
    state.savedSession = f.sessionId?.stringValue || '';
    return ok({});
  }
  if (u.includes('generativelanguage')) {
    state.aiPrompt = opts.body || '';
    if (state.ai === 'down') return ok({ error: { code: 500, message: 'boom' } }, 500);
    return ok({ candidates: [{ content: { parts: [{ text: 'Dạ em đây ạ.' }] } }] });
  }
  if (u.includes('accounts:signUp')) {
    state.signUps.push(u);
    return ok({ idToken: 'anon', refreshToken: 'anon-rt' });
  }
  if (u.includes('/documents/teams/')) {
    return ok(doc(`teams/${TEAM}`, {
      zaloBotName: { stringValue: 'Bot PickleBall JVB' },
      zaloBotToken: { stringValue: '250:abc' },
      name: { stringValue: 'Team' },
      zaloGroupId: { stringValue: 'g1' },
      bankInfo: { stringValue: 'TCB 123' },
      qrImage: { stringValue: 'AAAA' },
      lowBalanceThreshold: { integerValue: '50000' },
    }));
  }
  return ok({});
};

const env = { FIREBASE_PROJECT_ID: 'p', FIREBASE_API_KEY: 'k', GEMINI_API_KEY: 'g', TEAM_ID: TEAM, BOT_REFRESH_TOKEN: 'rt' };
const log = [];
let fails = 0;

async function send({ text, caption, from = { id: 'z1', display_name: 'An' } }) {
  state.sent = []; state.saved = []; state.patched = []; state.signUps = [];
  const message = { message_id: 'm' + Math.random(), date: Math.floor(Date.now() / 1000), chat: { id: 'g1', chat_type: 'GROUP' }, from };
  if (text !== undefined) message.text = text;
  if (caption !== undefined) message.caption = caption;
  const res = await worker.fetch(new Request(`https://h/${TEAM}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ message }),
  }), env);
  await res.json();
  await new Promise((r) => setTimeout(r, 20));
  return { sent: [...state.sent], saved: [...state.saved], patched: [...state.patched], signUps: [...state.signUps] };
}

/**
 * want: { reply: 'đoạn chữ', inbox: true/false, patched: true/false }
 * Mọi kịch bản đều phải có trả lời (reply) – đó là nguyên tắc.
 */
async function check(label, msg, want) {
  const r = await send(msg);
  const problems = [];
  if (!r.sent.length) problems.push('KHÔNG TRẢ LỜI');
  else if (want.reply && !r.sent.join('\n').includes(want.reply)) problems.push(`trả lời thiếu "${want.reply}"`);
  if (want.inbox && !r.saved.length) problems.push('phải vào hộp thư');
  if (!want.inbox && r.saved.length) problems.push('không được vào hộp thư');
  if (want.patched && !r.patched.length) problems.push('phải ghi vote vào buổi');
  if (!want.patched && r.patched.length) problems.push('không được ghi vote');
  const pass = problems.length === 0;
  if (!pass) fails++;
  log.push(`${pass ? 'OK  ' : 'SAI '} ${label.padEnd(40)} ` +
    `${r.sent.length ? `"${r.sent[0].slice(0, 46).replace(/\n/g, ' ')}"` : '(im lặng)'}` +
    `${r.saved.length ? ' · hộp thư' : ''}${r.patched.length ? ' · ghi vote' : ''}` +
    `${pass ? '' : '  ← ' + problems.join('; ')}`);
  return r;
}

const AN = 'z1', BINH = 'z2';
state.players = [player('p-an', 'An', AN), player('p-binh', 'Bình', BINH, 'Binh Dep Trai'), player('p-tung', 'Tùng')];

console.log('— Có buổi đang mở vote (giới hạn 4) —');
state.sessions = [sessionDoc({ max: 4, votes: { 'p-binh': true }, companions: { 'p-binh': 1 } })];
await check('vote "1" (người đã biết)', { text: '1' }, { reply: '✅ An ĐI', patched: true });
await check('vote "@Bot PickleBall JVB 1" (mention bot)', { text: '@Bot PickleBall JVB 1' }, { reply: '✅ An ĐI', patched: true });
const r2 = await check('vote "2" (kèm 1)', { text: '2' }, { reply: '+1 đính kèm', patched: true });
// id người chơi có dấu "-" → field path trong updateMask phải bọc backtick (`p-an`).
if (!r2.patched.every((p) => p.url.includes(encodeURIComponent('votes.`p-an`')))) {
  fails++; log.push('SAI  updateMask thiếu backtick cho id có dấu "-"');
}
state.patchFail = true;
await check('ghi vote lỗi → hộp thư + báo đã nhận', { text: '1' }, { reply: 'chưa ghi được ngay', inbox: true });
state.patchFail = false;
await check('vote "0"', { text: '0' }, { reply: '👌 An KHÔNG ĐI', patched: true });
await check('vote "3" vượt chỗ (còn 2)', { text: '3' }, { reply: 'Còn 2/4 chỗ' });
await check('vote câu ngắn "cho em đi với"', { text: 'cho em đi với' }, { reply: '✅ An ĐI', patched: true });
const TUNG = { id: 'z9', display_name: 'Tùng' };
const px = await check('vote hộ "@An 1" (Tùng vote hộ)', { text: '@Bot PickleBall JVB @An 1', from: TUNG }, { reply: '✅ An ĐI "Thứ 7" · Tùng vote hộ', patched: true });
if (!px.sent.join('\n').includes('Tùng')) { fails++; log.push('SAI  vote hộ phải ghi tên người vote hộ'); }
const px2 = await check('vote hộ nhiều người "@Bình 0 @An 2"', { text: '@Bình 0 @An 2', from: TUNG }, { reply: '👌 Bình KHÔNG ĐI', patched: true });
if (!px2.sent.join('\n').includes('An +1 đính kèm')) { fails++; log.push('SAI  vote hộ "@An 2" phải ra +1 đính kèm'); }
if (!(px2.patched.length === 1 && px2.patched[0].url.includes('p-binh') && px2.patched[0].url.includes('p-an'))) { fails++; log.push('SAI  vote hộ nhiều người phải ghi trong MỘT lần PATCH'); }
await check('vote hộ + tự vote "1 @An 0"', { text: '1 @An 0', from: TUNG }, { reply: '✅ Tùng ĐI', patched: true });
await check('vote hộ theo tên hiển thị Zalo đã nhớ "@Binh Dep Trai 1"', { text: '@Binh Dep Trai 1', from: TUNG }, { reply: '✅ Bình ĐI', patched: true });
await check('vote hộ tên dài chứa tên app "@Nguyễn Văn An 0"', { text: '@Nguyễn Văn An 0', from: TUNG }, { reply: '👌 An KHÔNG ĐI', patched: true });
await check('vote hộ tên lạ', { text: '@Người Lạ 1', from: TUNG }, { reply: 'Không tìm thấy người chơi "nguoi la"' });
await check('vote hộ số sai "@An 10"', { text: '@An 10', from: TUNG }, { reply: 'em chưa hiểu' });
await check('vote hộ vượt chỗ "@An 3" (còn 2)', { text: '@An 3', from: TUNG }, { reply: 'Còn 2/4 chỗ' });
await check('"@An đi không?" là câu hỏi → AI', { text: '@An đi không?', from: TUNG }, { reply: 'Dạ em đây' });
await check('"@An đi nhé" ngắn có từ khoá nhưng nói với người khác → AI', { text: '@An đi nhé', from: TUNG }, { reply: 'Dạ em đây' });
await check('"@An mai đi sớm nhé" là câu nói → AI', { text: '@An mai đi sớm nhé anh ơi', from: TUNG }, { reply: 'Dạ em đây' });
const px3 = await check('người lạ tự vote + vote hộ "1 @An 1"', { text: '1 @An 1', from: { id: 'z8', display_name: 'Người Mới' } }, { reply: '✅ An ĐI', inbox: true, patched: true });
if (!(px3.saved.length === 1 && px3.saved[0] === '1')) { fails++; log.push(`SAI  hộp thư chỉ được chứa phần tự vote "1", đang là ${JSON.stringify(px3.saved)}`); }
if (!px3.sent.join('\n').includes('chưa có trong danh sách')) { fails++; log.push('SAI  phải báo người gửi chưa có tên'); }
await check('khớp theo tên hiển thị', { text: '1', from: { id: 'z9', display_name: 'Tùng' } }, { reply: '✅ Tùng ĐI', patched: true });
await check('người lạ vote → hộp thư + báo', { text: '1', from: { id: 'z8', display_name: 'Người Mới' } }, { reply: 'chưa có trong danh sách', inbox: true });
await check('số sai "10"', { text: '10' }, { reply: 'em chưa hiểu' });
await check('số sai "1,2,3"', { text: '1,2,3' }, { reply: 'em chưa hiểu' });
await check('lệnh nước "n1 2" → hộp thư + báo', { text: 'n1 2' }, { reply: 'Đã nhận lệnh nước', inbox: true });
await check('lệnh nước "+1 n1"', { text: '+1 n1' }, { reply: 'Đã nhận lệnh nước', inbox: true });
await check('xem danh sách nước', { text: 'nước' }, { reply: 'BẢNG GIÁ NƯỚC' });
await check('hướng dẫn', { text: '@bot help' }, { reply: 'BOT QUỸ PICKLEBALL' });
await check('"vote" → danh sách vote đang mở', { text: '@Bot PickleBall JVB vote' }, { reply: 'VOTE ĐANG MỞ' });
await check('chuyện phiếm → AI', { text: 'thời tiết đẹp nhỉ' }, { reply: 'Dạ em đây' });
await check('câu hỏi có từ khoá vote "sân mấy người chơi em?" → AI', { text: 'sân mấy người chơi em?' }, { reply: 'Dạ em đây' });
await check('"có đi không?" → AI, không ghi vote', { text: 'có đi không?' }, { reply: 'Dạ em đây' });
await check('câu dài có "oke" KHÔNG phải vote', { text: 'anh Sơn bảo anh oke rồi em' }, { reply: 'Dạ em đây' });
await check('câu có số "100k" → AI', { text: 'tăng cho anh Tiến 100k tiền quỹ' }, { reply: 'Dạ em đây' });
await check('chỉ @bot, không nội dung', { text: '@Bot PickleBall JVB' }, { reply: 'em đây' });
state.ai = 'down';
await check('AI lỗi vẫn trả lời', { text: 'thời tiết đẹp nhỉ' }, { reply: 'em chưa hiểu ý' });
state.ai = 'ok';

{
  const q = await send({ text: '1' });
  if (!q.sent[0]?.startsWith('↩️ An: "1"\n\n')) { fails++; log.push(`SAI  trả lời phải trích tin đang trả lời, đang là ${JSON.stringify(q.sent[0]?.slice(0, 30))}`); }
  else log.push('OK   trả lời trích lại tin đang trả lời (↩️ An: "1")');
}

console.log('\n— Route cho app/cron: giục nạp quỹ, kết quả vote hết hạn —');
{
  state.sent = []; state.voteState = [];
  const res = await worker.fetch(new Request(`https://h/${TEAM}?action=remind`, { method: 'POST', headers: { 'X-Bot-Api-Secret-Token': 'sec' } }), { ...env, ZALO_SECRET: 'sec' });
  const body = await res.json();
  const okR = body.ok && state.sent[0]?.includes('NHẮC NẠP QUỸ') && state.photos.length === 1;
  if (!okR) fails++;
  log.push(`${okR ? 'OK  ' : 'SAI '} ${'?action=remind → nhắc + QR'.padEnd(40)} "${(state.sent[0] || '(im lặng)').slice(0, 46).replace(/\n/g, ' ')}"${state.photos.length ? ' · QR' : ''}`);
  const bad = await worker.fetch(new Request(`https://h/${TEAM}?action=remind`, { method: 'POST' }), { ...env, ZALO_SECRET: 'sec' });
  if (bad.status !== 403) { fails++; log.push('SAI  ?action=remind thiếu secret phải 403'); } else log.push('OK   ?action=remind thiếu secret → 403');

  state.sent = []; state.photos = []; state.voteState = [];
  state.sessions = [sessionDoc({ id: 's9', deadlineOffsetH: -1, dateOffsetH: 2, votes: { 'p-an': true, 'p-binh': false }, companions: { 'p-an': 1 }, max: 4, voteMsg: 'm1' })];
  const cr = await worker.fetch(new Request('https://h/cron-votes', { headers: { Authorization: 'Bearer cs' } }), { ...env, CRON_SECRET: 'cs' });
  const cb = await cr.json();
  const okC = cb.ok && state.sent[0]?.includes('HẾT HẠN VOTE') && state.sent[0].includes('An (+1 đính kèm)') && state.sent[0].includes('Không đi: Bình') && state.voteState.length === 1;
  if (!okC) fails++;
  log.push(`${okC ? 'OK  ' : 'SAI '} ${'/cron-votes → báo kết quả + ghi dấu'.padEnd(40)} "${(state.sent[0] || '(im lặng)').slice(0, 46).replace(/\n/g, ' ')}"`);
  state.sent = []; state.voteState = []; state.announced = true;
  await (await worker.fetch(new Request('https://h/cron-votes', { headers: { Authorization: 'Bearer cs' } }), { ...env, CRON_SECRET: 'cs' })).json();
  if (state.sent.length) { fails++; log.push('SAI  /cron-votes đã báo rồi thì không báo lại'); } else log.push('OK   /cron-votes không báo lại buổi đã báo');
  state.announced = false;

  // Buổi app đã tự chốt (giới hạn 1): Tùng vote "đi" nhưng bị cắt, An có tên
  // trong danh sách dù vote cũ là "không". Kết quả phải theo danh sách chơi.
  state.sent = []; state.voteState = [];
  state.sessions = [sessionDoc({ id: 's8', status: 'closed', deadlineOffsetH: -1, dateOffsetH: 2, max: 1, voteMsg: 'm2',
    votes: { 'p-an': false, 'p-tung': true }, players: ['p-an'] })];
  await (await worker.fetch(new Request('https://h/cron-votes', { headers: { Authorization: 'Bearer cs' } }), { ...env, CRON_SECRET: 'cs' })).json();
  const msg = state.sent[0] || '';
  const okL = msg.includes('ĐI (1/1 suất)') && msg.includes('• An') && !msg.includes('• Tùng') && !msg.includes('Không đi: An')
    && msg.includes('Hết chỗ: Tùng');
  if (!okL) fails++;
  log.push(`${okL ? 'OK  ' : 'SAI '} ${'/cron-votes buổi đã chốt: theo danh sách'.padEnd(40)} "${msg.slice(0, 46).replace(/\n/g, ' ')}"`);
}

console.log('\n— Không có buổi nào đang mở vote —');
state.sessions = [sessionDoc({ status: 'closed' })];
await check('vote "1"', { text: '1' }, { reply: 'chưa có buổi nào đang mở vote' });
await check('"vote" → báo không có', { text: 'vote' }, { reply: 'không có vote nào đang mở' });
await check('ghi nước vẫn chạy', { text: 'n1 2' }, { reply: 'Đã nhận lệnh nước', inbox: true });

console.log('\n— Buổi đang vote nhưng đã hết hạn —');
state.sessions = [sessionDoc({ deadlineOffsetH: -2, dateOffsetH: -1 })];
await check('vote "1"', { text: '1' }, { reply: 'hết hạn vote' });
await check('"vote" vẫn liệt kê kèm "hết hạn"', { text: 'vote' }, { reply: 'Đã hết hạn vote' });

console.log('\n— Ảnh kèm chú thích (nội dung ở caption) —');
state.sessions = [sessionDoc({ status: 'closed' })];
await check('caption "n1 2"', { caption: 'n1 2' }, { reply: 'Đã nhận lệnh nước', inbox: true });

console.log('\n— Nhiều buổi cùng mở vote (mã buổi B1/B2) —');
state.sessions = [
  sessionDoc({ id: 's1', code: 1, title: 'Thứ 5', dateOffsetH: 48, deadlineOffsetH: 24 }),
  sessionDoc({ id: 's2', code: 2, title: 'Chủ nhật', dateOffsetH: 120, deadlineOffsetH: 96 }),
];
/** Kiểm tra vote được ghi vào đúng buổi. */
async function checkInto(label, msg, sessionId, want) {
  const r = await check(label, msg, want);
  if (!r.patched.some((p) => p.url.includes(`/sessions/${sessionId}?`))) {
    fails++;
    log[log.length - 1] += `  ← phải ghi vào buổi ${sessionId}`;
  }
  return r;
}
await checkInto('"1" trống → buổi gần nhất', { text: '1' }, 's1',
  { reply: 'ĐI B1 "Thứ 5"', patched: true });
await checkInto('"B2 1" → buổi Chủ nhật', { text: 'B2 1' }, 's2',
  { reply: 'ĐI B2 "Chủ nhật"', patched: true });
await checkInto('"B2 0" → không đi buổi Chủ nhật', { text: 'B2 0' }, 's2',
  { reply: 'KHÔNG ĐI B2 "Chủ nhật"', patched: true });
await checkInto('"B2 2" → đi 2 người buổi Chủ nhật', { text: 'B2 2' }, 's2',
  { reply: '+1 đính kèm', patched: true });
// Mã không đang mở (buổi vừa chốt / gõ nhầm): không được tính sang buổi gần nhất.
await check('mã lạ "B9 1" → báo, không ghi vào buổi khác', { text: 'B9 1' },
  { reply: 'không có buổi B9 đang mở' });
await check('"B10 1" không bị coi là gõ sai số suất', { text: 'B10 1' },
  { reply: 'không có buổi B10 đang mở' });
await checkInto('vote hộ "B2 @An 1"', { text: 'B2 @An 1', from: { id: 'z9', display_name: 'Tùng' } },
  's2', { reply: 'ĐI B2 "Chủ nhật" · Tùng vote hộ', patched: true });
await check('"B2 10" vẫn báo nhập sai', { text: 'B2 10' }, { reply: 'chưa hiểu' });
await check('"vote" liệt kê kèm mã buổi', { text: 'vote' }, { reply: '[B2] Chủ nhật' });
await check('"vote" hướng dẫn nhắn kèm mã', { text: 'vote' }, { reply: '"B1 1" = đi buổi B1' });

console.log('\n— Mở lại vote sau khi chốt, người trong danh sách nhắn "0" —');
// Buổi mở lại: danh sách chốt lần trước An, Bình, Tùng (app đã ghi vote "đi" cho họ).
state.sessions = [sessionDoc({ max: 4, votes: { 'p-an': true, 'p-binh': true, 'p-tung': true }, players: ['p-an', 'p-binh', 'p-tung'] })];
await check('mở lại vote: An nhắn "0" → còn 2 suất', { text: '0' }, { reply: '👥 2/4 suất', patched: true });

console.log('\n— Người được quản lý thêm vào danh sách rồi nhắn "0" —');
// An được tích trên app (có trong danh sách chơi, đã vote đi), Bình vote đi.
state.sessions = [sessionDoc({ max: 4, votes: { 'p-an': true, 'p-binh': true }, players: ['p-an'] })];
await check('An nhắn "0" → nhả chỗ, còn 1 suất', { text: '0' }, { reply: '👥 1/4 suất', patched: true });
state.sessions = [sessionDoc({ max: 4, votes: { 'p-an': false, 'p-binh': true }, players: ['p-an'] })];
await check('"vote" không liệt kê An đã báo không đi', { text: 'vote' }, { reply: '👥 1/4 suất: Bình' });
state.sessions = [sessionDoc({ max: 2, votes: { 'p-binh': true }, players: ['p-an'] })];
await check('được thêm, chưa trả lời: vẫn giữ chỗ', { text: 'vote' }, { reply: '👥 2/2 suất: An, Bình' });

{
  // Ngữ cảnh cho AI phải đếm suất giống câu xác nhận của bot: Bình +1 đính
  // kèm, An được quản lý thêm (chưa trả lời) → 3/4 suất, không phải "1 người".
  state.sessions = [sessionDoc({ max: 4, votes: { 'p-binh': true }, companions: { 'p-binh': 1 }, players: ['p-an'] })];
  state.aiPrompt = '';
  await send({ text: '@Bot PickleBall JVB sân còn mấy chỗ vậy em' });
  const okA = state.aiPrompt.includes('3/4 suất đã giữ');
  if (!okA) fails++;
  log.push(`${okA ? 'OK  ' : 'SAI '} ${'ngữ cảnh AI đếm suất như bot'.padEnd(40)} ${okA ? '' : '← ' + (state.aiPrompt.match(/đang vote[^;]*/)?.[0] || 'không thấy dòng buổi')}`);
}

console.log('\n— Tin vote vào hộp thư phải mang theo buổi đã chọn —');
state.sessions = [
  sessionDoc({ id: 's1', code: 1, title: 'Thứ 5', dateOffsetH: 48, deadlineOffsetH: 24 }),
  sessionDoc({ id: 's2', code: 2, title: 'Chủ nhật', dateOffsetH: 120, deadlineOffsetH: 96 }),
];
{
  state.savedSession = '';
  await check('người lạ "B2 1" → hộp thư kèm buổi B2', { text: 'B2 1', from: { id: 'z-moi', display_name: 'Người Mới' } },
    { reply: 'Đã nhận vote', inbox: true });
  if (state.savedSession !== 's2') { fails++; log[log.length - 1] += `  ← hộp thư phải ghi buổi s2, đang ghi "${state.savedSession}"`; }
  state.patchFail = true;
  state.savedSession = '';
  await check('ghi vote lỗi → hộp thư kèm buổi gần nhất', { text: '1' }, { reply: 'chưa ghi được ngay', inbox: true });
  state.patchFail = false;
  if (state.savedSession !== 's1') { fails++; log[log.length - 1] += `  ← hộp thư phải ghi buổi s1, đang ghi "${state.savedSession}"`; }
}

console.log('\n— Tin giống vote nhưng không phải vote —');
state.sessions = [sessionDoc({ max: 4 })];
await check('"@Bình tham" không ghi Bình là đi', { text: '@Bình tham' }, { reply: 'Dạ em đây' });
await check('"2 người ?" là câu hỏi, không ghi vote', { text: '2 người ?' }, { reply: 'Dạ em đây' });
await check('"2 người !" vẫn là vote 2 suất', { text: '2 người !' }, { reply: '+1 đính kèm', patched: true });
await check('hai mã "b12 0.1 B10" vẫn báo gõ sai', { text: 'b12 0.1 B10' }, { reply: 'chưa hiểu' });

console.log('\n— Tên có chữ cái rời ("Tuấn B") không bị đọc thành mã buổi —');
state.players.push(player('p-tuanb', 'Tuấn B'));
state.sessions = [
  sessionDoc({ id: 's1', code: 1, title: 'Thứ 5', dateOffsetH: 48, deadlineOffsetH: 24 }),
  sessionDoc({ id: 's2', code: 2, title: 'Chủ nhật', dateOffsetH: 120, deadlineOffsetH: 96 }),
];
await checkInto('vote hộ "@Tuấn B 1" → buổi gần nhất', { text: '@Tuấn B 1' }, 's1',
  { reply: '✅ Tuấn B ĐI B1 "Thứ 5"', patched: true });
await checkInto('vote hộ "@Tuấn B B2 1" → buổi B2', { text: '@Tuấn B B2 1' }, 's2',
  { reply: '✅ Tuấn B ĐI B2 "Chủ nhật"', patched: true });
state.players.pop();
// B1 đã chốt, đang mở B2 và B3: ví dụ trong hướng dẫn phải là mã đang mở.
state.sessions = [
  sessionDoc({ id: 's2', code: 2, title: 'Chủ nhật', dateOffsetH: 120, deadlineOffsetH: 96 }),
  sessionDoc({ id: 's3', code: 3, title: 'Thứ 3', dateOffsetH: 200, deadlineOffsetH: 190 }),
];
await check('"vote" ví dụ dùng mã đang mở (B2)', { text: 'vote' }, { reply: '"B2 1" = đi buổi B2' });

console.log('\n— Thiếu BOT_REFRESH_TOKEN (không được tạo tài khoản ẩn danh) —');
state.sessions = [sessionDoc({ max: 4 })];
{
  const envNoToken = { ...env };
  delete envNoToken.BOT_REFRESH_TOKEN;
  state.sent = []; state.saved = []; state.patched = []; state.signUps = [];
  const message = { message_id: 'm-no-token', date: Math.floor(Date.now() / 1000),
    chat: { id: 'g1', chat_type: 'GROUP' }, from: { id: 'z1', display_name: 'An' }, text: '1' };
  const res = await worker.fetch(new Request(`https://h/${TEAM}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ message }),
  }), envNoToken);
  await res.json();
  await new Promise((r) => setTimeout(r, 20));
  const problems = [];
  if (state.signUps.length) problems.push('ĐÃ TẠO TÀI KHOẢN ẨN DANH');
  if (!state.saved.length) problems.push('phải vào hộp thư cho app ghi hộ');
  if (!state.sent.length) problems.push('KHÔNG TRẢ LỜI');
  if (state.patched.length) problems.push('không được ghi vote khi chưa có token');
  if (problems.length) fails++;
  log.push(`${problems.length ? 'SAI ' : 'OK  '} ${'vote khi thiếu token'.padEnd(40)} ` +
    `${state.sent.length ? `"${state.sent[0].slice(0, 46).replace(/\n/g, ' ')}"` : '(im lặng)'}` +
    `${state.saved.length ? ' · hộp thư' : ''}${problems.length ? '  ← ' + problems.join('; ') : ''}`);
}

console.log(log.join('\n'));
console.log(fails === 0 ? `\n✅ ${log.length} kịch bản đều đúng.` : `\n❌ ${fails}/${log.length} kịch bản sai.`);
process.exit(fails === 0 ? 0 : 1);
