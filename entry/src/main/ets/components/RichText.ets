/*
 * 微博正文富文本渲染：把 RichText.parseWeiboRich 产出的分段画成一个 Text。
 *
 * 用 Text + Span/ImageSpan 而不是 StyledString，是因为 Span 原生支持 onClick
 * （见 SDK span.d.ts：Span 仅支持 onClick/onHover 两个通用事件），
 * 这样 @用户名 / #话题# / 网页链接 既能上品牌色又能分别响应点击，
 * 同时保留 Text 自身的断行与省略号能力。
 */

import { RichKind, RichSegment, readingSegments } from '../common/RichText';
import { Theme, fs } from '../common/Theme';

@Component
export struct RichTextView {
  @Prop segments: RichSegment[] = [];
  @Prop hasInlineVideo: boolean = false;
  @Prop isDark: boolean = false;
  /** 正文字号（vp）；行内表情按此放大 2vp，与官方表情观感接近。 */
  @Prop fontSize: number = 16;
  @Prop lineHeight: number = 24;
  /** 0 表示不限行数（首页正文按官方行为完整展示）。 */
  @Prop maxLines: number = 0;
  /** 次级内容（转发原文、评论）用次级文字色。 */
  @Prop secondary: boolean = false;
  /** 字号缩放（应用内「字体大小」设置）。 */
  @Prop fontScale: number = 1.0;
  onMentionTap: (uid: string, name: string) => void = () => {};
  onTopicTap: (topic: string) => void = () => {};
  onLinkTap: (url: string) => void = () => {};
  /** 长文末尾的「展开」；参数是要展开哪条帖的 postId（转发原文会传原帖 id）。 */
  onExpandTap: (target: string) => void = () => {};

  private bodyColor(): ResourceColor {
    return this.secondary ? Theme.textSecondary(this.isDark) : Theme.textPrimary(this.isDark);
  }

  private mentionName(segment: RichSegment): string {
    return segment.text.startsWith('@') ? segment.text.substring(1) : segment.text;
  }

  private dispatch(segment: RichSegment): void {
    if (segment.kind === RichKind.Mention) {
      if (segment.target.length > 0) { this.onMentionTap(segment.target, this.mentionName(segment)); }
      else { this.onLinkTap('https://weibo.com/n/' + encodeURIComponent(this.mentionName(segment))); }
      return;
    }
    if (segment.kind === RichKind.Topic) {
      this.onTopicTap(segment.target);
      return;
    }
    if (segment.kind === RichKind.Expand) {
      this.onExpandTap(segment.target);
      return;
    }
    if (segment.kind === RichKind.Link) {
      this.onLinkTap(segment.target);
    }
  }

  build() {
    Text() {
      ForEach(readingSegments(this.segments, this.hasInlineVideo), (segment: RichSegment, index: number): void => {
        if (segment.kind === RichKind.Emoji && segment.imageUrl.length > 0) {
          ImageSpan(segment.imageUrl)
            .width(this.fontSize + 4)
            .height(this.fontSize + 4)
            .verticalAlign(ImageSpanAlignment.CENTER)
            .objectFit(ImageFit.Contain)
        } else if (segment.kind === RichKind.Text) {
          Span(segment.text)
            .fontColor(this.bodyColor())
        } else {
          // @用户名 / #话题# / 网页链接 / 「展开」：品牌色 + 可点击
          Span(segment.text)
            .fontColor(Theme.brand())
            .onClick((): void => { this.dispatch(segment); })
        }
      }, (segment: RichSegment, index: number): string => `${index}|${segment.kind}|${segment.text}|${segment.target}|${segment.imageUrl}`)
    }
    .width('100%')
    .fontSize(fs(this.fontSize, this.fontScale))
    .lineHeight(fs(this.lineHeight, this.fontScale))
    .maxLines(this.maxLines > 0 ? this.maxLines : 4096)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .textAlign(TextAlign.Start)
  }
}
