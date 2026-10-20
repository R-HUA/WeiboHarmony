/** Pure link classification. IDs stay strings; video object IDs are never post IDs. */
export interface WeiboLinkTarget { kind: string; id: string; url: string; }
/**
 * 微博图床域名（含各尺寸别名的子域）。
 *
 * 正文里「查看图片」这类文字链接的 href 常常就是图床直链（`https://wx3.sinaimg.cn/large/xxx.jpg`）。
 * 这种地址浏览器直开会被防盗链挡成 403，只有在 App 内看图才正常，因此单独归为 `image`，
 * 交给页面在原图浏览器里打开，而不是丢给系统浏览器。
 */
const IMAGE_HOSTS: string[] = ['sinaimg.cn', 'sinaimg.com', 'weibocdn.com', 'sinacdn.cn'];
/** 图床的尺寸别名目录：没有扩展名时靠它确认这是一张图（如 /large/、/mw690/、/orj360/）。 */
const IMAGE_PATH_ALIAS: RegExp = /^\/(?:large|mw\d+|thumb\d+|thumbnail|small|bmiddle|original|orj\d+|woriginal)\//i;
const IMAGE_EXTENSION: RegExp = /\.(?:jpg|jpeg|jfif|png|gif|webp|bmp|heic|avif)$/i;
/**
 * 「查看图片」这类锚点文字。
 *
 * 并非每个接口版本都把图床地址写进 href：有的只给一个指向微博页面的「查看图片」文字链接，
 * 只按地址判断会漏掉这种帖子。文字是第二条可用信号——命中即按「用户想看图」处理，
 * 由解析器打开落地页取配图（见 imageFromWeiboPage）。
 */
const IMAGE_VIEW_TEXTS: string[] = [
  '查看图片', '查看原图', '查看大图', '点击查看图片', '查看图集', '查看图片详情', '查看大图及更多'
];

export function decodeLinkPart(value: string): string {
  try { return decodeURIComponent(value.replace(/\+/g, ' ')); } catch (_) { return value; }
}
export function linkQuery(url: string, key: string): string {
  const match: RegExpExecArray | null = new RegExp('[?&]' + key + '=([^&#]*)').exec(url);
  return match === null ? '' : decodeLinkPart(match[1]);
}
/** 只认白名单图床：外站地址即使以 .jpg 结尾也不在 App 内打开，仍然交系统浏览器。 */
function isWeiboImage(host: string, path: string): boolean {
  let onImageHost: boolean = false;
  for (let index: number = 0; index < IMAGE_HOSTS.length; index++) {
    const domain: string = IMAGE_HOSTS[index];
    if (host === domain || host.endsWith('.' + domain)) { onImageHost = true; break; }
  }
  if (!onImageHost) { return false; }
  return IMAGE_EXTENSION.test(path) || IMAGE_PATH_ALIAS.test(path);
}

/** 锚点文字是否在说「看图」。允许「共9张图 查看图片」这类前后缀。 */
export function isImageViewText(text: string): boolean {
  const clean: string = text.replace(/[\s「」『』【】《》<>＞>]+/g, '');
  if (clean.length === 0) { return false; }
  for (let index: number = 0; index < IMAGE_VIEW_TEXTS.length; index++) {
    if (clean.includes(IMAGE_VIEW_TEXTS[index])) { return true; }
  }
  return false;
}

/**
 * 从微博落地页取配图地址（`og:image` 是标准出口，`$CONFIG['page_pic']` 兜底老页面）。
 * 只接受图床地址：页面给的头像/logo 之类不会被当成用户要看的那张图。
 */
