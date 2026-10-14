import { WeiboComment, WeiboCommentFilter, WeiboPost } from '../model/WeiboModel';
import { WeiboCommentsStore } from '../store/WeiboCommentsStore';
import { Theme, Radius, Spacing, fs } from '../common/Theme';
import { parseWeiboRich, stripExpandMarker } from '../common/RichText';
import { RichTextView } from './RichText';

/** 主评论只开放服务器提供的排序选项。 */
@Component
export struct WeiboCommentSort {
  @ObjectLink store: WeiboCommentsStore;
  @Prop post: WeiboPost;
  @Prop isDark: boolean = false;
  @Prop fontScale: number = 1;

  @Builder
  SortMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.weibo_comments_hot') })
        .enabled(this.store.filters.some((filter: WeiboCommentFilter): boolean => filter.order === 'hot'))
        .onClick((): void => { this.store.selectOrder('hot', this.post); })
      MenuItem({ content: $r('app.string.weibo_comments_latest') })
        .enabled(this.store.filters.some((filter: WeiboCommentFilter): boolean => filter.order === 'latest'))
        .onClick((): void => { this.store.selectOrder('latest', this.post); })
    }
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 3 }) {
        Text(this.store.order === 'hot' ? $r('app.string.weibo_comments_hot') : $r('app.string.weibo_comments_latest'))
          .fontSize(fs(13, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(fs(10, this.fontScale))
          .fontColor([Theme.textSecondary(this.isDark)])
      }
    }
    .backgroundColor(Color.Transparent)
    .padding({ left: 4, right: 0, top: 10, bottom: 10 })
    .enabled(this.store.filters.length > 0)
    .bindMenu(this.SortMenu())
  }
}

/** 回复在根评论下展开，滚动与返回仍由详情页管理。 */
@Component
export struct WeiboCommentThread {
  @Prop comment: WeiboComment;
  @Prop post: WeiboPost;
  @Prop isDark: boolean = false;
  @Prop fontScale: number = 1;
  @Prop refreshRootId: string = '';
  @Prop @Watch('onRefresh') refreshTick: number = 0;
  @State private expanded: boolean = false;
  @State private replies: WeiboCommentsStore = new WeiboCommentsStore();
  @Prop sending: boolean = false;
  onReply: (comment: WeiboComment) => void = () => {};
  onRepost: (comment: WeiboComment) => void = () => {};
  onCopy: (comment: WeiboComment) => void = () => {};
  onMention: (uid: string, name: string) => void = () => {};
  onTopic: (topic: string) => void = () => {};
  onLink: (url: string, label: string) => void = () => {};

  aboutToDisappear(): void { this.replies.cancel(); }

  private onRefresh(): void {
    if (this.refreshRootId !== this.comment.id) { return; }
    this.replies.loaded = false;
    if (this.expanded) { this.replies.load(this.post, this.comment.id); }
  }

  private toggleReplies(): void {
    this.expanded = !this.expanded;
    if (this.expanded && !this.replies.loaded) { this.replies.load(this.post, this.comment.id); }
    if (!this.expanded) { this.replies.cancel(); }
  }

  /** 展开后以完整列表为准，已显示全部时不再提供无效入口。 */
  private canExpandReplies(): boolean {
    if (this.replies.loaded) { return this.replies.items.length > 2 || this.replies.nextCursor !== null; }
    return this.comment.replyCount > Math.min(2, this.comment.replies.length) || this.comment.replies.length > 2;
  }

  private previewReplies(): WeiboComment[] {
    return (this.replies.loaded ? this.replies.items : this.comment.replies).slice(0, 2);
  }

  @Builder
  CommentActions(comment: WeiboComment) {
    Menu() {
      MenuItem({ content: $r('app.string.weibo_reply') })
        .enabled(!this.sending)
        .onClick((): void => { this.onReply(comment); })
      MenuItem({ content: $r('app.string.weibo_repost_action') })
        .enabled(!this.sending)
        .onClick((): void => { this.onRepost(comment); })
      MenuItem({ content: $r('app.string.weibo_copy') })
        .onClick((): void => { this.onCopy(comment); })
    }
  }

