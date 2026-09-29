import { PostEntities } from '../store/PostEntities';
import { ThreadCard, ThreadItemData, EmptyView, ErrorView, LoadingView } from '../components/CommonComponents';
import { curves } from '@kit.ArkUI';
import { WeiboPost, WeiboSuggestion } from '../model/WeiboModel';
import { SearchStore, SearchLoadState } from '../store/SearchStore';
import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { buildWeiboThreadItem } from '../common/WeiboCardItems';
import { requestTopicSearch } from '../common/TopicRequest';
import { openExternalUrl } from '../common/ExternalLink';

type TabAnimationDirection = 'left' | 'right';

/** Weibo search with live suggestions and posts from the mobile search container. */
@Component
export struct WeiboSearch {
  pageScroller: Scroller = new Scroller();
  @Prop topInset: number = 64;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  onOpenPost: (post: WeiboPost) => void = () => {};
  onOpenUserProfile: (userId: string, userName: string) => void = () => {};
  @StorageLink('weiboPostTick') @Watch('onPostEntitiesChanged') postTick: number = 0;
  private onPostEntitiesChanged(): void { this.store.posts = this.store.posts.map((post: WeiboPost): WeiboPost => PostEntities.shared().apply(post)); }
  @State isDark: boolean = isDarkMode();
  @StorageLink('weiboSearchQuery') keyword: string = '';
  @StorageLink('weiboSearchRequestTick') @Watch('onSearchRequested') searchRequestTick: number = 0;
  @State store: SearchStore = new SearchStore();
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  private onDarkTick(): void {
    this.isDark = isDarkMode();
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

  @StorageLink('weiboAuthTick') @Watch('onSessionChanged') authTick: number = 0;
  private onSessionChanged(): void { this.store.clear(); }
  aboutToDisappear(): void { this.store.cancel(); }
  private onSearchRequested(): void { this.search(); }
  private async search(): Promise<void> { await this.store.search(this.keyword); }

/** 卡片映射统一走 common/WeiboCardItems：正文富文本、转发引述块、发帖设备
 *  这三处口径必须与首页/用户主页完全一致。 */
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

  /** 正文/评论里的 #话题#：本页在信息流根内容里，同样借 AppStorage 信号交给宿主导航页。 */
  private openTopic(topic: string): void {
    requestTopicSearch(topic);
  }

  /** 正文里的网页链接：交给系统浏览器（见 common/ExternalLink）。 */
  private openLink(url: string): void {
    openExternalUrl(this.getUIContext(), url);
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

  @Builder
  SuggestionRow(item: WeiboSuggestion) {
    Row({ space: Spacing.sm }) {
      SymbolGlyph(item.isHot ? $r('sys.symbol.flame_fill') : $r('sys.symbol.magnifyingglass'))
        .fontSize(fs(18, this.fontScale))
        .fontColor([item.isHot ? Theme.brand() : Theme.textSecondary(this.isDark)])
      Text(item.word)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${item.count}`)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
    }
    .width('100%')
    .height(52)
    .padding({ left: Spacing.lg, right: Spacing.lg })
    .backgroundColor(Theme.sheetGlass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
    .border({ width: 0.5, color: Theme.manualGlassBorder() })
    .shadow(Theme.glassShadowStyle())
    .systemMaterial(ImmMaterial.rowItem())
    .borderRadius(Radius.lg)
    .onClick((): void => {
      this.keyword = item.word;
      this.search();
    })
  }

  build() {
    Scroll(this.pageScroller) {
      Column({ space: Spacing.md }) {
        if (this.store.state === SearchLoadState.Loading) {
          LoadingView({ message: $r('app.string.weibo_loading') })
            .height(360)
        } else if (this.store.state === SearchLoadState.Error) {
          ErrorView({ message: this.store.errorMessage, onRetry: (): void => { this.search(); } })
            .height(360)
        } else if (this.store.state === SearchLoadState.Success && this.store.posts.length === 0 && this.store.suggestions.length === 0) {
          EmptyView({ message: $r('app.string.weibo_search_empty'), icon: '⌕' })
            .height(360)
        } else if (this.store.state === SearchLoadState.Success) {
          Column({ space: Spacing.sm }) {
            ForEach(this.store.posts, (post: WeiboPost): void => {
              ThreadCard({
                item: this.toThreadCard(post),
                onTap: (_id: string): void => { this.openPost(post); },
                onComment: (_id: string): void => { this.openPost(post); },
                onAvatarTap: (id: string, name: string): void => { this.openUserProfile(id, name); },
                // 正文里的 @用户名/#话题#/网页链接：各自走自己的跳转，不落到整卡详情
                onMentionTap: (uid: string, name: string): void => { this.openUserProfile(uid, name); },
                onTopicTap: (topic: string): void => { this.openTopic(topic); },
                onLinkTap: (url: string): void => { this.openLink(url); },
                onImageTap: (urls: string[], index: number): void => {
                  // 以卡片传入的列表为准（正文高清档 / 转发原文自己的图）
                  this.openImagePreview(urls.length > 0 ? urls : (post.previewPictures ?? post.pictures), index);
                },
                skipImageCache: true,
              })
            }, (post: WeiboPost): string => post.id)
            if (this.store.errorMessage.length > 0) {
              Text(this.store.errorMessage).fontColor(Theme.textSecondary(this.isDark))
            }
            if (this.store.nextCursor !== null) {
              Button(this.store.loadingMore ? '正在加载' : '加载更多微博')
                .enabled(!this.store.loadingMore)
                .onClick((): void => { this.store.loadMore(); })
            }
            ForEach(this.store.suggestions, (item: WeiboSuggestion): void => {
              this.SuggestionRow(item)
            }, (item: WeiboSuggestion): string => item.word)
          }
          .width('100%')
        } else {
          EmptyView({ message: $r('app.string.weibo_search_empty'), icon: '⌕' })
            .height(360)
        }
      }
      .width('100%')
      .padding({ top: this.topInset, left: Spacing.lg, right: Spacing.lg, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.bg(this.isDark))
    .translate({ x: this.pageTranslateX })
    .opacity(this.pageOpacity)
  }
}
