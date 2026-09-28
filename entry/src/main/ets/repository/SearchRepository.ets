import { WeiboPost, WeiboSuggestion } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
export interface SearchPage { items: WeiboPost[]; nextCursor: string | null; }
interface SearchCursor { version: number; page: number; query: string; }
export interface SearchSource {
  generation(): number;
  search(query: string, cursor: string | null): Promise<SearchPage>;
  suggestions(query: string): Promise<WeiboSuggestion[]>;
}
export class SearchRepository implements SearchSource {
  generation(): number { return WeiboAuthManager.getInstance().getGeneration(); }
  async search(query: string, cursor: string | null): Promise<SearchPage> {
    let page: number = 1;
    if (cursor !== null) {
      const decoded: SearchCursor = JSON.parse(cursor) as SearchCursor;
      if (decoded.version !== 1 || decoded.query !== query || !Number.isInteger(decoded.page) || decoded.page < 2) {
        throw new Error('搜索游标已失效，请刷新');
      }
      page = decoded.page;
    }
    const items: WeiboPost[] = await WeiboService.getInstance().fetchSearchPosts(query, page);
    const next: SearchCursor = { version: 1, page: page + 1, query: query };
    return { items: items, nextCursor: items.length > 0 ? JSON.stringify(next) : null };
  }
  suggestions(query: string): Promise<WeiboSuggestion[]> {
    return WeiboService.getInstance().fetchSuggestions(query, 8);
  }
}
