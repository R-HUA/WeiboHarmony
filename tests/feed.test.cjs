const { test } = require('node:test');
const assert = require('node:assert/strict');
const load = require('./load.cjs');
global.Observed = value => value;

const { FeedStore, FeedLoadState } = load('entry/src/main/ets/store/FeedStore.ets', {
  '@kit.PerformanceAnalysisKit': { hilog: { warn: () => {} } },
  '../repository/FeedRepository': { FeedRepository: class {} }
});

function deferred() { let resolve, reject; const promise = new Promise((r, j) => { resolve = r; reject = j; }); return { promise, resolve, reject }; }
const post = id => ({ id });
const tick = () => new Promise(resolve => setTimeout(resolve));

function fixture(kind) {
  let generation = 0;
  let cache = { posts: [], cursor: null, anchorId: '', offset: 0 };
  const fetches = [], saves = [], positions = [], loads = [];
  const source = {
    generation: () => generation,
    fetchFirst: k => { const d = deferred(); fetches.push({ kind: k, cursor: null, ...d }); return d.promise; },
    fetchMore: (k, c) => { const d = deferred(); fetches.push({ kind: k, cursor: c, ...d }); return d.promise; },
    loadCache: k => { loads.push(k); return Promise.resolve(cache); },
    saveCache: (k, posts, cursor, current) => { saves.push({ kind: k, posts, cursor, current }); return Promise.resolve(); },
    savePosition: (k, id, offset) => { positions.push({ kind: k, id, offset }); return Promise.resolve(); }
  };
  return {
    store: new FeedStore(kind, source), fetches, saves, positions, loads,
    setCache: c => { cache = c; }, logout: () => { generation++; }
  };
}

test('cache renders first, then network refresh merges and persists', async () => {
  const f = fixture('recommend');
  f.setCache({ posts: [post('a'), post('b')], cursor: 'rc2', anchorId: 'b', offset: -30 });
  const loading = f.store.loadFirst(false);
  await tick();
  assert.equal(f.loads[0], 'recommend');
  assert.equal(f.store.state, FeedLoadState.Success);
  assert.deepEqual(f.store.posts.map(p => p.id), ['a', 'b']);
  assert.equal(f.store.hasMore, true);
  assert.equal(f.store.pendingAnchorId, 'b');
  assert.equal(f.store.pendingAnchorOffset, -30);
  assert.equal(f.store.refreshing, true);
  f.fetches[0].resolve({ items: [post('x'), post('a')], nextCursor: 'rc2' });
  await loading;
  await tick();
  assert.deepEqual(f.store.posts.map(p => p.id), ['x', 'a', 'b']);
  assert.equal(f.store.refreshing, false);
  assert.equal(f.saves.length, 1);
  assert.deepEqual(f.saves[0].posts.map(p => p.id), ['x', 'a', 'b']);
  assert.equal(f.saves[0].cursor, 'rc2');
  assert.equal(f.saves[0].current(), true);
});

test('offline keeps cached content; without cache the error state surfaces', async () => {
  const f = fixture('following');
  f.setCache({ posts: [post('old')], cursor: null, anchorId: '', offset: 0 });
  const first = f.store.loadFirst(false);
  await tick();
  f.fetches[0].reject(new Error('网络不可用'));
  await first;
  assert.equal(f.store.state, FeedLoadState.Success);
  assert.deepEqual(f.store.posts, [post('old')]);
  assert.equal(f.store.errorMessage, '网络不可用');
  assert.equal(f.store.refreshing, false);
  assert.equal(f.saves.length, 0);

  const g = fixture('recommend');
  const second = g.store.loadFirst(false);
  await tick();
  assert.equal(g.store.state, FeedLoadState.Loading);
  g.fetches[0].reject(new Error('网络不可用'));
  await second;
  assert.equal(g.store.state, FeedLoadState.Error);
  assert.deepEqual(g.store.posts, []);
});

