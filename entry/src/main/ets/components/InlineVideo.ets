import { ACTIVE_FEED_VIDEO_KEY } from '../common/Constants';

let nextPlayerOwner: number = 0;

/** Each mounted player owns a unique token, even when the same post appears twice. */
@Component
export struct InlineVideo {
  @Prop @Watch('onSourceChange') url: string = '';
  @StorageLink('weiboAuthTick') @Watch('onAuthChange') authTick: number = 0;
  @Prop @Watch('onCoverChange') cover: string = '';
  @State private availableWidth: number = 0;
  @State private coverRatio: number = 16 / 9;
  private onCoverChange(): void { this.coverRatio = 16 / 9; }
  private mediaWidth(): number { return Math.max(1, this.availableWidth); }
  private mediaHeight(): number { return Math.max(180, Math.min(360, this.mediaWidth() / this.coverRatio)); }
  @StorageLink(ACTIVE_FEED_VIDEO_KEY) @Watch('onOwnerChange') owner: string = '';
  @State private failed: boolean = false;
  @State private paused: boolean = false;
  @State private fullscreen: boolean = false;
  @State private controlsVisible: boolean = true;
  @State private elapsed: number = 0;
  @State private duration: number = 0;
  private hideTimer: number = -1;
  private clearHideTimer(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
  }
  private showControls(): void {
    this.clearHideTimer(); this.controlsVisible = true;
    if (this.active() && !this.paused && !this.fullscreen) {
      this.hideTimer = setTimeout((): void => { this.controlsVisible = false; this.hideTimer = -1; }, 3000);
    }
  }
  private timeLabel(seconds: number): string {
    const value: number = Math.max(0, Math.floor(seconds));
    return `${Math.floor(value / 60)}:${(value % 60).toString().padStart(2, '0')}`;
  }
  private token: string = `player-${++nextPlayerOwner}`;
  private controller: VideoController = new VideoController();

  private onAuthChange(): void { this.stop(); }
  private onSourceChange(): void { this.stop(); this.failed = false; }
  private active(): boolean { return this.owner === this.token; }
  private onOwnerChange(): void {
    if (!this.active()) {
      this.clearHideTimer();
      if (this.fullscreen) {
        try { this.controller.exitFullscreen(); } catch (_) {}
        this.fullscreen = false;
      }
      try { this.controller.stop(); } catch (_) {}
    }
  }
  private stop(): void {
    this.clearHideTimer();
    if (!this.active()) { return; }
    try { this.controller.stop(); } catch (_) {}
    this.owner = '';
  }
  aboutToDisappear(): void { this.stop(); }

  build() {
    Column() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.active()) {
        Video({ src: this.url, previewUri: this.cover, controller: this.controller })
          .width(this.mediaWidth()).height(this.mediaHeight())
          .autoPlay(true).controls(this.fullscreen).objectFit(ImageFit.Contain)
          // Inline native controls consume vertical drags. Only explicit buttons below receive taps.
          .hitTestBehavior(this.fullscreen ? HitTestMode.Default : HitTestMode.None)
          .onStart((): void => { this.paused = false; this.showControls(); })
          .onPause((): void => { this.paused = true; this.showControls(); })
          .onPrepared((event): void => { if (event) { this.duration = event.duration; } })
          .onUpdate((event): void => { if (event) { this.elapsed = event.time; } })
          .onFinish((): void => { this.stop(); })
          .onError((): void => { this.failed = true; this.stop(); })
          .onFullscreenChange((event): void => { this.fullscreen = event.fullscreen; this.showControls(); })
      } else {
        Image(this.cover).width(this.mediaWidth()).height(this.mediaHeight()).objectFit(ImageFit.Contain)
          .onComplete((event): void => {
            if (event && event.width > 0 && event.height > 0) { this.coverRatio = event.width / event.height; }
          })
          .hitTestBehavior(HitTestMode.None)
      }
      Column() {
        if (!this.active() || this.paused) {
          Button({ type: ButtonType.Circle }) {
            if (this.failed) { Text('重试').fontColor(Color.White).fontSize(14) }
            else { Image($r('app.media.video_play')).width(48).height(48).objectFit(ImageFit.Contain).hitTestBehavior(HitTestMode.None) }
          }
            .width(72).height(72).padding(0).fontSize(22).fontColor(Color.White)
            .backgroundColor(Color.Transparent)
            .accessibilityText(this.failed ? '重试播放视频' : '播放视频')
            .onClick((): void => { if (this.active()) { this.controller.start(); } else { this.failed = false; this.elapsed = 0; this.duration = 0; this.paused = false; this.controlsVisible = true; this.owner = this.token; } }, 8)
        }
      }.width(this.mediaWidth()).height(this.mediaHeight()).justifyContent(FlexAlign.Center)
      if (this.active() && !this.fullscreen && this.controlsVisible) {
        Row({ space: 4 }) {
          Button({ type: ButtonType.Circle }) {
            if (this.paused) {
              Image($r('app.media.video_play')).width(28).height(28).hitTestBehavior(HitTestMode.None)
            } else {
              Image($r('app.media.video_pause')).width(28).height(28).hitTestBehavior(HitTestMode.None)
            }
          }.width(48).height(48).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(this.paused ? '继续播放' : '暂停播放')
          .onClick((): void => {
            if (this.paused) { this.controller.start(); } else { this.controller.pause(); }
            this.showControls();
          }, 8)
          Text(this.timeLabel(this.elapsed) + ' / ' + this.timeLabel(this.duration))
            .fontSize(12).fontColor(Color.White).height(48).layoutWeight(1)
            .maxLines(1).textAlign(TextAlign.Center).hitTestBehavior(HitTestMode.None)
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.video_fullscreen')).width(28).height(28).hitTestBehavior(HitTestMode.None)
          }.width(48).height(48).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('全屏播放')
          .onClick((): void => { this.controller.requestFullscreen(true); }, 8)
        }.width('100%').alignItems(VerticalAlign.Center)
        .padding({ left: 8, right: 8, top: 12, bottom: 4 })
        .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#99000000', 1]] })
      }
    }
    .width(this.mediaWidth()).height(this.mediaHeight()).backgroundColor(Color.Black).borderRadius(12).clip(true)
    // Consume a genuine background tap without excluding the parent's pan recognizer.
    .onClick((): void => {
      if (this.active()) {
        if (this.paused) { this.controller.start(); } else { this.controller.pause(); }
        this.showControls();
      }
    }, 8)
    .onVisibleAreaChange([0], (_visible: boolean, ratio: number): void => {
      if (ratio === 0 && !this.fullscreen) { this.stop(); }
    })
    }.width('100%').alignItems(HorizontalAlign.Start)
    .onAreaChange((_old: Area, area: Area): void => { this.availableWidth = Number(area.width); })
  }
}
