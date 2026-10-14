import { WeiboHotCategory, WeiboHotTopic } from '../model/WeiboModel';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { curves } from '@kit.ArkUI';
import { WeiboService } from '../service/WeiboService';
import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonComponents';

enum HotLoadState {
  Idle = 0,
  Loading = 1,
  Success = 2,
  Error = 3,
}

type TabAnimationDirection = 'left' | 'right';

/** 每个分类读取自己的真实榜单，词条由宿主压入内容页导航。 */
@Component
export struct WeiboHotSearch {
  pageScroller: Scroller = new Scroller();
  @Prop topInset: number = 64;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  @State isDark: boolean = isDarkMode();
  @State state: HotLoadState = HotLoadState.Idle;
  @State topics: WeiboHotTopic[] = [];
  @State category: WeiboHotCategory = WeiboHotCategory.Hot;
  private revision: number = 0;
  private readonly categories: WeiboHotCategory[] = [WeiboHotCategory.Hot, WeiboHotCategory.Tech,
    WeiboHotCategory.Entertainment, WeiboHotCategory.Life, WeiboHotCategory.Social,
    WeiboHotCategory.Sports, WeiboHotCategory.Animation, WeiboHotCategory.Mine];
  @StorageLink('weiboAuthTick') @Watch('onSessionChanged') authTick: number = 0;
  @State errorMessage: string = '';
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  onOpenTopic: (topic: WeiboHotTopic) => void = () => {};

  aboutToAppear(): void {
    this.loadTopics();
  }

  aboutToDisappear(): void { this.revision++; }
  private onSessionChanged(): void { this.loadTopics(); }

  private categoryLabel(category: WeiboHotCategory): ResourceStr {
    switch (category) {
      case WeiboHotCategory.Hot: return $r('app.string.weibo_hot_all');
      case WeiboHotCategory.Tech: return $r('app.string.weibo_hot_tech');
      case WeiboHotCategory.Entertainment: return $r('app.string.weibo_hot_entertainment');
      case WeiboHotCategory.Life: return $r('app.string.weibo_hot_life');
      case WeiboHotCategory.Social: return $r('app.string.weibo_hot_social');
      case WeiboHotCategory.Sports: return $r('app.string.weibo_hot_sports');
      case WeiboHotCategory.Animation: return $r('app.string.weibo_hot_animation');
      case WeiboHotCategory.Mine: return $r('app.string.weibo_hot_mine');
    }
  }

  private selectCategory(category: WeiboHotCategory): void {
    if (this.category === category) { return; }
    this.category = category;
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.loadTopics();
  }

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

  private async loadTopics(): Promise<void> {
    const revision: number = ++this.revision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    this.state = HotLoadState.Loading;
    this.errorMessage = '';
    try {
      const result: WeiboHotTopic[] = await WeiboService.getInstance().fetchHotTopics(this.category);
      if (revision !== this.revision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.topics = result;
      this.state = HotLoadState.Success;
    } catch (error) {
      if (revision !== this.revision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.topics = [];
      this.errorMessage = (error as Error).message ?? '微博热搜加载失败，请稍后重试';
      this.state = HotLoadState.Error;
    }
  }

  @Builder
  TopicRow(topic: WeiboHotTopic) {
    Row({ space: Spacing.md }) {
      Text(topic.rank === null ? $r('app.string.weibo_hot_pinned') : `${topic.rank}`)
        .width(fs(32, this.fontScale))
        .fontSize(fs(14, this.fontScale))
        .fontWeight(topic.rank === null || topic.rank <= 3 ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(topic.rank === null || topic.rank <= 3 ? Theme.brand() : Theme.textSecondary(this.isDark))
        .textAlign(TextAlign.Center)
      Column({ space: 4 }) {
        Row({ space: Spacing.sm }) {
          Text(topic.word)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
            .fontWeight(FontWeight.Medium)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (topic.label.length > 0) {
            Text(topic.label)
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.brand())
          }
        }
        .width('100%')
        if (topic.description.length > 0 || topic.heat !== null) {
          Text(topic.description.length > 0 ? topic.description : `${topic.heat}`)
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.sheetGlass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
    .border({ width: 0.5, color: Theme.manualGlassBorder() })
    .shadow(Theme.glassShadowStyle())
    .systemMaterial(ImmMaterial.rowItem())
    .borderRadius(Radius.postCard)
    .onClick((): void => { this.onOpenTopic(topic); }, 8)
  }

  build() {
    Scroll(this.pageScroller) {
      Column({ space: Spacing.md }) {
        Row({ space: Spacing.sm }) {
          Scroll() {
            Row({ space: Spacing.sm }) {
              ForEach(this.categories, (category: WeiboHotCategory): void => {
                Button(this.categoryLabel(category), { type: ButtonType.Normal })
                  .fontSize(fs(14, this.fontScale))
                  .fontColor(this.category === category ? Theme.brand() : Theme.textSecondary(this.isDark))
                  .backgroundColor(Color.Transparent)
                  .borderRadius(0)
                  .border({ width: { bottom: this.category === category ? 2 : 0 }, color: Theme.brand() })
                  .onClick((): void => { this.selectCategory(category); })
              }, (category: WeiboHotCategory): string => category)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(fs(20, this.fontScale))
              .fontColor([Theme.textPrimary(this.isDark)])
          }
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.weibo_refresh_hot'))
          .enabled(this.state !== HotLoadState.Loading)
          .onClick((): void => { this.loadTopics(); })
        }
        .width('100%')
        if (this.state === HotLoadState.Loading) {
          LoadingView({ message: $r('app.string.weibo_loading') })
            .height(360)
        } else if (this.state === HotLoadState.Error) {
          ErrorView({ message: this.errorMessage, onRetry: (): void => { this.loadTopics(); } })
            .height(360)
        } else if (this.state === HotLoadState.Success && this.topics.length === 0) {
          EmptyView({ message: $r('app.string.weibo_hot_empty'), icon: '○' })
            .height(360)
        } else if (this.state === HotLoadState.Success) {
          Column({ space: Spacing.sm }) {
            ForEach(this.topics, (topic: WeiboHotTopic): void => {
              this.TopicRow(topic)
            }, (topic: WeiboHotTopic): string => topic.query)
          }
          .width('100%')
        } else {
          EmptyView({ message: $r('app.string.weibo_hot_empty'), icon: '○' })
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
