import { PostEntities } from '../store/PostEntities';
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { ThreadCard, ThreadItemData, ThreadSharePayload, EmptyView, ErrorView } from '../components/CommonComponents';
import { ThreadListSkeleton } from '../components/Skeleton';
import { Breakpoint, CARD_COLUMNS_KEY, ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode, isLargeScreenForm, isWideFormDevice as detectWideFormDevice, overrideColumns, readColumnMode } from '../common/Theme';
import { WeiboPost } from '../model/WeiboModel';
import { buildWeiboThreadItem } from '../common/WeiboCardItems';
import { openWeiboLink } from '../common/WeiboLinkNavigation';
import { FeedLoadState, FeedStore } from '../store/FeedStore';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService } from '../service/WeiboService';
import { ShareUtil } from '../common/ShareUtil';

/** Lazy WaterFlow data source: refreshes reload every card while paged results append only their tail. */
class WeiboPostDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  public data: WeiboPost[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): WeiboPost {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reload(): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataReloaded();
    }
  }

  notifyAdd(start: number): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      for (let added: number = start; added < this.data.length; added++) {
        this.listeners[index].onDataAdd(added);
      }
    }
  }
}

export enum WeiboTimelineMode {
  Recommend = 0,
  Following = 1,
}

type TabAnimationDirection = 'left' | 'right';

/** 帖子卡片在窗口坐标系中的区域，用于定位阅读锚点。 */
interface CardArea { y: number; h: number; }

/**
 * TiebaPura 首页的信息层级与帖子卡片，数据仅来自微博只读适配层。
 * 推荐与关注两个信息流经 FeedStore 读取：缓存先上屏、网络后台刷新，
 * 阅读位置以“帖子 ID＋相对偏移”持久化并在下次进入时恢复。
 */
@Component
export struct WeiboHomeTab {
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  @Prop mode: WeiboTimelineMode = WeiboTimelineMode.Recommend;
  onPendingChanged: (pending: boolean) => void = () => {};
  @Prop @Watch('onAcceptUpdate') acceptUpdateTrigger: number = 0;
  private onAcceptUpdate(): void { if (this.isActive) { this.feed.acceptPendingUpdate(); } }
  @Prop showHeader: boolean = true;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  /** 外部请求平滑回到列表顶端；值递增一次即消费一次（底部导航单击首页 Tab）。 */
  @Prop @Watch('onScrollTopRequest') scrollTopTrigger: number = 0;
  /** 当前是否为屏幕上可见的那条信息流；隐藏的一条不响应回顶请求。 */
  @Prop @Watch('onActiveChanged') isActive: boolean = true;
  private feedReady: boolean = false;
  private onActiveChanged(): void {
    if (!this.isActive || !this.feedReady) { return; }
    this.resetReadingViewport();
    this.feed.enter();
  }
  /** Reserved in the scroll content, so floating host chrome never shrinks the scroll viewport. */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 116;
  onOpenPost: (post: WeiboPost) => void = () => {};
  onOpenUserProfile: (userId: string, userName: string) => void = () => {};
  /** 点正文里的 #话题#：由宿主切到搜索页并发起该话题的检索。 */
  onOpenTopic: (topic: string) => void = () => {};
  @StorageLink('weiboPostTick') @Watch('onPostEntitiesChanged') postTick: number = 0;
  private onPostEntitiesChanged(): void { this.reapplyEntities(); }
  @State isDark: boolean = isDarkMode();
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  /** Device capability gate shared with TiebaPura's large-screen feeds. */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  private timelineScroller: Scroller = new Scroller();
  @State timelineDataSource: WeiboPostDataSource = new WeiboPostDataSource();
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @StorageLink('columnMode') columnMode: number = 0;
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;
  /** 数据在 aboutToAppear 里按 mode 建立正确实例。 */
  @State feed: FeedStore = new FeedStore('recommend');
  /** 下拉刷新指示；由 Refresh 组件经 $$ 双向绑定驱动。 */
  @State pullRefreshing: boolean = false;
  /** 各卡片最新区域；滚动会持续触发 onAreaChange，这里的值始终接近实时。 */
  private cardAreas: Map<string, CardArea> = new Map();
  /** Scroll 视口在窗口坐标系中的顶边，作为锚点偏移的参照。 */
  private scrollViewportY: number = 0;
  /** Scroll 视口高度与信息流内容高度；用于首屏不满一屏时的自动补页判定。 */
  private scrollViewportHeight: number = 0;
  private timelineContentHeight: number = 0;
  /** 待恢复的锚点帖子 ID；其首次 onAreaChange 时应用一次滚动。 */
  private positionRestoring: string = '';
  private restoreRelative: number = 0;

