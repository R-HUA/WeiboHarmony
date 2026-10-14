const { test } = require('node:test');
const assert = require('node:assert/strict');
const load = require('./load.cjs');
const constants = load('entry/src/main/ets/common/Constants.ets');
const { WeiboMapper } = load('entry/src/main/ets/api/WeiboMapper.ets', { '../common/Constants': constants });
const { ResponseCache } = load('entry/src/main/ets/domain/ResponseCache.ts');
const model = load('entry/src/main/ets/model/WeiboModel.ets');
global.Observed = value => value;

// 响应仅为官方脚本字段的离线用例，不代表线上会话核验。
const filters = [
  { title: '<span>按热度</span>', param: 'flow=hot-value', isDefault: 1 },
  { title: '按时间', param: 'flow=time-value', isDefault: 0 },
];
const rawComment = id => ({ idstr: id, user: { idstr: 'u1', screen_name: '作者' }, text: '正文' });
const rawPage = (ids = ['c1'], maxId = '0') => ({ ok: 1, data: ids.map(rawComment), filter_group: filters, max_id: maxId, total_number: 12 });
const post = { id: 'p1', userId: 'u1', commentBulletinMode: 1 };
function deferred() {
  let resolve, reject;
  const promise = new Promise((r, j) => { resolve = r; reject = j; });
  return { promise, resolve, reject };
}
function serviceFixture() {
  const reads = [], writes = [];
  let generation = 0, listener, loggedIn = true;
  const auth = {
    getGeneration: () => generation, onSessionChange: cb => { listener = cb; },
    hasCookie: () => loggedIn, getDesktopCookie: () => loggedIn ? 'desktop' : '',
    getCookie: () => loggedIn ? 'mobile' : '',
  };
  const { WeiboService } = load('entry/src/main/ets/service/WeiboService.ets', {
    '../model/WeiboModel': model,
    '../api/WeiboMapper': { WeiboMapper }, '../domain/ResponseCache': { ResponseCache }, '../common/Constants': constants,
    '../store/PostEntities': { PostEntities: { shared: () => ({ clear() {} }) } },
    '@kit.RemoteCommunicationKit': { rcp: { Form: class { constructor(fields) { this.fields = fields; } } } },
    '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, info() {}, warn() {} } },
    '../network/WeiboHttpClient': { WeiboHttpClient: {
      getDesktop(url, cookie) { const d = deferred(); reads.push({ url, cookie, ...d }); return d.promise; },
      postForm(url, cookie, form) { const d = deferred(); writes.push({ url, cookie, form, ...d }); return d.promise; },
    } },
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => auth } }, './WeiboVisitorSession': {},
  });
  return { service: new WeiboService(), reads, writes, logout() { generation++; loggedIn = false; listener(); } };
}
function storeFixture() {
  const requests = [];
  let generation = 0;
  const fetch = (post, rootId, param, cursor) => {
    const d = deferred(); requests.push({ post, rootId, param, cursor, ...d }); return d.promise;
  };
  const { WeiboCommentsStore } = load('entry/src/main/ets/store/WeiboCommentsStore.ets', {
    '../service/WeiboService': { WeiboService: { getInstance: () => ({
      fetchComments: (post, param, cursor) => fetch(post, '', param, cursor),
      fetchCommentReplies: fetch,
    }) } },
    '../service/WeiboAuthManager': { WeiboAuthManager: { getInstance: () => ({ getGeneration: () => generation }) } },
  });
  return { store: new WeiboCommentsStore(), requests, logout() { generation++; } };
}
const page = (ids, maxId = '0') => WeiboMapper.commentsPage(rawPage(ids, maxId), null);

