const {test}=require('node:test');
const assert=require('node:assert/strict');
const load=require('./load.cjs');
const constants=load('entry/src/main/ets/common/Constants.ets');
const {parseWeiboRich,RichKind,readingSegments,richToPlainText}=load('entry/src/main/ets/common/RichText.ets',{'./Constants':constants});
test('screenshot repost chain identifies every mention and preserves the text',()=>{
 const source='哈哈哈哈//@龍宮輝夜://@凯喜博士DrCash://@史老柒:哈哈哈哈哈 //@他行记_:别别别 听我解释呀';
 const parts=parseWeiboRich(source);
 assert.deepEqual(parts.filter(s=>s.kind===RichKind.Mention).map(s=>s.text),['@龍宮輝夜','@凯喜博士DrCash','@史老柒','@他行记_']);
 assert.equal(richToPlainText(parts),source);
});
test('profile links resolve UIDs, external uid parameters remain external, URL punctuation survives',()=>{
 const parts=parseWeiboRich('<a href="/profile/123">@甲</a> <a href="//weibo.com/456">@乙</a> <a href="https://example.com/u/789?uid=42">网页</a>');
 assert.deepEqual(parts.filter(s=>s.kind===RichKind.Mention).map(s=>s.target),['123','456']);
 assert.equal(parts.find(s=>s.text==='网页').kind,RichKind.Link);
 const text='读 https://example.com/a). 然后 @丙';assert.equal(richToPlainText(parseWeiboRich(text)),text);
});
test('missing href still recognizes mentions, data-href cannot replace the real destination',()=>{
 assert.equal(parseWeiboRich('<a>@用户</a>')[0].kind,RichKind.Mention);
 assert.equal(parseWeiboRich('<a data-href="/u/12" href="/u/34">@用户</a>')[0].target,'34');
});
test('plain repost mentions preserve punctuation, hyphens and original text',()=>{
 const text='//@蘸盐://@张忆安-见龙在田:正文 //@香港社畜緋玖嵐：继续';
 const parsed=parseWeiboRich(text);
 assert.deepEqual(parsed.filter(s=>s.kind===RichKind.Mention).map(s=>s.text),['@蘸盐','@张忆安-见龙在田','@香港社畜緋玖嵐']);
 assert.equal(richToPlainText(parsed),text);
 assert.ok(parsed.filter(s=>s.kind===RichKind.Mention).every(s=>s.target===''));
});
test('mentions do not split email addresses or URL paths',()=>{
 const parsed=parseWeiboRich('mail@example.com https://example.com/@name @真实用户');
 assert.deepEqual(parsed.filter(s=>s.kind===RichKind.Mention).map(s=>s.text),['@真实用户']);
});
test('linked mentions keep UID and name-only anchors use name fallback',()=>{
 const parsed=parseWeiboRich('<a href="https://weibo.com/u/42">@甲</a> <a href="/n/乙">@乙</a>');
 assert.deepEqual(parsed.filter(s=>s.kind===RichKind.Mention).map(s=>s.target),['42','']);
});
test('redundant video links disappear only with a playable video; other links remain',()=>{
 const parsed=parseWeiboRich('<a href="https://t.cn/example">作者的微博视频</a> <a href="https://example.com">网页链接</a>');
 assert.equal(readingSegments(parsed,false).length,parsed.length);
 const visible=readingSegments(parsed,true);
 assert.equal(visible.filter(s=>s.kind===RichKind.Link).length,1);
 assert.equal(visible.find(s=>s.kind===RichKind.Link).text,'网页链接');
});
test('application and relative anchors retain their destinations for link resolution',()=>{
 for(const target of ['sinaweibo://browser?url=https%3A%2F%2Fwx1.sinaimg.cn%2Flarge%2Fa.jpg','detail/123','mailto:someone@example.com']){
  const parts=parseWeiboRich(`<a href="${target}">查看图片</a>`);
  assert.equal(parts[0].kind,RichKind.Link);assert.equal(parts[0].target,target);
 }
 assert.equal(parseWeiboRich('<a href="javascript:alert(1)">文字</a>')[0].kind,RichKind.Text);
});
