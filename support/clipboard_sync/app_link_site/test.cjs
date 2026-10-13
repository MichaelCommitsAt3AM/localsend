const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const script = fs.readFileSync(__dirname + '/public/app.js', 'utf8');
const fixture = {
  version: 2, kind: 'localsend-clipboard-pair', fingerprint: 'A'.repeat(64),
  token: 'B'.repeat(64), port: 53319, addresses: ['192.0.2.1'], expires: Math.floor(Date.now()/1000) + 180,
};
function run(fragment) {
  const status = { textContent: '' }, open = { hidden: true, removeAttribute(name) { delete this[name]; } };
  let replaced = '', expire;
  vm.runInNewContext(script, {
    location: { hash: '#' + fragment, pathname: '/pair' },
    history: { replaceState(_state, _title, path) { replaced = path; } },
    document: { getElementById(id) { return id === 'status' ? status : open; } },
    TextDecoder, Uint8Array, atob, Date,
    setTimeout(callback) { expire = callback; },
  });
  return { status, open, replaced, expire };
}
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const good = run(encode(fixture));
assert.equal(good.open.hidden, false);
assert.equal(good.open.href, 'localsend-clipboard://pair#' + encode(fixture));
assert.equal(good.replaced, '/pair');
good.expire();
assert.equal(good.open.hidden, true);
assert.equal(good.open.href, undefined);
assert.match(good.status.textContent, /expired/);
const expired = run(encode({ ...fixture, expires: Math.floor(Date.now()/1000) - 1 }));
assert.equal(expired.open.hidden, true);
assert.match(expired.status.textContent, /expired/);
for (const fragment of ['invalid*', 'x'.repeat(5501), encode({ ...fixture, token: '<script>' }), encode({ ...fixture, version: 99 })]) {
  const bad = run(fragment);
  assert.equal(bad.open.hidden, true);
  assert.match(bad.status.textContent, /invalid/);
}
console.log('Pairing link fallback tests passed.');