test('repost and like lists retain their own identifiers and server pagination', () => {
  const item = { idstr: '90071992547409931', user: { idstr: 'u1', screen_name: '作者' }, text: '<b>转发正文</b>', created_at: '刚刚' };
  const reposts = WeiboMapper.interactionsPage({ data: [item], total_number: 40, max_page: 2 }, 'reposts');
  assert.equal(reposts.items[0].id, item.idstr);
  assert.equal(reposts.items[0].rawText, item.text);
  assert.equal(reposts.maxPage, 2);
  const likes = WeiboMapper.interactionsPage({ data: [{ user: item.user }], total_number: 1 }, 'likes');
  assert.equal(likes.items[0].id, 'u1');
  assert.equal(likes.items[0].userName, '作者');
  assert.deepEqual(WeiboMapper.interactionsPage({ data: [], total_number: 0, max_page: 0 }, 'reposts').items, []);
  assert.throws(() => WeiboMapper.interactionsPage({ data: [], total_number: 4 }, 'reposts'), /分页/);
  assert.throws(() => WeiboMapper.interactionsPage({ data: [{}], total_number: 1 }, 'likes'), /用户/);
  assert.throws(() => WeiboMapper.interactionsPage({ data: [], total_number: -1 }, 'likes'), /信息/);
});

test('interaction tabs use the official desktop endpoints and page parameters', async () => {
  const f = serviceFixture();
  for (const [kind, endpoint] of [['reposts', 'repostTimeline'], ['likes', 'likeShow']]) {
    const request = f.service.fetchInteractions('p1', kind, 2);
    const url = new URL(f.reads.at(-1).url);
    assert.equal(url.pathname, `/ajax/statuses/${endpoint}`);
    assert.equal(url.searchParams.get('id'), 'p1');
    assert.equal(url.searchParams.get('page'), '2');
    assert.equal(url.searchParams.get('count'), '20');
    if (kind === 'reposts') { assert.equal(url.searchParams.get('moduleID'), 'feed'); }
    else {
      assert.equal(url.searchParams.get('attitude_type'), '0');
      assert.equal(url.searchParams.get('attitude_enable'), '1');
    }
    f.reads.at(-1).resolve(JSON.stringify({ ok: 1, data: [], total_number: 0, max_page: 0 }));
    assert.deepEqual((await request).items, []);
  }
});

test('comment repost submits the selected comment and user draft and rejects stale sessions', async () => {
  const f = serviceFixture(), request = f.service.repostComment('p1', 'child', ' //@作者:评论 ');
  assert.equal(f.writes[0].url, 'https://weibo.com/ajax/statuses/normal_repost');
  assert.deepEqual(f.writes[0].form.fields, { id: 'p1', cid: 'child', comment: '//@作者:评论', is_comment: '0' });
  f.writes[0].resolve('{"ok":1}'); await request;
  await assert.rejects(f.service.repostComment('p1', 'child', '  '), /不能为空/);
  const stale = f.service.repostComment('p1', 'child', '草稿');
  f.logout(); f.writes[1].resolve('{"ok":1}');
  await assert.rejects(stale, /取消/);
  await assert.rejects(f.service.repostComment('p1', 'child', '草稿'), /登录/);
});

test('comment IDs, root, reply target and previews retain actual relationships', () => {
  const mapped = WeiboMapper.toComment({ ...rawComment('90071992547409931'), rootid: 0, total_number: 4,
    comments: [{ ...rawComment('child'), reply_comment: { ...rawComment('target'), user: { idstr: 'u2', screen_name: '被回复者' } } }] });
  assert.equal(mapped.rootId, mapped.id);
  assert.equal(mapped.replyCount, 4);
  assert.equal(mapped.replies[0].rootId, mapped.id);
  assert.deepEqual(mapped.replies[0].replyTo, { id: 'target', userId: 'u2', userName: '被回复者' });
  assert.equal(WeiboMapper.toComment(rawComment('next'), mapped.id).rootId, mapped.id);
  assert.throws(() => WeiboMapper.toComment({ id: Number.MAX_SAFE_INTEGER + 1 }), /标识/);
  assert.throws(() => WeiboMapper.toComment({ ...rawComment('root'), comments: [{}] }), /标识/);
});

