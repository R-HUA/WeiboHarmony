import { Theme } from '../common/Theme';
import { InlineVideo } from './InlineVideo';

/** Static rows do not create a nested scroll recognizer. All multi-image cells are equal. */
@Component
export struct PictureGallery {
  @Prop pictures: string[] = [];
  @Prop videoUrl: string = '';
  @Prop videoCoverUrl: string = '';
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
    for (let i = 0; i < Math.min(9, this.mediaCount()); i += 3) { result.push(i); }
    return result;
  }

  private mediaCount(): number { return this.pictures.length + (this.videoUrl ? 1 : 0); }

  private cells(start: number): number[] {
    const result: number[] = [];
    for (let i = start; i < Math.min(start + 3, 9, this.mediaCount()); i++) { result.push(i); }
    return result;
  }

  /** 视频固定占首格，图片预览索引不包含视频项。 */
  private pictureIndex(cell: number): number { return cell - (this.videoUrl ? 1 : 0); }
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
      if (this.pictures.length === 1 && !this.videoUrl) {
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
            ForEach(this.cells(start), (cell: number): void => {
              if (this.videoUrl && cell === 0) {
                Column() {
                  InlineVideo({ url: this.videoUrl, cover: this.videoCoverUrl, fullscreenOnTap: true })
                }.width(this.side()).height(this.side())
              } else {
                Stack({ alignContent: Alignment.TopStart }) {
                  Image(this.pictures[this.pictureIndex(cell)]).width(this.side())
                    .height(this.ratios[this.pictures[this.pictureIndex(cell)]] < 0.5
                      ? this.side() / Math.max(0.01, this.ratios[this.pictures[this.pictureIndex(cell)]]) : this.side())
                    .objectFit(ImageFit.Contain)
                    .onComplete((event): void => {
                      if (event && event.width > 0 && event.height > 0) {
                        this.rememberRatio(this.pictures[this.pictureIndex(cell)], event.width / event.height);
                      }
                    })
                    .onError((): void => { this.imageFailed(this.pictures[this.pictureIndex(cell)]); })
                  if (this.failures[this.pictures[this.pictureIndex(cell)]]) {
                    Text('加载失败').fontSize(12).fontColor(Theme.textPrimary(this.isDark)).padding(6)
                  }
                  if (cell === 8 && this.mediaCount() > 9) {
                    Text(`+${this.mediaCount() - 9}`).fontColor(Color.White).padding(6).backgroundColor('#99000000')
                  }
                }.width(this.side()).height(this.side()).backgroundColor(Theme.bgSurface(this.isDark))
                  .borderRadius(8).clip(true)
                  .onClick((): void => { this.onPictureTap(this.pictureIndex(cell)); }, 8)
              }
            }, (cell: number): string => `${cell}:${this.videoUrl && cell === 0 ? this.videoUrl : this.pictures[this.pictureIndex(cell)]}`)
          }.width('100%')
        }, (start: number): string => `${start}`)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
    .onAreaChange((_old: Area, area: Area): void => { this.availableWidth = Number(area.width); })
  }
}
