const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const policy=load('entry/src/main/ets/domain/RequestPolicy.ts');
// 离线跑 WeiboHttpClient：用假 rcp.Session 记录真实发出去的头，RequestQueue 直通。
function client(responses){const sent=[];let cancelled=0;
 const rcp={Form:class{constructor(fields){this.fields=fields}},
  Request:class{constructor(url,method){this.url=url;this.method=method}},
  createSession:()=>({fetch:async request=>{sent.push(request);return responses.shift()},close(){} ,cancel:()=>{cancelled++}})};
 const {WeiboHttpClient}=load('entry/src/main/ets/network/WeiboHttpClient.ets',{
  '@kit.RemoteCommunicationKit':{rcp},
  '@kit.BasicServicesKit':{BusinessError:class extends Error{}},
  '../domain/RequestQueue':{RequestQueue:class{constructor(){}enqueue(task){return task()}invalidate(){}}},
  '../domain/RequestPolicy':policy
 });
 return {client:WeiboHttpClient,sent,cancelled:()=>cancelled};
}
const ok=()=>({statusCode:200,headers:{},toString:async()=>'ok'});
test('read requests stay browser-like and never invent an Origin header',async()=>{
 const f=client([ok(),ok()]);
 await f.client.get('https://m.weibo.cn/api/config','SUB=x');
 await f.client.getDesktop('https://weibo.com/ajax/feed','SUB=x');
 const [mobile,desktop]=f.sent.map(request=>request.headers);
 assert.equal(mobile.Origin,undefined);assert.equal(desktop.Origin,undefined);
 assert.equal(mobile.Referer,'https://m.weibo.cn/');
 assert.equal(desktop.Referer,'https://weibo.com/');
 assert.deepEqual(f.sent.map(request=>request.method),['GET','GET']);
});
test('only write requests add Origin, and they keep the double-submit token',async()=>{
 const f=client([ok(),ok()]);
 await f.client.postForm('https://weibo.com/ajax/friendships/create','SUB=x; XSRF-TOKEN=abc',{});
 await f.client.postForm('https://m.weibo.cn/api/comments/create','SUB=y',{});
 const [desktop,mobile]=f.sent.map(request=>request.headers);
 assert.deepEqual(f.sent.map(request=>request.method),['POST','POST']);
 assert.equal(desktop.Origin,'https://weibo.com');
 assert.equal(desktop['X-XSRF-TOKEN'],'abc');
 assert.equal(mobile.Origin,'https://m.weibo.cn');
 // 没有 XSRF-TOKEN 时不发空的自定义头，交给服务端自己的判断。
 assert.equal(mobile['X-XSRF-TOKEN'],undefined);
});
test('refreshed cookies reach the auth sink whatever the header casing is',async()=>{
 const seen=[];const sink=(origin,setCookie)=>seen.push([origin,setCookie]);
 const lower=client([{statusCode:200,headers:{'set-cookie':'XSRF-TOKEN=rotated; Path=/'},toString:async()=>'ok'}]);
 lower.client.setCookieSink(sink);
 await lower.client.get('https://weibo.com/ajax/feed','SUB=x');
 const upper=client([{statusCode:200,headers:{'Set-Cookie':['XSRF-TOKEN=a; Path=/','SUB=b']},toString:async()=>'ok'}]);
 upper.client.setCookieSink(sink);
 await upper.client.get('https://m.weibo.cn/api/config','SUB=x');
 assert.deepEqual(seen,[['https://weibo.com/','XSRF-TOKEN=rotated; Path=/'],['https://m.weibo.cn/','XSRF-TOKEN=a; Path=/\nSUB=b']]);
});
test('a rejected write still hands over the new token and reports its status',async()=>{
 const seen=[];
 const f=client([{statusCode:403,headers:{'Set-Cookie':'XSRF-TOKEN=fresh; Path=/'},toString:async()=>''}]);
 f.client.setCookieSink((origin,setCookie)=>seen.push(setCookie));
 await assert.rejects(f.client.postForm('https://weibo.com/ajax/friendships/create','SUB=x; XSRF-TOKEN=old',{}),error=>{
  assert.equal(error.code,403);assert.match(error.message,/拒绝/);return true;
 });
 assert.deepEqual(seen,['XSRF-TOKEN=fresh; Path=/']);
});
test('requests outside the two Weibo origins are refused before any socket opens',async()=>{
 const f=client([]);
 await assert.rejects(f.client.get('https://evil.test/api','SUB=x'),/不允许/);
 assert.equal(f.sent.length,0);
});
