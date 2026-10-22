/**
 * Kiểm thử webhook từ đầu đến cuối: gọi thẳng worker.fetch với Firestore, Firebase Auth
 * và Zalo giả lập. Nguyên tắc: AI CŨNG NHƯ NGƯỜI, ai @bot cũng phải được trả lời.
 *
 * Chạy:  node webhook/e2e-test.mjs      (không cần mạng; thoát mã 1 nếu có kịch bản sai)
 */
import worker from './zalo-webhook.js';

const TEAM = 'team-test-01';
const state = { sessions: [], players: [], sent: [], saved: [], patched: [], ai: 'ok' , signUps: [] };

const doc = (name, fields) => ({ name: `projects/p/databases/(default)/documents/${name}`, fields });
const priceField = (v) => ({
  arrayValue: { values: [{ mapValue: { fields: {
    date: { timestampValue: '2026-01-01T00:00:00Z' }, price: { integerValue: String(v) } } } }] },
});
const player = (id, name, zaloId = '') => doc(`teams/${TEAM}/players/${id}`, {
  name: { stringValue: name }, active: { booleanValue: true },
  ...(zaloId ? { zaloId: { stringValue: zaloId } } : {}),
});

function sessionDoc({ id = 's1', status = 'voting', dateOffsetH = 48, deadlineOffsetH = 24, title = 'Thứ 7',
  max = null, votes = {}, companions = {} } = {}) {
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
  return doc(`teams/${TEAM}/sessions/${id}`, f);
}

globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  const ok = (body, status = 200) => new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json' } });
  if (u.includes('/sendMessage')) { state.sent.push(JSON.parse(opts.body).text); return ok({ ok: true, result: { message_id: 'x' } }); }
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
  if (u.includes('/zaloInbox/')) { state.saved.push(JSON.parse(opts.body).fields.text.stringValue); return ok({}); }
  if (u.includes('generativelanguage')) {
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
state.players = [player('p-an', 'An', AN), player('p-binh', 'Bình', BINH), player('p-tung', 'Tùng')];

console.log('— Có buổi đang mở vote (giới hạn 4) —');
state.sessions = [sessionDoc({ max: 4, votes: { 'p-binh': true }, companions: { 'p-binh': 1 } })];
await check('vote "1" (người đã biết)', { text: '1' }, { reply: '✅ An: đi', patched: true });
await check('vote "@Bot PickleBall JVB 1" (mention bot)', { text: '@Bot PickleBall JVB 1' }, { reply: '✅ An: đi', patched: true });
const r2 = await check('vote "2" (kèm 1)', { text: '2' }, { reply: '+1 đính kèm', patched: true });
// id người chơi có dấu "-" → field path trong updateMask phải bọc backtick (`p-an`).
if (!r2.patched.every((p) => p.url.includes(encodeURIComponent('votes.`p-an`')))) {
  fails++; log.push('SAI  updateMask thiếu backtick cho id có dấu "-"');
}
state.patchFail = true;
await check('ghi vote lỗi → hộp thư + báo đã nhận', { text: '1' }, { reply: 'chưa ghi được ngay', inbox: true });
state.patchFail = false;
await check('vote "0"', { text: '0' }, { reply: '👌 An: không đi', patched: true });
await check('vote "3" vượt chỗ (còn 2)', { text: '3' }, { reply: 'chỉ còn 2 chỗ' });
await check('vote câu ngắn "cho em đi với"', { text: 'cho em đi với' }, { reply: '✅ An: đi', patched: true });
const TUNG = { id: 'z9', display_name: 'Tùng' };
const px = await check('vote hộ "@An 1" (Tùng vote hộ)', { text: '@Bot PickleBall JVB @An 1', from: TUNG }, { reply: '✅ An: đi "Thứ 7" (Tùng vote hộ)', patched: true });
if (!px.sent.join('\n').includes('Tùng')) { fails++; log.push('SAI  vote hộ phải ghi tên người vote hộ'); }
const px2 = await check('vote hộ nhiều người "@Bình 0 @An 2"', { text: '@Bình 0 @An 2', from: TUNG }, { reply: '👌 Bình: không đi', patched: true });
if (!px2.sent.join('\n').includes('An (+1 đính kèm)')) { fails++; log.push('SAI  vote hộ "@An 2" phải ra +1 đính kèm'); }
if (!(px2.patched.length === 1 && px2.patched[0].url.includes('p-binh') && px2.patched[0].url.includes('p-an'))) { fails++; log.push('SAI  vote hộ nhiều người phải ghi trong MỘT lần PATCH'); }
await check('vote hộ + tự vote "1 @An 0"', { text: '1 @An 0', from: TUNG }, { reply: '✅ Tùng: đi', patched: true });
await check('vote hộ tên lạ', { text: '@Người Lạ 1', from: TUNG }, { reply: 'Không tìm thấy người chơi "nguoi la"' });
await check('vote hộ số sai "@An 10"', { text: '@An 10', from: TUNG }, { reply: 'Em chưa hiểu' });
await check('vote hộ vượt chỗ "@An 3" (còn 2)', { text: '@An 3', from: TUNG }, { reply: 'chỉ còn 2 chỗ' });
await check('"@An đi không?" là câu hỏi → AI', { text: '@An đi không?', from: TUNG }, { reply: 'Dạ em đây' });
await check('"@An mai đi sớm nhé" là câu nói → AI', { text: '@An mai đi sớm nhé anh ơi', from: TUNG }, { reply: 'Dạ em đây' });
const px3 = await check('người lạ tự vote + vote hộ "1 @An 1"', { text: '1 @An 1', from: { id: 'z8', display_name: 'Người Mới' } }, { reply: '✅ An: đi', inbox: true, patched: true });
if (!(px3.saved.length === 1 && px3.saved[0] === '1')) { fails++; log.push(`SAI  hộp thư chỉ được chứa phần tự vote "1", đang là ${JSON.stringify(px3.saved)}`); }
if (!px3.sent.join('\n').includes('chưa có trong danh sách')) { fails++; log.push('SAI  phải báo người gửi chưa có tên'); }
await check('khớp theo tên hiển thị', { text: '1', from: { id: 'z9', display_name: 'Tùng' } }, { reply: '✅ Tùng: đi', patched: true });
await check('người lạ vote → hộp thư + báo', { text: '1', from: { id: 'z8', display_name: 'Người Mới' } }, { reply: 'chưa có trong danh sách', inbox: true });
await check('số sai "10"', { text: '10' }, { reply: 'Em chưa hiểu' });
await check('số sai "1,2,3"', { text: '1,2,3' }, { reply: 'Em chưa hiểu' });
await check('lệnh nước "n1 2" → hộp thư + báo', { text: 'n1 2' }, { reply: 'đã nhận lệnh nước', inbox: true });
await check('lệnh nước "+1 n1"', { text: '+1 n1' }, { reply: 'đã nhận lệnh nước', inbox: true });
await check('xem danh sách nước', { text: 'nước' }, { reply: 'DANH SÁCH NƯỚC' });
await check('hướng dẫn', { text: '@bot help' }, { reply: 'Bot Quỹ Pickleball' });
await check('"vote" → danh sách vote đang mở', { text: '@Bot PickleBall JVB vote' }, { reply: 'VOTE ĐANG MỞ' });
await check('chuyện phiếm → AI', { text: 'thời tiết đẹp nhỉ' }, { reply: 'Dạ em đây' });
await check('câu dài có "oke" KHÔNG phải vote', { text: 'anh Sơn bảo anh oke rồi em' }, { reply: 'Dạ em đây' });
await check('câu có số "100k" → AI', { text: 'tăng cho anh Tiến 100k tiền quỹ' }, { reply: 'Dạ em đây' });
await check('chỉ @bot, không nội dung', { text: '@Bot PickleBall JVB' }, { reply: 'Em đây' });
state.ai = 'down';
await check('AI lỗi vẫn trả lời', { text: 'thời tiết đẹp nhỉ' }, { reply: 'Em chưa hiểu ý' });
state.ai = 'ok';

console.log('\n— Không có buổi nào đang mở vote —');
state.sessions = [sessionDoc({ status: 'closed' })];
await check('vote "1"', { text: '1' }, { reply: 'chưa có buổi nào đang mở vote' });
await check('"vote" → báo không có', { text: 'vote' }, { reply: 'không có vote nào đang mở' });
await check('ghi nước vẫn chạy', { text: 'n1 2' }, { reply: 'đã nhận lệnh nước', inbox: true });

console.log('\n— Buổi đang vote nhưng đã hết hạn —');
state.sessions = [sessionDoc({ deadlineOffsetH: -2, dateOffsetH: -1 })];
await check('vote "1"', { text: '1' }, { reply: 'hết hạn vote' });
await check('"vote" vẫn liệt kê kèm "hết hạn"', { text: 'vote' }, { reply: 'Đã hết hạn vote' });

console.log('\n— Ảnh kèm chú thích (nội dung ở caption) —');
state.sessions = [sessionDoc({ status: 'closed' })];
await check('caption "n1 2"', { caption: 'n1 2' }, { reply: 'đã nhận lệnh nước', inbox: true });

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
