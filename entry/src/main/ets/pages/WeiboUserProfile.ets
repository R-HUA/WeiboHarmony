import { ACTIVE_FEED_VIDEO_KEY } from '../common/Constants';
import { PostEntities } from '../store/PostEntities';
import { WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { ThreadCard, ThreadItemData } from '../components/CommonComponents';
import { ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { DividerShowType, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';
import { buildWeiboThreadItem } from '../common/WeiboCardItems';
import { requestTopicSearch } from '../common/TopicRequest';
import { openWeiboLink } from '../common/WeiboLinkNavigation';
import { setWeiboPostLike, shareWeiboPost } from '../common/WeiboPostActions';

/** Explicit route input so profile navigation never depends on a card's transient state. */
export interface WeiboUserProfileRouteParam {
  userId: string;
  userName: string;
}

@Builder
export function WeiboUserProfileBuilder(): void {
  WeiboUserProfile()
}

/** Public profile and recent posts for the author selected from a timeline card. */
@Component
export struct WeiboUserProfile {
  @StorageLink('weiboPostTick') @Watch('onPostEntitiesChanged') postTick: number = 0;
  private onPostEntitiesChanged(): void { this.posts = this.posts.map((post: WeiboPost): WeiboPost => PostEntities.shared().apply(post)); }
  @State isDark: boolean = isDarkMode();
  @State userId: string = '';
  @State fallbackName: string = '';
  @State profile: WeiboUser | null = null;
  @State posts: WeiboPost[] = [];
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State timelineError: string = '';
  @State followBusy: boolean = false;
  @State following: boolean = false;
  @State relationshipKnown: boolean = false;
  @StorageLink('weiboAuthTick') @Watch('onAuthChanged') authTick: number = 0;
  @StorageLink('weiboRelationshipTick') @Watch('syncRelationship') relationshipTick: number = 0;
  private revision: number = 0;
  private alive: boolean = false;
  private routeTimer: number = -1;
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** Actual system top inset, populated by EntryAbility for each window. */
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  private profileScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.alive = true;
    this.routeTimer = setTimeout((): void => { this.loadRouteProfile(); }, 50);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.revision++;
    if (this.routeTimer >= 0) { clearTimeout(this.routeTimer); }
  }

  private onAuthChanged(): void {
    this.revision++;
    this.profile = null;
    this.posts = [];
    this.followBusy = false;
    this.relationshipKnown = false;
    this.following = false;
    if (this.alive && this.userId.length > 0) { this.loadProfile(); }
  }

  private isCurrent(revision: number, generation: number): boolean {
    return this.alive && revision === this.revision && generation === WeiboAuthManager.getInstance().getGeneration();
  }

  private syncRelationship(): void {
    const value: boolean | undefined = WeiboService.getInstance().getFollowing(this.userId);
    this.relationshipKnown = value !== undefined;
    this.following = value === true;
  }

  private followLabel(): string {
    if (this.followBusy) { return '处理中…'; }
    if (!WeiboAuthManager.getInstance().hasCookie()) { return '登录后关注'; }
    if (!this.relationshipKnown) { return '刷新关注状态'; }
    return this.following ? '取消关注' : '关注';
  }

  private async changeFollowing(): Promise<void> {
    if (this.followBusy || this.profile === null) { return; }
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboLogin' }).catch((): void => {
        this.getUIContext().getPromptAction().showToast({ message: '登录页面打开失败' });
      });
      return;
    }
    const revision: number = this.revision;
    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    this.followBusy = true;
    try {
      const service: WeiboService = WeiboService.getInstance();
      if (!this.relationshipKnown) {
        await service.fetchUserProfile(this.userId);
      } else {
        await service.setFollowing(this.userId, !this.following);
      }
      if (!this.isCurrent(revision, generation)) { return; }
      this.syncRelationship();
      if (!this.relationshipKnown) {
        this.getUIContext().getPromptAction().showToast({ message: '暂未获取到关注状态，请稍后重试' });
      }
    } catch (error) {
      if (!this.isCurrent(revision, generation)) { return; }
      this.syncRelationship();
      this.getUIContext().getPromptAction().showToast({ message: (error as Error).message ?? '关注操作失败' });
    } finally {
      if (this.isCurrent(revision, generation)) { this.followBusy = false; }
    }
  }

  private async loadRouteProfile(): Promise<void> {
    const params: WeiboUserProfileRouteParam[] =
      this.weiboNavStack.getParamByName('WeiboUserProfile') as WeiboUserProfileRouteParam[];
    if (params === undefined || params === null || params.length === 0) {
      this.loading = false;
      this.errorMessage = '用户资料参数不完整';
      return;
    }
    const routeParam: WeiboUserProfileRouteParam = params[params.length - 1];
    this.userId = typeof routeParam.userId === 'string' ? routeParam.userId.trim() : '';
    this.fallbackName = typeof routeParam.userName === 'string' ? routeParam.userName.trim() : '';
    if (this.userId.length === 0) {
      this.loading = false;
      this.errorMessage = '该用户资料暂不可用';
      return;
    }
    await this.loadProfile();
  }

  private async loadProfile(): Promise<void> {
    if (this.userId.length === 0) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    this.timelineError = '';
    const revision: number = ++this.revision;
    const generation: number = WeiboAuthManager.getInstance().getGeneration();
    try {
      const service: WeiboService = WeiboService.getInstance();
      const profile: WeiboUser = await service.fetchUserProfile(this.userId);
      if (!this.isCurrent(revision, generation)) { return; }
      this.profile = profile;
      this.syncRelationship();
      try {
        const posts: WeiboPost[] = await service.fetchUserTimeline(this.userId, 1);
        if (!this.isCurrent(revision, generation)) { return; }
        this.posts = posts;
      } catch (error) {
        if (!this.isCurrent(revision, generation)) { return; }
        this.timelineError = (error as Error).message ?? '微博加载失败';
      }
    } catch (error) {
      if (!this.isCurrent(revision, generation)) { return; }
      this.profile = null;
      this.posts = [];
      this.errorMessage = (error as Error).message ?? '用户资料加载失败，请稍后重试';
    } finally {
      if (this.isCurrent(revision, generation)) { this.loading = false; }
    }
  }

