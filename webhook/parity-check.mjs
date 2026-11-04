// So logic vote của webhook (JS) với app (Dart) trên cùng các tình huống.
// test/app_webhook_parity_test.dart sinh tình huống + kết quả bên Dart rồi gọi:
//   node webhook/parity-check.mjs <file tình huống.json>
// Hai bên cùng đọc tin vote và đếm suất; lệch nhau là bot báo một đằng, app
// tính một nẻo (đã từng xảy ra nhiều lần), nên mọi lệch đều làm test đỏ.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, 'zalo-webhook.js'), 'utf8')
  .replace('export default {', 'const __worker = {');
const js = new Function(`${src}
;return { holdsSeat, seatHolders, seatsTaken, readVoteShape, readVoteValue, sessionCodeIn, parseProxyVotesJs };`)();

const { seats, texts, proxies } = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let bad = 0;
const show = (label, app, hook) => {
  if (bad++ < 20) console.log(`LỆCH ${label}\n   app:     ${JSON.stringify(app)}\n   webhook: ${JSON.stringify(hook)}`);
};

for (const c of seats) {
  const sess = { status: c.status, votes: c.votes, voteTimes: c.voteTimes, companions: c.companions, playerIds: c.playerIds };
  const h = js.seatHolders(sess);
  if (JSON.stringify(h) !== JSON.stringify(c.dart.holders)) show(`thứ tự giữ chỗ ${c.id}`, c.dart.holders, h);
  if (js.seatsTaken(sess) !== c.dart.seats) show(`số suất ${c.id}`, c.dart.seats, js.seatsTaken(sess));
  for (const [p, want] of Object.entries(c.dart.holds)) {
    if (js.holdsSeat(sess, p) !== want) show(`giữ chỗ ${c.id}/${p}`, want, js.holdsSeat(sess, p));
  }
}

for (const t of texts) {
  const shape = js.readVoteShape(t.text, t.bot);
  const err = !!shape.error;
  const v = shape.definite && !err ? js.readVoteValue(t.text, t.bot) : null;
  const hook = { err, vote: v ? v.vote : null, seats: v && v.vote ? v.seats : 0, code: js.sessionCodeIn(t.text) };
  const app = { err: t.dart.err, vote: t.dart.vote, seats: t.dart.vote === true ? t.dart.seats : 0, code: t.dart.code };
  if (JSON.stringify(hook) !== JSON.stringify(app)) show(`đọc tin "${t.text}"${t.bot ? ` (bot ${t.bot})` : ''}`, app, hook);
}

for (const t of proxies.texts) {
  const r = js.parseProxyVotesJs(t.text, '', proxies.players);
  const hook = r == null ? null : r.map((a) => ({
    id: a.player ? a.player.id : null, self: a.isSelf, err: !!a.error,
    vote: a.error ? null : a.vote, seats: a.error || !a.vote ? 0 : a.seats,
  }));
  if (JSON.stringify(hook) !== JSON.stringify(t.dart)) show(`vote hộ "${t.text}"`, t.dart, hook);
}

console.log(`Đã so ${seats.length} buổi, ${texts.length} tin vote, ${proxies.texts.length} tin vote hộ · lệch: ${bad}`);
process.exit(bad ? 1 : 0);
