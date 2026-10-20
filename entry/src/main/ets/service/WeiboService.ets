import { WeiboApiResponse, WeiboStatusApiResponse, WeiboConfigResponse, WeiboConfigData, WeiboFollowingTimelineResponse, WeiboResponseData, WeiboSuggestionJson, WeiboCardJson, WeiboUserJson, WeiboPictureJson, WeiboPictureSizeJson, WeiboVideoUrlsJson, WeiboVideoMediaInfoJson, WeiboPagePictureJson, WeiboPageInfoJson, WeiboPostJson, WeiboLongTextResponse } from '../api/WeiboDtos';
import { WeiboMapper } from '../api/WeiboMapper';
import { WeiboBuildCommentsResponse, WeiboInteractionsResponse } from '../api/WeiboDtos';
import { WeiboInteractionsPage } from '../model/WeiboModel';
import { PostEntities } from '../store/PostEntities';
import { ResponseCache } from '../domain/ResponseCache';
import { formatWeiboTime, stripHtml } from '../common/Constants';
import { rcp } from '@kit.RemoteCommunicationKit';
import { WeiboHttpClient, WeiboRequestError } from '../network/WeiboHttpClient';
import { WeiboCommentCursor, WeiboCommentsPage, WeiboHotCategory, WeiboHotTopic, WeiboPost, WeiboSuggestion, WeiboTimelinePage, WeiboUser } from '../model/WeiboModel';
import { WeiboAuthManager } from './WeiboAuthManager';
import { WeiboVisitorSession } from './WeiboVisitorSession';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_TAG: string = 'WeiboService';

/**
 * Adapter for public mobile containers and user-initiated post actions.
 * Endpoint responses are deliberately mapped to small app-owned models, so UI
 * code is insulated from undocumented response-shape changes.
 */
export class WeiboService {
  private static instance: WeiboService | null = null;
  private recentPost: WeiboPost | null = null;
  private commentCache: ResponseCache<WeiboCommentsPage> = new ResponseCache<WeiboCommentsPage>();
  private commentCacheKeys: Map<string, Set<string>> = new Map();
  private pendingLikes: Set<string> = new Set();
  private pendingFollows: Set<string> = new Set();
  private following: Map<string, boolean> = new Map();
  private relationshipRevision: number = 0;
  /**
   * 长文全文缓存（postId -> 全文 HTML）。
   * 一条长文会被列表卡片（点「展开」）和详情页先后索要，缓存住避免重复请求。
   */
  private longTextCache: Map<string, string> = new Map();
  /** 正在飞的长文请求：同一帖被两处同时索要时合并成一次网络请求。 */
  private longTextPending: Map<string, Promise<string>> = new Map();

  constructor() {
    WeiboAuthManager.getInstance().onSessionChange((): void => {
      this.recentPost = null;
      PostEntities.shared().clear();
      this.commentCache = new ResponseCache<WeiboCommentsPage>();
      this.commentCacheKeys.clear();
      this.pendingLikes.clear();
      this.pendingFollows.clear();
      this.following.clear();
      this.relationshipRevision++;
      this.longTextCache.clear();
      this.longTextPending.clear();
    });
  }

  static getInstance(): WeiboService {
    if (WeiboService.instance === null) {
      WeiboService.instance = new WeiboService();
    }
    return WeiboService.instance;
  }

  /** Warms the API 24 RCP connection while local auth/settings initialization is running. */
  preconnectTimeline(): void {
    WeiboHttpClient.preconnectMobile();
  }

