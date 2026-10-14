import { rcp } from '@kit.RemoteCommunicationKit';
import { RequestQueue } from '../domain/RequestQueue';
import { apiOrigin, xsrfToken } from '../domain/RequestPolicy';
import { BusinessError } from '@kit.BasicServicesKit';

const WEIBO_REFERER: string = 'https://m.weibo.cn/';
const WEIBO_USER_AGENT: string =
  'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
const WEIBO_DESKTOP_REFERER: string = 'https://weibo.com/';
/** Referer 是不带尾斜杠的形式；Origin 按规范只有 scheme + host。 */
const WEIBO_REFERER_ORIGIN: string = 'https://m.weibo.cn';
const WEIBO_DESKTOP_ORIGIN: string = 'https://weibo.com';
const WEIBO_DESKTOP_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36';
const MIN_REQUEST_INTERVAL_MS: number = 800;
const MOBILE_PRECONNECT_COOLDOWN_MS: number = 180000;

/** 响应 Cookie 的接收方（认证层实现）。见 WeiboHttpClient.absorbResponseCookies。 */
export type WeiboCookieSink = (origin: string, setCookie: string) => void;

/** A small isolated client so Weibo requests never inherit Tieba cookies. */
export class WeiboHttpClient {
  private static session: rcp.Session | null = null;
  private static queue: RequestQueue = new RequestQueue(MIN_REQUEST_INTERVAL_MS);
  /** 响应 Cookie 接收方：由 WeiboAuthManager 在初始化时注册。 */
  private static cookieSink: WeiboCookieSink | null = null;
  /** API 24+: keep the one mobile-origin handshake warm for the feed's first request. */
  private static mobilePreconnectTask: Promise<void> | null = null;
  private static lastMobilePreconnectAt: number = 0;

  private static getSession(): rcp.Session {
    if (WeiboHttpClient.session === null) {
      WeiboHttpClient.session = rcp.createSession({
        requestConfiguration: {
          transfer: {
            autoRedirect: false,
            maxAutoRedirects: 5,
            timeout: { connectMs: 15000, transferMs: 30000 },
          },
        },
      });
    }
    return WeiboHttpClient.session;
  }

  static async get(url: string, cookie: string): Promise<string> {
    apiOrigin(url);
    return WeiboHttpClient.queue.enqueue<string>(() => WeiboHttpClient.request(url, WeiboHttpClient.buildMobileHeaders(cookie)));
  }

  /** Desktop APIs can read public data anonymously or the account's own feed with its Cookie. */
  static async getDesktop(url: string, cookie: string = ''): Promise<string> {
    apiOrigin(url);
    return WeiboHttpClient.queue.enqueue<string>(() => WeiboHttpClient.request(url, WeiboHttpClient.buildDesktopHeaders(cookie)));
  }

  /**
   * Starts, but never blocks on, an API 24 `connectOnly` request. The later
   * timeline request uses the same long-lived Session and `m.weibo.cn` origin,
   * so it can reuse the TCP/TLS connection when it remains available.
   */
  static preconnectMobile(): void {
    const now: number = Date.now();
    if (WeiboHttpClient.mobilePreconnectTask !== null
      || now - WeiboHttpClient.lastMobilePreconnectAt < MOBILE_PRECONNECT_COOLDOWN_MS) {
      return;
    }
    WeiboHttpClient.lastMobilePreconnectAt = now;
    WeiboHttpClient.mobilePreconnectTask = WeiboHttpClient.connectMobileOnly();
  }

  static invalidateSession(): void {
    WeiboHttpClient.queue.invalidate();
    WeiboHttpClient.session?.cancel();
  }

  static setCookieSink(sink: WeiboCookieSink | null): void {
    WeiboHttpClient.cookieSink = sink;
  }

  /**
   * Write requests are deliberately explicit: callers create the form only
   * after a direct user gesture, and must pass the user-provided Cookie.
   */
  static async postForm(url: string, cookie: string, form: rcp.Form): Promise<string> {
    apiOrigin(url);
    return WeiboHttpClient.queue.enqueue<string>(() => WeiboHttpClient.performPost(url, cookie, form), 10);
  }

