const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const constants=load('entry/src/main/ets/common/Constants.ets');
const {WeiboMapper}=load('entry/src/main/ets/api/WeiboMapper.ets',{'../common/Constants':constants});
test('synthetic post preserves long IDs, raw semantics and nested repost',()=>{
 const post=WeiboMapper.toPost(require('./fixtures/post.json'));
 assert.equal(post.id,'9007199254740993123');assert.equal(post.userId,'42');assert.equal(post.repost.id,'123');
 assert.equal(post.createdAtTimestamp,null);assert.equal(post.rawCreatedAt,'刚刚');assert.equal(post.isLongText,true);
 assert.match(post.rawText,/<a /);assert.deepEqual(post.pictures,['https://example.invalid/fixture.jpg']);
 assert.deepEqual(post.previewPictures,['https://example.invalid/fixture.jpg']);
});
test('missing fields are tolerated, unsafe numeric IDs are not invented',()=>{
 const post=WeiboMapper.toPost({id:9007199254740992});assert.equal(post.id,'');assert.equal(post.text,'');assert.deepEqual(post.pictures,[]);assert.equal(post.repost,null);
 assert.equal(WeiboMapper.toUser({id:42}).id,'42');assert.equal(WeiboMapper.toComment({id:42}).id,'42');
});
test('absolute timestamps remain parseable',()=>{
 const post=WeiboMapper.toPost({id:'1',created_at:'2026-09-28T00:00:00Z'});assert.equal(post.createdAtTimestamp,Date.parse('2026-09-28T00:00:00Z'));assert.ok(post.fetchedAt>0);
});
test('sinaimg list tier rewrites to wap720 while preview keeps the original',()=>{
 const post=WeiboMapper.toPost({id:'4',pics:[{original:{url:'https://wx3.sinaimg.cn/orj1080/c1.jpg'}}]});
 assert.deepEqual(post.pictures,['https://wx3.sinaimg.cn/wap720/c1.jpg']);
 assert.deepEqual(post.previewPictures,['https://wx3.sinaimg.cn/orj1080/c1.jpg']);
 const small=WeiboMapper.toPost({id:'5',pics:[{url:'https://wx1.sinaimg.cn/thumbnail/t1.jpg'}]});
 assert.deepEqual(small.pictures,['https://wx1.sinaimg.cn/wap720/t1.jpg']);
});
test('desktop friendstimeline pictures fill both tiers via mixed media then pic_infos',()=>{
 const ordered=WeiboMapper.toPost({id:'6',mixed_media_info:{media_list:[
  {type:'pic',pic_info:{bmiddle:{url:'https://wx2.sinaimg.cn/bmiddle/b1.jpg'}}},
  {type:'video'},
  {type:'pic',pic_info:{large:{url:'https://wx2.sinaimg.cn/large/b2.jpg'}}}]}});
 assert.deepEqual(ordered.pictures,['https://wx2.sinaimg.cn/wap720/b1.jpg','https://wx2.sinaimg.cn/wap720/b2.jpg']);
 assert.deepEqual(ordered.previewPictures,['https://wx2.sinaimg.cn/bmiddle/b1.jpg','https://wx2.sinaimg.cn/large/b2.jpg']);
 const dict=WeiboMapper.toPost({id:'7',pic_infos:{
  first:{thumbnail:{url:'https://wx4.sinaimg.cn/thumbnail/d1.jpg'},mw2000:{url:'https://wx4.sinaimg.cn/mw2000/d1.jpg'}},
  second:{original:{url:'https://wx4.sinaimg.cn/large/d2.jpg'}}}});
 assert.equal(dict.pictures.length,2);assert.equal(dict.previewPictures.length,2);
 assert.ok(dict.previewPictures.includes('https://wx4.sinaimg.cn/mw2000/d1.jpg'));
 assert.ok(dict.previewPictures.includes('https://wx4.sinaimg.cn/large/d2.jpg'));
 assert.ok(dict.pictures.every(u=>u.includes('/wap720/')));
 const both=WeiboMapper.toPost({id:'8',pics:[{large:{url:'https://wx1.sinaimg.cn/large/x1.jpg'}}],pic_infos:{
  ignored:{large:{url:'https://wx1.sinaimg.cn/large/skip.jpg'}}}});
 assert.deepEqual(both.pictures,['https://wx1.sinaimg.cn/wap720/x1.jpg']);
});
test('video cover falls back through desktop fields and rewrites to wap720',()=>{
 const mobile=WeiboMapper.toPost({id:'9',page_info:{page_pic:{url:'https://wx1.sinaimg.cn/large/v1.jpg'}}});
 assert.equal(mobile.videoCoverUrl,'https://wx1.sinaimg.cn/wap720/v1.jpg');
 const desktop=WeiboMapper.toPost({id:'10',page_info:{media_info:{image:'https://wx2.sinaimg.cn/large/v2.jpg'}}});
 assert.equal(desktop.videoCoverUrl,'https://wx2.sinaimg.cn/wap720/v2.jpg');
 const top=WeiboMapper.toPost({id:'11',bmiddle_pic:'http://wx3.sinaimg.cn/bmiddle/v3.jpg'});
 assert.equal(top.videoCoverUrl,'https://wx3.sinaimg.cn/wap720/v3.jpg');
 assert.equal(WeiboMapper.toPost({id:'12'}).videoCoverUrl,'');
});
