const {test}=require('node:test');
const assert=require('node:assert/strict');
const load=require('./load.cjs');
global.Observed = value => value;
const {SearchStore,SearchLoadState}=load('entry/src/main/ets/store/SearchStore.ets',{'../repository/SearchRepository':{SearchRepository:class {}}});
function deferred(){let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j});return{promise,resolve,reject}}
function fixture(){let generation=0;const requests=[];const suggestions=[];const source={generation:()=>generation,search:(query,cursor)=>{const d=deferred();requests.push({query,cursor,...d});return d.promise;},suggestions:query=>{const d=deferred();suggestions.push({query,...d});return d.promise;}};return{store:new SearchStore(source),requests,suggestions,logout:()=>generation++}}
const post=id=>({id});
test('latest query wins when earlier response arrives late',async()=>{
 const f=fixture(),old=f.store.search('old'),fresh=f.store.search('new');
 f.requests[1].resolve({items:[post('new')],nextCursor:'next'});await Promise.resolve();
 f.requests[0].resolve({items:[post('old')],nextCursor:null});await old;
 f.suggestions[0].resolve([]);await fresh;assert.deepEqual(f.store.posts,[post('new')]);
});
test('refresh invalidates pagination including its finally block',async()=>{
 const f=fixture(),initial=f.store.search('query');f.requests[0].resolve({items:[post('a')],nextCursor:'page2'});await Promise.resolve();f.suggestions[0].resolve([]);await initial;
 const more=f.store.loadMore(),refresh=f.store.search('query');
 f.requests[2].resolve({items:[post('new')],nextCursor:'page2'});await Promise.resolve();f.suggestions[1].resolve([]);await refresh;
 const next=f.store.loadMore();f.requests[1].reject(new Error('stale failure'));await more;
 assert.equal(f.store.loadingMore,true);assert.equal(f.store.errorMessage,'');
 f.requests[3].resolve({items:[post('new'),post('b'),post('b')],nextCursor:'page3'});await next;
 assert.deepEqual(f.store.posts,[post('new'),post('b')]);assert.equal(f.store.loadingMore,false);
});
test('repeated cursor ends paging and session change discards response',async()=>{
 const f=fixture(),initial=f.store.search('q');f.requests[0].resolve({items:[post('a')],nextCursor:'same'});await Promise.resolve();f.suggestions[0].resolve([]);await initial;
 const more=f.store.loadMore();f.requests[1].resolve({items:[post('b')],nextCursor:'same'});await more;assert.equal(f.store.nextCursor,null);
 const search=f.store.search('private');f.logout();f.store.clear();f.requests[2].resolve({items:[post('secret')],nextCursor:null});await search;
 assert.deepEqual(f.store.posts,[]);assert.equal(f.store.state,SearchLoadState.Idle);
});
test('paging failure keeps existing posts and cursor for explicit retry',async()=>{
 const f=fixture(),initial=f.store.search('q');f.requests[0].resolve({items:[post('a')],nextCursor:'p2'});await Promise.resolve();f.suggestions[0].resolve([]);await initial;
 const more=f.store.loadMore();f.requests[1].reject(new Error('offline'));await more;
 assert.deepEqual(f.store.posts,[post('a')]);assert.equal(f.store.nextCursor,'p2');assert.equal(f.store.errorMessage,'offline');
});
