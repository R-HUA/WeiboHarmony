const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
global.AppStorage={values:new Map(),get(k){return this.values.get(k)},setOrCreate(k,v){this.values.set(k,v)}};
const policy=load('entry/src/main/ets/domain/RequestPolicy.ts');
function setup(config){let writes=0,captures=0,cleared=0;let stored=null;let fail=false;let cacheFail=false,cookieSink=null;const cacheCalls=[];
 class Vault{async init(){}async read(){return stored}async write(s){if(fail)throw new Error('disk full');writes++;stored=s}async clear(){stored={mobile:'',desktop:'',uid:''}}}
 const {WeiboAuthManager}=load('entry/src/main/ets/service/WeiboAuthManager.ets',{
 '@kit.ArkWeb':{webview:{WebCookieManager:{fetchCookie:async url=>{captures++;return url.includes('m.weibo')?'SUB=mobile-fixture':'SUB=desktop-fixture'},clearAllCookies:async()=>{cleared++}}}},
 '@kit.PerformanceAnalysisKit':{hilog:{warn:()=>{}}},
 '../domain/RequestPolicy':policy,
 '../cache/CacheManager':{CacheManager:{getInstance:()=>({init:async()=>{},get:async()=>'',put:async()=>{}})}},
 './CredentialVault':{CredentialVault:Vault},
 '../network/WeiboHttpClient':{WeiboHttpClient:{get:async()=>JSON.stringify(config),invalidateSession:()=>{},setCookieSink:sink=>{cookieSink=sink}}},
 './WeiboVisitorSession':{WeiboVisitorSession:{getInstance:()=>({clear:()=>{}})}},
 '../storage/ReaderDatabase':{ReaderDatabase:{shared:()=>({clearAccount:async account=>{cacheCalls.push(account);if(cacheFail)throw new Error('db broken')}})}}
 });return{auth:WeiboAuthManager.getInstance(),writes:()=>writes,captures:()=>captures,cleared:()=>cleared,fail:()=>fail=true,cacheCalls:()=>cacheCalls,failCache:()=>cacheFail=true,absorb:(origin,setCookie)=>cookieSink(origin,setCookie)};}
test('SUB alone never establishes authenticated account',async()=>{
 const f=setup({ok:1,data:{login:false,uid:'42'}});await f.auth.init({});await assert.rejects(f.auth.finishWebLogin(),/尚未确认/);assert.equal(f.auth.hasCookie(),false);assert.equal(f.writes(),0);
});
test('login capture is single-flight and credentials stay per-origin',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});await Promise.all([f.auth.finishWebLogin(),f.auth.finishWebLogin()]);assert.equal(f.writes(),1);assert.equal(f.captures(),2);assert.equal(f.auth.getAccountId(),'42');assert.equal(f.auth.getCookie(),'SUB=mobile-fixture');assert.equal(f.auth.getDesktopCookie(),'SUB=desktop-fixture');
 const before=f.auth.getGeneration();const logout=f.auth.logout();assert.equal(f.auth.hasCookie(),false);assert.ok(f.auth.getGeneration()>before);await logout;assert.equal(f.cleared(),1);assert.deepEqual(f.cacheCalls(),['42']);
});
test('secure storage failure does not report successful login',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});f.fail();await assert.rejects(f.auth.finishWebLogin(),/disk full/);assert.equal(f.auth.hasCookie(),false);assert.equal(f.auth.getAccountId(),'');
});
test('logout clears the account reading cache and survives cache failure',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});await f.auth.finishWebLogin();
 f.failCache();
 await f.auth.logout();
 assert.deepEqual(f.cacheCalls(),['42']);
 assert.equal(f.auth.hasCookie(),false);
 assert.equal(f.cleared(),1);
});

test('response cookies refresh the matching origin and never leak across origins',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});await f.auth.finishWebLogin();
 f.absorb('https://weibo.com/','XSRF-TOKEN=rotated-1; Path=/; Domain=.weibo.com; HttpOnly; Expires=Wed, 01 Jan 2031 00:00:00 GMT');
 assert.equal(f.auth.getDesktopCookie(),'SUB=desktop-fixture; XSRF-TOKEN=rotated-1');
 assert.equal(f.auth.getCookie(),'SUB=mobile-fixture');
 assert.equal(f.writes(),2);
 f.absorb('https://m.weibo.cn/','SUB=mobile-rotated; WBPSESS=new-session');
 assert.equal(f.auth.getCookie(),'SUB=mobile-rotated; WBPSESS=new-session');
 assert.equal(f.auth.getDesktopCookie(),'SUB=desktop-fixture; XSRF-TOKEN=rotated-1');
 assert.equal(f.writes(),2);
});
test('cookies from unrelated origins and attribute-only payloads are ignored',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});await f.auth.finishWebLogin();
 f.absorb('https://evil.test/','SUB=stolen');
 f.absorb('https://weibo.com/','Path=/; Domain=.weibo.com; Secure');
 assert.equal(f.auth.getDesktopCookie(),'SUB=desktop-fixture');
 assert.equal(f.writes(),1);
});
test('public endpoints never plant a guest cookie before login, and late cookies cannot outlive logout',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});
 f.absorb('https://m.weibo.cn/','SUB=guest-anon; ti=guest-anon');
 f.absorb('https://weibo.com/','SUB=guest-anon-desktop');
 assert.equal(f.auth.getCookie(),'');assert.equal(f.auth.getDesktopCookie(),'');
 assert.equal(f.auth.hasCookie(),false);assert.equal(f.writes(),0);
 await f.auth.finishWebLogin();
 assert.equal(f.writes(),1);
 await f.auth.logout();
 f.absorb('https://m.weibo.cn/','SUB=late-cookie');
 assert.equal(f.auth.getCookie(),'');assert.equal(f.writes(),1);
});