test('explicit refresh never overwrites live posts with stale cache', async () => {
  const f = fixture('recommend');
  const first = f.store.loadFirst(false);
  await tick();
  f.fetches[0].resolve({ items: [post('live')], nextCursor: 'c' });
  await first;
  f.setCache({ posts: [post('stale')], cursor: null, anchorId: 'stale', offset: 0 });
  const second = f.store.loadFirst(true);
  await tick();
  assert.deepEqual(f.store.posts.map(p => p.id), ['live']);
  assert.equal(f.store.state, FeedLoadState.Success);
  f.fetches[1].resolve({ items: [post('fresh')], nextCursor: 'c' });
  await second;
  assert.deepEqual(f.store.posts.map(p => p.id), ['fresh', 'live', 'stale']);
  assert.equal(f.store.pendingAnchorId, '');
});

test('loadMore merges and dedupes, ends on repeated cursor', async () => {
  const f = fixture('recommend');
  const first = f.store.loadFirst(false);
  await tick();
  f.fetches[0].resolve({ items: [post('a')], nextCursor: 'p2' });
  await first;
  const more = f.store.loadMore();
  await tick();
  assert.equal(f.fetches[1].cursor, 'p2');
  f.fetches[1].resolve({ items: [post('b'), post('b'), post('a')], nextCursor: 'p3' });
  await more;
  assert.deepEqual(f.store.posts.map(p => p.id), ['a', 'b']);
  assert.equal(f.store.hasMore, true);
  assert.equal(f.store.loadingMore, false);
  assert.deepEqual(f.saves[1].posts.map(p => p.id), ['a', 'b']);
  assert.equal(f.saves[1].cursor, 'p3');
  const repeated = f.store.loadMore();
  await tick();
  f.fetches[2].resolve({ items: [post('c')], nextCursor: 'p3' });
  await repeated;
  assert.deepEqual(f.store.posts.map(p => p.id), ['a', 'b', 'c']);
  assert.equal(f.store.hasMore, false);
  await f.store.loadMore();
  assert.equal(f.fetches.length, 3);
});

test('session change discards late loadMore response and cancel resets flags', async () => {
  const f = fixture('following');
  const first = f.store.loadFirst(false);
  await tick();
  f.fetches[0].resolve({ items: [post('m')], nextCursor: 'f2' });
  await first;
  const more = f.store.loadMore();
  f.logout();
  f.fetches[1].resolve({ items: [post('secret')], nextCursor: 'f3' });
  await more;
  assert.deepEqual(f.store.posts.map(p => p.id), ['m']);
  assert.equal(f.store.loadingMore, true);
  f.store.cancel();
  assert.equal(f.store.loadingMore, false);
});

test('savePosition only passes the anchor through in success state', async () => {
  const f = fixture('recommend');
  f.store.savePosition('a', -12);
  assert.equal(f.positions.length, 0);
  const first = f.store.loadFirst(false);
  await tick();
  f.fetches[0].resolve({ items: [post('a')], nextCursor: null });
  await first;
  f.store.savePosition('a', -12);
  assert.deepEqual(f.positions, [{ kind: 'recommend', id: 'a', offset: -12 }]);
  f.store.savePosition('', 0);
  assert.equal(f.positions.length, 1);
});

test('reset drops old account content and the pending anchor', async () => {
  const f = fixture('recommend');
  f.setCache({ posts: [post('a')], cursor: 'c', anchorId: 'a', offset: -5 });
  const first = f.store.loadFirst(false);
  await tick();
  f.fetches[0].resolve({ items: [post('a')], nextCursor: 'c' });
  await first;
  f.store.reset();
  assert.deepEqual(f.store.posts, []);
  assert.equal(f.store.state, FeedLoadState.Loading);
  assert.equal(f.store.pendingAnchorId, '');
  assert.equal(f.store.hasMore, false);
});

