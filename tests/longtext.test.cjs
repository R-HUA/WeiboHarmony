const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const constants=load('entry/src/main/ets/common/Constants.ets');
const {WeiboMapper}=load('entry/src/main/ets/api/WeiboMapper.ets',{'../common/Constants':constants});
function deferred(){let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j});return {promise,resolve,reject};}
function fixture(){
 let generation=0,change;const requests=[],desktop=[];
 const auth={getGeneration:()=>generation,onSessionChange:callback=>change=callback,getDesktopCookie:()=> 'synthetic-desktop'};
 const {WeiboService}=load('entry/src/main/ets/service/WeiboService.ets',{
  '../model/WeiboModel':load('entry/src/main/ets/model/WeiboModel.ets'),
  '../api/WeiboMapper':{WeiboMapper},'../store/PostEntities':{PostEntities:{shared:()=>({clear(){}})}},
  '../domain/ResponseCache':{ResponseCache:class{}},'../common/Constants':constants,
  '@kit.RemoteCommunicationKit':{},'@kit.PerformanceAnalysisKit':{hilog:{warn(){}}},
  '../network/WeiboHttpClient':{WeiboHttpClient:{getDesktop:async(url,cookie)=>{desktop.push({url,cookie});return JSON.stringify({data:{longTextContent:'desktop'}})}}},
  './WeiboAuthManager':{WeiboAuthManager:{getInstance:()=>auth}},'./WeiboVisitorSession':{}
 });
 const service=new WeiboService();service.get=()=>{const d=deferred();requests.push(d);return d.promise;};
 return {service,requests,desktop,logout(){generation++;change();}};
}
test('late long text cannot refill a cleared session cache or remove its new pending request',async()=>{
 const f=fixture();const old=f.service.fetchLongText('1');f.logout();
 const current=f.service.fetchLongText('1');
 f.requests[0].resolve(JSON.stringify({data:{longTextContent:'old private text'}}));
 assert.equal(await old,'');assert.equal(f.service.cachedLongText('1'),'');
 const shared=f.service.fetchLongText('1');assert.equal(f.requests.length,2);
 f.requests[1].resolve(JSON.stringify({data:{longTextContent:'new'}}));
 assert.equal(await current,'new');assert.equal(await shared,'new');
});
test('cancelled mobile long text must not start fallback in a new session',async()=>{
 const f=fixture();const old=f.service.fetchLongText('1');f.logout();
 f.requests[0].reject(Error('cancelled'));assert.equal(await old,'');assert.equal(f.desktop.length,0);
});
test('desktop long text fallback receives the desktop session credential',async()=>{
 const f=fixture();const pending=f.service.fetchLongText('1');
 f.requests[0].resolve('{}');assert.equal(await pending,'desktop');
 assert.equal(f.desktop[0].cookie,'synthetic-desktop');
});
