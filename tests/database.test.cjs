const{test}=require('node:test');const assert=require('node:assert/strict');const{DatabaseSync}=require('node:sqlite');const load=require('./load.cjs');
function create(){
 const db=new DatabaseSync(':memory:');
 function execute(sql,args=[]){return db.prepare(sql).run(...args)}
 const rdb={executeSql:async(sql,args)=>execute(sql,args),createTransaction:async()=>{db.exec('BEGIN');return{execute:async(sql,args)=>execute(sql,args),commit:async()=>db.exec('COMMIT'),rollback:async()=>db.exec('ROLLBACK')}},querySql:async(sql,args=[])=>{const rows=db.prepare(sql).all(...args);let index=-1;return{goToNextRow:()=>++index<rows.length,getString:i=>String(Object.values(rows[index])[i]),getDouble:i=>Number(Object.values(rows[index])[i]),isColumnNull:i=>Object.values(rows[index])[i]===null,close:()=>{}}}};
 const{ReaderDatabase}=load('entry/src/main/ets/storage/ReaderDatabase.ets',{'@kit.ArkData':{relationalStore:{getRdbStore:async()=>rdb,SecurityLevel:{S3:3}}},'../domain/RequestQueue':load('entry/src/main/ets/domain/RequestQueue.ts')});
 return{reader:new ReaderDatabase(),db};
}
const post=(id,age=0)=>({id,fetchedAt:Date.now()-age,text:'synthetic'});
test('feed order, account isolation and reading anchor survive round trip',async()=>{
 const f=create();await f.reader.init({});await f.reader.saveFeed('a','home',[post('2'),post('1')],'cursor',()=>true);await f.reader.saveFeed('b','home',[post('private')],null,()=>true);await f.reader.savePosition('a','home','1',12.5);
 const result=await f.reader.loadFeed('a','home');assert.deepEqual(result.posts.map(p=>p.id),['2','1']);assert.equal(result.anchorId,'1');assert.equal(result.offset,12.5);assert.equal(result.cursor,'cursor');await f.reader.clearAccount('a');assert.equal((await f.reader.loadFeed('a','home')).posts.length,0);assert.equal((await f.reader.loadFeed('b','home')).posts.length,1);f.db.close();
});
test('expired entries are removed, cache capped at 500 and local records protected',async()=>{
 const f=create();await f.reader.init({});f.db.prepare('INSERT INTO local_data VALUES(?,?,?,?)').run('a','bookmark','saved','{}');
 const posts=Array.from({length:520},(_,i)=>post(String(i)));posts[0]=post('expired',8*86400000);await f.reader.saveFeed('a','home',posts,null,()=>true);const result=await f.reader.loadFeed('a','home');assert.ok(result.posts.length<=500);assert.equal(result.posts.some(p=>p.id==='expired'),false);assert.equal(f.db.prepare('SELECT count(*) AS n FROM local_data').get().n,1);f.db.close();
});
test('session invalidated during save rolls back every row',async()=>{
 const f=create();await f.reader.init({});let checks=0;await f.reader.saveFeed('a','home',[post('secret')],null,()=>++checks===1);assert.equal((await f.reader.loadFeed('a','home')).posts.length,0);f.db.close();
});
