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

test('truncation cannot reuse the cursor beyond the saved 500 posts',async()=>{
 const f=create();await f.reader.init({});
 await f.reader.saveFeed('a','home',Array.from({length:520},(_,i)=>post(String(i))),'after-520',()=>true);
 const result=await f.reader.loadFeed('a','home');assert.equal(result.posts.length,500);
 assert.equal(result.cursor,null);assert.equal(result.needsRefresh,true);f.db.close();
});
test('expiry between saves and reads invalidates continuation and missing anchors',async()=>{
 const f=create();await f.reader.init({});
 await f.reader.saveFeed('a','home',[post('1'),post('2'),post('3')],'after-3',()=>true);
 await f.reader.savePosition('a','home','2',-15);
 f.db.prepare('UPDATE posts SET fetched=? WHERE id=?').run(Date.now()-8*86400000,'2');
 const result=await f.reader.loadFeed('a','home');assert.deepEqual(result.posts.map(p=>p.id),['1','3']);
 assert.equal(result.cursor,null);assert.equal(result.needsRefresh,true);assert.equal(result.anchorId,'');
 f.db.close();
});
test('eviction by another feed invalidates only the affected account stream',async()=>{
 const f=create();await f.reader.init({});
 await f.reader.saveFeed('a','home',[post('older',10000)],'old-tail',()=>true);
 await f.reader.saveFeed('b','home',[post('private')],'private-tail',()=>true);
 await f.reader.saveFeed('a','following',Array.from({length:500},(_,i)=>post('new-'+i)),'new-tail',()=>true);
 const home=await f.reader.loadFeed('a','home');assert.equal(home.needsRefresh,true);assert.equal(home.cursor,null);
 const other=await f.reader.loadFeed('b','home');assert.equal(other.needsRefresh,false);assert.equal(other.cursor,'private-tail');
 const following=await f.reader.loadFeed('a','following');assert.equal(following.needsRefresh,false);assert.equal(following.cursor,'new-tail');
 f.db.close();
});
test('legacy boundaries are untrusted until replaced by a fresh complete stream',async()=>{
 const f=create();await f.reader.init({});await f.reader.saveFeed('a','home',[post('old')],'legacy',()=>true);
 f.db.exec('DROP TABLE feed_boundary');
 // Re-open performs additive migration, without discarding old readable rows.
 const old=f.reader;old.initialization=null;await old.init({});
 const legacy=await old.loadFeed('a','home');assert.equal(legacy.posts.length,1);assert.equal(legacy.cursor,null);assert.equal(legacy.needsRefresh,true);
 await old.saveFeed('a','home',[post('new')],'fresh',()=>true);
 const fresh=await old.loadFeed('a','home');assert.equal(fresh.cursor,'fresh');assert.equal(fresh.needsRefresh,false);
 await old.clearAccount('a');assert.equal(f.db.prepare('SELECT count(*) n FROM feed_boundary').get().n,0);f.db.close();
});

test('feed data and boundary are read as one snapshot across a concurrent replacement',async()=>{
 const f=create();await f.reader.init({});await f.reader.saveFeed('a','home',[post('old')],'old-tail',()=>true);
 const reading=f.reader.loadFeed('a','home');
 const writing=f.reader.saveFeed('a','home',[post('new1'),post('new2')],'new-tail',()=>true);
 const before=await reading;assert.deepEqual(before.posts.map(p=>p.id),['old']);assert.equal(before.cursor,'old-tail');
 await writing;const after=await f.reader.loadFeed('a','home');assert.deepEqual(after.posts.map(p=>p.id),['new1','new2']);assert.equal(after.cursor,'new-tail');assert.equal(after.needsRefresh,false);f.db.close();
});
