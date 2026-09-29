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

test('background refresh stages a new stream without moving cached content', async () => {
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
  assert.deepEqual(f.store.posts.map(p => p.id), ['a', 'b']);
  assert.equal(f.store.refreshing, false);
  assert.equal(f.store.hasPendingUpdate, true);
  assert.equal(f.store.pendingAnchorId, 'b');
  assert.equal(f.saves.length, 0);
  f.store.acceptPendingUpdate();
  assert.deepEqual(f.store.posts.map(p => p.id), ['x', 'a']);
  assert.equal(f.store.hasPendingUpdate, false);
  assert.equal(f.store.pendingAnchorId, '');
  assert.deepEqual(f.saves[0].posts.map(p => p.id), ['x', 'a']);
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
  assert.deepEqual(f.store.posts.map(p => p.id), ['fresh']);
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
  assert.deepEqual(f.positions, [{kind: 'recommend', id: '', offset: 0}, { kind: 'recommend', id: 'a', offset: -12 }]);
  f.store.savePosition('', 0);
  assert.equal(f.positions.length, 2);
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

test('retained cached stream keeps its own cursor while a new homepage is pending', async () => {
  const f = fixture('following');
  f.setCache({posts:[post('a'), post('b'), post('c')], cursor:'old',anchorId:'b',offset:0});
  const first=f.store.loadFirst(false); await tick();
  f.fetches[0].resolve({items:[post('a')],nextCursor:'p2'}); await first;
  const more=f.store.loadMore(); await tick();
  assert.equal(f.fetches[1].cursor,'old');
  f.fetches[1].resolve({items:[post('b')],nextCursor:'p3'}); await tick();
  assert.equal(f.fetches[2].cursor,'p3');
  f.fetches[2].resolve({items:[post('c'),post('d')],nextCursor:'p4'}); await more;
  assert.deepEqual(f.store.posts.map(p=>p.id),['a','b','c','d']);
  assert.equal(f.store.hasMore,true);
  assert.equal(f.saves.at(-1).cursor,'p4');
});

test('duplicate-page batches are bounded and cyclic cursors cannot loop', async () => {
  const f=fixture('following'); const first=f.store.loadFirst(false);await tick();
  f.fetches[0].resolve({items:[post('a')],nextCursor:'p2'});await first;
  const batch=f.store.loadMore();
  for(let i=1;i<=3;i++){await tick();f.fetches[i].resolve({items:[post('a')],nextCursor:'p'+(i+2)});}
  await batch;assert.equal(f.fetches.length,4);assert.equal(f.store.hasMore,true);
  const cyclic=f.store.loadMore();await tick();
  f.fetches[4].resolve({items:[post('a')],nextCursor:'p2'});await cyclic;
  assert.equal(f.store.hasMore,false);assert.equal(f.saves.at(-1).cursor,null);
});

test('cache publishes datasource changes before the network resolves', async()=>{
  const f=fixture('recommend');let snapshots=[];
  f.store.onContentChanged=()=>snapshots.push(f.store.posts.map(p=>p.id));
  f.setCache({posts:[post('cached')],cursor:null,anchorId:'cached',offset:-12});
  const first=f.store.loadFirst(false);await tick();
  assert.deepEqual(snapshots,[['cached']]);
  f.fetches[0].reject(Error('offline'));await first;
});

test('accepting an update invalidates older pagination and continues in server order',async()=>{
 const f=fixture('following');
 f.setCache({posts:[post('old')],cursor:'old-tail',anchorId:'old',offset:-45});
 let changes=0,resets=0;f.store.onContentChanged=()=>changes++;f.store.onStreamReplaced=()=>resets++;
 const first=f.store.loadFirst(false);await tick();
 assert.equal(changes,1);f.fetches[0].resolve({items:[post('new-1')],nextCursor:'new-p2'});await first;
 assert.equal(changes,1);assert.equal(resets,0);
 const oldMore=f.store.loadMore();await tick();assert.equal(f.fetches[1].cursor,'old-tail');
 f.store.acceptPendingUpdate();assert.equal(resets,1);
 f.fetches[1].resolve({items:[post('old-late')],nextCursor:'old-p3'});await oldMore;
 assert.deepEqual(f.store.posts.map(p=>p.id),['new-1']);
 const freshMore=f.store.loadMore();await tick();assert.equal(f.fetches[2].cursor,'new-p2');
 f.fetches[2].resolve({items:[post('new-2'),post('old')],nextCursor:null});await freshMore;
 assert.deepEqual(f.store.posts.map(p=>p.id),['new-1','new-2','old']);
});

test('incomplete offline cache remains readable but its old cursor is never requested',async()=>{
 const f=fixture('recommend');
 f.setCache({posts:[post('retained')],cursor:'unsafe',anchorId:'retained',offset:7,needsRefresh:true});
 const first=f.store.loadFirst(false);await tick();f.fetches[0].reject(Error('offline'));await first;
 assert.equal(f.store.needsRefresh,true);assert.equal(f.store.hasMore,false);
 await f.store.loadMore();assert.equal(f.fetches.length,1);
 assert.deepEqual(f.store.posts.map(p=>p.id),['retained']);
 const refresh=f.store.loadFirst(true);await tick();f.fetches[1].resolve({items:[post('first')],nextCursor:'safe'});await refresh;
 assert.equal(f.store.needsRefresh,false);assert.equal(f.store.hasMore,true);
 assert.deepEqual(f.store.posts.map(p=>p.id),['first']);
});

test('pending update is rejected after a session change and reset removes it',async()=>{
 const f=fixture('recommend');f.setCache({posts:[post('a')],cursor:null,anchorId:'',offset:0});
 const first=f.store.loadFirst(false);await tick();f.fetches[0].resolve({items:[post('b')],nextCursor:'p2'});await first;
 f.logout();f.store.acceptPendingUpdate();assert.deepEqual(f.store.posts.map(p=>p.id),['a']);
 assert.equal(f.store.hasPendingUpdate,false);assert.equal(f.saves.length,0);
 f.store.reset();assert.equal(f.store.hasPendingUpdate,false);assert.equal(f.store.needsRefresh,false);
});

test('explicit empty refresh persists an empty stream rather than reviving stale cache',async()=>{
 const f=fixture('recommend');f.setCache({posts:[post('old')],cursor:'old-tail',anchorId:'old',offset:20});
 const refresh=f.store.loadFirst(true);await tick();f.fetches[0].resolve({items:[],nextCursor:null});await refresh;
 assert.equal(f.store.state,FeedLoadState.Empty);assert.deepEqual(f.store.posts,[]);
 assert.equal(f.saves.at(-1).cursor,null);assert.deepEqual(f.saves.at(-1).posts,[]);
});


test('cold entry displays cache at top and adopts network without a pending badge', async () => {
  const f = fixture('following');
  f.setCache({ posts: [post('old')], cursor: 'old-c', anchorId: 'old', offset: -50 });
  const events = []; f.store.onPendingChanged = pending => events.push(pending);
  const loading = f.store.enter(); await tick();
  assert.equal(f.store.pendingAnchorId, '');
  assert.equal(f.store.pendingAnchorOffset, 0);
  f.fetches[0].resolve({ items: [post('new')], nextCursor: 'new-c' }); await loading;
  assert.deepEqual(f.store.posts.map(p => p.id), ['new']);
  assert.equal(events.includes(true), false);
});

test('tab entry adopts pending update without another request', async () => {
  const f = fixture('recommend');
  f.setCache({ posts: [post('old')], cursor: null, anchorId: '', offset: 0 });
  const loading = f.store.loadFirst(false); await tick();
  f.fetches[0].resolve({ items: [post('new')], nextCursor: 'c' }); await loading;
  assert.equal(f.store.hasPendingUpdate, true);
  await f.store.enter();
  assert.equal(f.fetches.length, 1);
  assert.equal(f.store.hasPendingUpdate, false);
  assert.deepEqual(f.store.posts.map(p => p.id), ['new']);
});

test('tab entry adopts in-flight result once; later background updates still wait', async () => {
  const f = fixture('recommend');
  f.setCache({ posts: [post('old')], cursor: null, anchorId: '', offset: 0 });
  const loading = f.store.loadFirst(false); await tick();
  await f.store.enter();
  assert.equal(f.fetches.length, 1);
  f.fetches[0].resolve({ items: [post('new')], nextCursor: 'c' }); await loading;
  assert.equal(f.store.hasPendingUpdate, false);
  assert.deepEqual(f.store.posts.map(p => p.id), ['new']);
  const background = f.store.loadFirst(false); await tick();
  f.fetches[1].resolve({ items: [post('later')], nextCursor: 'd' }); await background;
  assert.equal(f.store.hasPendingUpdate, true);
  assert.deepEqual(f.store.posts.map(p => p.id), ['new']);
});
