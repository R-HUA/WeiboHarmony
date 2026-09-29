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
  onContentChanged: () => void = (): void => {};
  onPendingChanged: (pending: boolean) => void = (): void => {};
  onStreamReplaced: () => void = (): void => {};
  hasPendingUpdate: boolean = false;
  needsRefresh: boolean = false;
  private pendingPage: FeedPage | null = null;
  private pendingSession: number = -1;
  private readonly kind: FeedKind;
  private source: FeedSource;
  private revision: number = 0;
  private adoptRevision: number = -1;
  private cursor: string | null = null;
  private visitedCursors: Set<string> = new Set();

  constructor(kind: FeedKind, source?: FeedSource) {
    this.kind = kind;
    this.source = source ?? new FeedRepository();
  }

  /** 账户切换时丢弃旧内容；置 Loading 避免空态在重建前闪现。 */
  reset(): void {
    this.revision++;
    this.visitedCursors.clear();
    this.clearPending(); this.needsRefresh = false;
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
    this.clearPending();
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
    this.clearPending();
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
      this.needsRefresh = cached.needsRefresh === true;
      this.cursor = this.needsRefresh ? null : cached.cursor;
      this.hasMore = this.cursor !== null;
      this.pendingAnchorId = explicit ? '' : cached.anchorId;
      this.pendingAnchorOffset = explicit ? 0 : cached.offset;
      this.state = FeedLoadState.Success;
      this.onContentChanged();
    } else if (this.posts.length === 0) {
      this.state = FeedLoadState.Loading;
    }
    try {
      const page: FeedPage = await this.source.fetchFirst(this.kind);
      if (!this.current(revision, session)) { return; }
      if (!explicit && this.adoptRevision !== revision && this.posts.length > 0) {
        // A background result must not change the visible stream, its cursor or its anchor.
        this.pendingPage = page;
        this.pendingSession = session;
        this.hasPendingUpdate = true;
        this.onPendingChanged(true);
      } else {
        this.replaceStream(page, revision, session);
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

  /** Entering a tab adopts its pending/in-flight first page, without duplicating the request. */
  async enter(): Promise<void> {
    if (this.hasPendingUpdate) { this.acceptPendingUpdate(); return; }
    if (this.refreshing) { this.adoptRevision = this.revision; return; }
    await this.loadFirst(true);
  }

  private clearPending(): void {
    this.pendingPage = null; this.pendingSession = -1; this.hasPendingUpdate = false; this.onPendingChanged(false);
  }

  /** Explicit adoption starts a new contiguous stream; old pages cannot be appended to it. */
  acceptPendingUpdate(): void {
    if (this.pendingPage === null) { return; }
    const page: FeedPage = this.pendingPage;
    const session: number = this.pendingSession;
    if (session !== this.source.generation()) { this.clearPending(); return; }
    this.replaceStream(page, ++this.revision, session);
  }

  private replaceStream(page: FeedPage, revision: number, session: number): void {
    this.clearPending();
    this.visitedCursors.clear();
    this.needsRefresh = false;
    this.loadingMore = false; this.refreshing = false; this.errorMessage = '';
    this.pendingAnchorId = ''; this.pendingAnchorOffset = 0;
    this.posts = this.unique(page.items);
    this.cursor = this.posts.length > 0 ? page.nextCursor : null;
    this.hasMore = this.cursor !== null;
    this.state = this.posts.length > 0 ? FeedLoadState.Success : FeedLoadState.Empty;
    this.onStreamReplaced();
    this.onContentChanged();
    this.persist(this.posts, this.cursor, revision, session);
    this.source.savePosition(this.kind, '', 0).catch((error: Error): void => {
      hilog.warn(0x0000, TAG, 'reset position failed: %{public}s', error.message);
    });
  }

  /** 追加下一页并去重；重复内容继续推进，空结果或循环游标终止，失败保留内容供重试。 */
  async loadMore(): Promise<void> {
    if (this.needsRefresh || this.refreshing || this.loadingMore || !this.hasMore || this.state !== FeedLoadState.Success || this.cursor === null) { return; }
    const revision: number = this.revision;
    const session: number = this.source.generation();
    this.loadingMore = true;
    this.errorMessage = '';
    try {
      // Duplicate-only pages within this stream still advance its cursor.
      // Bound each foreground batch to avoid draining an unbounded sequence of duplicates.
      for (let attempt: number = 0; attempt < 3; attempt++) {
        const cursor: string | null = this.cursor;
        if (cursor === null) { break; }
        const page: FeedPage = await this.source.fetchMore(this.kind, cursor);
        if (!this.current(revision, session)) { return; }
        this.visitedCursors.add(cursor);
        const merged: WeiboPost[] = this.unique(this.posts.concat(page.items));
        const grew: boolean = merged.length > this.posts.length;
        this.hasMore = page.items.length > 0 && page.nextCursor !== null && !this.visitedCursors.has(page.nextCursor);
        this.cursor = this.hasMore ? page.nextCursor : null;
        this.posts = merged;
        this.persist(merged, this.cursor, revision, session);
        if (grew || !this.hasMore) { break; }
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