function repoFixture(accountId, generation = 0) {
  const calls = { recommendPages: [], followingMaxIds: [] };
  const reader = [];
  const service = {
    fetchRecommendTimeline: async page => { calls.recommendPages.push(page); return [post('r' + page)]; },
    fetchFollowingTimeline: async maxId => {
      calls.followingMaxIds.push(maxId);
      if (maxId === 'end') { return { items: [], nextMaxId: '', hasMore: false }; }
      return { items: [post('f' + maxId)], nextMaxId: maxId === 'next0' ? 'end' : 'next0', hasMore: true };
    }
  };
  const readerDb = {
    loadFeed: (account, feed) => { reader.push(['load', account, feed]); return Promise.resolve({ posts: [], cursor: null, anchorId: '', offset: 0 }); },
    saveFeed: (account, feed, posts, cursor, current) => { reader.push(['save', account, feed, posts.length, cursor, current()]); return Promise.resolve(); },
    savePosition: (account, feed, id, offset) => { reader.push(['pos', account, feed, id, offset]); return Promise.resolve(); }
  };
  const { FeedRepository, GUEST_ACCOUNT } = load('entry/src/main/ets/repository/FeedRepository.ets', {
    '../service/WeiboService': { WeiboService: { getInstance: () => service } },
    '../service/WeiboAuthManager': { WeiboAuthManager: { getInstance: () => ({ getGeneration: () => generation, getAccountId: () => accountId }) } },
    '../storage/ReaderDatabase': { ReaderDatabase: { shared: () => readerDb } }
  });
  return { repo: new FeedRepository(), calls, reader, GUEST_ACCOUNT };
}

test('recommend paging uses versioned page cursors and rejects foreign ones', async () => {
  const f = repoFixture('42');
  assert.equal(f.repo.generation(), 0);
  const first = await f.repo.fetchFirst('recommend');
  assert.deepEqual(f.calls.recommendPages, [1]);
  assert.ok(first.nextCursor);
  await f.repo.fetchMore('recommend', first.nextCursor);
  assert.deepEqual(f.calls.recommendPages, [1, 2]);
  await assert.rejects(f.repo.fetchMore('recommend', '{"version":1,"kind":"recommend","page":1}'), /游标已失效/);
  await assert.rejects(f.repo.fetchMore('recommend', '{"version":1,"kind":"following","maxId":"x"}'), /游标已失效/);
  await assert.rejects(f.repo.fetchMore('recommend', 'not-json'), /游标已失效/);
});

test('following paging maps the server cursor and reports exhaustion', async () => {
  const f = repoFixture('42');
  const first = await f.repo.fetchFirst('following');
  assert.deepEqual(f.calls.followingMaxIds, ['0']);
  assert.ok(first.nextCursor);
  const second = await f.repo.fetchMore('following', first.nextCursor);
  assert.deepEqual(f.calls.followingMaxIds, ['0', 'next0']);
  const third = await f.repo.fetchMore('following', second.nextCursor);
  assert.deepEqual(f.calls.followingMaxIds, ['0', 'next0', 'end']);
  assert.equal(third.nextCursor, null);
});

test('cache reads and writes are account and feed scoped', async () => {
  const guest = repoFixture('');
  assert.equal(guest.GUEST_ACCOUNT, 'guest');
  await guest.repo.loadCache('recommend');
  await guest.repo.saveCache('recommend', [post('a')], 'c', () => true);
  await guest.repo.savePosition('recommend', 'a', -3);
  assert.deepEqual(guest.reader, [
    ['load', 'guest', 'recommend'],
    ['save', 'guest', 'recommend', 1, 'c', true],
    ['pos', 'guest', 'recommend', 'a', -3]
  ]);
  const owned = repoFixture('42');
  await owned.repo.loadCache('following');
  assert.deepEqual(owned.reader[0], ['load', '42', 'following']);
});
