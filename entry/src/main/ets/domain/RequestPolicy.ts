export function apiOrigin(url: string): string {
  if (/^https:\/\/m\.weibo\.cn\//.test(url)) { return 'https://m.weibo.cn/'; }
  if (/^https:\/\/weibo\.com\//.test(url)) { return 'https://weibo.com/'; }
  throw new Error('不允许的微博 API 地址');
}
export function xsrfToken(cookie: string): string {
  const match: RegExpExecArray | null = /(?:^|;\s*)XSRF-TOKEN=([^;]+)/.exec(cookie);
  if (match === null) { return ''; }
  try { return decodeURIComponent(match[1]); } catch (error) { throw new Error('登录凭据格式无效'); }
}

/** Set-Cookie 里的属性名不是 Cookie，不能混进请求头。 */
const COOKIE_ATTRIBUTES: string[] = [
  'path', 'domain', 'expires', 'max-age', 'secure', 'httponly', 'samesite', 'priority', 'version', 'comment'
];

function appendCookie(pairs: string[], order: string[], name: string, value: string): void {
  if (name.length === 0 || value.length === 0) { return; }
  const lower: string = name.toLowerCase();
  for (let index: number = 0; index < COOKIE_ATTRIBUTES.length; index++) {
    if (lower === COOKIE_ATTRIBUTES[index]) { return; }
  }
  for (let index: number = 0; index < order.length; index++) {
    if (order[index] === name) {
      pairs[index] = `${name}=${value}`;
      return;
    }
  }
  order.push(name);
  pairs.push(`${name}=${value}`);
}

function splitCookiePairs(header: string, pairs: string[], order: string[]): void {
  const parts: string[] = header.split(/[;\r\n]+/);
  for (let index: number = 0; index < parts.length; index++) {
    const piece: string = parts[index].trim();
    const separator: number = piece.indexOf('=');
    if (separator <= 0) { continue; }
    appendCookie(pairs, order, piece.substring(0, separator).trim(), piece.substring(separator + 1).trim());
  }
}

/**
 * 把服务端的 `Set-Cookie` 合并进现有 Cookie 头：同名覆盖、其余保留。
 *
 * 微博的 `XSRF-TOKEN` 随响应轮换，写接口用「Cookie 值 == 请求头 X-XSRF-TOKEN」做双提交校验；
 * 只发不取会让登录时快照的令牌过期，之后所有写请求都被判 403。
 *
 * 只处理 `name=value`：属性的删除语义（过期时间已在过去、Max-Age=0）不在这里实现——
 * 服务端换发令牌用的都是新值，把请求头里的旧值删掉反而更危险。
 */
export function mergeCookieHeader(base: string, setCookie: string): string {
  const pairs: string[] = [];
  const order: string[] = [];
  splitCookiePairs(base, pairs, order);
  splitCookiePairs(setCookie, pairs, order);
  return pairs.join('; ');
}
