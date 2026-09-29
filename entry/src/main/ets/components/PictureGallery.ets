import { Theme } from '../common/Theme';

/** Static rows do not create a nested scroll recognizer. All multi-image cells are equal. */
@Component
export struct PictureGallery {
  @Prop pictures: string[] = [];
  @Prop isDark: boolean = false;
  onPictureTap: (index: number) => void = () => {};
  @State private availableWidth: number = 0;
  @State private ratio: number = 1;
  @State private ratios: Record<string, number> = {};
  @State private failures: Record<string, boolean> = {};

  private imageFailed(url: string): void {
    const next: Record<string, boolean> = {};
    Object.keys(this.failures).forEach((key: string): void => { next[key] = this.failures[key]; });
    next[url] = true; this.failures = next;
  }

  private rows(): number[] {
    const result: number[] = [];
    for (let i = 0; i < Math.min(9, this.pictures.length); i += 3) { result.push(i); }
    return result;
  }
  private side(): number { return Math.max(1, (this.availableWidth - 8) / 3); }

  private singleHeight(): number {
    return Math.min(360, this.availableWidth * 1.25,
      this.availableWidth / Math.max(0.01, this.ratio));
  }

  private singleWidth(): number {
    return this.ratio < 0.5 ? this.availableWidth : Math.min(this.availableWidth, this.singleHeight() * this.ratio);
  }

  private rememberRatio(url: string, ratio: number): void {
    if (this.ratios[url] === ratio) { return; }
    const next: Record<string, number> = {};
    Object.keys(this.ratios).forEach((key: string): void => { next[key] = this.ratios[key]; });
    next[url] = ratio; this.ratios = next;
  }

  build() {
    Column({ space: 4 }) {
      if (this.pictures.length === 1) {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.pictures[0]).width('100%')
            .height(this.singleWidth() / Math.max(0.01, this.ratio))
            .objectFit(ImageFit.Contain)
            .onError((): void => { this.imageFailed(this.pictures[0]); })
            .onComplete((event): void => {
              if (event && event.width > 0 && event.height > 0) { this.ratio = event.width / event.height; }
            })
          if (this.failures[this.pictures[0]]) {
            Text('加载失败').fontSize(12).fontColor(Theme.textPrimary(this.isDark)).padding(8)
          }

        }.width(this.singleWidth()).height(this.singleHeight()).borderRadius(8).clip(true)
        .onClick((): void => { this.onPictureTap(0); }, 8)
      } else {
        ForEach(this.rows(), (start: number): void => {
          Row({ space: 4 }) {
            ForEach(this.pictures.slice(start, Math.min(start + 3, 9)), (url: string, offset: number): void => {
              Stack({ alignContent: Alignment.TopStart }) {
                Image(url).width(this.side())
                  .height(this.ratios[url] < 0.5 ? this.side() / Math.max(0.01, this.ratios[url]) : this.side())
                  .objectFit(ImageFit.Contain)
                  .onComplete((event): void => {
                    if (event && event.width > 0 && event.height > 0) {
                      this.rememberRatio(url, event.width / event.height);
                    }
                  })
                  .onError((): void => { this.imageFailed(url); })
                if (this.failures[url]) {
                  Text('加载失败').fontSize(12).fontColor(Theme.textPrimary(this.isDark)).padding(6)
                }
                if (start + offset === 8 && this.pictures.length > 9) {
                  Text(`+${this.pictures.length - 9}`).fontColor(Color.White).padding(6).backgroundColor('#99000000')
                }
              }.width(this.side()).height(this.side()).backgroundColor(Theme.bgSurface(this.isDark))
              .borderRadius(8).clip(true)
              .onClick((): void => { this.onPictureTap(start + offset); }, 8)
            }, (url: string, offset: number): string => `${start + offset}:${url}`)
          }.width('100%')
        }, (start: number): string => `${start}`)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
    .onAreaChange((_old: Area, area: Area): void => { this.availableWidth = Number(area.width); })
  }
}
