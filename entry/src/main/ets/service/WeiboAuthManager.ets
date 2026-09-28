import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CacheManager } from '../cache/CacheManager';
import { CredentialVault, StoredSession } from './CredentialVault';
import { WeiboHttpClient } from '../network/WeiboHttpClient';
import { WeiboVisitorSession } from './WeiboVisitorSession';
import { ReaderDatabase } from '../storage/ReaderDatabase';

const TAG: string = 'WeiboAuthManager';

interface AccountConfigData { login?: boolean; uid?: string | number; }
interface AccountConfig { ok?: number; data?: AccountConfigData; msg?: string; }
const TARGET_USER_ID_KEY: string = 'weibo_target_user_id';

export class WeiboAuthManager {
  private static instance: WeiboAuthManager | null = null;
  private initialization: Promise<void> | null = null;
  private captureTask: Promise<void> | null = null;
  private vault: CredentialVault = new CredentialVault();
  private session: StoredSession = { mobile: '', desktop: '', uid: '' };
  private targetUserId: string = '';
  private generation: number = 0;
  private listeners: Array<() => void> = [];
  static getInstance(): WeiboAuthManager {
    if (WeiboAuthManager.instance === null) { WeiboAuthManager.instance = new WeiboAuthManager(); }
    return WeiboAuthManager.instance;
  }
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialization === null) { this.initialization = this.initialize(context); }
    try { await this.initialization; }
    catch (error) { this.initialization = null; throw new Error((error as Error).message); }
  }
  private async initialize(context: common.UIAbilityContext): Promise<void> {
    await this.vault.init(context);
    this.session = await this.vault.read() ?? { mobile: '', desktop: '', uid: '' };
    const cache: CacheManager = CacheManager.getInstance();
    await cache.init(context);
    this.targetUserId = await cache.get(TARGET_USER_ID_KEY) ?? '';
  }
  getGeneration(): number { return this.generation; }
  onSessionChange(listener: () => void): void { this.listeners.push(listener); }
  getCookie(): string { return this.session.mobile; }
  getDesktopCookie(): string { return this.session.desktop; }
  getAccountId(): string { return this.session.uid; }
  hasCookie(): boolean { return this.session.uid.length > 0 && this.session.mobile.length > 0; }
  /** The login page invokes an action; credentials stay inside the authentication boundary. */
  async finishWebLogin(): Promise<void> {
    if (this.captureTask !== null) { return this.captureTask; }
    this.captureTask = this.captureAndValidate();
    try { await this.captureTask; } finally { this.captureTask = null; }
  }
  private async captureAndValidate(): Promise<void> {
    const generation: number = this.generation;
    const mobile: string = await webview.WebCookieManager.fetchCookie('https://m.weibo.cn/', false);
    const desktop: string = await webview.WebCookieManager.fetchCookie('https://weibo.com/', false);
    if (!/(?:^|;\s*)SUB=/.test(mobile)) { throw new Error('请先完成微博网页登录'); }
    const raw: string = await WeiboHttpClient.get('https://m.weibo.cn/api/config', mobile);
    let config: AccountConfig;
    try { config = JSON.parse(raw) as AccountConfig; }
    catch (error) { throw new Error('微博要求重新登录或完成验证，请在网页中操作'); }
    const uid: string = String(config.data?.uid ?? '');
    if (config.ok !== 1 || config.data?.login !== true || !/^[1-9][0-9]*$/.test(uid)) {
      throw new Error('尚未确认登录账户，请完成登录或验证后重试');
    }
    if (generation !== this.generation) { throw new Error('登录已取消'); }
    const next: StoredSession = { mobile: mobile, desktop: desktop, uid: uid };
    await this.vault.write(next);
    if (generation !== this.generation) { await this.vault.clear(); throw new Error('登录已取消'); }
    this.invalidate();
    this.session = next;
    this.notifyUi();
  }
  async logout(): Promise<void> {
    const account: string = this.session.uid;
    this.invalidate();
    this.session = { mobile: '', desktop: '', uid: '' };
    this.notifyUi();
    // 先失效会话再清理本地数据；阅读缓存按账户隔离，清理失败仅告警，
    // 不阻断后续凭据与 Web 登录态的严格清理。
    if (account.length > 0) {
      try {
        await ReaderDatabase.shared().clearAccount(account);
      } catch (error) {
        hilog.warn(0x0000, TAG, 'clearAccount reading cache failed uid=%{public}s err=%{public}s',
          account, JSON.stringify(error));
      }
    }
    try { await this.vault.clear(); }
    finally { await webview.WebCookieManager.clearAllCookies(); }
  }
  private invalidate(): void {
    this.generation++;
    WeiboHttpClient.invalidateSession();
    WeiboVisitorSession.getInstance().clear();
    this.listeners.forEach((listener: () => void): void => listener());
  }
  private notifyUi(): void {
    AppStorage.setOrCreate<number>('weiboAuthTick', (AppStorage.get<number>('weiboAuthTick') ?? 0) + 1);
  }
  getTargetUserId(): string { return this.targetUserId; }
  async setTargetUserId(value: string): Promise<void> {
    this.targetUserId = value.trim();
    await CacheManager.getInstance().put(TARGET_USER_ID_KEY, this.targetUserId);
  }
}
