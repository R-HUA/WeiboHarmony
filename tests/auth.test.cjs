const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
global.AppStorage={values:new Map(),get(k){return this.values.get(k)},setOrCreate(k,v){this.values.set(k,v)}};
function setup(config){let writes=0,captures=0,cleared=0;let stored=null;let fail=false;
 class Vault{async init(){}async read(){return stored}async write(s){if(fail)throw new Error('disk full');writes++;stored=s}async clear(){stored={mobile:'',desktop:'',uid:''}}}
 const {WeiboAuthManager}=load('entry/src/main/ets/service/WeiboAuthManager.ets',{
 '@kit.ArkWeb':{webview:{WebCookieManager:{fetchCookie:async url=>{captures++;return url.includes('m.weibo')?'SUB=mobile-fixture':'SUB=desktop-fixture'},clearAllCookies:async()=>{cleared++}}}},
 '../cache/CacheManager':{CacheManager:{getInstance:()=>({init:async()=>{},get:async()=>'',put:async()=>{}})}},
 './CredentialVault':{CredentialVault:Vault},
 '../network/WeiboHttpClient':{WeiboHttpClient:{get:async()=>JSON.stringify(config),invalidateSession:()=>{}}},
 './WeiboVisitorSession':{WeiboVisitorSession:{getInstance:()=>({clear:()=>{}})}}
 });return{auth:WeiboAuthManager.getInstance(),writes:()=>writes,captures:()=>captures,cleared:()=>cleared,fail:()=>fail=true};}
test('SUB alone never establishes authenticated account',async()=>{
 const f=setup({ok:1,data:{login:false,uid:'42'}});await f.auth.init({});await assert.rejects(f.auth.finishWebLogin(),/尚未确认/);assert.equal(f.auth.hasCookie(),false);assert.equal(f.writes(),0);
});
test('login capture is single-flight and credentials stay per-origin',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});await Promise.all([f.auth.finishWebLogin(),f.auth.finishWebLogin()]);assert.equal(f.writes(),1);assert.equal(f.captures(),2);assert.equal(f.auth.getAccountId(),'42');assert.equal(f.auth.getCookie(),'SUB=mobile-fixture');assert.equal(f.auth.getDesktopCookie(),'SUB=desktop-fixture');
 const before=f.auth.getGeneration();const logout=f.auth.logout();assert.equal(f.auth.hasCookie(),false);assert.ok(f.auth.getGeneration()>before);await logout;assert.equal(f.cleared(),1);
});
test('secure storage failure does not report successful login',async()=>{
 const f=setup({ok:1,data:{login:true,uid:'42'}});await f.auth.init({});f.fail();await assert.rejects(f.auth.finishWebLogin(),/disk full/);assert.equal(f.auth.hasCookie(),false);assert.equal(f.auth.getAccountId(),'');
});
