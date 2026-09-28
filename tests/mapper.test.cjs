const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const constants=load('entry/src/main/ets/common/Constants.ets');
const {WeiboMapper}=load('entry/src/main/ets/api/WeiboMapper.ets',{'../common/Constants':constants});
test('synthetic post preserves long IDs, raw semantics and nested repost',()=>{
 const post=WeiboMapper.toPost(require('./fixtures/post.json'));
 assert.equal(post.id,'9007199254740993123');assert.equal(post.userId,'42');assert.equal(post.repost.id,'123');
 assert.equal(post.createdAtTimestamp,null);assert.equal(post.rawCreatedAt,'刚刚');assert.equal(post.isLongText,true);
 assert.match(post.rawText,/<a /);assert.deepEqual(post.pictures,['https://example.invalid/fixture.jpg']);
});
test('missing fields are tolerated, unsafe numeric IDs are not invented',()=>{
 const post=WeiboMapper.toPost({id:9007199254740992});assert.equal(post.id,'');assert.equal(post.text,'');assert.deepEqual(post.pictures,[]);assert.equal(post.repost,null);
 assert.equal(WeiboMapper.toUser({id:42}).id,'42');assert.equal(WeiboMapper.toComment({id:42}).id,'42');
});
test('absolute timestamps remain parseable',()=>{
 const post=WeiboMapper.toPost({id:'1',created_at:'2026-09-28T00:00:00Z'});assert.equal(post.createdAtTimestamp,Date.parse('2026-09-28T00:00:00Z'));assert.ok(post.fetchedAt>0);
});
