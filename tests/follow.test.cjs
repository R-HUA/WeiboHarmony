const {test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');
const constants=load('entry/src/main/ets/common/Constants.ets');
const {WeiboMapper}=load('entry/src/main/ets/api/WeiboMapper.ets',{'../common/Constants':constants});
global.AppStorage={get:()=>0,setOrCreate(){}};
function deferred(){let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j});return {promise,resolve,reject};}
function fixture(){
 let generation=0,change,loggedIn=true;const requests=[];
 const auth={getGeneration:()=>generation,onSessionChange:cb=>change=cb,getDesktopCookie:()=> 'desktop',getCookie:()=> 'mobile',hasCookie:()=>loggedIn,getAccountId:()=> '99'};
 const {WeiboService}=load('entry/src/main/ets/service/WeiboService.ets',{
  '../api/WeiboMapper':{WeiboMapper},'../store/PostEntities':{PostEntities:{shared:()=>({clear(){},confirmLike(){}})}},
  '../domain/ResponseCache':{ResponseCache:class{}},'../common/Constants':constants,
  '@kit.RemoteCommunicationKit':{rcp:{Form:class{constructor(fields){this.fields=fields;}}}},'@kit.PerformanceAnalysisKit':{hilog:{warn(){}}},
  '../network/WeiboHttpClient':{WeiboHttpClient:{postForm(url,cookie,form){const d=deferred();requests.push({url,cookie,form,...d});return d.promise;}}},
  './WeiboAuthManager':{WeiboAuthManager:{getInstance:()=>auth}},'./WeiboVisitorSession':{}
 });
 const service=new WeiboService();
 service.get=async()=>JSON.stringify({ok:1,data:{userInfo:{id:'42',following:false}}});
 return {service,requests,logout(){generation++;loggedIn=false;change();},login(){loggedIn=true;}};
}
test('following is tri-state and never inferred from follower counts',()=>{
 assert.equal(WeiboMapper.toUser({followers_count:100}).following,undefined);
 for(const value of [true,1])assert.equal(WeiboMapper.toUser({following:value}).following,true);
 for(const value of [false,0])assert.equal(WeiboMapper.toUser({following:value}).following,false);
});
test('follow/unfollow use their distinct forms and update only after confirmed success',async()=>{
 const f=fixture();await f.service.fetchUserProfile('42');
 const follow=f.service.setFollowing('42',true);assert.equal(f.service.getFollowing('42'),false);
 assert.match(f.requests[0].url,/friendships\/create$/);assert.deepEqual(f.requests[0].form.fields,{friend_uid:'42'});assert.equal(f.requests[0].cookie,'desktop');
 await assert.rejects(f.service.setFollowing('42',true),/正在处理/);
 f.requests[0].resolve('{"ok":1}');await follow;assert.equal(f.service.getFollowing('42'),true);
 const unfollow=f.service.setFollowing('42',false);assert.match(f.requests[1].url,/friendships\/destory$/);assert.deepEqual(f.requests[1].form.fields,{uid:'42'});
 f.requests[1].resolve('{"ok":1}');await unfollow;assert.equal(f.service.getFollowing('42'),false);
});
test('failed write invalidates relationship and requires refresh; guests/self/invalid UIDs cannot write',async()=>{
 const f=fixture();await f.service.fetchUserProfile('42');const action=f.service.setFollowing('42',true);
 f.requests[0].reject(Error('发送结果未知'));await assert.rejects(action,/未知/);assert.equal(f.service.getFollowing('42'),undefined);
 await f.service.fetchUserProfile('42');assert.equal(f.service.getFollowing('42'),false);
 await assert.rejects(f.service.setFollowing('99',true));await assert.rejects(f.service.setFollowing('bad',true));f.logout();await assert.rejects(f.service.setFollowing('42',true),/登录/);assert.equal(f.requests.length,1);
});
test('stale profile cannot undo follow; old-session completion cannot unlock new-session write',async()=>{
 const f=fixture(),read=deferred();f.service.get=()=>read.promise;const profile=f.service.fetchUserProfile('42');
 const follow=f.service.setFollowing('42',true);f.requests[0].resolve('{"ok":1}');await follow;
 read.resolve('{"ok":1,"data":{"userInfo":{"id":"42","following":false}}}');assert.equal((await profile).following,true);
 const old=f.service.setFollowing('42',false);f.logout();f.login();const current=f.service.setFollowing('42',true);
 f.requests[1].resolve('{"ok":1}');await assert.rejects(old,/取消/);assert.equal(f.service.getFollowing('42'),undefined);
 await assert.rejects(f.service.setFollowing('42',false),/正在处理/);
 f.requests[2].resolve('{"ok":1}');await current;assert.equal(f.service.getFollowing('42'),true);
});
test('unlike uses destroyLike and stale completion cannot remove the new account lock',async()=>{
 const f=fixture();const old=f.service.setLike('42',false);
 assert.match(f.requests[0].url,/statuses\/destroyLike$/);assert.deepEqual(f.requests[0].form.fields,{id:'42'});
 f.logout();f.login();const current=f.service.setLike('42',true);
 f.requests[0].resolve('{"ok":1}');await assert.rejects(old,/取消/);
 await assert.rejects(f.service.setLike('42',false),/正在处理/);
 f.requests[1].resolve('{"ok":1}');await current;
});
