const {test}=require('node:test');
const assert=require('node:assert/strict');
const load=require('./load.cjs');
const constants=load('entry/src/main/ets/common/Constants.ets');
const rich=load('entry/src/main/ets/common/RichText.ets',{'./Constants':constants});
const media=load('entry/src/main/ets/common/WeiboMedia.ets');
const {WeiboMapper}=load('entry/src/main/ets/api/WeiboMapper.ets',{'../common/Constants':constants});
const {buildWeiboThreadItem}=load('entry/src/main/ets/common/WeiboCardItems.ets',{'./RichText':rich,'./WeiboMedia':media});
function video(id,url,objectId){return {id,text:'视频正文',user:{id:'42',screen_name:'原作者'},page_info:{object_id:objectId,media_info:{stream_url:url}}};}

test('a duplicated original video belongs only inside the repost block in feed and detail',()=>{
 const post=WeiboMapper.toPost({...video('2','https://cdn.invalid/a.mp4'),retweeted_status:video('1','https://cdn.invalid/a.mp4')});
 const card=buildWeiboThreadItem(post);
 assert.equal(card.videoUrl,'');assert.equal(card.repostVideoUrl,post.repost.videoUrl);
 assert.equal(media.ownVideoUrl(post),'');assert.equal(media.ownVideoUrl(post.repost),post.repost.videoUrl);
});
test('media identity deduplicates different renditions while unrelated parent video survives',()=>{
 const original=video('1','https://cdn.invalid/a.mp4','1034:42');
 const parent=video('2','https://cdn.invalid/hd.mp4','1034:42');
 assert.equal(buildWeiboThreadItem(WeiboMapper.toPost({...parent,retweeted_status:original})).videoUrl,'');
 const distinct=buildWeiboThreadItem(WeiboMapper.toPost({...video('3','https://cdn.invalid/other.mp4','1034:43'),retweeted_status:original}));
 assert.equal(distinct.videoUrl,'https://cdn.invalid/other.mp4');assert.equal(distinct.repostVideoUrl,'https://cdn.invalid/a.mp4');
});
test('different media query parameters alone do not prove shared ownership',()=>{
 const post=WeiboMapper.toPost({...video('2','https://cdn.invalid/play?id=2'),retweeted_status:video('1','https://cdn.invalid/play?id=1')});
 assert.equal(buildWeiboThreadItem(post).videoUrl,post.videoUrl);
});
test('original-only and parent-only videos stay with their owner; mapping leaves cached data intact',()=>{
 const parent=WeiboMapper.toPost({id:'2',retweeted_status:video('1','https://cdn.invalid/a.mp4')});
 const before=JSON.stringify(parent);assert.equal(buildWeiboThreadItem(parent).repostVideoUrl,parent.repost.videoUrl);assert.equal(JSON.stringify(parent),before);
 const onlyParent=buildWeiboThreadItem(WeiboMapper.toPost({...video('2','https://cdn.invalid/b.mp4'),retweeted_status:{id:'1',text:'无视频'}}));
 assert.equal(onlyParent.videoUrl,'https://cdn.invalid/b.mp4');assert.equal(onlyParent.repostVideoUrl,undefined);
});
