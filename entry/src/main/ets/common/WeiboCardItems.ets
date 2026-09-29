/*
 * WeiboPost -> ThreadItemData 的唯一映射点。
 *
 * 首页信息流、搜索结果、用户主页三处原本各写了一份 toThreadCard，改一处漏两处；
 * 正文富文本、转发引述块、发帖设备这几处口径必须完全一致，所以统一收在这里。
 */

import { WeiboPost } from '../model/WeiboModel';
import { RichKind, RichSegment, appendExpandAction, parseWeiboRich, stripExpandMarker } from './RichText';
import { ThreadItemData } from '../components/CommonComponents';

/**
 * 微博正文 HTML -> 可点击分段。
 *
 * `rawText` 是接口原样返回的 HTML（Mapper 里刻意保留），`text` 是 stripHtml 后的纯文本。
 * 优先用 rawText 才能还原 @/话题/链接/表情；缓存里缺 rawText 时退化为纯文本，
 * 至少正文还能读、裸链还能被识别出来。
 */
export function toWeiboRichSegments(raw: string | undefined, fallback: string): RichSegment[] {
  const source: string = raw !== undefined && raw.length > 0 ? raw : fallback;
  return parseWeiboRich(source);
}

/** 转发原文按官方样式拼成「@原作者：原文」，交给引述块渲染。 */
export function toWeiboRepostSegments(repost: WeiboPost): RichSegment[] {
  const head: RichSegment[] = [];
  if (repost.userName.length > 0) {
    head.push({ kind: RichKind.Mention, text: `@${repost.userName}`, target: repost.userId, imageUrl: '' });
    head.push({ kind: RichKind.Text, text: '：', target: '', imageUrl: '' });
  }
  return head.concat(toWeiboRichSegments(repost.rawText, repost.text));
}

/** 发帖设备文案：「来自 iPhone 14 Pro Max」；无来源返回空串。 */
export function toWeiboDeviceLabel(source: string): string {
  const value: string = source.trim();
  return value.length > 0 ? `来自 ${value}` : '';
}

export function buildWeiboThreadItem(post: WeiboPost): ThreadItemData {
  const firstImage: string = post.pictures.length > 0 ? post.pictures[0] : '';
  const titleText: string = post.text.length > 0 ? post.text : post.userName;
  const body: RichSegment[] = toWeiboRichSegments(post.rawText, post.text);
  const repost: WeiboPost | null = post.repost;
  const repostBody: RichSegment[] = repost === null ? [] : toWeiboRepostSegments(repost);
  const device: string = toWeiboDeviceLabel(post.source ?? '');
  // 长文帖：列表接口只给截断正文 + 一个「展开」标记。标记摘掉，换成我们自己的可点「展开」，
  // 点击时才去拉全文（列表里预取会把几十条长文一次性打满）。
  const isLongText: boolean = post.isLongText === true;
  const displayBody: RichSegment[] = isLongText ? appendExpandAction(body, post.id) : stripExpandMarker(body);
  // 转发原文同样会被接口截断，末尾那个「展开」也是标记而不是正文：
  // 不处理的话它会以 Link 段渲染出来，点一下直接跳浏览器（实测）。
  const repostLong: boolean = repost !== null && repost.isLongText === true;
  const displayRepost: RichSegment[] = repostBody.length === 0
    ? repostBody
    : (repostLong ? appendExpandAction(repostBody, repost!.id) : stripExpandMarker(repostBody));
  // 转发原文的媒体，图与视频要**分开判定**（真机实测 2026-09-28）：
  //   · 图：桌面接口不会把转发原文的图挂到当前帖上——否则列表里早就显示了，
  //     所以有图就补渲染，不会被重复。
  //   · 视频：接口会把转发原文的视频同时挂到当前帖上（同一条视频会出现两次），
  //     所以只有在当前帖自己没有视频时才补渲染。
  const repostPictures: string[] = repost === null ? [] : repost.pictures;
  const repostVideoUrl: string = repost !== null && post.videoUrl.length === 0 ? repost.videoUrl : '';
  const repostVideoCover: string = repostVideoUrl.length > 0 && repost !== null ? repost.videoCoverUrl : '';
  return {
    tid: post.id,
    postId: post.id,
    forumId: '',
    title: titleText,
    // 微博没有「吧名」这个概念。以前这里放的是发帖设备（post.source），
    // 结果设备名被渲染在卡片左下角——那个位置在贴吧结构里是「所属吧」，语义完全不同。
    forumName: '',
    forumAvatar: '',
    author: post.userName,
    authorId: post.userId,
    authorAvatar: post.userAvatar,
    replyNum: post.commentCount,
    likeCount: post.likeCount,
    isLiked: post.isLiked,
    abstract: repost === null ? '' : repost.text,
    firstImage: firstImage,
    images: post.pictures,
    videoUrl: post.videoUrl,
    videoCoverUrl: post.videoCoverUrl,
    createTime: post.createdAt,
    isTop: false,
    isGood: false,
    isLongText: isLongText,
    // 转发原文的长文信息：卡片点它的「展开」时要拉原帖全文
    repostId: repost === null ? undefined : repost.id,
    repostLongText: repostLong,
    previewImages: post.previewPictures ?? post.pictures,
    repostImages: repostPictures.length > 0 ? repostPictures : undefined,
    repostPreviewImages: repostPictures.length > 0 && repost !== null
      ? (repost.previewPictures ?? repost.pictures)
      : undefined,
    repostVideoUrl: repostVideoUrl.length > 0 ? repostVideoUrl : undefined,
    repostVideoCoverUrl: repostVideoCover.length > 0 ? repostVideoCover : undefined,
    richText: displayBody.length > 0 ? displayBody : undefined,
    richRepost: displayRepost.length > 0 ? displayRepost : undefined,
    // 设备名改到作者名右侧的时间行（官方即「5小时前 来自 iPhone 14 Pro Max」）
    deviceLabel: device.length > 0 ? device : undefined,
  };
}