  @Builder
  CommentRow(comment: WeiboComment, child: boolean = false) {
    Row({ space: Spacing.sm }) {
      if (comment.userAvatar.length > 0) {
        Image(comment.userAvatar)
          .width(child ? 26 : 34)
          .height(child ? 26 : 34)
          .borderRadius(Radius.full)
          .objectFit(ImageFit.Cover)
          .onClick((): void => { this.onMention(comment.userId, comment.userName); })
      }
      Column({ space: 4 }) {
        Row({ space: Spacing.sm }) {
          Column({ space: 2 }) {
            Text(comment.userName)
              .fontSize(fs(13, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
              .onClick((): void => { this.onMention(comment.userId, comment.userName); })
            Text(comment.createdAt)
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(fs(12, this.fontScale))
            .fontColor([Theme.textSecondary(this.isDark)])
          Text(`${comment.likeCount}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .width('100%')
        if (comment.replyTo !== null && comment.replyTo.userName.length > 0) {
          Text($r('app.string.weibo_reply_to', comment.replyTo.userName))
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        RichTextView({
          segments: stripExpandMarker(parseWeiboRich(comment.rawText || comment.text)),
          isDark: this.isDark, fontSize: 14, lineHeight: 21, fontScale: this.fontScale,
          onMentionTap: (uid: string, name: string): void => { this.onMention(uid, name); },
          onTopicTap: (topic: string): void => { this.onTopic(topic); },
          onLinkTap: (url: string, label: string): void => { this.onLink(url, label); },
        })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .bindMenu(this.CommentActions(comment))
  }

  build() {
    Column({ space: Spacing.sm }) {
      this.CommentRow(this.comment)
      if (this.expanded || this.comment.replyCount > 0 || this.comment.replies.length > 0) {
        Column({ space: Spacing.sm }) {
          if (this.expanded) {
            ForEach(this.replies.items, (reply: WeiboComment): void => {
              this.CommentRow(reply, true)
            }, (reply: WeiboComment): string => reply.id)
            if (this.replies.loading) {
              LoadingProgress().width(18).height(18)
            } else if (this.replies.errorMessage.length > 0) {
              Text(this.replies.errorMessage).fontSize(fs(13, this.fontScale)).fontColor(Theme.danger())
              Button($r('app.string.weibo_retry'))
                .onClick((): void => { this.replies.load(this.post, this.comment.id, this.replies.items.length > 0 && this.replies.nextCursor !== null); })
            } else if (this.replies.loaded && this.replies.items.length === 0) {
              Text($r('app.string.weibo_no_replies')).fontSize(fs(13, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
            }
            if (this.replies.nextCursor !== null && !this.replies.loading && this.replies.errorMessage.length === 0) {
              Row().width('100%').height(1)
                .onVisibleAreaChange([0], (visible: boolean): void => {
                  if (visible) { this.replies.load(this.post, this.comment.id, true); }
                })
            }
          } else {
            ForEach(this.previewReplies(), (reply: WeiboComment): void => {
              this.CommentRow(reply, true)
            }, (reply: WeiboComment): string => reply.id)
          }
          if (this.canExpandReplies() || (this.expanded && (!this.replies.loaded || this.replies.loading || this.replies.errorMessage.length > 0))) {
            Button(this.expanded ? $r('app.string.weibo_collapse_replies')
              : this.comment.replyCount > 0 ? $r('app.string.weibo_all_replies', this.comment.replyCount) : $r('app.string.weibo_view_replies'))
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.brand())
              .backgroundColor(Color.Transparent)
              .onClick((): void => { this.toggleReplies(); })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 34 + Spacing.sm })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })
  }
}
