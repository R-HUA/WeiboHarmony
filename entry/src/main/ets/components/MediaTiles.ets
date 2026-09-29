import { InlineVideo } from './InlineVideo';
import { PictureGallery } from './PictureGallery';

export const MIXED_MEDIA_MAX_PICTURES: number = 2;

/** Mixed media and reposts share the same gallery and full-width inline player. */
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
        PictureGallery({ pictures: this.pictures, isDark: this.isDark, onPictureTap: this.onPictureTap })
      }
      if (this.videoUrl.length > 0) {
        InlineVideo({ url: this.videoUrl, cover: this.videoCoverUrl })
      }
    }.width('100%')
  }
}
