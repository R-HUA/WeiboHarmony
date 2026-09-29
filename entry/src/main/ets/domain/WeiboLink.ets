/** Pure link classification. IDs stay strings; video object IDs are never post IDs. */
export interface WeiboLinkTarget { kind: string; id: string; url: string; }
export function decodeLinkPart(value: string): string {
  try { return decodeURIComponent(value.replace(/\+/g, ' ')); } catch (_) { return value; }
}
export function linkQuery(url: string, key: string): string {
  const match: RegExpExecArray | null = new RegExp('[?&]' + key + '=([^&#]*)').exec(url);
  return match === null ? '' : decodeLinkPart(match[1]);
}
export function parseWeiboLink(input: string): WeiboLinkTarget {
  let url: string = input.trim().replace(/&amp;/g, '&');
  if (url.startsWith('//')) { url = 'https:' + url; }
  if (url.startsWith('/')) { url = 'https://m.weibo.cn' + url; }
  const match: RegExpExecArray | null = /^https?:\/\/([^/?#]+)([^?#]*)/i.exec(url);
  if (match === null) { return { kind: 'unsupported', id: '', url: url }; }
  const host: string = match[1].toLowerCase();
  const path: string = match[2].replace(/\/$/, '');
  const trusted: boolean = ['weibo.com', 'www.weibo.com', 'm.weibo.cn', 'weibo.cn', 'www.weibo.cn', 'video.weibo.com', 's.weibo.com', 't.cn'].includes(host);
  if (!trusted) { return { kind: 'external', id: '', url: url }; }
  url = url.replace(/^http:/i, 'https:');
  if (host === 't.cn') { return { kind: 'short', id: '', url: url }; }
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
