import { ACTIVE_FEED_VIDEO_KEY } from '../common/Constants';
import { InlineVideo } from '../components/InlineVideo';
import { PictureGallery } from '../components/PictureGallery';
import { PostEntities } from '../store/PostEntities';
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { WeiboComment, WeiboPost, WeiboUser } from '../model/WeiboModel';
import { RichSegment, parseWeiboRich, stripExpandMarker } from '../common/RichText';
import { RichTextView } from '../components/RichText';
import { MixedMediaTiles, MIXED_MEDIA_MAX_PICTURES } from '../components/MediaTiles';
import { requestTopicSearch } from '../common/TopicRequest';
import { openExternalUrl } from '../common/ExternalLink';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService } from '../service/WeiboService';
import { ImmBlur, ImmMaterial, MaterialManager, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { ShareUtil } from '../common/ShareUtil';
import { DividerShowType, HdsNavDestination, HdsNavDestinationTitleMode, HdsTabs, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';

/**
 * Routed post detail. It deliberately owns its scroll, comments, and bottom
 * composer so a timeline card never expands in place.
 */
export interface WeiboPostDetailRouteParam {
  postId: string;
}

/**
 * 点正文里 @用户名 要跳到用户主页。
 * 结构与 pages/WeiboUserProfile 的 WeiboUserProfileRouteParam 完全一致，
 * 但刻意不 import 那个类型：WeiboUserProfile 反过来 import 了本文件的
 * WeiboPostDetailRouteParam，互相 import 会构成循环。
 */
interface MentionRouteParam {
  userId: string;
  userName: string;
}

@Builder
export function WeiboPostDetailBuilder(): void {
  WeiboPostDetail()
}

@Component
export struct WeiboPostDetail {
  @StorageLink('weiboPostTick') @Watch('onPostEntitiesChanged') postTick: number = 0;
  private onPostEntitiesChanged(): void { if (this.post !== null) { this.post = PostEntities.shared().apply(this.post); } }
  @State isDark: boolean = isDarkMode();
  @State postId: string = '';
  @State post: WeiboPost | null = null;
  @State comments: WeiboComment[] = [];
  @State loading: boolean = true;
  @State commentsPage: number = 1;
  @State commentsHasMore: boolean = true;
  private commentsRevision: number = 0;
  private viewRevision: number = 0;
  @State commentsLoading: boolean = false;
  @State errorMessage: string = '';
  /** 长文正文全文（HTML）。空串表示这不是长文，或者还没拉到。 */
  @State private longTextRaw: string = '';
  /** 转发原文的全文（HTML）。转发也可能是长文。 */
  @State private repostLongTextRaw: string = '';
  @State commentDraft: string = '';
  @State commentSending: boolean = false;
  @State accountAvatarUrl: string = '';
  @State accountName: string = '';
  /** One-shot entrance for the post and conversation after data becomes available. */
  @State contentOpacity: number = 0;
  @State contentTranslateY: number = 18;
  @State contentScale: number = 0.985;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @StorageLink('weibo.navigation_indicator_height') navigationIndicatorHeight: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  private detailScroller: Scroller = new Scroller();
  private gestureShareListening: boolean = false;
  private gestureSharing: boolean = false;
  private gestureSharePreviewPostId: string = '';
  private gestureSharePreviewUri: string = '';
  private gestureSharePreviewContentKey: string = '';
  private gesturesShareCallback: (target: harmonyShare.SharableTarget) => void =
    (target: harmonyShare.SharableTarget): void => {
      this.sharePostByGesture(target);
    };

  async aboutToAppear(): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await WeiboAuthManager.getInstance().init(context);
    await this.loadCurrentAccountProfile();
    this.registerGesturesShare();
    setTimeout((): void => {
      this.loadRoutePost();
    }, 50);
  }

  aboutToDisappear(): void {
    this.viewRevision++; this.commentsRevision++;
    this.unregisterGesturesShare();
  }

  /** HDS destinations receive their argument from the shared NavPathStack. */
  private async loadRoutePost(): Promise<void> {
    const params: WeiboPostDetailRouteParam[] =
      this.weiboNavStack.getParamByName('WeiboPostDetail') as WeiboPostDetailRouteParam[];
    if (params === undefined || params === null || params.length === 0) {
      this.loading = false;
      this.errorMessage = '该微博信息暂不可用';
      return;
    }
    const routeParam: WeiboPostDetailRouteParam = params[params.length - 1];
    this.postId = routeParam.postId;
    if (this.postId.length === 0) {
      this.loading = false;
      this.errorMessage = '该微博信息暂不可用';
      return;
    }
    const cached: WeiboPost | null = WeiboService.getInstance().getRememberedPost(this.postId);
    if (cached !== null) {
      this.post = cached;
      this.loading = false;
      this.presentPostContent();
      await this.prepareGestureSharePreview();
      await this.loadComments();
      await this.loadLongTextIfNeeded();
      return;
    }
    await this.loadPost();
    await this.loadLongTextIfNeeded();
  }

  private onWeiboAuthTick(): void {
    this.viewRevision++; this.commentsRevision++;
    this.post = null; this.comments = []; this.commentDraft = '';
    this.commentsLoading = false; this.commentSending = false;
    this.errorMessage = '登录状态已改变，请返回列表重新打开';
    this.loadCurrentAccountProfile();
  }

  /** The reply capsule shows the actual account avatar represented by the saved Cookie. */
  private async loadCurrentAccountProfile(): Promise<void> {
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.accountAvatarUrl = '';
      this.accountName = '';
      return;
    }
    const revision: number = this.viewRevision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    try {
      const account: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.accountAvatarUrl = account.avatarUrl;
      this.accountName = account.screenName;
    } catch (error) {
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.accountAvatarUrl = '';
      this.accountName = '';
    }
  }

  /**
   * 详情页必须给出完整正文：长文帖在列表接口里是截断版（末尾带「展开 / 全文」标记），
   * 只有再调一次全文接口才有完整内容——这就是「点进详情还是显示展开」的根因。
   * Service 侧有缓存和在飞合并，所以从信息流先点过「展开」再进来不会重复请求。
   */
  private async loadLongTextIfNeeded(): Promise<void> {
    const post: WeiboPost | null = this.post;
    if (post === null) {
      return;
    }
    const mainId: string = post.isLongText === true ? post.id : '';
    const repost: WeiboPost | null = post.repost;
    const repostId: string = repost !== null && repost.isLongText === true ? repost.id : '';
    this.longTextRaw = '';
    this.repostLongTextRaw = '';
    if (mainId.length === 0 && repostId.length === 0) {
      return;
    }
    const revision: number = this.viewRevision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    if (mainId.length > 0) {
      const html: string = await WeiboService.getInstance().fetchLongText(mainId);
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.longTextRaw = html;
    }
    if (repostId.length > 0) {
      const html: string = await WeiboService.getInstance().fetchLongText(repostId);
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.repostLongTextRaw = html;
    }
  }

  private async loadPost(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    this.contentOpacity = 0;
    this.contentTranslateY = 18;
    this.contentScale = 0.985;
    const revision: number = this.viewRevision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    try {
      const post: WeiboPost = await WeiboService.getInstance().fetchPost(this.postId);
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.post = post;
      this.presentPostContent();
      await this.prepareGestureSharePreview();
      await this.loadComments();
    } catch (error) {
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.errorMessage = (error as Error).message ?? '帖子详情加载失败，请稍后重试';
    } finally {
      if (revision === this.viewRevision && session === WeiboAuthManager.getInstance().getGeneration()) { this.loading = false; }
    }
  }

  private presentPostContent(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 360, 34) }, (): void => {
      this.contentOpacity = 1;
      this.contentTranslateY = 0;
      this.contentScale = 1;
    });
  }

  private popRoute(): void {
    this.weiboNavStack.pop();
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  /**
   * 正文 HTML -> 可点击分段。
   * `rawText` 是接口原样返回的 HTML，`text` 是 stripHtml 后的纯文本；
   * 优先用 rawText 才能还原 @/话题/链接/表情，缺失时退化为纯文本（裸链仍能被识别）。
   */
  private richSegments(raw: string | undefined, fallback: string): RichSegment[] {
    const source: string = raw !== undefined && raw.length > 0 ? raw : fallback;
    // 详情页永远不要「展开」这个假按钮：要么已经拿到全文，要么是接口的截断版，
    // 后者也已经在进页面时补拉过全文，标记留着只会让人以为还能点。
    return stripExpandMarker(parseWeiboRich(source));
  }

  /** 正文分段：优先用拉到（或 Service 里已缓存）的全文，没有再回落截断正文。 */
  private postSegments(currentPost: WeiboPost): RichSegment[] {
    if (this.longTextRaw.length > 0) {
      return stripExpandMarker(parseWeiboRich(this.longTextRaw));
    }
    return this.richSegments(currentPost.rawText, currentPost.text);
  }

  /** 转发原文分段：同上。 */
  private repostSegments(repost: WeiboPost): RichSegment[] {
    if (this.repostLongTextRaw.length > 0) {
      return stripExpandMarker(parseWeiboRich(this.repostLongTextRaw));
    }
    return this.richSegments(repost.rawText, repost.text);
  }

  /** 正文里的 @用户名：压一层用户主页进导航栈。 */
  private openMention(uid: string, name: string): void {
    const userId: string = uid.trim();
    if (userId.length === 0) {
      return;
    }
    const param: MentionRouteParam = { userId: userId, userName: name.trim() };
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  /** #话题#：本页在导航栈里，拿不到首页那个回调，改用 AppStorage 信号通知宿主导航页。 */
  private openTopic(topic: string): void {
    requestTopicSearch(topic);
  }

  /** 网页链接：交系统浏览器（见 common/ExternalLink）。 */
  private openLink(url: string): void {
    openExternalUrl(this.getUIContext(), url);
  }

  private async loadComments(append: boolean = false): Promise<void> {
    if (this.postId.length === 0 || (append && (this.commentsLoading || !this.commentsHasMore))) { return; }
    const revision: number = ++this.commentsRevision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    const pageNumber: number = append ? this.commentsPage + 1 : 1;
    this.commentsLoading = true;
    try {
      const page = await WeiboService.getInstance().fetchComments(this.postId, pageNumber);
      if (revision !== this.commentsRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      const ids: Set<string> = new Set();
      const combined: WeiboComment[] = append ? this.comments.concat(page.items) : page.items;
      const next: WeiboComment[] = combined.filter((comment: WeiboComment): boolean => {
        if (!comment.id || ids.has(comment.id)) { return false; } ids.add(comment.id); return true;
      });
      this.commentsHasMore = page.hasMore && (!append || next.length > this.comments.length);
      this.commentsPage = pageNumber; this.comments = next;
    } catch (error) {
      if (revision !== this.commentsRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
    } finally {
      if (revision === this.commentsRevision && session === WeiboAuthManager.getInstance().getGeneration()) { this.commentsLoading = false; }
    }
  }

  private async toggleLike(): Promise<void> {
    if (this.post === null) {
      return;
    }
    const source: WeiboPost = this.post;
    const liked: boolean = !source.isLiked;
    const revision: number = this.viewRevision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    try {
      await WeiboService.getInstance().setLike(source.id, liked);
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      const updated: WeiboPost = PostEntities.shared().apply(source);
      this.post = updated;
      WeiboService.getInstance().rememberPost(updated);
      this.getUIContext().getPromptAction().showToast({
        message: liked ? $r('app.string.weibo_like_success') : $r('app.string.weibo_unlike_success')
      });
    } catch (error) {
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      const message: string = (error as Error).message ?? '微博操作失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private sharePost(): void {
    if (this.post === null) {
      return;
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareUtil.shareLink(this.getUIContext(), context, `https://m.weibo.cn/detail/${this.post.id}`,
      this.post.userName, this.post.text);
  }

  /** Mobile link sent when the user performs HarmonyOS' one-grab-one-release gesture. */
  private postShareUrl(post: WeiboPost): string {
    return `https://m.weibo.cn/detail/${post.id}`;
  }

  /** Register only while this detail is visible so another page can own the same system gesture. */
  private registerGesturesShare(): void {
    if (this.gestureShareListening || !canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      return;
    }
    try {
      harmonyShare.on('gesturesShare', this.gesturesShareCallback);
      this.gestureShareListening = true;
    } catch {
      this.gestureShareListening = false;
    }
  }

  private unregisterGesturesShare(): void {
    if (!this.gestureShareListening) {
      return;
    }
    try {
      harmonyShare.off('gesturesShare', this.gesturesShareCallback);
    } catch {
      // The page is leaving; discarding the local registration state is safe.
    }
    this.gestureShareListening = false;
  }

  private createGestureShareData(post: WeiboPost, thumbnailUri: string): systemShare.SharedData {
    if (thumbnailUri.length > 0) {
      return new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: this.postShareUrl(post),
        thumbnailUri: thumbnailUri,
        title: post.userName + ' 的微博',
        description: post.text
      });
    }
    return new systemShare.SharedData({
      utd: utd.UniformDataType.HYPERLINK,
      content: this.postShareUrl(post),
      title: post.userName + ' 的微博',
      description: post.text
    });
  }

  private async captureGestureSharePreview(post: WeiboPost): Promise<string> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const previewPath: string = context.filesDir + '/weibo-gesture-share-' + post.id + '.png';
    try {
      const pixelMap: image.PixelMap = await this.getUIContext().getComponentSnapshot().createFromBuilder(
        (): void => {
          this.GestureSharePreview();
        }, 0, true, { scale: 1, waitUntilRenderFinished: true });
      const packer: image.ImagePacker = image.createImagePacker();
      const data: ArrayBuffer = await packer.packToData(pixelMap, { format: 'image/png', quality: 100 });
      const file: fileIo.File = fileIo.openSync(previewPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        fileIo.writeSync(file.fd, data);
      } finally {
        fileIo.closeSync(file.fd);
      }
      return fileUri.getUriFromPath(previewPath);
    } catch {
      return '';
    }
  }

  private async prepareGestureSharePreview(): Promise<void> {
    const currentPost: WeiboPost | null = this.post;
    if (currentPost === null) {
      return;
    }
    const contentKey: string = this.gestureSharePreviewKey(currentPost);
    if (this.gestureSharePreviewPostId === currentPost.id && this.gestureSharePreviewContentKey === contentKey) {
      return;
    }
    const previewUri: string = await this.captureGestureSharePreview(currentPost);
    if (this.post !== null && this.post.id === currentPost.id &&
      this.gestureSharePreviewKey(this.post) === contentKey) {
      this.gestureSharePreviewPostId = currentPost.id;
      this.gestureSharePreviewUri = previewUri;
      this.gestureSharePreviewContentKey = contentKey;
    }
  }

  private gestureSharePreviewKey(post: WeiboPost): string {
    const mediaUrl: string = post.pictures.length > 0 ? post.pictures[0] : post.videoCoverUrl;
    return `${post.id}|${post.userName}|${post.userAvatar}|${post.text}|${post.createdAt}|${post.source}|` +
      `${post.repostCount}|${post.commentCount}|${post.likeCount}|${mediaUrl}`;
  }

  private async sharePostByGesture(target: harmonyShare.SharableTarget): Promise<void> {
    const currentPost: WeiboPost | null = this.post;
    if (currentPost === null || this.gestureSharing) {
      return;
    }
    this.gestureSharing = true;
    try {
      if (this.gestureSharePreviewPostId !== currentPost.id ||
        this.gestureSharePreviewContentKey !== this.gestureSharePreviewKey(currentPost)) {
        await this.prepareGestureSharePreview();
      }
      const shareData: systemShare.SharedData = this.createGestureShareData(currentPost, this.gestureSharePreviewUri);
      await target.share(shareData);
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_gesture_share_failed') });
    }
    this.gestureSharing = false;
  }

  @Builder
  GestureSharePreview() {
    if (this.post !== null) {
      Column({ space: Spacing.sm }) {
        Row({ space: Spacing.sm }) {
          if (this.post.userAvatar.length > 0) {
            Image(this.post.userAvatar)
              .width(42)
              .height(42)
              .objectFit(ImageFit.Cover)
              .borderRadius(Radius.full)
              .clip(true)
          } else {
            Stack() {
              Text(this.post.userName.substring(0, 1))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .width(42)
            .height(42)
            .backgroundColor(Theme.brand())
            .borderRadius(Radius.full)
            .alignContent(Alignment.Center)
          }
          Column({ space: 2 }) {
            Text(this.post.userName)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.post.createdAt}${this.post.source.length > 0 ? ' · ' + this.post.source : ''}`)
              .fontSize(12)
              .fontColor(Theme.textSecondary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        RichTextView({
          segments: this.richSegments(this.post.rawText, this.post.text),
          isDark: this.isDark,
          fontSize: 16,
          lineHeight: 24,
          maxLines: 5,
          fontScale: this.fontScale,
          onMentionTap: (uid: string, name: string): void => { this.openMention(uid, name); },
          onTopicTap: (topic: string): void => { this.openTopic(topic); },
          onLinkTap: (url: string): void => { this.openLink(url); }
        })
          .width('100%')
        if (this.post.pictures.length > 0) {
          Image(this.post.pictures[0])
            .width('100%')
            .height(148)
            .objectFit(ImageFit.Cover)
            .borderRadius(Radius.md)
        } else if (this.post.videoCoverUrl.length > 0) {
          Image(this.post.videoCoverUrl)
            .width('100%')
            .height(148)
            .objectFit(ImageFit.Cover)
            .borderRadius(Radius.md)
        }
        Row({ space: Spacing.md }) {
          Text($r('app.string.weibo_gesture_share_reposts'))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.isDark))
          Text(`${this.post.repostCount}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text($r('app.string.weibo_gesture_share_comments'))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.isDark))
          Text(`${this.post.commentCount}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text($r('app.string.weibo_gesture_share_likes'))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.isDark))
          Text(`${this.post.likeCount}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width('100%')
        Text(this.postShareUrl(this.post))
          .width('100%')
          .fontSize(11)
          .fontColor(Theme.brand())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(320)
      .padding(Spacing.lg)
      .backgroundColor(Theme.bgCard(this.isDark))
      .border({ width: 1, color: Theme.manualGlassBorder() })
      .borderRadius(Radius.postCard)
    }
  }

  private async sendComment(): Promise<void> {
    if (this.commentSending || this.commentDraft.trim().length === 0 || this.postId.length === 0) {
      return;
    }
    this.commentSending = true;
    const revision: number = this.viewRevision;
    const session: number = WeiboAuthManager.getInstance().getGeneration();
    try {
      await WeiboService.getInstance().publishComment(this.postId, this.commentDraft);
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      this.commentDraft = '';
      await this.loadComments();
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_comment_success') });
    } catch (error) {
      if (revision !== this.viewRevision || session !== WeiboAuthManager.getInstance().getGeneration()) { return; }
      const message: string = (error as Error).message ?? '评论发送失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      if (revision === this.viewRevision && session === WeiboAuthManager.getInstance().getGeneration()) { this.commentSending = false; }
    }
  }

  private visiblePictureCount(pictures: string[]): number {
    return pictures.length > 9 ? 9 : pictures.length;
  }

  private pictureColumns(pictures: string[]): number {
    const count: number = this.visiblePictureCount(pictures);
    return count === 2 || count === 4 ? 2 : 3;
  }

  private pictureCellHeight(pictures: string[]): number {
    const count: number = this.visiblePictureCount(pictures);
    return count === 2 || count === 4 ? 150 : 106;
  }

  private pictureGridHeight(pictures: string[]): number {
    const count: number = this.visiblePictureCount(pictures);
    const columns: number = this.pictureColumns(pictures);
    const rows: number = Math.ceil(count / columns);
    return rows * this.pictureCellHeight(pictures) + (rows - 1) * Spacing.sm;
  }

  private openImagePreview(urls: string[], index: number): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ImagePreview',
      params: { urls: urls, index: index }
    }).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '原图预览打开失败，请稍后重试' });
    });
  }

  @Builder
  DetailTitleBar() {
    Column() {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .accessibilityText($r('app.string.weibo_back'))
        .onClick((): void => { this.popRoute(); })
        Text($r('app.string.weibo_post_detail_title'))
          .layoutWeight(1)
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .textAlign(TextAlign.Center)
        Button() {
          SymbolGlyph($r('sys.symbol.share'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(20, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .accessibilityText($r('app.string.weibo_share'))
        .onClick(() => { this.sharePost(); })
      }
      .width('100%')
      .height(64)
      .padding({ left: Spacing.lg, right: Spacing.lg })
    }
    .width('100%')
  }

  @Builder
  PictureGrid(pictures: string[]) {
    PictureGallery({ pictures: pictures, isDark: this.isDark,
      onPictureTap: (index: number): void => { this.openImagePreview(pictures, index); } })
  }

  /** 该帖是否同时带图和视频，且图不超过混排上限。 */
  private useMixedMediaLayout(post: WeiboPost): boolean {
    return post.videoUrl.length > 0
      && post.pictures.length > 0
      && post.pictures.length <= MIXED_MEDIA_MAX_PICTURES;
  }

  @Builder
  VideoPlayer(currentPost: WeiboPost) {
    if (currentPost.videoUrl.length > 0) {
      InlineVideo({ url: currentPost.videoUrl, cover: currentPost.videoCoverUrl })
    }
  }

  @Builder
  RepostCard(repost: WeiboPost) {
    Column({ space: Spacing.sm }) {
      Row({ space: 4 }) {
        Text($r('app.string.weibo_repost_label'))
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary(this.isDark))
        Text(`· @${repost.userName}`)
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      RichTextView({
        segments: this.repostSegments(repost),
        isDark: this.isDark,
        fontSize: 14,
        lineHeight: 21,
        fontScale: this.fontScale,
        onMentionTap: (uid: string, name: string): void => { this.openMention(uid, name); },
        onTopicTap: (topic: string): void => { this.openTopic(topic); },
        onLinkTap: (url: string): void => { this.openLink(url); }
      })
        .width('100%')
      if (repost.isLongText === true && this.repostLongTextRaw.length === 0) {
        Button('查看转发原文').onClick((): void => { this.openLink(this.postShareUrl(repost)); }, 8)
      }
      if (repost.videoUrl.length > 0 && this.post?.videoUrl !== repost.videoUrl) {
        this.VideoPlayer(repost)
      }
      if (repost.pictures.length > 0) {
        // 详情与预览使用高清档；缓存里无该字段的旧记录回退列表档
        this.PictureGrid(repost.previewPictures ?? repost.pictures)
      }
    }
    .width('100%')
    .padding(Spacing.md)
    .backgroundColor(Theme.brandBg(this.isDark))
    .borderRadius(Radius.md)
  }

  @Builder
  PostBody(currentPost: WeiboPost) {
    Column({ space: Spacing.md }) {
      Row({ space: Spacing.sm }) {
        if (currentPost.userAvatar.length > 0) {
          Image(currentPost.userAvatar)
            .width(44)
            .height(44)
            .borderRadius(Radius.full)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text(currentPost.userName.substring(0, 1))
              .fontSize(fs(17, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.brand())
          }
          .width(44)
          .height(44)
          .backgroundColor(Theme.brandBg(this.isDark))
          .borderRadius(Radius.full)
          .alignContent(Alignment.Center)
        }
        Column({ space: 2 }) {
          Text(currentPost.userName)
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(`${currentPost.createdAt}${currentPost.source.length > 0 ? ' · ' + currentPost.source : ''}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      RichTextView({
        segments: this.postSegments(currentPost),
        isDark: this.isDark,
        fontSize: 17,
        lineHeight: 27,
        fontScale: this.fontScale,
        onMentionTap: (uid: string, name: string): void => { this.openMention(uid, name); },
        onTopicTap: (topic: string): void => { this.openTopic(topic); },
        onLinkTap: (url: string): void => { this.openLink(url); }
      })
        .width('100%')
      if (currentPost.isLongText === true && this.longTextRaw.length === 0) {
        Button('查看微博原文').onClick((): void => { this.openLink(this.postShareUrl(currentPost)); }, 8)
      }
      // 图文混排帖（同时有图有视频）走「等宽正方形并排」，与信息流卡片同一套几何。
      // 图超过 MIXED_MEDIA_MAX_PICTURES 张时不做混排：三列网格放不下，硬塞会藏图。
      if (this.useMixedMediaLayout(currentPost)) {
        MixedMediaTiles({
          pictures: currentPost.pictures,
          videoUrl: currentPost.videoUrl,
          videoCoverUrl: currentPost.videoCoverUrl,
          isDark: this.isDark,
          fontScale: this.fontScale,
          onPictureTap: (index: number): void => {
            this.openImagePreview(currentPost.previewPictures ?? currentPost.pictures, index);
          }
        })
      } else {
        this.VideoPlayer(currentPost)
        if (currentPost.pictures.length > 0) {
          // 详情与预览使用高清档；缓存里无该字段的旧记录回退列表档
          this.PictureGrid(currentPost.previewPictures ?? currentPost.pictures)
        }
      }
      if (currentPost.repost !== null) {
        this.RepostCard(currentPost.repost)
      }
      Row({ space: Spacing.md }) {
        Text(`转发 ${currentPost.repostCount}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
        Text(`评论 ${currentPost.commentCount}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(`${currentPost.isLiked ? '♥' : '♡'} ${currentPost.likeCount}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .layoutWeight(1)
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
  CommentsSection() {
    Column({ space: Spacing.md }) {
      if (this.commentsHasMore && this.comments.length > 0) {
        Button(this.commentsLoading ? '正在加载评论' : '加载更多评论')
          .enabled(!this.commentsLoading)
          .onClick((): void => { this.loadComments(true); })
      }
      Text($r('app.string.weibo_post_comments_title'))
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .width('100%')
      if (this.commentsLoading && this.comments.length === 0) {
        Row({ space: Spacing.sm }) {
          LoadingProgress().width(18).height(18)
          Text($r('app.string.weibo_comments_loading'))
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
      } else if (this.comments.length === 0) {
        Text($r('app.string.weibo_no_comments'))
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      } else {
        ForEach(this.comments, (comment: WeiboComment): void => {
          Row({ space: Spacing.sm }) {
            if (comment.userAvatar.length > 0) {
              Image(comment.userAvatar)
                .width(34)
                .height(34)
                .borderRadius(Radius.full)
                .objectFit(ImageFit.Cover)
            }
            Column({ space: 3 }) {
              Row() {
                Text(comment.userName)
                  .fontSize(fs(13, this.fontScale))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.textPrimary(this.isDark))
                  .layoutWeight(1)
                Text(`${comment.likeCount}`)
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .width('100%')
              RichTextView({
                segments: this.richSegments(comment.rawText, comment.text),
                isDark: this.isDark,
                fontSize: 14,
                lineHeight: 21,
                fontScale: this.fontScale,
                onMentionTap: (uid: string, name: string): void => { this.openMention(uid, name); },
                onTopicTap: (topic: string): void => { this.openTopic(topic); },
                onLinkTap: (url: string): void => { this.openLink(url); }
              })
                .width('100%')
              Text(comment.createdAt)
                .fontSize(fs(11, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: Spacing.sm, bottom: Spacing.md })
          .border({ width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })
        }, (comment: WeiboComment): string => comment.id)
      }
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
    .margin({ top: Spacing.md })
  }

  @Builder
  CommentAvatar() {
    if (this.accountAvatarUrl.length > 0) {
      Image(this.accountAvatarUrl)
        .width(40)
        .height(40)
        .objectFit(ImageFit.Cover)
        .borderRadius(20)
        .clip(true)
    } else if (this.accountName.length > 0) {
      Text(this.accountName.substring(0, 1).toUpperCase())
        .width(40)
        .height(40)
        .fontSize(fs(16, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor(Theme.brand())
        .borderRadius(20)
        .textAlign(TextAlign.Center)
    } else {
      SymbolGlyph($r('sys.symbol.person'))
        .width(40)
        .height(40)
        .fontSize(fs(20, this.fontScale))
        .fontColor([$r('sys.color.icon_primary')])
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .borderRadius(20)
    }
  }

  private capsuleMaterial(materialEnabled: boolean): uiMaterial.Material | undefined {
    if (!materialEnabled) {
      return undefined;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (!MaterialManager.isSupported()) {
        return undefined;
      }
      try {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true,
          applyShadow: false,
          colorInvert: true,
          lightEffect: { color: Theme.brand() }
        });
      } catch (e) {
        return undefined;
      }
    }
    return undefined;
  }

  private controlMaterial(materialEnabled: boolean): uiMaterial.Material | undefined {
    if (!materialEnabled) {
      return undefined;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (!MaterialManager.isSupported()) {
        return undefined;
      }
      try {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          interactive: true,
          applyShadow: false,
          colorInvert: true,
          lightEffect: { color: Theme.brand() }
        });
      } catch (e) {
        return undefined;
      }
    }
    return undefined;
  }

  @Builder
  CommentAvatarButton(materialEnabled: boolean) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      this.CommentAvatar()
    }
    .width(42)
    .height(42)
    .padding(1)
    .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
    .borderRadius(21)
    .clip(true)
    .systemMaterial(this.controlMaterial(materialEnabled))
  }

  @Builder
  CommentToolButton(symbol: Resource, materialEnabled: boolean) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(symbol)
        .fontSize(fs(22, this.fontScale))
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(42)
    .height(42)
    .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
    .borderRadius(21)
    .clip(true)
    .systemMaterial(this.controlMaterial(materialEnabled))
  }

  @Builder
  CommentComposerContent(materialEnabled: boolean) {
    Row({ space: 6 }) {
      this.CommentAvatarButton(materialEnabled)
      TextInput({ text: this.commentDraft, placeholder: $r('app.string.weibo_comment_placeholder') })
        .layoutWeight(1)
        .height(48)
        .fontSize(fs(17, this.fontScale))
        .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
        .fontColor(Theme.textPrimary(this.isDark))
        .placeholderColor(Theme.textSecondary(this.isDark))
        .borderRadius(Radius.full)
        .clip(true)
        .padding({ left: Spacing.md, right: Spacing.md })
        .onChange((value: string): void => { this.commentDraft = value; })
        .systemMaterial(this.controlMaterial(materialEnabled))
      this.CommentToolButton($r('sys.symbol.picture'), materialEnabled)
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.paperplane_fill'))
          .fontSize(fs(21, this.fontScale))
          .fontColor([this.commentDraft.trim().length > 0 && !this.commentSending
            ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_primary')])
      }
      .width(42)
      .height(42)
      .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
      .borderRadius(21)
      .clip(true)
      .enabled(this.commentDraft.trim().length > 0 && !this.commentSending)
      .accessibilityText($r('app.string.weibo_send_comment'))
      .onClick(() => { this.sendComment(); })
      .systemMaterial(this.controlMaterial(materialEnabled))
    }
    .width('100%')
    .height(64)
    .padding({ left: 10, right: 8 })
    .borderRadius(32)
    .clip(true)
    .backgroundColor(materialEnabled ? Color.Transparent : Theme.bgCard(this.isDark))
    .border({ width: materialEnabled ? 0 : 1, color: Theme.manualGlassBorder() })
    .systemMaterial(this.capsuleMaterial(materialEnabled))
  }

  /** HDS floating tab bar is HarmonyX's reply-composer capsule shell. */
  @Builder
  CommentComposerCapsule() {
    // HDS 悬浮栏和其 systemMaterialEffect 从 6.1.0(23) 即可用；
    // 不要将它错误地与 API 26 的 ArkUI uiMaterial 绑在一起。
    if (deviceInfo.apiAvailable('6.1.0(23)')) {
      HdsTabs() {
        TabContent() {
        }
        .tabBar(this.CommentComposerContent(true))
      }
      .scrollable(false)
      .barPosition(BarPosition.End)
      .barMode(BarMode.Fixed)
      .barHeight('100%')
      .barWidth('100%')
      .barFloatingStyle({
        lightColor: Theme.brand(),
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        thermoCtrl: true
      })
      .width('100%')
      .height(64)
    } else {
      this.CommentComposerContent(false)
    }
  }

  @Builder
  BottomComposer() {
    Column() {
      this.CommentComposerCapsule()
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: this.navigationIndicatorHeight + 12 })
  }

  @Builder
  DetailContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.detailScroller) {
        Column() {
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
                .onClick(() => { this.loadPost(); })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 120 })
          } else if (this.post !== null) {
            Column() {
              this.PostBody(this.post)
              this.CommentsSection()
            }
            .width('100%')
            .opacity(this.contentOpacity)
            .translate({ y: this.contentTranslateY })
            .scale({ x: this.contentScale, y: this.contentScale })
            .renderGroup(true)
          }
        }
        .width('100%')
        .padding({
          left: 12,
          right: 12,
          top: this.statusBarHeight + 64,
          bottom: this.navigationIndicatorHeight + 92
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      if (this.post !== null && !this.loading) {
        this.BottomComposer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
  }

  build() {
    HdsNavDestination() {
      this.DetailContent()
    }
    .onHidden((): void => { AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, ''); })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(true)
    .onBackPressed((): boolean => {
      this.popRoute();
      return true;
    })
    .bindToScrollable([this.detailScroller])
    .titleBar({
      avoidLayoutSafeArea: true,
      content: {
        stackBuilder: (): void => this.DetailTitleBar(),
        divider: { showType: DividerShowType.OFF }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .backgroundColor(Theme.bg(this.isDark))
  }
}