  async fetchUserProfile(userId: string): Promise<WeiboUser> {
    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    const revision: number = this.relationshipRevision;
    const escapedUserId: string = encodeURIComponent(userId.trim());
    const raw: string = await this.get(`https://m.weibo.cn/api/container/getIndex?containerid=100505${escapedUserId}`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const user: WeiboUserJson | undefined = response.data?.userInfo;
    if (user === undefined) {
      throw new Error('微博没有返回用户资料');
    }
    const profile: WeiboUser = this.toUser(user);
    if (generation !== WeiboAuthManager.getInstance().getGeneration()) { throw new Error('请求已取消'); }
    if (revision === this.relationshipRevision && !this.pendingFollows.has(profile.id)) {
      if (profile.following !== undefined) { this.following.set(profile.id, profile.following); }
      else { this.following.delete(profile.id); }
    } else { profile.following = this.following.get(profile.id); }
    return profile;
  }

  getFollowing(userId: string): boolean | undefined { return this.following.get(userId); }

  /**
   * 用户主动发起的写请求（关注/取关/点赞/评论），必要时补一次重试。
   *
   * 微博的 CSRF 令牌（XSRF-TOKEN）随响应轮换，写接口用「Cookie 值 == 请求头 X-XSRF-TOKEN」
   * 双提交校验：拿着过期令牌就是 403。而这一次 403 的响应本身通常已换发新令牌
   * （WeiboAuthManager 收到响应就并进 Cookie），因此用最新 Cookie 原样重发一次即可，
   * 不必让用户看到「微博拒绝了」。
   *
   * 只有 HTTP 层的 403 才重试：其它状态码和业务错误（`ok:0`，如需要验证码、次数超限）
   * 都已经带了明确原因，重复发送没有意义，也可能加重风控。
   */
  private async postAuthenticatedWrite(endpoint: string, useDesktopCookie: boolean,
    form: rcp.Form): Promise<void> {
    try {
      this.parseResponse(await this.sendWrite(endpoint, useDesktopCookie, form));
      return;
    } catch (error) {
      if ((error as WeiboRequestError).code !== 403) { throw error as Error; }
    }
    this.parseResponse(await this.sendWrite(endpoint, useDesktopCookie, form));
  }

  private sendWrite(endpoint: string, useDesktopCookie: boolean, form: rcp.Form): Promise<string> {
    return WeiboHttpClient.postForm(endpoint, this.requireAccountCookie(useDesktopCookie), form);
  }

  /** Only called by the profile's explicit follow/unfollow action. */
  async setFollowing(userId: string, following: boolean): Promise<void> {
    const id: string = userId.trim();
    const auth: WeiboAuthManager = WeiboAuthManager.getInstance();
    this.requireAccountCookie(true);
    if (!/^[1-9][0-9]*$/.test(id) || id === auth.getAccountId()) { throw new Error('无法关注该用户'); }
    if (this.pendingFollows.has(id)) { throw new Error('关注操作正在处理中'); }
    const generation: number = auth.getGeneration();
    const form: rcp.Form = following ? new rcp.Form({ friend_uid: id }) : new rcp.Form({ uid: id });
    form.keys = following ? ['friend_uid'] : ['uid'];
    const endpoint: string = following ? 'https://weibo.com/ajax/friendships/create'
      : 'https://weibo.com/ajax/friendships/destory';
    this.pendingFollows.add(id);
    this.relationshipRevision++;
    try {
      await this.postAuthenticatedWrite(endpoint, true, form);
      if (generation !== auth.getGeneration()) { throw new Error('请求已取消'); }
      this.following.set(id, following);
    } catch (error) {
      // A timeout can have committed remotely. Require a fresh read before the next toggle.
      if (generation === auth.getGeneration()) { this.following.delete(id); }
      throw new Error((error as Error).message ?? '关注操作失败');
    } finally {
      if (generation === auth.getGeneration()) {
        this.pendingFollows.delete(id);
        this.relationshipRevision++;
        AppStorage.setOrCreate<number>('weiboRelationshipTick', (AppStorage.get<number>('weiboRelationshipTick') ?? 0) + 1);
      }
    }
  }

  /** Resolve the profile, including the HD avatar, for the account in the saved Cookie. */
  async fetchCurrentUserProfile(): Promise<WeiboUser> {
    const cookie: string = this.requireAccountCookie();
    const raw: string = await WeiboHttpClient.get('https://m.weibo.cn/api/config', cookie);
    let config: WeiboConfigResponse;
    try {
      config = JSON.parse(raw) as WeiboConfigResponse;
    } catch (error) {
      throw new Error('微博返回了无法解析的登录资料');
    }
    const data: WeiboConfigData | undefined = config.data;
    const uid: string = data?.uid?.trim() ?? '';
    if (config.ok !== 1 || data === undefined || !data.login || uid.length === 0) {
      const message: string = config.msg?.trim() ?? '';
      throw new Error(message.length > 0 ? message : '微博未接受当前登录态，请重新登录后再试');
    }
    return await this.fetchUserProfile(uid);
  }

  async fetchUserTimeline(userId: string, page: number): Promise<WeiboPost[]> {
    const escapedUserId: string = encodeURIComponent(userId.trim());
    const safePage: number = page < 1 ? 1 : page;
    const raw: string = await this.get(
      `https://m.weibo.cn/api/container/getIndex?containerid=230413${escapedUserId}&page=${safePage}&count=20`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const cards: WeiboCardJson[] = response.data?.cards ?? [];
    const posts: WeiboPost[] = [];
    for (let index: number = 0; index < cards.length; index++) {
      const card: WeiboCardJson = cards[index];
      if (card.card_type === 9 && card.mblog !== undefined) {
        posts.push(this.toPost(card.mblog));
      }
    }
    return posts;
  }

  /** Public recommendation timeline used by the first tab. */
  async fetchRecommendTimeline(page: number): Promise<WeiboPost[]> {
    const safePage: number = page < 1 ? 1 : page;
    const raw: string = await this.get(
      `https://m.weibo.cn/api/container/getIndex?containerid=102803&page=${safePage}`);
    return this.postsFromResponse(raw);
  }

  /**
   * The logged-in account's following timeline. The mobile `231093` container
   * lists followed users, while this desktop feed returns their actual posts.
   */
  async fetchFollowingTimeline(maxId: string): Promise<WeiboTimelinePage> {
    const cookie: string = this.requireAccountCookie(true);
    const cursor: string = maxId.trim().length > 0 ? maxId.trim() : '0';
    const raw: string = await WeiboHttpClient.getDesktop(
      `https://weibo.com/ajax/feed/friendstimeline?count=20&max_id=${encodeURIComponent(cursor)}`, cookie);
    return this.followingPageFromResponse(raw, cursor);
  }

  /**
   * Search posts through Weibo's mobile search container. It uses the same
   * account-or-visitor session as the timeline, so public results work before
   * login and a saved Cookie can return the user's normal search results.
   */
  async fetchSearchPosts(query: string, page: number): Promise<WeiboPost[]> {
    const cleanQuery: string = query.trim();
    if (cleanQuery.length === 0) {
      return [];
    }
    const safePage: number = page < 1 ? 1 : page;
    const containerId: string = `100103type%3D1%26q%3D${encodeURIComponent(cleanQuery)}`;
    const raw: string = await this.get(
      `https://m.weibo.cn/api/container/getIndex?containerid=${containerId}&page_type=searchall&page=${safePage}`);
    return this.postsFromResponse(raw);
  }

  /**
   * Resolves a single post for a routed detail page. The in-memory copy makes
   * the transition immediate; this endpoint is the fallback after recreation.
   */
  async fetchPost(postId: string): Promise<WeiboPost> {
    const id: string = postId.trim();
    if (id.length === 0) {
      throw new Error('微博信息不完整，无法打开详情');
    }
    const raw: string = await this.get(`https://m.weibo.cn/statuses/show?id=${encodeURIComponent(id)}`);
    this.parseResponse(raw);
    const response: WeiboStatusApiResponse = JSON.parse(raw) as WeiboStatusApiResponse;
    if (response.data === undefined) {
      throw new Error('微博没有返回帖子详情');
    }
    const post: WeiboPost = this.toPost(response.data);
    this.recentPost = PostEntities.shared().adopt(post);
    return post;
  }

  rememberPost(post: WeiboPost): void {
    this.recentPost = post;
  }

  /**
   * 长文全文。
   *
   * `isLongText` 的帖子，列表接口只给截断到约 140 字的 HTML，末尾那截「展开 / 全文」是
   * 接口自带的分隔标记、不是正文。不补这一步，就会出现「列表截断显示展开，点进详情还是展开」。
   *
   * 两条通道：移动端 `/statuses/extend`（关注流的 postId 同样可用），拿不到再退回桌面端
   * `/ajax/statuses/longtext`。都失败返回空串——调用方保留截断正文，不要变成白屏。
   */
  async fetchLongText(postId: string): Promise<string> {
    const id: string = postId.trim();
    if (id.length === 0) { return ''; }
    const cached: string | undefined = this.longTextCache.get(id);
    if (cached !== undefined) { return cached; }
    const inflight: Promise<string> | undefined = this.longTextPending.get(id);
    if (inflight !== undefined) { return inflight; }

    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    const task: Promise<string> = this.loadLongText(id, generation);
    this.longTextPending.set(id, task);
    try {
      const html: string = await task;
      if (generation !== WeiboAuthManager.getInstance().getGeneration()) { return ''; }
      if (html.length > 0) {
        this.longTextCache.set(id, html);
      }
      return html;
    } finally {
      if (this.longTextPending.get(id) === task) { this.longTextPending.delete(id); }
    }
  }

  /** 已经拿到的全文；没有返回空串（同步，供渲染路径直接取用）。 */
  cachedLongText(postId: string): string {
    return this.longTextCache.get(postId.trim()) ?? '';
  }

  private async loadLongText(id: string, generation: number): Promise<string> {
    const encoded: string = encodeURIComponent(id);
    try {
      const raw: string = await this.get(`https://m.weibo.cn/statuses/extend?id=${encoded}`);
      const html: string = WeiboMapper.longTextContent(JSON.parse(raw) as WeiboLongTextResponse);
      if (html.length > 0) { return html; }
      hilog.warn(0x0000, LOG_TAG, 'Mobile long text empty for %{public}s', id);
    } catch (error) {
      hilog.warn(0x0000, LOG_TAG, 'Mobile long text failed: %{public}s', JSON.stringify(error));
    }
    if (generation !== WeiboAuthManager.getInstance().getGeneration()) { return ''; }
    try {
      const raw: string = await WeiboHttpClient.getDesktop(`https://weibo.com/ajax/statuses/longtext?id=${encoded}`, WeiboAuthManager.getInstance().getDesktopCookie());
      return WeiboMapper.longTextContent(JSON.parse(raw) as WeiboLongTextResponse);
    } catch (error) {
      hilog.warn(0x0000, LOG_TAG, 'Desktop long text failed: %{public}s', JSON.stringify(error));
      return '';
    }
  }

  getRememberedPost(postId: string): WeiboPost | null {
    if (this.recentPost === null || this.recentPost.id !== postId) {
      return null;
    }
    return this.recentPost;
  }

  /** 首屏缓存按排序隔离；后续页传递服务器游标。 */
  async fetchComments(post: WeiboPost, param: string = '', cursor: WeiboCommentCursor | null = null): Promise<WeiboCommentsPage> {
    if (cursor !== null) { return this.fetchCommentsPage(post, '', param, cursor); }
    const key: string = `${post.id}:${param}`;
    const keys: Set<string> = this.commentCacheKeys.get(post.id) ?? new Set<string>();
    keys.add(key);
    this.commentCacheKeys.set(post.id, keys);
    return this.commentCache.get(key, () => this.fetchCommentsPage(post, '', param, null));
  }

  prefetchComments(post: WeiboPost): void {
    this.fetchComments(post).catch((error: Error): void => {
      hilog.debug(0x0000, LOG_TAG, 'event=comment_prefetch_failed post=%{public}s message=%{public}s', post.id, error.message);
    });
  }

  /** 子回复使用根评论标识，与主评论列表独立分页。 */
  fetchCommentReplies(post: WeiboPost, rootId: string, param: string = '',
    cursor: WeiboCommentCursor | null = null): Promise<WeiboCommentsPage> {
    return this.fetchCommentsPage(post, rootId, param, cursor);
  }

  private async fetchCommentsPage(post: WeiboPost, rootId: string, param: string,
    cursor: WeiboCommentCursor | null): Promise<WeiboCommentsPage> {
    const child: boolean = rootId.length > 0;
    const auth: WeiboAuthManager = WeiboAuthManager.getInstance();
    const generation: number = auth.getGeneration();
    const cookie: string = auth.getDesktopCookie();
    // 推荐流来自移动站，缺少桌面评论所需的精选模式时，按原帖详情补齐。
    if (!child && post.commentBulletinMode === undefined) {
      const detail: string = await WeiboHttpClient.getDesktop(
        `https://weibo.com/ajax/statuses/show?id=${encodeURIComponent(post.id)}`, cookie);
      this.parseResponse(detail);
      const source: WeiboPostJson = JSON.parse(detail) as WeiboPostJson;
      if (generation !== auth.getGeneration()) { throw new Error('请求已取消'); }
      if (source.is_show_bulletin === undefined) { throw new Error('微博未返回评论模式，请稍后重试'); }
      post.commentBulletinMode = source.is_show_bulletin;
    }
    let url: string = `https://weibo.com/ajax/statuses/buildComments?is_reload=1&id=${encodeURIComponent(child ? rootId : post.id)}`
      + `&is_mix=${child ? 1 : 0}&fetch_level=${child ? 1 : 0}&count=20&uid=${encodeURIComponent(post.userId)}&locale=zh-CN`
      + `&is_show_bulletin=${child ? 2 : post.commentBulletinMode}&max_id=${encodeURIComponent(cursor?.maxId ?? '')}`;
    if (!child) { url += '&type=feed'; }
    if (cursor !== null) {
      if (cursor.maxIdType) { url += `&max_id_type=${encodeURIComponent(cursor.maxIdType)}`; }
    }
    if (param) {
      const separator: number = param.indexOf('=');
      if (separator <= 0) { throw new Error('微博评论排序参数不完整'); }
      url += `&${encodeURIComponent(param.substring(0, separator))}=${encodeURIComponent(param.substring(separator + 1))}`;
    }
    const raw: string = await WeiboHttpClient.getDesktop(url, cookie);
    this.parseResponse(raw);
    const result: WeiboCommentsPage = WeiboMapper.commentsPage(JSON.parse(raw) as WeiboBuildCommentsResponse, cursor, rootId);
    hilog.debug(0x0000, LOG_TAG, 'event=comments_loaded post=%{public}s root=%{public}s count=%{public}d', post.id, rootId, result.items.length);
    return result;
  }

  private invalidateComments(postId: string): void {
    for (const key of this.commentCacheKeys.get(postId) ?? new Set<string>()) { this.commentCache.invalidate(key); }
    this.commentCacheKeys.delete(postId);
  }

  /** 参数与网页版详情的转发、赞页签保持一致。 */
  async fetchInteractions(postId: string, kind: 'reposts' | 'likes', page: number): Promise<WeiboInteractionsPage> {
    const endpoint: string = kind === 'reposts' ? 'repostTimeline' : 'likeShow';
    const params: string = kind === 'reposts' ? '&moduleID=feed' : '&attitude_type=0&attitude_enable=1';
    const raw: string = await WeiboHttpClient.getDesktop(
      `https://weibo.com/ajax/statuses/${endpoint}?id=${encodeURIComponent(postId)}&page=${page}&count=20${params}`,
      WeiboAuthManager.getInstance().getDesktopCookie());
    this.parseResponse(raw);
    const result: WeiboInteractionsPage = WeiboMapper.interactionsPage(JSON.parse(raw) as WeiboInteractionsResponse, kind);
    hilog.debug(0x0000, LOG_TAG, 'event=interactions_loaded post=%{public}s kind=%{public}s page=%{public}d count=%{public}d',
      postId, kind, page, result.items.length);
    return result;
  }

  /** 评论转发保留原帖和评论标识，只有用户发送草稿时调用。 */
  async repostComment(postId: string, commentId: string, content: string): Promise<void> {
    this.requireAccountCookie(true);
    const comment: string = content.trim();
    if (!postId.trim() || !commentId.trim() || !comment) { throw new Error('转发内容不能为空'); }
    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    const form: rcp.Form = new rcp.Form({ id: postId, cid: commentId, comment: comment, is_comment: '0' });
    form.keys = ['id', 'cid', 'comment', 'is_comment'];
    await this.postAuthenticatedWrite('https://weibo.com/ajax/statuses/normal_repost', true, form);
    if (generation !== WeiboAuthManager.getInstance().getGeneration()) { throw new Error('请求已取消'); }
    hilog.info(0x0000, LOG_TAG, 'event=comment_reposted post=%{public}s comment=%{public}s', postId, commentId);
  }

  /** Like or cancel a like. This is never called automatically. */
  async setLike(postId: string, like: boolean): Promise<void> {
    const id: string = postId.trim();
    this.requireAccountCookie(true);
    if (id.length === 0) {
      throw new Error('微博信息不完整，无法点赞');
    }
    const form: rcp.Form = new rcp.Form({ id: id });
    form.keys = ['id'];
    const endpoint: string = like
      ? 'https://weibo.com/ajax/statuses/setLike'
      : 'https://weibo.com/ajax/statuses/destroyLike';
    if (this.pendingLikes.has(id)) { throw new Error('点赞请求正在处理中'); }
    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    this.pendingLikes.add(id);
    try {
      await this.postAuthenticatedWrite(endpoint, true, form);
      if (generation !== WeiboAuthManager.getInstance().getGeneration()) { throw new Error('请求已取消'); }
      PostEntities.shared().confirmLike(id, like);
    } finally {
      if (generation === WeiboAuthManager.getInstance().getGeneration()) { this.pendingLikes.delete(id); }
    }
  }

  /** Publish one user-authored comment after the user presses Send. */
  async publishComment(postId: string, content: string): Promise<void> {
    const id: string = postId.trim();
    const cleanContent: string = content.trim();
    this.requireAccountCookie();
    if (id.length === 0 || cleanContent.length === 0) {
      throw new Error('评论内容不能为空');
    }
    const form: rcp.Form = new rcp.Form({ id: id, content: cleanContent });
    form.keys = ['id', 'content'];
    // A timed-out write may have reached the server too. Never reuse its old comments.
    this.invalidateComments(id);
    try {
      await this.postAuthenticatedWrite('https://m.weibo.cn/api/comments/create', false, form);
    } finally { this.invalidateComments(id); }
  }

  /** 仅由用户点击发送触发，cid 指向实际被回复的评论。 */
  async publishReply(postId: string, commentId: string, content: string): Promise<void> {
    const id: string = postId.trim();
    const cid: string = commentId.trim();
    const comment: string = content.trim();
    this.requireAccountCookie(true);
    if (!id || !cid || !comment) { throw new Error('回复对象或内容不完整'); }
    const form: rcp.Form = new rcp.Form({ id: id, cid: cid, comment: comment });
    form.keys = ['id', 'cid', 'comment'];
    this.invalidateComments(id);
    try {
      await this.postAuthenticatedWrite('https://weibo.com/ajax/comments/reply', true, form);
      hilog.info(0x0000, LOG_TAG, 'event=comment_reply_sent post=%{public}s comment=%{public}s', id, cid);
    } finally { this.invalidateComments(id); }
  }

  /** 分类使用各自榜单接口，“我的”沿用当前桌面登录态。 */
  async fetchHotTopics(category: WeiboHotCategory): Promise<WeiboHotTopic[]> {
    let endpoint: string;
    switch (category) {
      case WeiboHotCategory.Hot: endpoint = '/ajax/side/hotSearch'; break;
      case WeiboHotCategory.Tech: endpoint = '/ajax/statuses/technology'; break;
      case WeiboHotCategory.Entertainment: endpoint = '/ajax/statuses/entertainment'; break;
      case WeiboHotCategory.Life: endpoint = '/ajax/statuses/life'; break;
      case WeiboHotCategory.Social: endpoint = '/ajax/statuses/social'; break;
      case WeiboHotCategory.Sports: endpoint = '/ajax/statuses/sport'; break;
      case WeiboHotCategory.Animation: endpoint = '/ajax/statuses/acg'; break;
      case WeiboHotCategory.Mine: endpoint = '/ajax/statuses/mineBand'; break;
    }
    const cookie: string = category === 'mine' ? this.requireAccountCookie(true)
      : WeiboAuthManager.getInstance().getDesktopCookie();
    const raw: string = await WeiboHttpClient.getDesktop(`https://weibo.com${endpoint}`, cookie);
    const response: WeiboApiResponse = this.parseResponse(raw);
    if (response.data === undefined) { throw new Error('微博未返回热搜榜单'); }
    const result: WeiboHotTopic[] = WeiboMapper.hotTopics(response.data);
    hilog.debug(0x0000, LOG_TAG, 'event=hot_topics_loaded category=%{public}s count=%{public}d', category, result.length);
    return result;
  }

  /** Public search autocomplete. A full result page still requires a user session. */
  async fetchSuggestions(query: string, limit: number): Promise<WeiboSuggestion[]> {
    const cleanQuery: string = query.trim();
    if (cleanQuery.length === 0) {
      return [];
    }
    const raw: string = await WeiboHttpClient.getDesktop(
      `https://weibo.com/ajax/side/search?q=${encodeURIComponent(cleanQuery)}`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const source: WeiboSuggestionJson[] = response.data?.hotquery ?? [];
    const result: WeiboSuggestion[] = [];
    const safeLimit: number = limit > 0 ? limit : source.length;
    for (let index: number = 0; index < source.length && index < safeLimit; index++) {
      const item: WeiboSuggestionJson = source[index];
      const word: string = item.suggestion?.trim() ?? '';
      if (word.length > 0) {
        result.push({ word: word, count: item.count ?? 0, isHot: item.top_flag === 2 });
      }
    }
    return result;
  }

  private async get(url: string): Promise<string> {
    const accountCookie: string = WeiboAuthManager.getInstance().getCookie();
    const visitorCookie: string = WeiboVisitorSession.getInstance().getCookie();
    const cookie: string = accountCookie.length > 0 ? accountCookie : visitorCookie;
    return WeiboHttpClient.get(url, cookie);
  }

  private postsFromResponse(raw: string): WeiboPost[] {
    const response: WeiboApiResponse = this.parseResponse(raw);
    const data: WeiboResponseData | undefined = response.data;
    if (data === undefined) {
      // ok:1 却没有 data 属于接口结构异常。这里必须抛错而不是返回空数组：
      // 返回空数组会被 FeedStore 判定为 Empty，把「拿不到数据」显示成「内容为空」，
      // 既没有错误提示也不会重试（首页冷启动误显示空态的一半原因就在这里）。
      throw new Error('微博接口未返回内容，请稍后重试');
    }
    const cards: WeiboCardJson[] = data.cards ?? [];
    const posts: WeiboPost[] = [];
    this.appendPostsFromCards(cards, posts);
    if (posts.length === 0) {
      hilog.warn(0x0000, LOG_TAG, 'No post parsed from %{public}d card(s)', cards.length);
    }
    return posts;
  }

  private followingPageFromResponse(raw: string, requestedMaxId: string): WeiboTimelinePage {
    const trimmed: string = raw.trim();
    if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html') || trimmed.includes('passport.weibo.com')) {
      throw new Error('微博未接受当前登录态，请重新登录后再试');
    }
    let response: WeiboFollowingTimelineResponse;
    try {
      response = JSON.parse(raw) as WeiboFollowingTimelineResponse;
    } catch (error) {
      throw new Error('微博返回了无法解析的关注动态');
    }
    if (response.ok !== 1) {
      const message: string = response.msg?.trim() ?? '';
      throw new Error(message.length > 0 ? message : '微博关注动态接口暂不可用，请稍后重试');
    }
    const source: WeiboPostJson[] = response.statuses ?? [];
    const items: WeiboPost[] = [];
    for (let index: number = 0; index < source.length; index++) {
      items.push(this.toPost(source[index]));
    }
    const cursorValue: string | number | undefined = response.max_id;
    const nextMaxId: string = cursorValue === undefined ? '' : `${cursorValue}`;
    const hasMore: boolean = items.length > 0 && nextMaxId.length > 0
      && nextMaxId !== '0' && nextMaxId !== requestedMaxId;
    return { items: items, nextMaxId: nextMaxId, hasMore: hasMore };
  }

  private appendPostsFromCards(cards: WeiboCardJson[], posts: WeiboPost[]): void {
    for (let index: number = 0; index < cards.length; index++) {
      const card: WeiboCardJson = cards[index];
      if (card.mblog !== undefined && (card.card_type === 9 || card.card_type === undefined)) {
        posts.push(this.toPost(card.mblog));
      }
      const group: WeiboCardJson[] | undefined = card.card_group;
      if (group !== undefined) {
        this.appendPostsFromCards(group, posts);
      }
    }
  }

  private requireAccountCookie(desktop: boolean = false): string {
    const auth: WeiboAuthManager = WeiboAuthManager.getInstance();
    const cookie: string = desktop ? auth.getDesktopCookie() : auth.getCookie();
    if (!WeiboAuthManager.getInstance().hasCookie() || cookie.length === 0) {
      throw new Error('请先在“我的”中完成微博登录');
    }
    return cookie;
  }

  private parseResponse(raw: string): WeiboApiResponse {
    const trimmed: string = raw.trim();
    if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html') || trimmed.includes('visitor.passport.weibo.cn')) {
      throw new Error('微博未接受当前登录态，请重新登录后再试');
    }
    let response: WeiboApiResponse;
    try {
      response = JSON.parse(raw) as WeiboApiResponse;
    } catch (error) {
      throw new Error('微博返回了无法解析的数据');
    }
    if (response.ok !== 1) {
      const message: string = response.msg?.trim() ?? '';
      const url: string = response.url ?? '';
      if (response.ok === -100 || url.includes('login.php')) {
        throw new Error('微博要求登录，请在“我的”中完成登录后重试');
      }
      if (url.includes('captcha')) {
        throw new Error('微博要求验证码，请在设置中更新 Cookie 后重试');
      }
      throw new Error(message.length > 0 ? message : '微博接口暂不可用，请稍后重试');
    }
    return response;
  }

  private toUser(source: WeiboUserJson): WeiboUser { return WeiboMapper.toUser(source); }
  private toPost(source: WeiboPostJson): WeiboPost { return PostEntities.shared().adopt(WeiboMapper.toPost(source)); }
}
