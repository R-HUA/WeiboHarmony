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
