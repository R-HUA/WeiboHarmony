const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const domain=load('entry/src/main/ets/domain/WeiboLink.ets');const {parseWeiboLink:p,targetFromWeiboPage:page,isImageViewText,imageFromWeiboPage}=domain;
test('post, profile, topic and video links keep distinct identities',()=>{
 for(const url of ['https://m.weibo.cn/status/Ab123','https://weibo.com/123/Ab123','https://m.weibo.cn/detail/123'])assert.equal(p(url).kind,'post');
 assert.equal(p('https://weibo.com/u/123').id,'123');assert.equal(p('https://m.weibo.cn/profile/123').kind,'user');
 assert.equal(p('https://weibo.com/n/%E7%94%B2').id,'甲');
 assert.equal(p('https://weibo.com/tv/show/1034:123').kind,'video');
 assert.equal(p('https://video.weibo.com/show?fid=1034:123&mid=456').id,'456');
 assert.equal(p('https://s.weibo.com/weibo?q=%23test%23').id,'#test#');
});
test('host spoofing, credentials and script URLs cannot become native routes',()=>{
 for(const url of ['https://weibo.com.evil.test/u/123','https://weibo.com@evil.test/u/123','https://evil.test/weibo.com/u/123'])assert.equal(p(url).kind,'external');
 assert.equal(p('javascript:alert(1)').kind,'unsupported');
});
test('video page needs explicit post metadata; fid is not a post ID',()=>{
 const source=p('https://weibo.com/tv/show/1034:123');
 assert.equal(page('<meta property="og:url" content="https://m.weibo.cn/status/9007199254740993123">',source).id,'9007199254740993123');
 assert.equal(page('{"fid":"1034:123","id":"456"}',source).kind,'video');
});
function resolver(responses){let closed=false;const requests=[];
 const api={createSession:()=>({fetch:async request=>{requests.push(request);return responses.shift()},close:()=>closed=true}),Request:class {constructor(url,method){this.url=url;this.method=method}}};
 const {resolveWeiboLink}=load('entry/src/main/ets/service/WeiboLinkResolver.ets',{'@kit.RemoteCommunicationKit':{rcp:api},'../domain/WeiboLink':domain});
 return {resolveWeiboLink,requests,closed:()=>closed};
}
test('shortlink redirects to native post without fetching it or adding cookies',async()=>{
 const f=resolver([{statusCode:302,headers:{location:'https://m.weibo.cn/status/123'}}]);
 assert.equal((await f.resolveWeiboLink('https://t.cn/test')).kind,'post');
 assert.equal(f.requests.length,1);assert.equal(f.requests[0].headers,undefined);assert.ok(f.closed());
});
test('external redirects stop resolution, loops close their session',async()=>{
 const f=resolver([{statusCode:302,headers:{location:'https://example.com/'}}]);
 assert.equal((await f.resolveWeiboLink('https://t.cn/test')).kind,'external');assert.equal(f.requests.length,1);
 const loop=resolver([{statusCode:302,headers:{location:'https://t.cn/test'}}]);
 await loop.resolveWeiboLink('https://t.cn/test');assert.equal(loop.requests.length,1);assert.ok(loop.closed());
});
test('failed resolution preserves original URL and closes session',async()=>{
 const f=resolver([{statusCode:503,headers:{}}]);
 assert.equal((await f.resolveWeiboLink('https://t.cn/test')).url,'https://t.cn/test');assert.ok(f.closed());
});
test('HTML shortlink landing and canonical video metadata open native post',async()=>{
 const f=resolver([{statusCode:200,headers:{},toString:async()=>'<meta http-equiv="refresh" content="0;url=https://m.weibo.cn/status/123">'}]);
 assert.equal((await f.resolveWeiboLink('https://t.cn/test')).kind,'post');
 const v=resolver([{statusCode:200,headers:{},toString:async()=>'<link rel="canonical" href="https://weibo.com/42/Abc123">'}]);
 assert.equal((await v.resolveWeiboLink('https://weibo.com/tv/show/1034:123')).id,'Abc123');
});