export function imageFromWeiboPage(html: string): string {
  const pictures: string[] = [];
  const tag: RegExpExecArray | null = /<meta\b[^>]*property=["']og:image["'][^>]*>/i.exec(html);
  if (tag !== null) {
    const content: RegExpExecArray | null = /\bcontent\s*=\s*["']([^"']*)["']/i.exec(tag[0]);
    if (content !== null) { pictures.push(content[1].trim()); }
  }
  const config: RegExpExecArray | null = /\$CONFIG\[['"]page_pic['"]\]\s*=\s*['"]([^'"]+)['"]/.exec(html);
  if (config !== null) { pictures.push(config[1].trim()); }
  for (let index: number = 0; index < pictures.length; index++) {
    const target: WeiboLinkTarget = parseWeiboLink(pictures[index]);
    if (target.kind === 'image') { return target.url; }
  }
  return '';
}

/** 先还原包裹地址，再分类，避免应用协议和编码后的图片链接被直接拒绝。 */
export function parseWeiboLink(input: string): WeiboLinkTarget {
  let url: string = input.trim().replace(/&amp;/g, '&');
  for (let count: number = 0; count < 5; count++) {
    if (/^(?:https?|sinaweibo)%3a/i.test(url)) { url = decodeLinkPart(url); continue; }
    const app: RegExpExecArray | null = /^sinaweibo:\/\/([^/?#]+)/i.exec(url);
    if (app !== null) {
      if (app[1].toLowerCase() === 'detail') {
        const id: string = linkQuery(url, 'mblogid');
        if (/^[A-Za-z0-9]+$/.test(id)) { return { kind: 'post', id: id, url: `https://m.weibo.cn/detail/${id}` }; }
      }
      if (app[1].toLowerCase() === 'userinfo') {
        const uid: string = linkQuery(url, 'uid');
        if (/^\d+$/.test(uid)) { return { kind: 'user', id: uid, url: `https://weibo.com/u/${uid}` }; }
      }
      const wrapped: string = linkQuery(url, 'url');
      if (wrapped.length > 0) { url = wrapped; continue; }
    }
    const wrapper: RegExpExecArray | null = /^https?:\/\/(?:(?:www|m)\.)?weibo\.(?:com|cn)\/(?:sinaurl|showpic)(?:\.php)?\?/i.exec(url);
    if (wrapper !== null) {
      const wrapped: string = linkQuery(url, 'u') || linkQuery(url, 'url');
      if (wrapped.length > 0) { url = wrapped; continue; }
    }
    break;
  }
  if (url.length === 0 || /^(?:javascript|data):/i.test(url)) { return { kind: 'unsupported', id: '', url: '' }; }
  if (url.startsWith('//')) { url = 'https:' + url; }
  if (!/^[A-Za-z][A-Za-z0-9+.-]*:/.test(url) && !url.startsWith('/')) {
    url = /^[^/\s]+\.[^/\s]+(?:\/|$)/.test(url) ? 'https://' + url : 'https://m.weibo.cn/' + url;
  }
  if (url.startsWith('/')) { url = 'https://m.weibo.cn' + url; }
  const match: RegExpExecArray | null = /^https?:\/\/([^/?#]+)([^?#]*)/i.exec(url);
  if (match === null) { return { kind: 'external', id: '', url: url }; }
  const host: string = match[1].toLowerCase();
  const path: string = match[2].replace(/\/$/, '');
  // 图床直链先于站点白名单判定：它不在信任站点里，但必须在 App 内预览而非跳浏览器。
  if (isWeiboImage(host, path)) { return { kind: 'image', id: '', url: url.replace(/^http:/i, 'https:') }; }
  const trusted: boolean = ['weibo.com', 'www.weibo.com', 'm.weibo.cn', 'weibo.cn', 'www.weibo.cn', 'video.weibo.com', 'photo.weibo.com', 's.weibo.com', 't.cn'].includes(host);
  if (!trusted) { return { kind: 'external', id: '', url: url }; }
  url = url.replace(/^http:/i, 'https:');
  if (host === 't.cn') { return { kind: 'short', id: '', url: url }; }
  if (host === 'photo.weibo.com') { return { kind: 'photo', id: '', url: url }; }
  let found: RegExpExecArray | null = /^\/(?:status|detail)\/([A-Za-z0-9]+)$/.exec(path);
  if (found === null) { found = /^\/\d+\/([A-Za-z0-9]+)$/.exec(path); }
  if (found !== null) { return { kind: 'post', id: found[1], url: url }; }
  found = /^\/(?:(?:u|profile)\/)?(\d+)$/.exec(path);
  if (found !== null) { return { kind: 'user', id: found[1], url: url }; }
  if (path === '/profile' && /^\d+$/.test(linkQuery(url, 'uid'))) {
    return { kind: 'user', id: linkQuery(url, 'uid'), url: url };
  }
  if (host === 's.weibo.com' && linkQuery(url, 'q').length > 0) {
    return { kind: 'topic', id: linkQuery(url, 'q'), url: url };
  }
  if (path.startsWith('/n/')) { return { kind: 'name', id: decodeLinkPart(path.substring(3)), url: url }; }
  if (host === 'video.weibo.com' || path.startsWith('/tv/show') || path === '/s/video/index') {
    const mid: string = linkQuery(url, 'mid');
    return { kind: /^\d+$/.test(mid) ? 'post' : 'video', id: mid, url: url };
  }
  return { kind: 'page', id: '', url: url };
}

/** Extract only explicit post/profile metadata, never arbitrary numbers in page text. */
export function targetFromWeiboPage(html: string, source: WeiboLinkTarget): WeiboLinkTarget {
  let match: RegExpExecArray | null;
  if (source.kind === 'name' || source.kind === 'page') {
    match = /\$CONFIG\[['"]oid['"]\]\s*=\s*['"](\d+)['"]/.exec(html);
    if (match !== null) { return { kind: 'user', id: match[1], url: source.url }; }
  }
  const canonical: RegExpExecArray | null = /<link\b[^>]*rel=["']canonical["'][^>]*href=["']([^"']+)["']/i.exec(html);
  if (canonical !== null) {
    const target: WeiboLinkTarget = parseWeiboLink(canonical[1]);
    if (target.kind === 'post' || target.kind === 'user') { return target; }
  }
  const og: RegExpExecArray | null = /<meta\b[^>]*property=["']og:url["'][^>]*content=["']([^"']+)["']/i.exec(html);
  if (og !== null) {
    const target: WeiboLinkTarget = parseWeiboLink(og[1]);
    if (target.kind === 'post' || target.kind === 'user') { return target; }
  }
  return source;
}

/** HTML shortlink redirects are data, never executable script. */
export function shortlinkPageRedirect(html: string): string {
  const tag: RegExpExecArray | null = /<meta\b[^>]*http-equiv=["']refresh["'][^>]*content=["']([^"']+)["']/i.exec(html);
  if (tag === null) { return ''; }
  const destination: RegExpExecArray | null = /\burl\s*=\s*(https?:\/\/\S+)/i.exec(tag[1]);
  return destination === null ? '' : destination[1].replace(/&amp;/g, '&');
}
