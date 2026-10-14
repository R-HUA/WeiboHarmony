import { InlineVideo } from './InlineVideo';
import { PictureGallery } from './PictureGallery';

/** 混排视频占用一个宫格项，图片预览仍使用原图片索引。 */
@Component
export struct MixedMediaTiles {
  @Prop pictures: string[] = [];
  @Prop videoUrl: string = '';
  @Prop videoCoverUrl: string = '';
  @Prop isDark: boolean = false;
  @Prop fontScale: number = 1;
  onPictureTap: (index: number) => void = () => {};
  build() {
    Column({ space: 8 }) {
      if (this.pictures.length > 0) {
        PictureGallery({ pictures: this.pictures, videoUrl: this.videoUrl, videoCoverUrl: this.videoCoverUrl,
          isDark: this.isDark, onPictureTap: this.onPictureTap })
      }
      if (this.videoUrl.length > 0 && this.pictures.length === 0) {
        InlineVideo({ url: this.videoUrl, cover: this.videoCoverUrl })
      }
    }.width('100%')
  }
}
