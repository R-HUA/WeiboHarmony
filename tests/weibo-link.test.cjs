const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const domain=load('entry/src/main/ets/domain/WeiboLink.ets');const {parseWeiboLink:p,targetFromWeiboPage:page}=domain;
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
