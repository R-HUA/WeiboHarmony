import { hilog } from '@kit.PerformanceAnalysisKit';
import { WeiboPost } from '../model/WeiboModel';
import { CachedFeed } from '../storage/ReaderDatabase';
import { FeedKind, FeedPage, FeedSource, FeedRepository } from '../repository/FeedRepository';

const TAG: string = 'FeedStore';

export enum FeedLoadState { Idle = 0, Loading = 1, Success = 2, Empty = 3, Error = 4 }

/**
 * 首页信息流可观察状态：本地缓存先上屏、网络首页后台刷新替换；
 * 分页合并去重，阅读位置经仓储持久化，账户切换（登录/退出）丢弃旧内容。
 */
@Observed
export class FeedStore {
  state: FeedLoadState = FeedLoadState.Idle;
  posts: WeiboPost[] = [];
  errorMessage: string = '';
  loadingMore: boolean = false;
  /** 由是否存在下一游标推导。 */
  hasMore: boolean = false;
  /** 网络首页请求进行中；已有内容仍保持可读。 */
  refreshing: boolean = false;
  /** 缓存恢复出的阅读锚点：帖子 ID＋相对视口偏移，页面渲染后一次性消费。 */
  pendingAnchorId: string = '';
  pendingAnchorOffset: number = 0;
  private readonly kind: FeedKind;
  private source: FeedSource;
  private revision: number = 0;
  private cursor: string | null = null;

  constructor(kind: FeedKind, source?: FeedSource) {
    this.kind = kind;
    this.source = source ?? new FeedRepository();
  }

  /** 账户切换时丢弃旧内容；置 Loading 避免空态在重建前闪现。 */
  reset(): void {
    this.revision++;
    this.posts = [];
    this.errorMessage = '';
    this.cursor = null;
    this.hasMore = false;
    this.loadingMore = false;
    this.refreshing = false;
    this.pendingAnchorId = '';
    this.pendingAnchorOffset = 0;
    this.state = FeedLoadState.Loading;
  }

  cancel(): void {
    this.revision++;
    this.loadingMore = false;
    this.refreshing = false;
  }

  private current(revision: number, session: number): boolean {
    return revision === this.revision && session === this.source.generation();
  }

  private unique(posts: WeiboPost[]): WeiboPost[] {
    const ids: Set<string> = new Set();
    return posts.filter((post: WeiboPost): boolean => {
      if (post.id.length === 0 || ids.has(post.id)) { return false; }
      ids.add(post.id);
      return true;
    });
  }

  /** 后台持久化失败不阻断阅读，仅记录日志供排查。 */
  private persist(posts: WeiboPost[], cursor: string | null, revision: number, session: number): void {
    this.source.saveCache(this.kind, posts, cursor, (): boolean => this.current(revision, session))
      .catch((error: Error): void => {
        hilog.warn(0x0000, TAG, 'saveCache failed kind=%{public}s err=%{public}s', this.kind, JSON.stringify(error));
      });
  }

  /**
   * 首次进入先展示本地缓存（含上次阅读位置），再请求网络首页替换内容。
   * 缓存只在无内容时上屏，避免用陈旧缓存覆盖在线内容；网络失败保留已展示内容。
   */
  async loadFirst(explicit: boolean): Promise<void> {
    const revision: number = ++this.revision;
    const session: number = this.source.generation();
    this.loadingMore = false;
    this.refreshing = true;
    this.errorMessage = '';
    let cached: CachedFeed | null = null;
    try {
      cached = await this.source.loadCache(this.kind);
    } catch (error) {
      // 缓存读取失败降级为纯网络路径
      cached = null;
    }
    if (!this.current(revision, session)) { return; }
    if (cached !== null && cached.posts.length > 0 && this.posts.length === 0) {
      this.posts = this.unique(cached.posts);
      this.cursor = cached.cursor;
      this.hasMore = cached.cursor !== null;
      this.pendingAnchorId = cached.anchorId;
      this.pendingAnchorOffset = cached.offset;
      this.state = FeedLoadState.Success;
    } else if (this.posts.length === 0) {
      this.state = FeedLoadState.Loading;
    }
    try {
      const page: FeedPage = await this.source.fetchFirst(this.kind);
      if (!this.current(revision, session)) { return; }
      // 刷新结果与「当前内容＋缓存」合并去重：保住本会话已见内容与深层已翻页缓存
      let base: WeiboPost[] = this.posts;
      if (cached !== null) { base = base.concat(cached.posts); }
      const merged: WeiboPost[] = this.unique(page.items.concat(base));
      this.posts = merged;
      this.cursor = page.nextCursor;
      this.hasMore = page.nextCursor !== null;
      this.state = merged.length > 0 ? FeedLoadState.Success : FeedLoadState.Empty;
      if (merged.length > 0) {
        this.persist(merged, page.nextCursor, revision, session);
      }
    } catch (error) {
      if (!this.current(revision, session)) { return; }
      this.errorMessage = (error as Error).message;
      if (this.posts.length === 0) {
        this.state = FeedLoadState.Error;
      }
    } finally {
      if (this.current(revision, session)) { this.refreshing = false; }
    }
  }

  /** 追加下一页并去重；空结果或重复游标终止分页，失败保留当前内容供重试。 */
  async loadMore(): Promise<void> {
    if (this.refreshing || this.loadingMore || !this.hasMore || this.state !== FeedLoadState.Success || this.cursor === null) { return; }
    const revision: number = this.revision;
    const session: number = this.source.generation();
    const cursor: string = this.cursor;
    this.loadingMore = true;
    this.errorMessage = '';
    try {
      const page: FeedPage = await this.source.fetchMore(this.kind, cursor);
      if (!this.current(revision, session)) { return; }
      const merged: WeiboPost[] = this.unique(this.posts.concat(page.items));
      const grew: boolean = merged.length > this.posts.length;
      this.hasMore = page.nextCursor !== null && grew && page.nextCursor !== cursor;
      this.cursor = page.nextCursor;
      if (grew) {
        this.posts = merged;
        this.persist(merged, page.nextCursor, revision, session);
      }
    } catch (error) {
      if (!this.current(revision, session)) { return; }
      this.errorMessage = (error as Error).message;
    } finally {
      if (this.current(revision, session)) { this.loadingMore = false; }
    }
  }

  /** 持久化阅读位置：锚点帖子 ID＋其顶边相对视口顶边的偏移。 */
  savePosition(anchorId: string, offset: number): void {
    if (this.state !== FeedLoadState.Success || anchorId.length === 0) { return; }
    this.source.savePosition(this.kind, anchorId, offset).catch((error: Error): void => {
      hilog.warn(0x0000, TAG, 'savePosition failed kind=%{public}s err=%{public}s', this.kind, JSON.stringify(error));
    });
  }
}
