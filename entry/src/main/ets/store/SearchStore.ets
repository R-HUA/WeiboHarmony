import { WeiboPost, WeiboSuggestion } from '../model/WeiboModel';
import { SearchSource, SearchPage, SearchRepository } from '../repository/SearchRepository';
export enum SearchLoadState { Idle = 0, Loading = 1, Success = 2, Error = 3 }
@Observed
export class SearchStore {
  state: SearchLoadState = SearchLoadState.Idle;
  posts: WeiboPost[] = [];
  suggestions: WeiboSuggestion[] = [];
  errorMessage: string = '';
  loadingMore: boolean = false;
  nextCursor: string | null = null;
  query: string = '';
  private revision: number = 0;
  private source: SearchSource;
  constructor(source: SearchSource = new SearchRepository()) { this.source = source; }
  clear(): void {
    this.revision++; this.posts = []; this.suggestions = []; this.errorMessage = '';
    this.nextCursor = null; this.loadingMore = false; this.state = SearchLoadState.Idle;
  }
  cancel(): void { this.revision++; this.loadingMore = false; }
  private current(revision: number, session: number): boolean {
    return revision === this.revision && session === this.source.generation();
  }
  private unique(posts: WeiboPost[]): WeiboPost[] {
    const ids: Set<string> = new Set();
    return posts.filter((post: WeiboPost): boolean => {
      if (!post.id || ids.has(post.id)) { return false; } ids.add(post.id); return true;
    });
  }
  async search(value: string): Promise<void> {
    const query: string = value.trim();
    if (!query) { this.clear(); return; }
    if (query !== this.query) { this.posts = []; }
    this.query = query;
    const revision: number = ++this.revision;
    const session: number = this.source.generation();
    this.loadingMore = false; this.nextCursor = null; this.suggestions = []; this.errorMessage = '';
    this.state = SearchLoadState.Loading;
    try {
      const page: SearchPage = await this.source.search(query, null);
      if (!this.current(revision, session)) { return; }
      this.posts = this.unique(page.items); this.nextCursor = page.nextCursor;
      this.state = SearchLoadState.Success;
      try {
        const suggestions: WeiboSuggestion[] = await this.source.suggestions(query);
        if (this.current(revision, session)) { this.suggestions = suggestions; }
      } catch (error) {}
    } catch (error) {
      if (!this.current(revision, session)) { return; }
      this.errorMessage = (error as Error).message;
      this.state = this.posts.length > 0 ? SearchLoadState.Success : SearchLoadState.Error;
    }
  }
  async loadMore(): Promise<void> {
    if (this.loadingMore || this.state !== SearchLoadState.Success || this.nextCursor === null) { return; }
    const revision: number = this.revision;
    const session: number = this.source.generation();
    const cursor: string = this.nextCursor;
    this.loadingMore = true; this.errorMessage = '';
    try {
      const page: SearchPage = await this.source.search(this.query, cursor);
      if (!this.current(revision, session)) { return; }
      const merged: WeiboPost[] = this.unique(this.posts.concat(page.items));
      this.nextCursor = merged.length === this.posts.length || cursor === page.nextCursor ? null : page.nextCursor;
      this.posts = merged;
    } catch (error) {
      if (this.current(revision, session)) { this.errorMessage = (error as Error).message; }
    } finally {
      if (this.current(revision, session)) { this.loadingMore = false; }
    }
  }
}