test('weibo image CDN links are images, other hosts stay external',()=>{
 const shot='https://wx3.sinaimg.cn/large/8864d058gy1ihkiheo809j214z14zqmu.jpg';
 assert.equal(p(shot).kind,'image');assert.equal(p(shot).url,shot);
 assert.equal(p('http://wx1.sinaimg.cn/mw690/abc.webp').kind,'image');
 assert.equal(p('http://wx1.sinaimg.cn/mw690/abc.webp').url,'https://wx1.sinaimg.cn/mw690/abc.webp');
 assert.equal(p('https://tvax1.sinaimg.cn/large/006APoFYly1gxxx.png').kind,'image');
 assert.equal(p('https://wx2.sinaimg.cn/large/006APoFYly1gxxx').kind,'image');
 assert.equal(p('https://f.video.weibocdn.com/o0/abc.mp4').kind,'external');
 for(const url of ['https://evil.test/a.jpg','https://example.com/large/a.jpg','https://sinaimg.cn.evil.test/a.jpg'])
  assert.equal(p(url).kind,'external');
});
test('view-image anchor text is recognized, ordinary label text is not',()=>{
 for(const text of ['查看图片','查看原图','查看大图',' 查看图片 ','查看图片>>','共9张图 查看图片'])assert.equal(isImageViewText(text),true);
 for(const text of ['网页链接','全文','@某人','#话题#','图片质量不错',''])assert.equal(isImageViewText(text),false);
});
test('landing page og:image supplies the picture when the anchor only says 查看图片',()=>{
 const html='<meta content="https://wx3.sinaimg.cn/orj360/006APoFYly1abc.jpg" property="og:image">';
 assert.equal(imageFromWeiboPage(html),'https://wx3.sinaimg.cn/orj360/006APoFYly1abc.jpg');
 assert.equal(imageFromWeiboPage("<meta property='og:image' content='//wx1.sinaimg.cn/large/a.png'>"),'https://wx1.sinaimg.cn/large/a.png');
 assert.equal(imageFromWeiboPage('$CONFIG[\'page_pic\'] = "https://wx2.sinaimg.cn/large/b.jpg"'),'https://wx2.sinaimg.cn/large/b.jpg');
 assert.equal(imageFromWeiboPage('<meta property="og:image" content="https://example.com/a.jpg">'),'');
 assert.equal(imageFromWeiboPage('<html>no picture</html>'),'');
});
test('resolver only digs out the picture when the anchor asked for one',async()=>{
 const html='<meta property="og:image" content="https://wx3.sinaimg.cn/large/abc.jpg">';
 const wanted=resolver([{statusCode:200,headers:{},toString:async()=>html}]);
 const target=await wanted.resolveWeiboLink('https://t.cn/somewhere',true);
 assert.equal(target.kind,'image');assert.equal(target.url,'https://wx3.sinaimg.cn/large/abc.jpg');
 assert.ok(wanted.closed());
 const plain=resolver([{statusCode:200,headers:{},toString:async()=>html}]);
 assert.equal((await plain.resolveWeiboLink('https://t.cn/somewhere')).kind,'short');
 const post=resolver([{statusCode:200,headers:{},toString:async()=>html}]);
 assert.equal((await post.resolveWeiboLink('https://m.weibo.cn/status/Ab123',true)).kind,'image');
 assert.equal(post.requests.length,1);
 const untouched=resolver([]);
 assert.equal((await untouched.resolveWeiboLink('https://m.weibo.cn/status/Ab123')).kind,'post');
 assert.equal(untouched.requests.length,0);
 const empty=resolver([{statusCode:200,headers:{},toString:async()=>'<html>no picture</html>'}]);
 assert.equal((await empty.resolveWeiboLink('https://m.weibo.cn/status/Ab123',true)).kind,'post');
});
test('a transition page picture never hijacks the redirect to the real landing page',async()=>{
 const transition='<meta property="og:image" content="https://wx3.sinaimg.cn/large/logo.jpg">'
  +'<meta http-equiv="refresh" content="0;url=https://m.weibo.cn/status/456">';
 const follow=resolver([{statusCode:200,headers:{},toString:async()=>transition},
  {statusCode:200,headers:{},toString:async()=>'<meta property="og:image" content="https://wx3.sinaimg.cn/large/real.jpg">'}]);
 const target=await follow.resolveWeiboLink('https://t.cn/transition',true);
 assert.equal(target.kind,'image');assert.equal(target.url,'https://wx3.sinaimg.cn/large/real.jpg');
 assert.equal(follow.requests.length,2);
 const bare=resolver([{statusCode:200,headers:{},toString:async()=>transition},
  {statusCode:200,headers:{},toString:async()=>'<html>final</html>'}]);
 assert.equal((await bare.resolveWeiboLink('https://t.cn/transition',true)).kind,'post');
});
