const { test } = require('node:test');
const assert = require('node:assert/strict');
const load = require('./load.cjs');
const { RequestQueue } = load('entry/src/main/ets/domain/RequestQueue.ts');
const { ResponseCache } = load('entry/src/main/ets/domain/ResponseCache.ts');
const { apiOrigin, xsrfToken } = load('entry/src/main/ets/domain/RequestPolicy.ts');
function deferred() { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; }
test('serial queue prioritizes foreground writes, continues after failure', async () => {
  const queue = new RequestQueue(0), gate = deferred(), order = [];
  const first = queue.enqueue(async () => { order.push('first'); await gate.promise; });
  const read = queue.enqueue(async () => { order.push('read'); return 1; });
  const write = queue.enqueue(async () => { order.push('write'); throw new Error('failure'); }, 10);
  const failed = assert.rejects(write, /failure/);
  assert.deepEqual(order, ['first']); gate.resolve();
  await Promise.all([first, read, failed]);
  assert.deepEqual(order, ['first', 'write', 'read']);
});
test('session invalidation rejects queued and late responses', async () => {
  const queue = new RequestQueue(0), gate = deferred(); let called = false;
  const first = assert.rejects(queue.enqueue(() => gate.promise), /取消/);
  const second = assert.rejects(queue.enqueue(async () => { called = true; }), /取消/);
  queue.invalidate(); gate.resolve('old account');
  await Promise.all([first, second]); assert.equal(called, false);
  assert.equal(await queue.enqueue(async () => 'new account'), 'new account');
});
test('comment invalidation rejects old response without deleting newer request', async () => {
  const cache = new ResponseCache(30000), old = deferred(), fresh = deferred();
  const stale = assert.rejects(cache.get('p', () => old.promise), /数据已更新/);
  cache.invalidate('p'); const next = cache.get('p', () => fresh.promise);
  old.resolve(['old']); await stale;
  let duplicate = false;
  const shared = cache.get('p', async () => { duplicate = true; return []; });
  fresh.resolve(['new']); assert.deepEqual(await next, ['new']); await shared;
  assert.equal(duplicate, false);
  assert.deepEqual(await cache.get('p', async () => []), ['new']);
});
test('expired cache refetches and a failed fetch can be retried', async () => {
  const cache = new ResponseCache(0); let calls = 0;
  await cache.get('p', async () => ++calls); await cache.get('p', async () => ++calls);
  assert.equal(calls, 2);
  await assert.rejects(cache.get('q', async () => { throw new Error('offline'); }), /offline/);
  assert.equal(await cache.get('q', async () => 3), 3);
});
test('credentials only target exact HTTPS API hosts', () => {
  assert.equal(apiOrigin('https://m.weibo.cn/api/config'), 'https://m.weibo.cn/');
  assert.equal(apiOrigin('https://weibo.com/ajax/feed'), 'https://weibo.com/');
  for (const url of ['http://weibo.com/a','https://weibo.com.evil/a','https://weibo.com@evil/a','https://evil/a','https://weibo.com:444/a']) {
    assert.throws(() => apiOrigin(url));
  }
  assert.equal(xsrfToken('a=1; XSRF-TOKEN=a%2Bb'), 'a+b');
  assert.throws(() => xsrfToken('XSRF-TOKEN=%ZZ'));
});
