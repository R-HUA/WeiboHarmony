import { WeiboPost, WeiboTimelinePage } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { CachedFeed, ReaderDatabase } from '../storage/ReaderDatabase';

/** 首页信息流类别；数据库的 feed 键与缓存隔离都以此为粒度。 */
export type FeedKind = 'recommend' | 'following';

export interface FeedPage { items: WeiboPost[]; nextCursor: string | null; }

/** 版本化不透明游标：推荐流用页码，关注流用服务端 max_id，UI 不解读其内容。 */
interface FeedCursor { version: number; kind: FeedKind; page?: number; maxId?: string; }

export interface FeedSource {
  generation(): number;
  fetchFirst(kind: FeedKind): Promise<FeedPage>;
  fetchMore(kind: FeedKind, cursor: string): Promise<FeedPage>;
  loadCache(kind: FeedKind): Promise<CachedFeed>;
  saveCache(kind: FeedKind, posts: WeiboPost[], cursor: string | null, current: () => boolean): Promise<void>;
  savePosition(kind: FeedKind, anchorId: string, offset: number): Promise<void>;
}

/** 未登录（访客态）共用的缓存账户键；仅存公共推荐流内容，退出登录不清理。 */
export const GUEST_ACCOUNT: string = 'guest';

/**
 * 首页信息流数据源：微博只读兼容服务负责取数，ArkData 阅读缓存负责持久化。
 * 游标在此编解码，页面与 Store 始终持有不透明字符串。
 */
export class FeedRepository implements FeedSource {
  generation(): number { return WeiboAuthManager.getInstance().getGeneration(); }

  /** 缓存按账户隔离：已登录用 UID，访客共用公共桶。 */
  private account(): string {
    const uid: string = WeiboAuthManager.getInstance().getAccountId();
    return uid.length > 0 ? uid : GUEST_ACCOUNT;
  }

  async fetchFirst(kind: FeedKind): Promise<FeedPage> {
    return this.fetchPage(kind, null);
  }

  async fetchMore(kind: FeedKind, cursor: string): Promise<FeedPage> {
    return this.fetchPage(kind, cursor);
  }

  private async fetchPage(kind: FeedKind, cursor: string | null): Promise<FeedPage> {
    const service: WeiboService = WeiboService.getInstance();
    if (kind === 'recommend') {
      let page: number = 1;
      if (cursor !== null) { page = this.decodeRecommend(cursor); }
      const items: WeiboPost[] = await service.fetchRecommendTimeline(page);
      const nextCursor: string | null = items.length > 0 ? this.recommendCursor(page + 1) : null;
      return { items: items, nextCursor: nextCursor };
    }
    let maxId: string = '0';
    if (cursor !== null) { maxId = this.decodeFollowing(cursor); }
    const page: WeiboTimelinePage = await service.fetchFollowingTimeline(maxId);
    const nextCursor: string | null = page.hasMore ? this.followingCursor(page.nextMaxId) : null;
    return { items: page.items, nextCursor: nextCursor };
  }

  private recommendCursor(page: number): string {
    const cursor: FeedCursor = { version: 1, kind: 'recommend', page: page };
    return JSON.stringify(cursor);
  }

  private followingCursor(maxId: string): string {
    const cursor: FeedCursor = { version: 1, kind: 'following', maxId: maxId };
    return JSON.stringify(cursor);
  }

  /** 持久化游标可能跨版本残留，解码失败按失效处理，由上层刷新首页。 */
  private decode(cursor: string): FeedCursor {
    try {
      return JSON.parse(cursor) as FeedCursor;
    } catch (error) {
      throw new Error('信息流游标已失效，请刷新');
    }
  }

  private decodeRecommend(cursor: string): number {
    const decoded: FeedCursor = this.decode(cursor);
    const page: number = decoded.page ?? 0;
    if (decoded.version !== 1 || decoded.kind !== 'recommend' || !Number.isInteger(page) || page < 2) {
      throw new Error('信息流游标已失效，请刷新');
    }
    return page;
  }

  private decodeFollowing(cursor: string): string {
    const decoded: FeedCursor = this.decode(cursor);
    const maxId: string = decoded.maxId ?? '';
    if (decoded.version !== 1 || decoded.kind !== 'following' || maxId.length === 0) {
      throw new Error('信息流游标已失效，请刷新');
    }
    return maxId;
  }

  async loadCache(kind: FeedKind): Promise<CachedFeed> {
    return ReaderDatabase.shared().loadFeed(this.account(), kind);
  }

  async saveCache(kind: FeedKind, posts: WeiboPost[], cursor: string | null, current: () => boolean): Promise<void> {
    return ReaderDatabase.shared().saveFeed(this.account(), kind, posts, cursor, current);
  }

  async savePosition(kind: FeedKind, anchorId: string, offset: number): Promise<void> {
    return ReaderDatabase.shared().savePosition(this.account(), kind, anchorId, offset);
  }
}