  async aboutToAppear(): Promise<void> {
    // This runs beside local auth initialization; it does not transfer feed data.
    WeiboService.getInstance().preconnectTimeline();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await WeiboAuthManager.getInstance().init(context);
    this.feed = new FeedStore(this.mode === WeiboTimelineMode.Recommend ? 'recommend' : 'following');
    this.feed.onPendingChanged = (pending: boolean): void => { this.onPendingChanged(pending); };
    this.feed.onContentChanged = (): void => { this.syncTimeline(); this.beginPositionRestore(); };
    this.feed.onStreamReplaced = (): void => { this.resetReadingViewport(); };
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    this.feedReady = true;
    await this.loadFirstPage(true);
  }

  aboutToDisappear(): void {
    this.feedReady = false;
    this.saveReadingPosition();
    this.feed.cancel();
    this.feed.onContentChanged = (): void => {};
    this.feed.onStreamReplaced = (): void => {};
    this.feed.onPendingChanged = (): void => {};
  }
  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /** Mirrors TiebaPura's WaterFlow contract: page replacement reloads, pagination appends. */
  private syncTimeline(): void {
    const previous: WeiboPost[] = this.timelineDataSource.data;
    const next: WeiboPost[] = this.feed.posts;
    let isAppend: boolean = previous.length > 0 && next.length > previous.length;
    if (isAppend) {
      for (let index: number = 0; index < previous.length; index++) {
        if (previous[index].id !== next[index].id) {
          isAppend = false;
          break;
        }
      }
    }
    this.timelineDataSource.data = next;
    if (isAppend) {
      this.timelineDataSource.notifyAdd(previous.length);
    } else {
      this.timelineDataSource.reload();
    }
  }

  /** 跨页面互动状态（点赞等）变化后把实体层状态套回当前列表。 */
  private reapplyEntities(): void {
    this.feed.posts = this.feed.posts.map((post: WeiboPost): WeiboPost => PostEntities.shared().apply(post));
    this.syncTimeline();
  }

  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    try {
      this.timelineScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (error) {
    }
  }

