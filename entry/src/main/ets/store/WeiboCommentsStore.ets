import { WeiboComment, WeiboCommentCursor, WeiboCommentFilter, WeiboCommentsPage, WeiboPost } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { WeiboAuthManager } from '../service/WeiboAuthManager';

/** 主评论按所选排序读取，子回复沿用服务器顺序；两者共用分页失效规则。 */
@Observed
export class WeiboCommentsStore {
  items: WeiboComment[] = [];
  filters: WeiboCommentFilter[] = [];
  order: 'hot' | 'latest' = 'hot';
  nextCursor: WeiboCommentCursor | null = null;
  totalCount: number | undefined = undefined;
  loading: boolean = false;
  loaded: boolean = false;
  errorMessage: string = '';
  private revision: number = 0;

  cancel(): void { this.revision++; this.loading = false; }

  /** 排序切换必须重置游标，不能把两种结果混在一起。 */
  async selectOrder(order: 'hot' | 'latest', post: WeiboPost, rootId: string = ''): Promise<void> {
    if (order === this.order) { return; }
    this.order = order;
    this.items = [];
    this.loaded = false;
    this.nextCursor = null;
    await this.load(post, rootId);
  }

  /** 每个评论层级独立保留游标，刷新和切换会使旧请求失效。 */
  async load(post: WeiboPost, rootId: string = '', append: boolean = false): Promise<void> {
    if (append && (this.loading || this.nextCursor === null)) { return; }
    const revision: number = ++this.revision;
    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    const cursor: WeiboCommentCursor | null = append ? this.nextCursor : null;
    const filter: WeiboCommentFilter | undefined = rootId ? undefined
      : this.filters.find((item: WeiboCommentFilter): boolean => item.order === this.order);
    this.loading = true;
    this.errorMessage = '';
    if (!append) { this.nextCursor = null; }
    try {
      let page: WeiboCommentsPage = await this.fetch(post, rootId, filter?.param ?? '', cursor);
      if (!this.current(revision, generation)) { return; }
      if (!rootId) {
        if (page.filters.length > 0) { this.filters = page.filters; }
        const selected: WeiboCommentFilter | undefined = this.filters.find((item: WeiboCommentFilter): boolean => item.order === this.order);
        if (selected === undefined && page.items.length > 0) { throw new Error('微博未返回所选评论排序信息'); }
        // 首次请求取得元数据，服务器默认排序不一致时再请求所选排序。
        if (filter === undefined && selected !== undefined && !selected.isDefault) {
          page = await this.fetch(post, rootId, selected.param, null);
          if (!this.current(revision, generation)) { return; }
        }
      }
      const ids: Set<string> = new Set();
      const combined: WeiboComment[] = append ? this.items.concat(page.items) : page.items;
      const items: WeiboComment[] = combined.filter((item: WeiboComment): boolean => {
        if (ids.has(item.id)) { return false; }
        ids.add(item.id);
        return true;
      });
      this.nextCursor = append && items.length === this.items.length ? null : page.nextCursor;
      this.items = items;
      if (!append || page.totalCount !== undefined) { this.totalCount = page.totalCount; }
      this.loaded = true;
    } catch (error) {
      if (this.current(revision, generation)) { this.errorMessage = (error as Error).message; }
    } finally {
      if (this.current(revision, generation)) { this.loading = false; }
    }
  }

  private current(revision: number, generation: number): boolean {
    return revision === this.revision && generation === WeiboAuthManager.getInstance().getGeneration();
  }

  private fetch(post: WeiboPost, rootId: string, param: string,
    cursor: WeiboCommentCursor | null): Promise<WeiboCommentsPage> {
    const service: WeiboService = WeiboService.getInstance();
    return rootId ? service.fetchCommentReplies(post, rootId, param, cursor) : service.fetchComments(post, param, cursor);
  }
}