  private static async performPost(url: string, cookie: string, form: rcp.Form): Promise<string> {
    try {
      const origin: string = apiOrigin(url);
      const desktop: boolean = origin === WEIBO_DESKTOP_REFERER;
      const headers: Record<string, string> = desktop
        ? WeiboHttpClient.buildDesktopHeaders(cookie) : WeiboHttpClient.buildMobileHeaders(cookie);
      // Origin 只在写请求上补：同源 GET 本来就不发 Origin，凭空多一个自定义头只会扩大与线上
      // 浏览器的差异，而微博对异常头部组合的容错不可预期（见 docs/IMPLEMENTATION_PROGRESS.md）。
      headers['Origin'] = desktop ? WEIBO_DESKTOP_ORIGIN : WEIBO_REFERER_ORIGIN;
      const request: rcp.Request = new rcp.Request(url, 'POST');
      request.headers = headers;
      request.content = form;
      const response: rcp.Response = await WeiboHttpClient.getSession().fetch(request);
      WeiboHttpClient.absorbResponseCookies(url, response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return await response.toString() ?? '';
      }
      throw new WeiboRequestError(response.statusCode, WeiboHttpClient.messageForStatus(response.statusCode));
    } catch (error) {
      if (error instanceof WeiboRequestError) {
        throw error;
      }
      const businessError: BusinessError = error as BusinessError;
      throw new WeiboRequestError(businessError.code ?? -1, '发送结果未知，请核对微博后再决定是否重试');
    }
  }

  private static async request(url: string, headers: Record<string, string>): Promise<string> {
    try {
      const request: rcp.Request = new rcp.Request(url, 'GET');
      request.headers = headers;
      const response = await WeiboHttpClient.getSession().fetch(request);
      WeiboHttpClient.absorbResponseCookies(url, response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return await response.toString() ?? '';
      }
      throw new WeiboRequestError(response.statusCode, WeiboHttpClient.messageForStatus(response.statusCode));
    } catch (error) {
      if (error instanceof WeiboRequestError) {
        throw error;
      }
      const businessError: BusinessError = error as BusinessError;
      const message: string = businessError.message ?? '微博网络请求失败，请检查网络连接';
      if (message.toLowerCase().includes('timeout')) {
        throw new WeiboRequestError(31002, '微博请求超时，请稍后重试');
      }
      throw new WeiboRequestError(businessError.code ?? -1, message);
    }
  }

  /**
   * 把响应里的 Cookie 交回认证层合并。
   *
   * 微博的 CSRF 令牌（`XSRF-TOKEN`）会随响应轮换，写接口用「Cookie 里的令牌 == 请求头里的令牌」
   * 做校验：只发不取的话，登录时快照的令牌迟早过期，之后所有写请求都会被判 403。
   * 失败的响应也要收：403 常常就是服务端顺手换发新令牌的那一次。
   */
  private static absorbResponseCookies(url: string, response: rcp.Response): void {
    const sink: WeiboCookieSink | null = WeiboHttpClient.cookieSink;
    if (sink === null) { return; }
    // 头名字大小写按 HTTP/1.1 是不敏感的，rcp 内部用什么大小写没有承诺（历史上两种都出现过），
    // 取不到就换另一种写法再试一次，避免漏掉令牌轮换而让后续写请求被判 403。
    let raw: string | string[] | undefined = response.headers['set-cookie'];
    if (raw === undefined) { raw = response.headers['Set-Cookie']; }
    if (raw === undefined) { return; }
    const merged: string = Array.isArray(raw) ? raw.join('\n') : raw;
    if (merged.length === 0) { return; }
    sink(apiOrigin(url), merged);
  }

  private static async connectMobileOnly(): Promise<void> {
    try {
      const request: rcp.Request = new rcp.Request(WEIBO_REFERER, 'GET');
      request.connectOnly = true;
      await WeiboHttpClient.getSession().fetch(request);
    } catch (error) {
      // Connection warming is best-effort. The real user-visible request keeps
      // the existing error mapping and retries on a fresh connection as usual.
    } finally {
      WeiboHttpClient.mobilePreconnectTask = null;
    }
  }


  private static buildMobileHeaders(cookie: string): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': WEIBO_USER_AGENT,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': WEIBO_REFERER,
      'MWeibo-Pwa': '1',
      'X-Requested-With': 'XMLHttpRequest',
    };
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
      const token: string = xsrfToken(cookie);
      if (token.length > 0) { headers['X-XSRF-TOKEN'] = token; }
    }
    return headers;
  }

  private static buildDesktopHeaders(cookie: string): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': WEIBO_DESKTOP_USER_AGENT,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': WEIBO_DESKTOP_REFERER,
      'X-Requested-With': 'XMLHttpRequest',
    };
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
      const token: string = xsrfToken(cookie);
      if (token.length > 0) { headers['X-XSRF-TOKEN'] = token; }
    }
    return headers;
  }

  private static messageForStatus(status: number): string {
    if (status === 401) {
      return '微博要求登录，请检查 Cookie';
    }
    if (status === 403) {
      return '微博拒绝了本次访问，请更新 Cookie 或稍后重试';
    }
    if (status === 429 || status === 432) {
      return '微博限制了访问频率，请稍后重试或更新 Cookie';
    }
    return `微博请求失败，状态码 ${status}`;
  }
}

export class WeiboRequestError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    this.name = 'WeiboRequestError';
  }
}