test('server order, sorting metadata and two-part cursors are retained', () => {
  const response = { ...rawPage(['older', 'newer'], '90071992547409931'), max_id_type: 2 };
  const mapped = WeiboMapper.commentsPage(response, null);
  assert.deepEqual(mapped.items.map(item => item.id), ['older', 'newer']);
  assert.deepEqual(mapped.filters, [
    { order: 'hot', param: 'flow=hot-value', isDefault: true },
    { order: 'latest', param: 'flow=time-value', isDefault: false },
  ]);
  assert.deepEqual(mapped.nextCursor, { maxId: '90071992547409931', maxIdType: '2' });
  const stringDefault = WeiboMapper.commentsPage({ ...response, filter_group: [{ ...filters[0], isDefault: '1' }] }, null);
  assert.equal(stringDefault.filters[0].isDefault, true);
  assert.equal(WeiboMapper.commentsPage(response, mapped.nextCursor).nextCursor, null);
  assert.equal(WeiboMapper.commentsPage(rawPage([], 'next'), null).nextCursor, null);
  assert.throws(() => WeiboMapper.commentsPage({ ok: 1 }, null), /列表/);
  assert.throws(() => WeiboMapper.commentsPage({ ...response, max_id: Number.MAX_SAFE_INTEGER + 1 }, null), /游标/);
});

test('main comments and child replies use distinct buildComments parameters and server cursor', async () => {
  const f = serviceFixture();
  const main = f.service.fetchComments(post, 'flow=hot-value');
  const query = new URL(f.reads[0].url).searchParams;
  assert.equal(query.get('id'), 'p1'); assert.equal(query.get('uid'), 'u1');
  assert.equal(query.get('is_mix'), '0'); assert.equal(query.get('fetch_level'), '0');
  assert.equal(query.get('is_show_bulletin'), '1'); assert.equal(query.get('flow'), 'hot-value');
  f.reads[0].resolve(JSON.stringify(rawPage())); await main;
  const child = f.service.fetchCommentReplies(post, 'root', 'flow=time-value', { maxId: 'next', maxIdType: '2' });
  const childQuery = new URL(f.reads[1].url).searchParams;
  assert.equal(childQuery.get('id'), 'root'); assert.equal(childQuery.get('is_mix'), '1');
  assert.equal(childQuery.get('fetch_level'), '1'); assert.equal(childQuery.get('is_show_bulletin'), '2');
  assert.equal(childQuery.get('max_id'), 'next'); assert.equal(childQuery.get('max_id_type'), '2');
  assert.equal(childQuery.get('flow'), 'time-value');
  f.reads[1].resolve(JSON.stringify(rawPage())); await child;
  await assert.rejects(f.service.fetchComments(post, 'invented'), /排序参数/);
});

test('reply sends actual selected comment ID and invalidates both cached orders', async () => {
  const f = serviceFixture();
  for (const param of ['', 'flow=hot-value', 'flow=time-value']) {
    const read = f.service.fetchComments(post, param);
    f.reads.at(-1).resolve(JSON.stringify(rawPage())); await read;
  }
  await f.service.fetchComments(post, 'flow=hot-value'); assert.equal(f.reads.length, 3);
  for (const cid of ['root', 'child']) {
    const send = f.service.publishReply('p1', cid, ' 草稿正文 ');
    assert.equal(f.writes.at(-1).url, 'https://weibo.com/ajax/comments/reply');
    assert.deepEqual(f.writes.at(-1).form.fields, { id: 'p1', cid, comment: '草稿正文' });
    f.writes.at(-1).resolve('{"ok":1}'); await send;
    for (const param of ['', 'flow=hot-value', 'flow=time-value']) {
      const read = f.service.fetchComments(post, param);
      f.reads.at(-1).resolve(JSON.stringify(rawPage())); await read;
    }
  }
  assert.equal(f.reads.length, 9);
});