  /** Phones and narrow windows retain one column; large forms receive a true waterfall layout. */
  private waterfallColumns(): number {
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0 || this.viewportWidth < Breakpoint.sm) {
      return 1;
    }
    if (!isLargeScreenForm(this.isWideFormDevice)) {
      return 1;
    }
    const override: number = overrideColumns(this.columnMode, this.viewportWidth > this.viewportHeight);
    if (override > 0) {
      return override;
    }
    return this.viewportWidth > this.viewportHeight ? 3 : 2;
  }

  private waterfallColumnsTemplate(): string {
    const columns: number = this.waterfallColumns();
    if (columns === 4) {
      return '1fr 1fr 1fr 1fr';
    }
    return columns === 3 ? '1fr 1fr 1fr' : '1fr 1fr';
  }

  /** Lets ThreadCard tune image geometry and text density to the active waterfall column count. */
  private syncCardColumns(): void {
    AppStorage.setOrCreate<number>(CARD_COLUMNS_KEY, this.waterfallColumns());
  }

  private animationDirection(): TabAnimationDirection {
    const storedDirection: string | undefined = AppStorage.get<string>('animationDirection');
    return storedDirection === 'right' ? 'right' : 'left';
  }

  private onEnter(): void {
    if (this.animationTrigger > 0) {
      this.isAnimating = false;
      this.playEnterAnimation(this.animationDirection());
    }
  }

  private onExit(): void {
    if (this.exitTrigger > 0) {
      this.playExitAnimation(this.animationDirection());
    }
  }

  private playExitAnimation(direction: TabAnimationDirection): void {
    if (this.isAnimating) {
      return;
    }
    this.isAnimating = true;
    const endX: number = direction === 'left' ? -350 : 350;
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: (): void => { this.isAnimating = false; }
    }, (): void => {
      this.pageTranslateX = endX;
      this.pageOpacity = 0;
    });
  }

  private playEnterAnimation(direction: TabAnimationDirection): void {
    if (this.isAnimating) {
      return;
    }
    this.isAnimating = true;
    const startX: number = direction === 'left' ? 350 : -350;
    this.pageTranslateX = startX;
    this.pageOpacity = 0;
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 300, curve: curves.springMotion() }, (): void => {
        this.pageTranslateX = 0;
        this.pageOpacity = 1;
      });
    }, 0);
    setTimeout((): void => { this.isAnimating = false; }, 600);
  }

  /** 登录/退出后旧账户内容不再保留，立即按新身份重建信息流。 */
  private onWeiboAuthTick(): void {
    this.feed.reset();
    this.syncTimeline();
    this.loadFirstPage(true);
  }

  /**
   * 首页读取：FeedStore 先展示本地缓存（含上次阅读位置），再后台刷新替换。
   * explicit 表示用户主动加载/重试/下拉刷新；已有内容时失败以 Toast 提示，不清空页面。
   */
  private async loadFirstPage(explicit: boolean): Promise<void> {
    try {
      await this.feed.loadFirst(explicit);
      if (explicit && this.feed.posts.length > 0 && this.feed.errorMessage.length > 0) {
        this.getUIContext().getPromptAction().showToast({ message: this.feed.errorMessage });
      }
    } finally {
      // 下拉刷新指示只在显式刷新任务结束后收起，包括失败路径
      if (explicit) { this.pullRefreshing = false; }
    }
    if (!this.feed.hasPendingUpdate) { this.scheduleAutoFill(); }
  }

  private async loadMore(): Promise<void> {
    const previousCount: number = this.feed.posts.length;
    await this.feed.loadMore();
    this.syncTimeline();
    if (this.feed.errorMessage.length > 0 && this.feed.posts.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: this.feed.errorMessage });
    }
    if (this.feed.posts.length > previousCount) { this.scheduleAutoFill(); }
  }

  /**
   * 无缝加载的兜底：首屏内容不足一屏时列表根本滚不动，onReachEnd 永不触发，
   * 因此在每次载入结束后延迟一帧比对内容与视口高度，没铺满就再续一页。
   * 仅内容增长时继续自动补屏；重复页批次和失败留给底部按钮手动续读。
   */
  private scheduleAutoFill(): void {
    setTimeout((): void => { this.autoFillIfViewportNotFilled(); }, 0);
  }

  private autoFillIfViewportNotFilled(): void {
    if (!this.feed.hasMore || this.feed.loadingMore || this.feed.refreshing || this.feed.errorMessage.length > 0) { return; }
    if (this.feed.state !== FeedLoadState.Success || this.feed.posts.length === 0) { return; }
    if (this.scrollViewportHeight <= 0 || this.timelineContentHeight <= 0) { return; }
    if (this.timelineContentHeight > this.scrollViewportHeight + 8) { return; }
    this.loadMore();
  }

  /** 缓存恢复后记录待恢复锚点，由锚点卡片的首次 onAreaChange 触发滚动。 */
  private resetReadingViewport(): void {
    this.positionRestoring = ''; this.restoreRelative = 0;
    this.cardAreas.clear();
    try { this.timelineScroller.scrollTo({ xOffset: 0, yOffset: 0 }); }
    catch (_) { /* A not-yet-mounted scroller already starts at the top. */ }
  }

  private beginPositionRestore(): void {
    if (this.feed.pendingAnchorId.length === 0) { return; }
    if (this.feed.state !== FeedLoadState.Success) {
      this.feed.pendingAnchorId = '';
      return;
    }
    this.positionRestoring = this.feed.pendingAnchorId;
    this.restoreRelative = this.feed.pendingAnchorOffset;
    this.feed.pendingAnchorId = '';
  }

  private onCardAreaChange(post: WeiboPost, newValue: Area): void {
    this.cardAreas.set(post.id, { y: newValue.globalPosition.y as number, h: newValue.height as number });
    if (this.positionRestoring.length > 0 && this.positionRestoring === post.id) {
      this.applyRestoredPosition();
    }
  }

  /** 把锚点卡片顶边放回上次保存的视口相对偏移处；公式在保存点为不动点。 */
  private applyRestoredPosition(): void {
    const anchorId: string = this.positionRestoring;
    this.positionRestoring = '';
    const area: CardArea | undefined = this.cardAreas.get(anchorId);
    if (area === undefined) { return; }
    const targetY: number = this.scrollViewportY + this.restoreRelative;
    const currentY: number = this.timelineScroller.currentOffset().yOffset;
    this.timelineScroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, currentY + area.y - targetY) });
  }

  /** 底部导航单击当前首页 Tab：平滑回到列表顶端。 */
  private onScrollTopRequest(): void {
    if (this.scrollTopTrigger <= 0 || !this.isActive) { return; }
    try {
      this.timelineScroller.scrollTo({
        xOffset: 0,
        yOffset: 0,
        animation: { duration: 320, curve: Curve.EaseOut }
      });
    } catch (error) {
      // 视口尚未完成布局时忽略；下一次单击会重试
    }
  }

  /** 滚动停止/页面销毁时保存阅读位置：第一个底边越过视口顶边的帖子即锚点。 */
  private saveReadingPosition(): void {
    if (this.positionRestoring.length > 0) { return; }
    if (this.feed.state !== FeedLoadState.Success || this.feed.posts.length === 0) { return; }
    const posts: WeiboPost[] = this.feed.posts;
    for (let index: number = 0; index < posts.length; index++) {
      const area: CardArea | undefined = this.cardAreas.get(posts[index].id);
      if (area === undefined) { continue; }
      if (area.y + area.h > this.scrollViewportY) {
        this.feed.savePosition(posts[index].id, area.y - this.scrollViewportY);
        return;
      }
    }
  }

  /**
   * 卡片映射统一走 common/WeiboCardItems：正文富文本、转发引述块、发帖设备
   * 这三个口径在首页/搜索/用户主页必须完全一致，分散实现必然漂移。
   */
  private toThreadCard(post: WeiboPost): ThreadItemData {
    return buildWeiboThreadItem(post);
  }

  private openPost(post: WeiboPost): void {
    if (post.id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_post_unavailable') });
      return;
    }
    this.onOpenPost(post);
  }

  private openUserProfile(userId: string, userName: string): void {
    const id: string = typeof userId === 'string' ? userId.trim() : '';
    const name: string = typeof userName === 'string' ? userName.trim() : '';
    if (id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_profile_unavailable') });
      return;
    }
    this.onOpenUserProfile(id, name);
  }

  /** 正文里的 #话题#：切到搜索页并发起检索，而不是把用户丢到浏览器。 */
  private openTopic(topic: string): void {
    const keyword: string = typeof topic === 'string' ? topic.trim() : '';
    if (keyword.length === 0) {
      return;
    }
    this.onOpenTopic(keyword);
  }

  /** 正文里的网页链接：交给系统浏览器（见 common/ExternalLink）。 */
  /** `label` = 锚点展示文字：导航层用它补判「查看图片」这类没有图床地址的文字链接。 */
  private openLink(url: string, label: string = ''): void {
    openWeiboLink(this.getUIContext(), this.weiboNavStack, url, label);
  }

  private openImagePreview(urls: string[], index: number): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ImagePreview',
      params: { urls: urls, index: index }
    }).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '原图预览打开失败，请稍后重试' });
    });
  }

  private onShare(data: ThreadSharePayload): void {
    const url: string = `https://m.weibo.cn/detail/${data.tid}`;
    const abstract: string = data.abstract.length > 0 ? data.abstract : data.title;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareUtil.shareLink(this.getUIContext(), context, url, data.author, abstract);
  }

  private async toggleLike(post: WeiboPost, liked: boolean): Promise<void> {
    try {
      await WeiboService.getInstance().setLike(post.id, liked);
      // 点赞状态经 PostEntities 广播（postTick），onPostEntitiesChanged 负责套回列表
      this.getUIContext().getPromptAction().showToast({
        message: liked ? $r('app.string.weibo_like_success') : $r('app.string.weibo_unlike_success')
      });
    } catch (error) {
      const message: string = (error as Error).message ?? '微博操作失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  @Builder
  Header() {
    Column({ space: Spacing.sm }) {
      Row({ space: Spacing.md }) {
        Column({ space: 2 }) {
          Text(this.mode === WeiboTimelineMode.Recommend ? $r('app.string.weibo_recommend_title') : $r('app.string.weibo_following_title'))
            .fontSize(fs(20, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(this.mode === WeiboTimelineMode.Recommend ? $r('app.string.weibo_recommend_hint') : $r('app.string.weibo_following_hint'))
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button(this.feed.hasPendingUpdate ? '有更新' : '刷新')
          .height(36)
          .fontSize(fs(13, this.fontScale))
          .backgroundColor(Theme.manualGlass(this.isDark, true))
          .fontColor(Color.White)
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.accent())
          .systemMaterial(ImmMaterial.accent(this.isDark))
          .borderRadius(Radius.full)
          .onClick(() => {
            if (this.feed.hasPendingUpdate) { this.feed.acceptPendingUpdate(); }
            else { this.loadFirstPage(true); }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 52, left: Spacing.lg, right: Spacing.lg, bottom: Spacing.md })
    .backgroundColor(Theme.bg(this.isDark))
  }

  @Builder
  PostCard(post: WeiboPost): void {
    ThreadCard({
      item: this.toThreadCard(post),
      onTap: (_id: string): void => { this.openPost(post); },
      onComment: (_id: string): void => { this.openPost(post); },
      onLike: (_id: string, _postId: string, liked: boolean): void => { this.toggleLike(post, liked); },
      onShare: (data: ThreadSharePayload): void => { this.onShare(data); },
      onAvatarTap: (id: string, name: string): void => { this.openUserProfile(id, name); },
      // 正文/转发里的 @用户名、#话题#、网页链接：各自走自己的跳转，不落到整卡详情
      onMentionTap: (uid: string, name: string): void => { this.openUserProfile(uid, name); },
      onTopicTap: (topic: string): void => { this.openTopic(topic); },
      onLinkTap: (url: string, label: string): void => { this.openLink(url, label); },
      onImageTap: (urls: string[], index: number): void => {
        // 以卡片传入的列表为准：正文走高清档，转发原文走转发自己的图，
        // 卡片已在 ThreadItemData.previewImages / repostPreviewImages 里分好。
        this.openImagePreview(urls.length > 0 ? urls : (post.previewPictures ?? post.pictures), index);
      },
      skipImageCache: true
    })
  }

  /**
   * 无缝加载的状态位：分页由滚到底自动触发，这里只在请求中或已到末页时占位，
   * 其余时刻不占高度，避免打断滚动手感。
   */
  @Builder
  TimelineFooter(): void {
    if (this.feed.loadingMore) {
      Row({ space: Spacing.sm }) {
        LoadingProgress().width(18).height(18)
        Text($r('app.string.weibo_loading'))
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .width('100%')
      .height(48)
      .justifyContent(FlexAlign.Center)
    } else if (this.feed.needsRefresh) {
      Button('刷新信息流')
        .enabled(!this.feed.refreshing)
        .onClick((): void => {
          if (this.feed.hasPendingUpdate) { this.feed.acceptPendingUpdate(); }
          else { this.loadFirstPage(true); }
        }, 8)
        .margin({ top: 8, bottom: 8 })
    } else if (!this.feed.hasMore) {
      Text($r('app.string.weibo_timeline_no_more'))
        .width('100%')
        .height(48)
        .textAlign(TextAlign.Center)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    } else {
      Button(this.feed.errorMessage.length > 0 ? '重试' : '继续加载')
        .onClick((): void => { this.loadMore(); }, 8)
        .margin({ top: 8, bottom: 8 })
    }
  }

  @Builder
  WaterfallTimeline(): void {
    WaterFlow() {
      LazyForEach(this.timelineDataSource, (post: WeiboPost): void => {
        FlowItem() {
          this.PostCard(post)
        }
        .width('100%')
        .onAreaChange((_oldValue: Area, newValue: Area): void => { this.onCardAreaChange(post, newValue); })
      }, (post: WeiboPost): string => post.id)
    }
    .columnsTemplate(this.waterfallColumnsTemplate())
    .columnsGap(Spacing.md)
    .rowsGap(Spacing.md)
    .width('100%')
    .layoutDirection(FlexDirection.Column)
    .cachedCount(6)
  }

  @Builder
  Timeline() {
    // Idle 必须显式走骨架屏：FeedStore.state 初值是 Idle，而首帧发生在
    // `await WeiboAuthManager.init()` 之前，此时 `loadFirstPage` 还没跑。以前 Idle 没有分支、
    // 落到最后的兜底 else，于是冷启动会先闪一屏「没有内容」的空态——看起来就像提示语错了。
    if (this.feed.state === FeedLoadState.Idle || this.feed.state === FeedLoadState.Loading) {
      ThreadListSkeleton({ count: 4 })
        .margin({ top: Spacing.md })
    } else if (this.feed.state === FeedLoadState.Error) {
      ErrorView({ message: this.feed.errorMessage, onRetry: (): void => { this.loadFirstPage(true); } })
        .height('65%')
    } else if (this.feed.state === FeedLoadState.Empty) {
      EmptyView({
        message: this.mode === WeiboTimelineMode.Following
          ? $r('app.string.weibo_following_empty')
          : $r('app.string.weibo_recommend_empty'),
        icon: '○'
      })
        .height('65%')
    } else if (this.feed.state === FeedLoadState.Success) {
      Column({ space: Spacing.md }) {
        ForEach(this.feed.posts, (post: WeiboPost): void => {
          Column() {
            this.PostCard(post)
          }
          .width('100%')
          .onAreaChange((_oldValue: Area, newValue: Area): void => { this.onCardAreaChange(post, newValue); })
        }, (post: WeiboPost): string => post.id)
      }
      .width('100%')
    } else {
      // 理论上到不了；真到了也按「加载中」处理，不要谎报空态
      ThreadListSkeleton({ count: 4 })
        .margin({ top: Spacing.md })
    }
  }

  /** PaperTalk-style page scroll: Scroll owns the viewport; WaterFlow is a direct content block. */
  @Builder
  TimelineScroller() {
    // 下拉刷新看新内容：显式刷新保留当前卡片，新首页到达后原位替换
    Refresh({ refreshing: $$this.pullRefreshing }) {
      Scroll(this.timelineScroller) {
        Column() {
          if (this.feed.state === FeedLoadState.Success && this.waterfallColumns() > 1) {
            this.WaterfallTimeline()
          } else {
            this.Timeline()
          }
          if (this.feed.state === FeedLoadState.Success) {
            this.TimelineFooter()
          }
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: this.topInset, bottom: this.bottomInset })
        .onAreaChange((_oldValue: Area, newValue: Area): void => {
          this.timelineContentHeight = newValue.height as number;
        })
      }
      .layoutWeight(1)
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        this.scrollViewportY = newValue.globalPosition.y as number;
        this.scrollViewportHeight = newValue.height as number;
      })
      .onScrollStop((): void => {
        this.saveReadingPosition();
      })
      .onReachEnd((): void => {
        // 单列与多列统一走自动续页；重复触发由 FeedStore 的 loadingMore/hasMore 守卫吸收
        if (this.feed.state === FeedLoadState.Success) {
          this.loadMore();
        }
      })
    }
    .onRefreshing((): void => { this.loadFirstPage(true); })
    .pullToRefresh(true)
    .refreshOffset(64)
    .layoutWeight(1)
    .width('100%')
    .height('100%')
  }

  /** Same alpha-mask used by TiebaPura's HomeTab: content fades when it enters the floating title area. */
  private topFadeStop(): number {
    if (this.viewportWidth < 840 || this.viewportHeight <= 0) {
      return 0.15;
    }
    return Math.min(0.15, 108 / this.viewportHeight);
  }

  @Builder
  TopFadeOverlay() {
    Stack()
      .height('100%')
      .width('100%')
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['#00FFFFFF', 0.0], ['#FFFFFFFF', this.topFadeStop()], ['#FFFFFFFF', 1.0]]
      })
      .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Column() {
      if (this.showHeader) {
        this.Header()
      }
      Stack({ alignContent: Alignment.Top }) {
        this.TimelineScroller()

      }.width('100%').layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.viewportWidth = newValue.width as number;
      this.viewportHeight = newValue.height as number;
      this.syncCardColumns();
    })
    .overlay(this.showHeader ? undefined : this.TopFadeOverlay())
    .blendMode(this.showHeader ? BlendMode.SRC_OVER : BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
    .translate({ x: this.pageTranslateX })
    .opacity(this.pageOpacity)
  }
}
