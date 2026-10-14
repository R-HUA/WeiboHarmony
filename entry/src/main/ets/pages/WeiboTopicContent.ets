import { WeiboPost } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { SearchStore, SearchLoadState } from '../store/SearchStore';
import { PostEntities } from '../store/PostEntities';
import { ThreadCard, EmptyView, ErrorView, LoadingView } from '../components/CommonComponents';
import { buildWeiboThreadItem } from '../common/WeiboCardItems';
import { setWeiboPostLike, shareWeiboPost } from '../common/WeiboPostActions';
import { openWeiboLink } from '../common/WeiboLinkNavigation';
import { requestTopicSearch } from '../common/TopicRequest';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';
import { ACTIVE_FEED_VIDEO_KEY } from '../common/Constants';
import { ImmMaterial, Theme, Spacing, Radius, fs, isDarkMode } from '../common/Theme';
import { DividerShowType, HdsNavDestination, HdsNavDestinationTitleMode, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { WeiboUserProfileRouteParam } from './WeiboUserProfile';

/** 标题保留榜单名称，查询词保留上游话题标记。 */
export interface WeiboTopicContentRouteParam {
  title: string;
  query: string;
}

@Builder
export function WeiboTopicContentBuilder(): void { WeiboTopicContent() }

/** 热搜内容拥有独立查询与滚动状态，返回时不重建榜单。 */
@Component
export struct WeiboTopicContent {
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  @State private title: string = '';
  @State private query: string = '';
  @State private store: SearchStore = new SearchStore();
  @State private isDark: boolean = isDarkMode();
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('fontScale') fontScale: number = 1;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onSessionChanged') authTick: number = 0;
  @StorageLink('weiboPostTick') @Watch('onPostChanged') postTick: number = 0;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params: WeiboTopicContentRouteParam[] = this.weiboNavStack.getParamByName('WeiboTopicContent') as WeiboTopicContentRouteParam[];
    const target: WeiboTopicContentRouteParam | undefined = params[params.length - 1];
    if (target === undefined || !target.query.trim()) {
      this.store.errorMessage = this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.weibo_hot_target_invalid').id);
      this.store.state = SearchLoadState.Error;
      return;
    }
    this.title = target.title;
    this.query = target.query;
    this.search();
  }

  aboutToDisappear(): void { this.store.cancel(); }
  private onDarkTick(): void { this.isDark = isDarkMode(); }
  private onSessionChanged(): void { this.store.clear(); if (this.query) { this.search(); } }
  private onPostChanged(): void { this.store.posts = this.store.posts.map((post: WeiboPost): WeiboPost => PostEntities.shared().apply(post)); }
  private search(): void { this.store.search(this.query, false); }
  private popRoute(): void { this.weiboNavStack.pop(); syncWeiboSplitNavigation(this.weiboNavStack); }

  private openPost(post: WeiboPost, startAtComments: boolean = false): void {
    WeiboService.getInstance().rememberPost(post);
    WeiboService.getInstance().prefetchComments(post);
    const param: WeiboPostDetailRouteParam = { postId: post.id, startAtComments: startAtComments };
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  private openUser(userId: string, userName: string): void {
    const param: WeiboUserProfileRouteParam = { userId: userId, userName: userName };
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  private openImage(urls: string[], index: number): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ImagePreview', params: { urls: urls, index: index } })
      .catch((): void => { this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_image_open_failed') }); });
  }

  @Builder
  TitleBar() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(fs(28, this.fontScale)).fontColor([$r('sys.color.icon_primary')])
      }
      .width(44).height(44).backgroundColor(Color.Transparent).systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full).accessibilityText($r('app.string.weibo_back'))
      .onClick((): void => { this.popRoute(); })
      Text(this.title).layoutWeight(1).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark)).textAlign(TextAlign.Center).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank().width(44)
    }
    .width('100%').height(64).padding({ left: Spacing.lg, right: Spacing.lg })
  }

  @Builder
  Content() {
    Scroll(this.scroller) {
      Column({ space: Spacing.md }) {
        if (this.store.state === SearchLoadState.Loading) {
          LoadingView({ message: $r('app.string.weibo_loading') }).height(360)
        } else if (this.store.state === SearchLoadState.Error) {
          ErrorView({ message: this.store.errorMessage, onRetry: (): void => { this.search(); } }).height(360)
        } else if (this.store.state === SearchLoadState.Success && this.store.posts.length === 0) {
          EmptyView({ message: $r('app.string.weibo_search_empty'), icon: '⌕' }).height(360)
        } else if (this.store.state === SearchLoadState.Success) {
          ForEach(this.store.posts, (post: WeiboPost): void => {
            ThreadCard({
              item: buildWeiboThreadItem(post),
              onTap: (_id: string): void => { this.openPost(post); },
              onRepostTap: (_id: string): void => { this.openPost(post.repost!); },
              onComment: (_id: string): void => { this.openPost(post, true); },
              onLike: (_id: string, _postId: string, liked: boolean): void => { setWeiboPostLike(this.getUIContext(), post, liked); },
              onShare: (): void => { shareWeiboPost(this.getUIContext(), post); },
              onAvatarTap: (id: string, name: string): void => { this.openUser(id, name); },
              onMentionTap: (id: string, name: string): void => { this.openUser(id, name); },
              onTopicTap: (topic: string): void => { requestTopicSearch(topic); },
              onLinkTap: (url: string, label: string): void => { openWeiboLink(this.getUIContext(), this.weiboNavStack, url, label); },
              onImageTap: (urls: string[], index: number): void => { this.openImage(urls.length > 0 ? urls : (post.previewPictures ?? post.pictures), index); },
              skipImageCache: true,
            })
          }, (post: WeiboPost): string => post.id)
          if (this.store.errorMessage.length > 0) {
            Text(this.store.errorMessage).fontColor(Theme.danger()).fontSize(fs(13, this.fontScale))
          }
          if (this.store.nextCursor !== null) {
            Button(this.store.loadingMore ? $r('app.string.weibo_loading') : $r('app.string.weibo_more_posts'))
              .enabled(!this.store.loadingMore)
              .onClick((): void => { this.store.loadMore(); })
          }
        }
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 64, left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl })
    }
    .width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  build() {
    HdsNavDestination() { this.Content() }
      .onHidden((): void => { AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, ''); })
      .titleMode(HdsNavDestinationTitleMode.MINI).hideBackButton(true)
      .onBackPressed((): boolean => { this.popRoute(); return true; })
      .bindToScrollable([this.scroller])
      .titleBar({
        avoidLayoutSafeArea: true,
        content: { stackBuilder: (): void => this.TitleBar(), divider: { showType: DividerShowType.OFF } },
        style: {
          scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
          systemMaterialEffect: { materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.EXQUISITE },
        },
      })
      .width('100%').height('100%').backgroundColor(Theme.bg(this.isDark))
  }
}