test('failed writes invalidate pending and newly loaded comments; session change drops cache', async () => {
  const f = serviceFixture();
  const stale = assert.rejects(f.service.fetchComments(post, 'flow=time-value'), /数据已更新/);
  const send = f.service.publishComment('p1', '草稿');
  f.reads[0].resolve(JSON.stringify(rawPage())); await stale;
  const during = f.service.fetchComments(post, 'flow=hot-value');
  f.reads[1].resolve(JSON.stringify(rawPage())); await during;
  f.writes[0].reject(Error('发送结果未知')); await assert.rejects(send, /未知/);
  const fresh = f.service.fetchComments(post, 'flow=hot-value');
  assert.equal(f.reads.length, 3); f.reads[2].resolve(JSON.stringify(rawPage())); await fresh;
  f.logout(); const guest = f.service.fetchComments(post, 'flow=hot-value');
  assert.equal(f.reads.length, 4); assert.equal(f.reads[3].cookie, '');
  f.reads[3].resolve(JSON.stringify(rawPage())); await guest;
  await assert.rejects(f.service.publishReply('p1', 'root', 'draft'), /登录/);
});

test('sort switch resets cursor and rejects late append and old finally blocks', async () => {
  const f = storeFixture(), initial = f.store.load(post);
  f.requests[0].resolve(page(['hot'], 'next')); await initial;
  const old = f.store.load(post, '', true), switched = f.store.selectOrder('latest', post);
  assert.equal(f.requests[2].param, 'flow=time-value'); assert.equal(f.requests[2].cursor, null);
  assert.deepEqual(f.store.items, []);
  f.requests[2].resolve(page(['latest'], 'next-latest')); await switched;
  const next = f.store.load(post, '', true);
  f.requests[1].reject(Error('迟到失败')); await old;
  assert.equal(f.store.loading, true); assert.equal(f.store.errorMessage, '');
  f.requests[3].resolve(page(['latest', 'second', 'second'])); await next;
  assert.deepEqual(f.store.items.map(item => item.id), ['latest', 'second']);
  assert.equal(f.store.nextCursor, null);
});

test('server default latest triggers an explicit hot request; missing sort is an error', async () => {
  const f = storeFixture(), initial = f.store.load(post);
  const metadata = page(['latest']); metadata.filters.forEach(item => { item.isDefault = item.order === 'latest'; });
  f.requests[0].resolve(metadata); await Promise.resolve();
  assert.equal(f.requests[1].rootId, ''); assert.equal(f.requests[1].param, 'flow=hot-value');
  f.requests[1].resolve(page(['hot'])); await initial;
  assert.equal(f.store.items[0].id, 'hot');
  const missing = storeFixture(), request = missing.store.load(post);
  missing.requests[0].resolve({ ...page(['a']), filters: [] }); await request;
  assert.match(missing.store.errorMessage, /排序信息/); assert.equal(missing.store.loaded, false);
});

test('child replies keep server order without requiring or sending sorting filters', async () => {
  for (const childFilters of [[], page(['a']).filters.map(item => ({ ...item, isDefault: item.order === 'latest' }))]) {
    const f = storeFixture(), initial = f.store.load(post, 'root');
    f.requests[0].resolve({ ...page(['a', 'b'], 'next'), filters: childFilters }); await initial;
    assert.equal(f.requests.length, 1); assert.equal(f.requests[0].param, '');
    assert.equal(f.store.errorMessage, ''); assert.deepEqual(f.store.filters, []);
    assert.deepEqual(f.store.items.map(item => item.id), ['a', 'b']);
    const more = f.store.load(post, 'root', true);
    assert.equal(f.requests[1].param, ''); assert.equal(f.requests[1].cursor.maxId, 'next');
    f.requests[1].resolve({ ...page(['c']), filters: [] }); await more;
    assert.deepEqual(f.store.items.map(item => item.id), ['a', 'b', 'c']);
  }
});