/** 卡片映射统一走 common/WeiboCardItems：正文富文本、转发引述块、发帖设备
 *  这三处口径必须与首页/搜索页完全一致。 */
  private toThreadCard(post: WeiboPost): ThreadItemData {
    return buildWeiboThreadItem(post);
  }

  /** 正文里的 @用户名：本页就在导航栈里，直接再压一层用户主页即可。 */
  private openMention(uid: string, name: string): void {
    const userId: string = typeof uid === 'string' ? uid.trim() : '';
    if (userId.length === 0) {
      return;
    }
    const param: WeiboUserProfileRouteParam = { userId: userId, userName: name.trim() };
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  /** #话题#：借 AppStorage 信号请宿主导航页清栈切到搜索页。 */
  private openTopic(topic: string): void {
    requestTopicSearch(topic);
  }

  /** 正文里的网页链接：交给系统浏览器（见 common/ExternalLink）。 */
  private openLink(url: string): void {
    openWeiboLink(this.getUIContext(), this.weiboNavStack, url);
  }

  private openPost(post: WeiboPost): void {
    if (post.id.length === 0) {
      return;
    }
    WeiboService.getInstance().rememberPost(post);
    const param: WeiboPostDetailRouteParam = { postId: post.id };
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private popRoute(): void {
    this.weiboNavStack.pop();
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  private openImagePreview(urls: string[], index: number): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ImagePreview', params: { urls: urls, index: index } });
  }

  @Builder
  ProfileHeader(currentProfile: WeiboUser) {
    Column({ space: Spacing.md }) {
      if (currentProfile.coverUrl.length > 0) {
        Image(currentProfile.coverUrl)
          .width('100%')
          .height(132)
          .objectFit(ImageFit.Cover)
          .borderRadius(Radius.postCard)
      } else {
        Stack() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(fs(36, this.fontScale))
            .fontColor([$r('sys.color.icon_emphasize')])
        }
        .width('100%')
        .height(100)
        .backgroundColor(Theme.brandBg(this.isDark))
        .borderRadius(Radius.postCard)
        .alignContent(Alignment.Center)
      }
      Row({ space: Spacing.md }) {
        if (currentProfile.avatarUrl.length > 0) {
          Image(currentProfile.avatarUrl)
            .width(72)
            .height(72)
            .borderRadius(Radius.full)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text(currentProfile.screenName.length > 0 ? currentProfile.screenName.substring(0, 1) : '微')
              .fontSize(fs(26, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width(72)
          .height(72)
          .backgroundColor(Theme.brand())
          .borderRadius(Radius.full)
          .alignContent(Alignment.Center)
        }
        Column({ space: 4 }) {
          Text(currentProfile.screenName.length > 0 ? currentProfile.screenName : this.fallbackName)
            .fontSize(fs(20, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          if (currentProfile.verified && currentProfile.verifiedReason.length > 0) {
            Text(currentProfile.verifiedReason)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.brand())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(`@${currentProfile.id}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      if (currentProfile.id !== WeiboAuthManager.getInstance().getAccountId()) {
        Button(this.followLabel())
          .width('100%')
          .fontSize(fs(14, this.fontScale))
          .fontColor(this.following ? Theme.textPrimary(this.isDark) : Color.White)
          .backgroundColor(this.following ? Theme.bgSurface(this.isDark) : Theme.brand())
          .enabled(!this.followBusy)
          .onClick((): void => { this.changeFollowing(); }, 8)
      }
      if (currentProfile.description.length > 0) {
        Text(currentProfile.description)
          .fontSize(fs(14, this.fontScale))
          .lineHeight(fs(21, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .width('100%')
      }
      Row() {
        Text(`关注 ${currentProfile.followingCount}`)
          .layoutWeight(1)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
        Text(`${currentProfile.followersCount} 粉丝`)
          .layoutWeight(1)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .textAlign(TextAlign.Center)
        Text(`${currentProfile.statusesCount} 微博`)
          .layoutWeight(1)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .textAlign(TextAlign.End)
      }
      .width('100%')
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
  }

  @Builder
  ProfileContent() {
    Scroll(this.profileScroller) {
      Column({ space: Spacing.md }) {
        if (this.loading) {
          LoadingProgress().width(28).height(28).margin({ top: 120 })
        } else if (this.errorMessage.length > 0) {
          Column({ space: Spacing.md }) {
            Text(this.errorMessage)
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.danger())
              .textAlign(TextAlign.Center)
            Button($r('app.string.weibo_load'))
              .fontSize(fs(14, this.fontScale))
              .onClick((): void => { this.loadProfile(); })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 120 })
        } else if (this.profile !== null) {
          this.ProfileHeader(this.profile)
          Text($r('app.string.weibo_profile_posts'))
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .width('100%')
          if (this.timelineError.length > 0) {
            Text(this.timelineError).fontColor(Theme.danger()).width('100%')
            Button('重试加载微博').onClick((): void => { this.loadProfile(); })
          } else if (this.posts.length === 0) {
            Text($r('app.string.weibo_profile_no_posts'))
              .width('100%')
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .textAlign(TextAlign.Center)
              .padding({ top: Spacing.xl, bottom: Spacing.xl })
          } else {
            ForEach(this.posts, (post: WeiboPost): void => {
              ThreadCard({
                item: this.toThreadCard(post),
                onTap: (_id: string): void => { this.openPost(post); },
                onComment: (_id: string): void => { this.openPost(post); },
                onLike: (_id: string, _postId: string, liked: boolean): void => { setWeiboPostLike(this.getUIContext(), post, liked); },
                onShare: (): void => { shareWeiboPost(this.getUIContext(), post); },
                onAvatarTap: (id: string, name: string): void => { this.openMention(id, name); },
                // 正文里的 @用户名/#话题#/网页链接：各自走自己的跳转，不落到整卡详情
                onMentionTap: (uid: string, name: string): void => { this.openMention(uid, name); },
                onTopicTap: (topic: string): void => { this.openTopic(topic); },
                onLinkTap: (url: string): void => { this.openLink(url); },
                onImageTap: (urls: string[], index: number): void => {
                  // 以卡片传入的列表为准（正文高清档 / 转发原文自己的图）
                  this.openImagePreview(urls.length > 0 ? urls : (post.previewPictures ?? post.pictures), index);
                },
                skipImageCache: true
              })
            }, (post: WeiboPost): string => post.id)
          }
        }
      }
      .width('100%')
      .padding({
        left: Spacing.lg,
        right: Spacing.lg,
        top: this.statusBarHeight + 64,
        bottom: Spacing.xl
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  ProfileTitleBar() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(fs(28, this.fontScale))
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .accessibilityText($r('app.string.weibo_back'))
      .onClick((): void => { this.popRoute(); })
      Text($r('app.string.weibo_profile_title'))
        .layoutWeight(1)
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .textAlign(TextAlign.Center)
      Blank().width(44)
    }
    .width('100%')
    .height(64)
    .padding({ left: Spacing.lg, right: Spacing.lg })
  }

  build() {
    HdsNavDestination() {
      this.ProfileContent()
    }
    .onHidden((): void => { AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, ''); })
    .onShown((): void => { this.syncRelationship(); })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(true)
    .onBackPressed((): boolean => {
      this.popRoute();
      return true;
    })
    .bindToScrollable([this.profileScroller])
    .titleBar({
      avoidLayoutSafeArea: true,
      content: {
        stackBuilder: (): void => this.ProfileTitleBar(),
        divider: { showType: DividerShowType.OFF }
      },
      style: {
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
  }
}
