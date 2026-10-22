/**
 * Kiểm thử webhook từ đầu đến cuối: gọi thẳng worker.fetch với Firestore và
 * Zalo giả lập, kiểm tin nào được trả lời và tin nào được ghi vào hộp thư.
 *
 * Chạy:  node webhook/e2e-test.mjs
 *
 * Không cần mạng, không cần cài gì thêm. Thoát mã 1 nếu có kịch bản sai.
 */
import worker from './zalo-webhook.js';

const TEAM = 'team-test-01';
const state = { sessions: [], sent: [], saved: [] };

const doc = (fields) => ({ fields });
const priceField = (v) => ({
  arrayValue: { values: [{ mapValue: { fields: {
    date: { timestampValue: '2026-01-01T00:00:00Z' }, price: { integerValue: String(v) } } } }] },
});

function sessionDoc({ status = 'voting', dateOffsetH = 48, deadlineOffsetH = 24, title = 'Thứ 7' } = {}) {
  const now = Date.now();
  return doc({
    status: { stringValue: status },
    title: { stringValue: title },
    date: { timestampValue: new Date(now + dateOffsetH * 3600e3).toISOString() },
    voteDeadline: { timestampValue: new Date(now + deadlineOffsetH * 3600e3).toISOString() },
  });
}

globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  const ok = (body) => new Response(JSON.stringify(body), {
    status: 200, headers: { 'content-type': 'application/json' } });
  if (u.includes('/sendMessage')) {
    state.sent.push(JSON.parse(opts.body).text);
    return ok({ ok: true, result: { message_id: 'x' } });
  }
  if (u.includes('/drinkTypes')) {
    return ok({ documents: [
      doc({ name: { stringValue: 'Revive' }, code: { integerValue: '1' },
        active: { booleanValue: true }, prices: priceField(15000) }),
      doc({ name: { stringValue: 'Nước suối' }, code: { integerValue: '2' },
        active: { booleanValue: true }, prices: priceField(5000) }),
    ] });
  }
  if (u.includes('/sessions')) return ok({ documents: state.sessions });
  if (u.includes('/zaloInbox/')) {
    state.saved.push(JSON.parse(opts.body).fields.text.stringValue);
    return ok({});
  }
  if (u.includes('generativelanguage')) {
    return ok({ candidates: [{ content: { parts: [{ text: 'Dạ em đây ạ.' }] } }] });
  }
  if (u.includes('/documents/teams/')) {
    return ok(doc({
      zaloBotName: { stringValue: 'Bot PickleBall JVB' },
      zaloBotToken: { stringValue: '250:abc' },
      name: { stringValue: 'Team' },
      zaloGroupId: { stringValue: 'g1' },
    }));
  }
  return ok({});
};

const env = { FIREBASE_PROJECT_ID: 'p', FIREBASE_API_KEY: 'k', GEMINI_API_KEY: 'g', TEAM_ID: TEAM };
const log = [];
let fails = 0;

async function send({ text, caption }) {
  state.sent = [];
  state.saved = [];
  const message = {
    message_id: 'm' + Math.random(), date: Math.floor(Date.now() / 1000),
    chat: { id: 'g1', chat_type: 'GROUP' }, from: { id: 'z1', display_name: 'An' },
  };
  if (text !== undefined) message.text = text;
  if (caption !== undefined) message.caption = caption;
  const res = await worker.fetch(new Request(`https://h/${TEAM}`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ message }),
  }), env);
  await res.json();
  await new Promise((r) => setTimeout(r, 20));
  return { sent: [...state.sent], saved: [...state.saved] };
}

/** want: 'inbox' = phải vào hộp thư; hoặc đoạn chữ phải có trong câu trả lời. */
async function check(label, msg, want) {
  const r = await send(msg);
  const okInbox = want === 'inbox' && r.saved.length > 0 && r.sent.length === 0;
  const okReply = want !== 'inbox' && r.saved.length === 0 &&
    r.sent.length > 0 && r.sent[0].includes(want);
  const pass = okInbox || okReply;
  if (!pass) fails++;
  log.push(`${pass ? 'OK  ' : 'SAI '} ${label.padEnd(34)} ` +
    `${r.saved.length ? 'vào hộp thư' : 'không ghi'}` +
    `${r.sent.length ? ` · trả lời "${r.sent[0].slice(0, 40).replace(/\n/g, ' ')}"` : ''}`);
}

console.log('— Có buổi đang mở vote —');
state.sessions = [sessionDoc()];
await check('vote "1"', { text: '1' }, 'inbox');
await check('vote "0"', { text: '0' }, 'inbox');
await check('vote "2" (đi 2 người)', { text: '2' }, 'inbox');
await check('vote câu dài', { text: 'cho em đi với' }, 'inbox');
await check('số sai "10"', { text: '10' }, 'Em chưa hiểu');
await check('số sai "1,2,3"', { text: '1,2,3' }, 'Em chưa hiểu');
await check('lệnh nước "n1 2"', { text: 'n1 2' }, 'inbox');
await check('lệnh nước "+1 n1"', { text: '+1 n1' }, 'inbox');
await check('lệnh nước "n1 0" (xoá)', { text: 'n1 0' }, 'inbox');
await check('xem danh sách nước', { text: 'nước' }, 'DANH SÁCH NƯỚC');
await check('hướng dẫn', { text: '@bot help' }, 'Bot Quỹ Pickleball');
await check('chuyện phiếm → AI', { text: 'thời tiết đẹp nhỉ' }, 'Dạ em đây');

console.log('\n— Không có buổi nào đang mở vote —');
state.sessions = [sessionDoc({ status: 'closed' })];
await check('vote "1"', { text: '1' }, 'chưa có buổi nào đang mở vote');
await check('vote "0"', { text: '0' }, 'chưa có buổi nào đang mở vote');
await check('GHI NƯỚC vẫn phải chạy', { text: 'n1 2' }, 'inbox');
await check('"+1 n1" vẫn phải chạy', { text: '+1 n1' }, 'inbox');
await check('"n1 0" vẫn phải chạy', { text: 'n1 0' }, 'inbox');
await check('xem danh sách nước', { text: 'nước' }, 'DANH SÁCH NƯỚC');

console.log('\n— Buổi đang vote nhưng đã hết hạn —');
state.sessions = [sessionDoc({ deadlineOffsetH: -2, dateOffsetH: -1 })];
await check('vote "1"', { text: '1' }, 'hết hạn vote');
await check('ghi nước vẫn chạy', { text: 'n1 2' }, 'inbox');

console.log('\n— Chưa có buổi chơi nào —');
state.sessions = [];
await check('vote "1"', { text: '1' }, 'chưa có buổi nào đang mở vote');
await check('ghi nước vẫn chạy', { text: 'n1 2' }, 'inbox');

console.log('\n— Ảnh kèm chú thích (nội dung ở caption) —');
state.sessions = [sessionDoc({ status: 'closed' })];
await check('caption "n1 2"', { caption: 'n1 2' }, 'inbox');

console.log(log.join('\n'));
console.log(fails === 0 ? `\n✅ ${log.length} kịch bản đều đúng.` : `\n❌ ${fails}/${log.length} kịch bản sai.`);
process.exit(fails === 0 ? 0 : 1);
