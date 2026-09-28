const{test}=require('node:test');const assert=require('node:assert/strict');const load=require('./load.cjs');global.AppStorage={get:()=>0,setOrCreate:()=>{}};
const {PostEntities}=load('entry/src/main/ets/store/PostEntities.ets');
test('same entity synchronizes likes without double increment and clears per session',()=>{
 const entities=new PostEntities();const source={id:'1',isLiked:false,likeCount:5,rawText:'<b>full</b>'};entities.adopt(source);entities.confirmLike('1',true);
 assert.equal(entities.apply(source).likeCount,6);assert.equal(entities.apply(source).isLiked,true);assert.equal(entities.apply(source).rawText,source.rawText);
 entities.confirmLike('1',true);assert.equal(entities.apply(source).likeCount,6);entities.confirmLike('1',false);assert.equal(entities.apply(source).likeCount,5);
 entities.clear();assert.equal(entities.apply(source),source);
});