test('pagination without total count keeps the server count from the first page', async () => {
  const f = storeFixture(), initial = f.store.load(post);
  f.requests[0].resolve(page(['a'], 'next')); await initial;
  const more = f.store.load(post, '', true);
  f.requests[1].resolve({ ...page(['b']), totalCount: undefined }); await more;
  assert.equal(f.store.totalCount, 12);
});

test('reply pagination failure retains data and cursor; cancel and session reject late updates', async () => {
  const f = storeFixture(), initial = f.store.load(post, 'root');
  f.requests[0].resolve(page(['a'], 'p2')); await initial;
  const more = f.store.load(post, 'root', true); f.requests[1].reject(Error('离线')); await more;
  assert.equal(f.store.nextCursor.maxId, 'p2'); assert.equal(f.store.items[0].id, 'a'); assert.equal(f.store.errorMessage, '离线');
  const retry = f.store.load(post, 'root', true); f.store.cancel();
  f.requests[2].resolve(page(['stale'])); await retry;
  assert.equal(f.store.items[0].id, 'a'); assert.equal(f.store.loading, false);
  const newSession = f.store.load(post, 'root'); f.logout(); f.store.cancel();
  f.requests[3].resolve(page(['private'])); await newSession;
  assert.equal(f.store.items[0].id, 'a');
});

test('total and category boards map pinned rank, missing heat and exact topic query independently', () => {
  const result = WeiboMapper.hotTopics({ hotgovs: [{ word: '置顶', word_scheme: '#置顶原词#' }], realtime: [
    { word: '显示标题', word_scheme: '#完整查询词#', rank: 0, num: 0 },
    { word: '普通词', topic_flag: 1, realpos: 4, label_name: '新' },
  ] });
  assert.equal(result[0].rank, null); assert.equal(result[0].heat, null);
  assert.equal(result[1].rank, 1); assert.equal(result[1].heat, 0); assert.equal(result[1].query, '#完整查询词#');
  assert.equal(result[2].rank, 4); assert.equal(result[2].query, '#普通词#');
  const category = WeiboMapper.hotTopics({ band_list: [{ word: '分类标题', topic: '分类完整话题', rank: 0, description: '今日登顶' }] });
  assert.equal(category[0].query, '#分类完整话题#'); assert.equal(category[0].description, '今日登顶');
  assert.equal(WeiboMapper.hotTopics({ band_list: [{ word: '关键词' }] })[0].query, '关键词');
  assert.deepEqual(WeiboMapper.hotTopics({ band_list: [] }), []);
  assert.throws(() => WeiboMapper.hotTopics({}), /榜单/);
  assert.throws(() => WeiboMapper.hotTopics({ band_list: [{}] }), /名称/);
});

test('each hot category calls its official endpoint; Mine requires existing login', async () => {
  const f = serviceFixture();
  for (const [category, endpoint] of Object.entries({ hot: 'side/hotSearch', tech: 'statuses/technology', entertainment: 'statuses/entertainment',
    life: 'statuses/life', social: 'statuses/social', sports: 'statuses/sport', animation: 'statuses/acg', mine: 'statuses/mineBand' })) {
    const read = f.service.fetchHotTopics(category); assert.equal(f.reads.at(-1).url, `https://weibo.com/ajax/${endpoint}`);
    f.reads.at(-1).resolve(JSON.stringify({ ok: 1, data: category === 'hot' ? { realtime: [] } : { band_list: [] } }));
    assert.deepEqual(await read, []);
  }
  f.logout(); await assert.rejects(f.service.fetchHotTopics('mine'), /登录/); assert.equal(f.reads.length, 8);
  const blocked = f.service.fetchHotTopics('tech');
  f.reads[8].resolve('{"ok":-100,"url":"https://weibo.com/login.php"}'); await assert.rejects(blocked, /登录/);
});
