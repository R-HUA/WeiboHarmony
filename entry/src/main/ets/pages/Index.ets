import { ACTIVE_FEED_VIDEO_KEY } from '../common/Constants';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { curves, LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  HdsTabsModifier,
  hdsMaterial,
  BottomBuilderShowType,
  DividerShowType,
  ScrollEffectType,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { CacheManager } from '../cache/CacheManager';
import { ImmBlur, ImmMaterial, MaterialManager, Radius, Spacing, Theme, fs, initDarkMode, isDarkMode } from '../common/Theme';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { AppSettingsStore, DEFAULT_HIDE_UNSUPPORTED, DEFAULT_HOME_TAB_MATERIAL_LEVEL } from '../service/AppSettingsStore';
import { WeiboService } from '../service/WeiboService';
import { WeiboPost, WeiboUser, WeiboHotTopic } from '../model/WeiboModel';
import { WeiboTopicContentBuilder, WeiboTopicContentRouteParam } from './WeiboTopicContent';
import { WeiboHomeTab, WeiboTimelineMode } from './WeiboHomeTab';
import { WeiboPostDetailBuilder, WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { WeiboUserProfileBuilder, WeiboUserProfileRouteParam } from './WeiboUserProfile';
import { WeiboHotSearch } from './WeiboHotSearch';
import { WeiboSearch } from './WeiboSearch';
import { WeiboVisitorBootstrap } from '../components/WeiboVisitorBootstrap';
import {
  syncWeiboSplitNavigation,
  WEIBO_BREAKPOINT_KEY,
  WEIBO_CONTENT_DESTINATION_OPEN_KEY,
  WeiboResponsiveLayout
} from '../common/WeiboNavigationLayout';
import { TOPIC_REQUEST_KEY } from '../common/Constants';
import { topicFromRequest } from '../common/TopicRequest';

const PRIVACY_KEY: string = 'weibopura_privacy_agreed_v1';
const HDS_TAB_BAR_HEIGHT: number = 56;
const HOME_TAB_DOUBLE_TAP_WINDOW_MS: number = 360;

/** Mirrors TiebaPura's five-slot root navigation; every slot is backed by Weibo data. */
enum WeiboTab {
  Home = 0,
  Discover = 1,
  Search = 2,
  Messages = 3,
  Mine = 4,
}

type TabAnimationDirection = 'left' | 'right';

@Entry
@Component
struct Index {
  @State selectedTab: number = WeiboTab.Home;
  @State page1Enter: number = 0;
  @State page1Exit: number = 0;
  @State page2Enter: number = 0;
  @State page2Exit: number = 0;
  @State page3Enter: number = 0;
  @State page3Exit: number = 0;
  @State @Watch('onMessagesEnter') page4Enter: number = 0;
  @State @Watch('onMessagesExit') page4Exit: number = 0;
  @State @Watch('onMineEnter') page5Enter: number = 0;
  @State @Watch('onMineExit') page5Exit: number = 0;
  @State messagesTranslateX: number = 0;
  @State messagesOpacity: number = 1;
  @State messagesAnimating: boolean = false;
  @State mineTranslateX: number = 0;
  @State mineOpacity: number = 1;
  @State mineAnimating: boolean = false;
  /**
   * 首页信息流分段：推荐 / 关注。
   * 初值给「推荐」只是保守兜底，真正的默认值由 applyDefaultHomeMode() 在首帧之前定下来
   * （登录态决定：有 Cookie 进关注，游客进推荐）。
   */
  @State recommendPending: boolean = false;
  @State followingPending: boolean = false;
  @State acceptHomeUpdateTrigger: number = 0;

  private selectHomeMode(mode: WeiboTimelineMode): void {
    AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, '');
    if (this.homeMode === mode) { this.acceptHomeUpdateTrigger++; }
    this.homeModeChosen = true;
    this.homeMode = mode;
  }

  @State homeMode: WeiboTimelineMode = WeiboTimelineMode.Recommend;
  /** 用户是否手动切过分段。切过之后启动逻辑不再覆盖，否则刚点完就被弹回去。 */
  private homeModeChosen: boolean = false;
  @State privacyReady: boolean = false;
  @State privacyAccepted: boolean = false;
  @State isDark: boolean = isDarkMode();
  @State weiboReady: boolean = false;
  @State cookieConfigured: boolean = false;
  @Provide('weiboNavStack') weiboNavStack: NavPathStack = new NavPathStack();
  /** The source/destination layout follows the live window width, like HarmonyX. */
  @StorageLink(WEIBO_BREAKPOINT_KEY) @Watch('onBreakpointChange')
  breakpoint: string = WeiboResponsiveLayout.BREAKPOINT_SM;
  @StorageLink(WEIBO_CONTENT_DESTINATION_OPEN_KEY) @Watch('onContentDestinationChange')
  contentDestinationOpen: boolean = false;
  @State mainNavigationMode: NavigationMode = NavigationMode.Stack;
  @State accountProfile: WeiboUser | null = null;
  @State accountLoading: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @StorageLink('appAccentColor') @Watch('onAccentChanged') accentColor: string = '#E6162D';
  @StorageLink('appAccentTick') @Watch('onAccentTick') appAccentTick: number = 0;
  @StorageLink('homeTabMaterialLevel') @Watch('onHomeTabMaterialChanged')
  homeTabMaterialLevel: number = DEFAULT_HOME_TAB_MATERIAL_LEVEL;
  /**
   * 当前版本尚未实现「消息」页签与「我的收藏 / 我的点赞」，默认隐藏。
   * 这是一个位置索引开关：先移除被隐藏的页签，再把逻辑页签映射到 HdsTabs 的位置。
   */
  @StorageLink('hideUnsupportedFeatures') @Watch('onHideUnsupportedChanged')
  hideUnsupported: boolean = DEFAULT_HIDE_UNSUPPORTED;
  @StorageLink('weiboSearchQuery') weiboSearchText: string = '';
  /** 栈内页面（详情页/用户主页）点 #话题# 时写入的检索请求，见 common/TopicRequest.ets。 */
  @StorageLink(TOPIC_REQUEST_KEY) @Watch('onTopicRequest') topicRequest: string = '';
  @State searchFocusScale: number = 1;
  @State searchFocusOpacity: number = 0.92;
  @StorageLink('weibo.top_rect_height') topRectHeight: number = 0;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @StorageLink('weibo.navigation_indicator_height') navigationIndicatorHeight: number = 0;
  private context: common.UIAbilityContext | null = null;
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  /** Changes the keyed home subtree so ArkUI destroys and recreates both feeds. */
  @State homeFeedRebuildVersion: number = 0;
  /** 递增一次即让当前可见的首页信息流平滑回到列表顶端。 */
  @State homeScrollTopTrigger: number = 0;
  private lastHomeTabTapAt: number = 0;
  @State hdsTabsModifier: HdsTabsModifier = new HdsTabsModifier();
  private discoverScroller: Scroller = new Scroller();
  private searchScroller: Scroller = new Scroller();
  private messagesScroller: Scroller = new Scroller();
  private mineScroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    syncWeiboSplitNavigation(this.weiboNavStack);
    this.updateNavigationMode();
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    MaterialManager.init();
    await AppSettingsStore.getInstance().init(this.context);
    AppStorage.setOrCreate<string>('weiboSearchQuery', '');
    AppStorage.setOrCreate<number>('weiboSearchRequestTick', 0);
    this.configureHdsTabs();
    this.bindBuiltInTabScrollers();
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.isDark = systemDark;
    initDarkMode(systemDark);
    const cache: CacheManager = CacheManager.getInstance();
    await cache.init(this.context);
    const accepted: boolean = (await cache.get(PRIVACY_KEY)) === '1';
    if (accepted) {
      // 先把账号态与默认信息流解析完，再放行首帧。
      // 否则首帧会落在「推荐」、几十毫秒后才跳到「关注」，用户能看见一次分段闪动。
      // 这一段仍在隐私门之下（privacyReady 未置位、privacyAccepted 未置位），不会多出可见空白。
      await this.initAfterPrivacyConsent();
    }
    this.privacyAccepted = accepted;
    this.privacyReady = true;
  }

  private async initAfterPrivacyConsent(): Promise<void> {
    if (this.context === null) {
      return;
    }
    await UsageHabitsManager.getInstance().init(this.context);
    const followSystem: boolean = UsageHabitsManager.getInstance().isFollowSystemDark();
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.isDark = followSystem ? systemDark : UsageHabitsManager.getInstance().isDarkModeManual();
    initDarkMode(this.isDark);
    await WeiboAuthManager.getInstance().init(this.context);
    AppStorage.setOrCreate<number>('weiboAuthTick', AppStorage.get<number>('weiboAuthTick') ?? 0);
    this.refreshWeiboAccount();
    this.weiboReady = true;
  }

  private async acceptPrivacy(): Promise<void> {
    await CacheManager.getInstance().put(PRIVACY_KEY, '1');
    // 同理：账号态解析完再放行，避免刚同意完就先闪一下「推荐」
    await this.initAfterPrivacyConsent();
    this.privacyAccepted = true;
  }

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  private onAccentChanged(): void {
    this.configureHdsTabs();
  }

  private onAccentTick(): void {
    this.configureHdsTabs();
  }

  private onBreakpointChange(): void {
    this.updateNavigationMode();
  }

  private onContentDestinationChange(): void {
    this.updateNavigationMode();
  }

  /** Keep the root content and its routed destination side by side only when both fit. */
  private updateNavigationMode(): void {
    this.mainNavigationMode = WeiboResponsiveLayout.isWide(this.breakpoint) && this.contentDestinationOpen
      ? NavigationMode.Split : NavigationMode.Stack;
  }

  /** HarmonyX routing order: prepare the root split before adding a child destination. */
  private openContentDestination(): void {
    AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, '');
    this.contentDestinationOpen = true;
    AppStorage.setOrCreate<boolean>(WEIBO_CONTENT_DESTINATION_OPEN_KEY, true);
    this.updateNavigationMode();
  }

  private openPostDetail(post: WeiboPost, startAtComments: boolean = false): void {
    WeiboService.getInstance().rememberPost(post);
    WeiboService.getInstance().prefetchComments(post);
    const param: WeiboPostDetailRouteParam = { postId: post.id, startAtComments: startAtComments };
    this.openContentDestination();
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private openUserProfile(userId: string, userName: string): void {
    const param: WeiboUserProfileRouteParam = { userId: userId, userName: userName };
    this.openContentDestination();
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
  }

  private openHotTopic(topic: WeiboHotTopic): void {
    const param: WeiboTopicContentRouteParam = { title: topic.word, query: topic.query };
    this.openContentDestination();
    this.weiboNavStack.pushPath({ name: 'WeiboTopicContent', param: param });
  }

  private onHomeTabMaterialChanged(): void {
    this.configureHdsTabs();
  }

  /**
   * 底部导航实际渲染的逻辑页签。隐藏未支持功能时去掉「消息」，
   * 因此 HdsTabs 的位置索引与 WeiboTab 不再一一对应，必须经过下面的双向映射。
   */
  private visibleTabs(): number[] {
    if (this.hideUnsupported) {
      return [WeiboTab.Home, WeiboTab.Discover, WeiboTab.Search, WeiboTab.Mine];
    }
    return [WeiboTab.Home, WeiboTab.Discover, WeiboTab.Search, WeiboTab.Messages, WeiboTab.Mine];
  }

  /** 逻辑页签 → HdsTabs 位置索引；已隐藏的页签回落到首页。 */
  private toTabIndex(tab: number): number {
    const index: number = this.visibleTabs().indexOf(tab);
    return index < 0 ? 0 : index;
  }

  /** HdsTabs 位置索引 → 逻辑页签。 */
  private fromTabIndex(index: number): number {
    const tabs: number[] = this.visibleTabs();
    return index >= 0 && index < tabs.length ? tabs[index] : WeiboTab.Home;
  }

  /**
   * 开关切换时要处理两件事：正在「消息」页签上时原地回首页（否则该页签已不存在，
   * 标题与内容会脱节），以及让 HdsTabs 按新的页签数量重排。
   */
  private onHideUnsupportedChanged(): void {
    if (this.hideUnsupported && this.selectedTab === WeiboTab.Messages) {
      this.selectedTab = WeiboTab.Home;
      this.hdsTabsController.changeIndex(this.toTabIndex(WeiboTab.Home));
    }
  }

  aboutToDisappear(): void {
    this.hdsTabsController.unbindScroller(this.discoverScroller);
    this.hdsTabsController.unbindScroller(this.searchScroller);
    this.hdsTabsController.unbindScroller(this.messagesScroller);
    this.hdsTabsController.unbindScroller(this.mineScroller);
  }

  private onWeiboAuthTick(): void {
    this.accountLoading = false; this.accountProfile = null;
    this.refreshWeiboAccount();
    if (this.selectedTab === WeiboTab.Mine) {
      this.loadAccountProfile();
    }
  }

  private refreshWeiboAccount(): void {
    this.cookieConfigured = WeiboAuthManager.getInstance().hasCookie();
    this.applyDefaultHomeMode();
  }

  /**
   * 冷启动/登录态变化后定默认信息流：**有账号 Cookie 就进「关注」**。
   *
   * 关注流是登录账号自己的时间线，官方客户端首屏也是它；但游客态没有 Cookie，
   * 关注流只会落到错误页（见 openFollowing 的登录校验），这时保持「推荐」。
   * 用户手动切过分段一律不覆盖。
   */
  private applyDefaultHomeMode(): void {
    if (this.homeModeChosen) {
      return;
    }
    this.homeMode = this.cookieConfigured ? WeiboTimelineMode.Following : WeiboTimelineMode.Recommend;
  }

  /** Loads the account represented by the saved Cookie; public feeds remain usable when it fails. */
  private async loadAccountProfile(): Promise<void> {
    if (!this.cookieConfigured || this.accountLoading) {
      if (!this.cookieConfigured) {
        this.accountProfile = null;
      }
      return;
    }
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    this.accountLoading = true;
    try {
      const account: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
      if (session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.accountProfile = account;
    } catch (error) {
      if (session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.accountProfile = null;
    } finally {
      if (session === WeiboAuthManager.getInstance().getGeneration()) { this.accountLoading = false; }
    }
  }

  /** Programmatic selection is shared by the title-bar search shortcut and HdsTabs. */
  onPageHide(): void { AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, ''); }

  private switchTab(index: number): void {
    if (index === this.selectedTab) {
      return;
    }
    AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, '');
    this.selectedTab = index;
    if (index === WeiboTab.Mine) {
      this.refreshWeiboAccount();
      this.loadAccountProfile();
    }
  }

  /** HdsTabs reports the current and destination indices before its content transition begins. */
  private onTabAnimationStart(currentIndex: number, targetIndex: number, _event: TabsAnimationEvent): void {
    if (currentIndex === targetIndex) {
      return;
    }
    const direction: TabAnimationDirection = targetIndex > currentIndex ? 'left' : 'right';
    AppStorage.setOrCreate<string>('animationDirection', direction);
    this.triggerExit(currentIndex);
    setTimeout((): void => {
      this.triggerEnter(targetIndex);
    }, 1);
  }

  private triggerEnter(index: number): void {
    if (index === WeiboTab.Home) {
      this.page1Enter++;
    } else if (index === WeiboTab.Discover) {
      this.page2Enter++;
    } else if (index === WeiboTab.Search) {
      this.page3Enter++;
    } else if (index === WeiboTab.Messages) {
      this.page4Enter++;
    } else if (index === WeiboTab.Mine) {
      this.page5Enter++;
    }
  }

  private triggerExit(index: number): void {
    if (index === WeiboTab.Home) {
      this.page1Exit++;
    } else if (index === WeiboTab.Discover) {
      this.page2Exit++;
    } else if (index === WeiboTab.Search) {
      this.page3Exit++;
    } else if (index === WeiboTab.Messages) {
      this.page4Exit++;
    } else if (index === WeiboTab.Mine) {
      this.page5Exit++;
    }
  }

  private animationDirection(): TabAnimationDirection {
    const storedDirection: string | undefined = AppStorage.get<string>('animationDirection');
    return storedDirection === 'right' ? 'right' : 'left';
  }

  private onMessagesEnter(): void {
    if (this.page4Enter > 0) {
      this.messagesAnimating = false;
      this.playMessagesEnterAnimation(this.animationDirection());
    }
  }

  private onMessagesExit(): void {
    if (this.page4Exit > 0) {
      this.playMessagesExitAnimation(this.animationDirection());
    }
  }

  private playMessagesExitAnimation(direction: TabAnimationDirection): void {
    if (this.messagesAnimating) {
      return;
    }
    this.messagesAnimating = true;
    const endX: number = direction === 'left' ? -350 : 350;
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: (): void => { this.messagesAnimating = false; }
    }, (): void => {
      this.messagesTranslateX = endX;
      this.messagesOpacity = 0;
    });
  }

  private playMessagesEnterAnimation(direction: TabAnimationDirection): void {
    if (this.messagesAnimating) {
      return;
    }
    this.messagesAnimating = true;
    const startX: number = direction === 'left' ? 350 : -350;
    this.messagesTranslateX = startX;
    this.messagesOpacity = 0;
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 300, curve: curves.springMotion() }, (): void => {
        this.messagesTranslateX = 0;
        this.messagesOpacity = 1;
      });
    }, 0);
    setTimeout((): void => { this.messagesAnimating = false; }, 600);
  }

  private onMineEnter(): void {
    if (this.page5Enter > 0) {
      this.mineAnimating = false;
      this.playMineEnterAnimation(this.animationDirection());
    }
  }

  private onMineExit(): void {
    if (this.page5Exit > 0) {
      this.playMineExitAnimation(this.animationDirection());
    }
  }

  private playMineExitAnimation(direction: TabAnimationDirection): void {
    if (this.mineAnimating) {
      return;
    }
    this.mineAnimating = true;
    const endX: number = direction === 'left' ? -350 : 350;
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: (): void => { this.mineAnimating = false; }
    }, (): void => {
      this.mineTranslateX = endX;
      this.mineOpacity = 0;
    });
  }

  private playMineEnterAnimation(direction: TabAnimationDirection): void {
    if (this.mineAnimating) {
      return;
    }
    this.mineAnimating = true;
    const startX: number = direction === 'left' ? 350 : -350;
    this.mineTranslateX = startX;
    this.mineOpacity = 0;
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 300, curve: curves.springMotion() }, (): void => {
        this.mineTranslateX = 0;
        this.mineOpacity = 1;
      });
    }, 0);
    setTimeout((): void => { this.mineAnimating = false; }, 600);
  }

  /**
   * 底部首页 Tab 的点击语义：单击当前首页 → 平滑回到列表顶端；
   * 360ms 内再次单击 → 重建整个首页信息流（保留既有行为）。
   */
  private onTabBarClick(index: number): void {
    if (index !== WeiboTab.Home) {
      this.lastHomeTabTapAt = 0;
      return;
    }
    const now: number = Date.now();
    // 从其它 tab 切回首页时 selectedTab 仍是旧值，这一下只用于切换，不计入双击窗口
    if (this.selectedTab !== WeiboTab.Home) {
      this.lastHomeTabTapAt = 0;
      return;
    }
    const withinDoubleTapWindow: boolean = this.lastHomeTabTapAt > 0
      && now - this.lastHomeTabTapAt <= HOME_TAB_DOUBLE_TAP_WINDOW_MS;
    if (withinDoubleTapWindow) {
      this.homeFeedRebuildVersion++;
      this.lastHomeTabTapAt = 0;
      return;
    }
    this.homeScrollTopTrigger++;
    this.lastHomeTabTapAt = now;
  }

  private configureHdsTabs(): void {
    const modifier: HdsTabsModifier = new HdsTabsModifier();
    modifier
      .vertical(false)
      .barPosition(BarPosition.End)
      .barHeight(HDS_TAB_BAR_HEIGHT)
      .barFloatingStyle({
        adaptToHandedness: true,
        barBottomMargin: 30,
        lightColor: this.accentColor,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: this.resolveHomeTabMaterialLevel()
        }
      });
    this.hdsTabsModifier = modifier;
  }

  private resolveHomeTabMaterialLevel(): hdsMaterial.MaterialLevel {
    if (this.homeTabMaterialLevel === 0) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.homeTabMaterialLevel === 1) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.homeTabMaterialLevel === 2) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  /** Match PaperTalk: convert the current window's raw top avoid area at layout time. */
  private topAvoidAreaVp(): number {
    return this.getUIContext().px2vp(this.topRectHeight);
  }

  /** The content inset is based on the actual system status-bar avoid area. */
  private contentTopInset(): number {
    return this.topAvoidAreaVp() + 56;
  }

  /** HarmonyX uses a second title-bar row for Search, so results begin below both rows. */
  private searchContentTopInset(): number {
    return this.topAvoidAreaVp() + 112;
  }

  private submitWeiboSearch(value: string): void {
    const query: string = value.trim();
    this.weiboSearchText = query;
    AppStorage.setOrCreate<number>('weiboSearchRequestTick',
      (AppStorage.get<number>('weiboSearchRequestTick') ?? 0) + 1);
  }

  /**
   * 信息流卡片里点 #话题#：切到搜索页并把话题词直接搜掉。
   * `weiboSearchText` 本身就是 `weiboSearchQuery` 的 StorageLink，
   * 所以调用 submitWeiboSearch 就够了——搜索页的 @Watch 会拿新关键词发起请求。
   */
  private openTopicSearch(topic: string): void {
    const keyword: string = topic.trim();
    if (keyword.length === 0) {
      return;
    }
    this.switchTab(WeiboTab.Search);
    this.submitWeiboSearch(keyword);
  }

  /**
   * 栈内页面（详情页、用户主页）请求检索话题：它们在 Navigation 栈里，
   * 拿不到 onOpenTopic 回调，只能通过 AppStorage 信号通知这里。
   * 先清栈退回首页再切搜索页，否则搜索结果会被详情页盖住看不见。
   */
  private onTopicRequest(): void {
    const topic: string = topicFromRequest(this.topicRequest);
    if (topic.length === 0) {
      return;
    }
    if (this.weiboNavStack.size() > 0) {
      this.weiboNavStack.clear();
      syncWeiboSplitNavigation(this.weiboNavStack);
    }
    this.openTopicSearch(topic);
  }

  private setSearchFocused(focused: boolean): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 240, 26) }, (): void => {
      this.searchFocusScale = focused ? 1.015 : 1;
      this.searchFocusOpacity = focused ? 1 : 0.92;
    });
  }

  /** Native HDS title content lets the framework place text against the real safe area. */
  private currentHdsTitle(): Resource {
    if (this.selectedTab === WeiboTab.Discover) {
      return $r('app.string.weibo_hot_title');
    }
    if (this.selectedTab === WeiboTab.Search) {
      return $r('app.string.weibo_search_title');
    }
    if (this.selectedTab === WeiboTab.Messages) {
      return $r('app.string.weibo_tab_messages');
    }
    if (this.selectedTab === WeiboTab.Mine) {
      return $r('app.string.weibo_mine_title');
    }
    return $r('app.string.weibo_tab_home');
  }

  /** Mirrors HarmonyX's immersive title material rather than drawing a header in each page. */
  private titleBarStyle(): TitleBarStyleOptions {
    return {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(16)
      },
      originalStyle: {
        backgroundStyle: { backgroundColor: $r('sys.color.ohos_id_color_background_transparent') },
        contentStyle: {
          titleStyle: {
            mainTitleColor: $r('sys.color.font_primary'),
            subTitleColor: $r('sys.color.font_secondary')
          },
          backIconStyle: { iconColor: $r('sys.color.icon_primary') },
          subIconStyle: { iconColor: $r('sys.color.icon_primary') },
          menuStyle: { iconColor: $r('sys.color.icon_primary') }
        }
      },
      scrollEffectStyle: {
        backgroundStyle: { backgroundColor: Theme.bg(this.isDark) },
        contentStyle: {
          titleStyle: {
            mainTitleColor: $r('sys.color.font_primary'),
            subTitleColor: $r('sys.color.font_secondary')
          },
          backIconStyle: { iconColor: $r('sys.color.icon_primary') },
          subIconStyle: { iconColor: $r('sys.color.icon_primary') },
          menuStyle: { iconColor: $r('sys.color.icon_primary') }
        }
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
  }

  private bindBuiltInTabScrollers(): void {
    this.hdsTabsController.bindScroller(WeiboTab.Discover, this.discoverScroller);
    this.hdsTabsController.bindScroller(WeiboTab.Search, this.searchScroller);
    this.hdsTabsController.bindScroller(WeiboTab.Messages, this.messagesScroller);
    this.hdsTabsController.bindScroller(WeiboTab.Mine, this.mineScroller);
  }

  @Builder
  PrivacyGate() {
    Column({ space: Spacing.lg }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(48)
        .fontColor([$r('sys.color.icon_emphasize')])
      Text($r('app.string.weibo_privacy_title'))
        .fontSize(fs(22, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text($r('app.string.weibo_privacy_body'))
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .textAlign(TextAlign.Center)
        .lineHeight(fs(22, this.fontScale))
        .padding({ left: Spacing.xl, right: Spacing.xl })
      Button($r('app.string.weibo_privacy_agree'))
        .width('78%')
        .height(48)
        .fontSize(fs(16, this.fontScale))
        .backgroundColor(Theme.manualGlass(this.isDark, true))
        .fontColor(Color.White)
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle())
        .backgroundEffect(ImmBlur.accent())
        .systemMaterial(ImmMaterial.accent(this.isDark))
        .borderRadius(Radius.full)
        .onClick(() => { this.acceptPrivacy(); })
      Button($r('app.string.weibo_privacy_exit'))
        .fontSize(fs(14, this.fontScale))
        .backgroundColor(Color.Transparent)
        .fontColor(Theme.textSecondary(this.isDark))
        .onClick(() => {
          if (this.context !== null) {
            this.context.terminateSelf().catch(() => {});
          }
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Theme.bg(this.isDark))
  }

  /** The source HomeTab's two-pill header, kept inside Home rather than the bottom navigation. */
  @Builder
  HomeHeaderOverlay() {
    Row({ space: 16 }) {
      Text((this.homeMode === WeiboTimelineMode.Recommend && this.recommendPending) ? $r('app.string.weibo_recommend_updated') : $r('app.string.weibo_recommend_title'))
        .accessibilityText((this.homeMode === WeiboTimelineMode.Recommend && this.recommendPending) ? $r('app.string.weibo_recommend_updated_accessibility') : $r('app.string.weibo_recommend_title'))
        .fontSize(fs(16, this.fontScale))
        .fontWeight(this.homeMode === WeiboTimelineMode.Recommend ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.homeMode === WeiboTimelineMode.Recommend ? this.accentColor : $r('sys.color.font_primary'))
        .backgroundColor(Theme.segGlass(this.isDark, this.homeMode === WeiboTimelineMode.Recommend))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(this.homeMode === WeiboTimelineMode.Recommend ? BlurStyle.Regular : BlurStyle.Thin,
          { scale: this.homeMode === WeiboTimelineMode.Recommend ? 0.8 : 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, this.homeMode === WeiboTimelineMode.Recommend))
        .borderRadius(Radius.full)
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .onClick(() => { this.selectHomeMode(WeiboTimelineMode.Recommend); })
      Text((this.homeMode === WeiboTimelineMode.Following && this.followingPending) ? $r('app.string.weibo_following_updated') : $r('app.string.weibo_following_title'))
        .accessibilityText((this.homeMode === WeiboTimelineMode.Following && this.followingPending) ? $r('app.string.weibo_following_updated_accessibility') : $r('app.string.weibo_following_title'))
        .fontSize(fs(16, this.fontScale))
        .fontWeight(this.homeMode === WeiboTimelineMode.Following ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.homeMode === WeiboTimelineMode.Following ? this.accentColor : $r('sys.color.font_primary'))
        .backgroundColor(Theme.segGlass(this.isDark, this.homeMode === WeiboTimelineMode.Following))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(this.homeMode === WeiboTimelineMode.Following ? BlurStyle.Regular : BlurStyle.Thin,
          { scale: this.homeMode === WeiboTimelineMode.Following ? 0.8 : 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, this.homeMode === WeiboTimelineMode.Following))
        .borderRadius(Radius.full)
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .onClick(() => { this.selectHomeMode(WeiboTimelineMode.Following); })
      Blank()
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
      }
      .width(44)
      .height(44)
      .backgroundColor(Theme.segGlass(this.isDark, false))
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
      .shadow(Theme.segGlassShadow(this.isDark, false))
      .borderRadius(Radius.full)
      .accessibilityText($r('app.string.weibo_tab_search'))
      .onClick(() => { this.switchTab(WeiboTab.Search); })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: this.topAvoidAreaVp() })
    .backgroundColor(Color.Transparent)
    .zIndex(15)
  }

  @Builder
  HomeFeedContent() {
    ForEach([this.homeFeedRebuildVersion], (_version: number): void => {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack() {
          WeiboHomeTab({
            mode: WeiboTimelineMode.Recommend,
            acceptUpdateTrigger: this.acceptHomeUpdateTrigger,
            onPendingChanged: (pending: boolean): void => { this.recommendPending = pending; },
            showHeader: false,
            topInset: 108,
            bottomInset: 128,
            animationTrigger: this.page1Enter,
            exitTrigger: this.page1Exit,
            scrollTopTrigger: this.homeScrollTopTrigger,
            isActive: this.homeMode === WeiboTimelineMode.Recommend,
            onOpenPost: (post: WeiboPost, startAtComments: boolean): void => this.openPostDetail(post, startAtComments),
            onOpenUserProfile: (userId: string, userName: string): void => this.openUserProfile(userId, userName),
            onOpenTopic: (topic: string): void => this.openTopicSearch(topic)
          })
        }
        .width('100%')
        .height('100%')
        .visibility(this.homeMode === WeiboTimelineMode.Recommend ? Visibility.Visible : Visibility.Hidden)
        Stack() {
          WeiboHomeTab({
            mode: WeiboTimelineMode.Following,
            acceptUpdateTrigger: this.acceptHomeUpdateTrigger,
            onPendingChanged: (pending: boolean): void => { this.followingPending = pending; },
            showHeader: false,
            topInset: 108,
            bottomInset: 128,
            animationTrigger: this.page1Enter,
            exitTrigger: this.page1Exit,
            scrollTopTrigger: this.homeScrollTopTrigger,
            isActive: this.homeMode === WeiboTimelineMode.Following,
            onOpenPost: (post: WeiboPost, startAtComments: boolean): void => this.openPostDetail(post, startAtComments),
            onOpenUserProfile: (userId: string, userName: string): void => this.openUserProfile(userId, userName),
            onOpenTopic: (topic: string): void => this.openTopicSearch(topic)
          })
        }
        .width('100%')
        .height('100%')
        .visibility(this.homeMode === WeiboTimelineMode.Following ? Visibility.Visible : Visibility.Hidden)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
    }, (version: number): string => version.toString())
  }

  /** Reference project's official Navigation title slot: interactive material provides press glow. */
  @Builder
  HomeTitleBar() {
    Row({ space: 16 }) {
      Text((this.homeMode === WeiboTimelineMode.Recommend && this.recommendPending) ? $r('app.string.weibo_recommend_updated') : $r('app.string.weibo_recommend_title'))
        .accessibilityText((this.homeMode === WeiboTimelineMode.Recommend && this.recommendPending) ? $r('app.string.weibo_recommend_updated_accessibility') : $r('app.string.weibo_recommend_title'))
        .fontSize(fs(16, this.fontScale))
        .fontWeight(this.homeMode === WeiboTimelineMode.Recommend ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.homeMode === WeiboTimelineMode.Recommend ? this.accentColor : $r('sys.color.font_primary'))
        .systemMaterial(ImmMaterial.seg(this.homeMode === WeiboTimelineMode.Recommend))
        .borderRadius(Radius.full)
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .onClick(() => { this.selectHomeMode(WeiboTimelineMode.Recommend); })
      Text((this.homeMode === WeiboTimelineMode.Following && this.followingPending) ? $r('app.string.weibo_following_updated') : $r('app.string.weibo_following_title'))
        .accessibilityText((this.homeMode === WeiboTimelineMode.Following && this.followingPending) ? $r('app.string.weibo_following_updated_accessibility') : $r('app.string.weibo_following_title'))
        .fontSize(fs(16, this.fontScale))
        .fontWeight(this.homeMode === WeiboTimelineMode.Following ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.homeMode === WeiboTimelineMode.Following ? this.accentColor : $r('sys.color.font_primary'))
        .systemMaterial(ImmMaterial.seg(this.homeMode === WeiboTimelineMode.Following))
        .borderRadius(Radius.full)
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .onClick(() => { this.selectHomeMode(WeiboTimelineMode.Following); })
      Blank()
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(20, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.seg(false))
      .borderRadius(Radius.full)
      .accessibilityText($r('app.string.weibo_tab_search'))
      .onClick(() => { this.switchTab(WeiboTab.Search); })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg })
    .backgroundColor(Color.Transparent)
  }

  /** HarmonyX-style title-bar bottom region: a material search field below the native title. */
  @Builder
  WeiboSearchBottomBuilder(): void {
    if (this.selectedTab === WeiboTab.Search) {
      Row() {
        Stack() {
        Search({
          value: this.weiboSearchText,
          placeholder: $r('app.string.weibo_search_placeholder')
        })
          .width('100%')
          .height(38)
          .backgroundColor(Color.Transparent)
          .fontColor(Theme.textPrimary(this.isDark))
          .onChange((value: string): void => {
            this.weiboSearchText = value;
          })
          .onFocus((): void => { this.setSearchFocused(true); })
          .onBlur((): void => { this.setSearchFocused(false); })
          .onSubmit((value: string): void => this.submitWeiboSearch(value))
      }
      .width('88%')
      .height(38)
      .scale({ x: this.searchFocusScale, y: this.searchFocusScale })
      .opacity(this.searchFocusOpacity)
      .renderGroup(true)
      .borderRadius(Radius.full)
      .clip(true)
      .systemMaterial(ImmMaterial.seg(false))
      }
      .width('100%')
      .height(56)
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  HomePage() {
    this.HomeFeedContent()
  }

  @Builder
  MessagesPage() {
    Scroll(this.messagesScroller) {
      Column({ space: Spacing.md }) {
        Text($r('app.string.weibo_feature_unavailable'))
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 120, bottom: 180 })
      }
      .width('100%')
      .padding({ top: this.contentTopInset(), left: Spacing.lg, right: Spacing.lg, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.bg(this.isDark))
    .translate({ x: this.messagesTranslateX })
    .opacity(this.messagesOpacity)
  }

  @Builder
  MineEntry(icon: Resource, title: ResourceStr, note: ResourceStr, onTap: () => void): void {
    Row({ space: Spacing.md }) {
      SymbolGlyph(icon)
        .fontSize(fs(20, this.fontScale))
        .fontColor([Theme.brand()])
        .width(28)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
        Text(note)
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(fs(17, this.fontScale))
        .fontColor([Theme.textTertiary(this.isDark)])
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
    .onClick(() => { onTap(); })
  }

  private async openMyPosts(): Promise<void> {
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    let userId: string = this.accountProfile === null ? '' : this.accountProfile.id;
    if (userId.length === 0 && this.cookieConfigured) {
      try {
        const account: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
        if (session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
        this.accountProfile = account;
        userId = account.id;
      } catch (error) {
      }
    }
    if (userId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录并完成账号资料读取' });
      return;
    }
    this.openUserProfile(userId, this.accountProfile?.screenName ?? '');
  }

  private openFollowing(): void {
    if (!this.cookieConfigured) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录微博后查看关注动态' });
      return;
    }
    this.homeMode = WeiboTimelineMode.Following;
    this.selectedTab = WeiboTab.Home;
  }

  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboSettings' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '设置页打开失败，请稍后重试' });
    });
  }

  private openAboutSoftware(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutSoftware' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '关于软件页面打开失败，请稍后重试' });
    });
  }

  @Builder
  MinePage() {
    Scroll(this.mineScroller) {
      Column({ space: Spacing.md }) {
        if (this.cookieConfigured && this.accountProfile !== null) {
          Row({ space: Spacing.md }) {
            if (this.accountProfile.avatarUrl.length > 0) {
              Image(this.accountProfile.avatarUrl)
                .width(58)
                .height(58)
                .borderRadius(Radius.full)
                .objectFit(ImageFit.Cover)
            } else {
              Stack() {
                Text(this.accountProfile.screenName.substring(0, 1))
                  .fontSize(fs(22, this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
              }
              .width(58)
              .height(58)
              .borderRadius(Radius.full)
              .backgroundColor(Theme.brand())
              .alignContent(Alignment.Center)
            }
            Column({ space: 4 }) {
              Text(this.accountProfile.screenName)
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text(this.accountProfile.description.length > 0 ? this.accountProfile.description : '已登录微博')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.postCard)

          Row() {
            Column({ space: 3 }) {
              Text(`${this.accountProfile.followingCount}`).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('关注').fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
            }.layoutWeight(1)
            Column({ space: 3 }) {
              Text(this.accountProfile.followersCount).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('粉丝').fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
            }.layoutWeight(1)
            Column({ space: 3 }) {
              Text(`${this.accountProfile.statusesCount}`).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('微博').fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
            }.layoutWeight(1)
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.postCard)
        } else {
          Column({ space: Spacing.sm }) {
            Text(this.accountLoading ? '正在读取微博账号…' :
              (this.cookieConfigured ? '微博账号资料暂不可用' : $r('app.string.weibo_mine_cookie_missing')))
              .fontSize(fs(16, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
            Text($r('app.string.weibo_mine_cookie_note'))
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .lineHeight(fs(19, this.fontScale))
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.postCard)
        }

        this.MineEntry($r('sys.symbol.doc'), '我的微博', '读取当前登录账号发布的微博', () => { this.openMyPosts(); })
        this.MineEntry($r('sys.symbol.person_2'), '关注动态', '查看我关注的用户最新微博', () => { this.openFollowing(); })
        // 这两项依赖微博尚未开放的能力，默认隐藏；关闭开关后恢复显示。
        if (!this.hideUnsupported) {
          this.MineEntry($r('sys.symbol.star'), '我的收藏', '微博公开接口暂不返回收藏列表', () => {
            this.getUIContext().getPromptAction().showToast({ message: '微博公开接口暂不提供“我的收藏”列表' });
          })
          this.MineEntry($r('sys.symbol.heart'), '我的点赞', '支持在微博详情中点赞或取消点赞', () => {
            this.getUIContext().getPromptAction().showToast({ message: '微博接口支持单条点赞，暂未提供点赞历史列表' });
          })
        }
        this.MineEntry($r('sys.symbol.arrow_clockwise'), '刷新账号资料', '重新读取昵称、头像和统计数据', () => { this.loadAccountProfile(); })
        this.MineEntry($r('sys.symbol.gearshape'), '软件设置', '主题色、应用语言与深浅色模式', () => { this.openSettings(); })
        this.MineEntry($r('sys.symbol.info_circle'), $r('app.string.weibo_software_about_entry'),
          $r('app.string.weibo_software_about_entry_description'), () => { this.openAboutSoftware(); })

        Button(this.cookieConfigured ? $r('app.string.weibo_login_reauth') : $r('app.string.weibo_login_title'))
          .width('100%')
          .height(48)
          .fontSize(fs(15, this.fontScale))
          .backgroundColor(Theme.manualGlass(this.isDark, true))
          .fontColor(Color.White)
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.accent())
          .systemMaterial(ImmMaterial.accent(this.isDark))
          .borderRadius(Radius.full)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboLogin' }).catch(() => {
              this.getUIContext().getPromptAction().showToast({ message: '登录页打开失败，请稍后重试' });
            });
          })
      }
      .width('100%')
      .padding({ top: this.contentTopInset(), left: Spacing.lg, right: Spacing.lg, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .backgroundColor(Theme.bg(this.isDark))
    .translate({ x: this.mineTranslateX })
    .opacity(this.mineOpacity)
  }

  private symbolFor(index: number): Resource {
    if (index === WeiboTab.Discover) {
      return $r('sys.symbol.flame_fill');
    }
    if (index === WeiboTab.Search) {
      return $r('sys.symbol.magnifyingglass');
    }
    if (index === WeiboTab.Messages) {
      return $r('sys.symbol.envelope');
    }
    if (index === WeiboTab.Mine) {
      return $r('sys.symbol.person');
    }
    return $r('sys.symbol.house_fill');
  }

  private hdsTabBar(icon: Resource, label: Resource): BottomTabBarStyle {
    const normalGlyph: SymbolGlyphModifier = new SymbolGlyphModifier(icon)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE);
    normalGlyph.fontColor([$r('sys.color.icon_primary')]);
    const selectedGlyph: SymbolGlyphModifier = new SymbolGlyphModifier(icon)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE);
    selectedGlyph.fontColor([this.accentColor]);
    return BottomTabBarStyle.of({ normal: normalGlyph, selected: selectedGlyph }, label)
      .labelStyle({
        unselectedColor: $r('sys.color.font_primary'),
        selectedColor: this.accentColor
      })
      .padding({ bottom: 0 });
  }

  @Builder
  HdsTabContents() {
    TabContent() {
      this.HomePage()
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Home), $r('app.string.weibo_tab_home')))

    TabContent() {
      WeiboHotSearch({
        pageScroller: this.discoverScroller,
        topInset: this.contentTopInset(),
        animationTrigger: this.page2Enter,
        exitTrigger: this.page2Exit,
        onOpenTopic: (topic: WeiboHotTopic): void => this.openHotTopic(topic)
      })
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Discover), $r('app.string.weibo_tab_discover')))

    TabContent() {
      WeiboSearch({
        pageScroller: this.searchScroller,
        topInset: this.searchContentTopInset(),
        animationTrigger: this.page3Enter,
        exitTrigger: this.page3Exit,
        onOpenPost: (post: WeiboPost, startAtComments: boolean): void => this.openPostDetail(post, startAtComments),
        onOpenUserProfile: (userId: string, userName: string): void => this.openUserProfile(userId, userName)
      })
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Search), $r('app.string.weibo_tab_search')))

    // 「消息」页签在当前版本尚未实现，隐藏时直接不渲染该 TabContent，
    // 页签数量随之变化，因此所有索引都要经 fromTabIndex / toTabIndex 换算。
    if (!this.hideUnsupported) {
      TabContent() {
        this.MessagesPage()
      }
      .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Messages), $r('app.string.weibo_tab_messages')))
    }

    TabContent() {
      this.MinePage()
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Mine), $r('app.string.weibo_tab_mine')))
  }

  /** One native title slot for the tab shell; individual pages only own scrollable content. */
  @Builder
  HdsPageTitle(title: Resource): void {
    Text(title)
      .fontSize(fs(20, this.fontScale))
      .fontWeight(FontWeight.Bold)
      .fontColor(Theme.textPrimary(this.isDark))
  }

  /** One native title slot for the tab shell; individual pages only own scrollable content. */
  @Builder
  HdsTitleBarContent(): void {
    if (this.privacyReady && this.privacyAccepted && this.selectedTab === WeiboTab.Home) {
      this.HomeTitleBar()
    } else {
      Column().width('100%').height(0)
    }
  }

  @Builder
  HdsTabsShell() {
    HdsTabs({ controller: this.hdsTabsController, index: this.toTabIndex(this.selectedTab) }) {
      this.HdsTabContents()
    }
    .width('100%')
    .height('100%')
    .barPosition(BarPosition.End)
    .barOverlap(true)
    .scrollable(true)
    .animationDuration(0)
    .attributeModifier(this.hdsTabsModifier)
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onChange((index: number): void => {
      this.switchTab(this.fromTabIndex(index));
    })
    .onTabBarClick((index: number): void => {
      this.onTabBarClick(this.fromTabIndex(index));
    })
    .onAnimationStart((currentIndex: number, targetIndex: number, event: TabsAnimationEvent): void => {
      this.onTabAnimationStart(this.fromTabIndex(currentIndex), this.fromTabIndex(targetIndex), event);
    })
  }

  /** Accent material instances are immutable, so remount the tab shell after a theme-color change. */
  @Builder
  AccentResponsiveTabs(): void {
    if (this.appAccentTick % 2 === 0) {
      this.HdsTabsShell()
    } else {
      this.HdsTabsShell()
    }
  }

  /** HDS route dispatcher: child destinations own their title material and scroll linkage. */
  @Builder
  WeiboNavigationBuilder(name: string): void {
    if (name === 'WeiboPostDetail') {
      WeiboPostDetailBuilder()
    } else if (name === 'WeiboUserProfile') {
      WeiboUserProfileBuilder()
    } else if (name === 'WeiboTopicContent') {
      WeiboTopicContentBuilder()
    }
  }

  build() {
    HdsNavigation(this.weiboNavStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        if (!this.privacyReady || !this.privacyAccepted) {
          this.PrivacyGate()
        } else {
          this.AccentResponsiveTabs()
        }
        if (this.weiboReady && !this.cookieConfigured) {
          WeiboVisitorBootstrap()
            .position({ x: -1, y: -1 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
    }
    .titleBar({
      style: this.titleBarStyle(),
      avoidLayoutSafeArea: true,
      content: {
        title: {
          mainTitle: this.privacyReady && this.privacyAccepted && this.selectedTab !== WeiboTab.Home
            ? this.currentHdsTitle() : ''
        },
        stackBuilder: (): void => this.HdsTitleBarContent(),
        bottomBuilder: {
          builder: (): void => this.WeiboSearchBottomBuilder(),
          height: this.selectedTab === WeiboTab.Search ? 56 : 0,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        },
        divider: { showType: DividerShowType.OFF }
      }
    })
    .navDestination(this.WeiboNavigationBuilder)
    .mode(this.mainNavigationMode)
    .navBarWidth(480)
    .minContentWidth(360)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideTitleBar(false)
    .hideBackButton(true)
    .bindToScrollable([
      this.discoverScroller,
      this.searchScroller,
      this.messagesScroller,
      this.mineScroller
    ])
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
