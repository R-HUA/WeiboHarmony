/*
 * Weibo data models.
 *
 * These models intentionally describe only the fields consumed by the UI.  The
 * mobile endpoint may add fields at any time, so callers must treat omitted
 * fields as empty values.
 */

export interface WeiboUser {
  id: string;
  screenName: string;
  description: string;
  avatarUrl: string;
  coverUrl: string;
  followersCount: string;
  followingCount: number;
  statusesCount: number;
  verified: boolean;
  verifiedReason: string;
  /** Omitted means the server has not supplied a relationship state. */
  following?: boolean;
}

export interface WeiboPost {
  rawText?: string;
  rawCreatedAt?: string;
  createdAtTimestamp?: number | null;
  fetchedAt?: number;
  isLongText?: boolean;
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  text: string;
  /** 列表展示档：微博图床按路径尺寸段改写为 wap720 中图，避免原图过大加载失败。 */
  pictures: string[];
  /** 高清档：保留接口原始最高画质地址，供详情与原图预览使用。 */
  previewPictures?: string[];
  /** A directly playable MP4 stream supplied by the mobile status endpoint. */
  videoUrl: string;
  /** Stable media object identity when supplied by Weibo. */
  videoId?: string;
  /** Poster image for the video stream; used while the player is preparing. */
  videoCoverUrl: string;
  createdAt: string;
  source: string;
  likeCount: number;
  commentCount: number;
  /** 评论接口沿用原帖的精选评论模式，不凭空改变服务器规则。 */
  commentBulletinMode?: number;
  repostCount: number;
  isLiked: boolean;
  repost: WeiboPost | null;
}

/** One cursor-based page from the logged-in account's following feed. */
export interface WeiboTimelinePage {
  items: WeiboPost[];
  nextMaxId: string;
  hasMore: boolean;
}

export interface WeiboComment {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  text: string;
  /** 原始 HTML（含 @/话题/链接/表情标签），供富文本渲染；text 是它的纯文本降级。 */
  rawText?: string;
  createdAt: string;
  likeCount: number;
  /** 子回复刷新其所属根线程，主评论的根标识就是自身。 */
  rootId: string;
  replyTo: WeiboCommentTarget | null;
  replyCount: number;
  /** 首屏只预览两条，全部回复另行分页。 */
  replies: WeiboComment[];
}

/** 回复目标使用真实评论标识，昵称仅用于展示。 */
export interface WeiboCommentTarget {
  id: string;
  userId: string;
  userName: string;
}

/** 游标两部分必须一起传回服务器，不能用页码代替。 */
export interface WeiboCommentCursor {
  maxId: string;
  maxIdType: string;
}

/** 参数取服务器 filter_group，避免写死排序值。 */
export interface WeiboCommentFilter {
  order: 'hot' | 'latest';
  param: string;
  isDefault: boolean;
}

/** 缺失计数保留为空，避免用当前一页的长度伪造总数。 */
export interface WeiboCommentsPage {
  items: WeiboComment[];
  nextCursor: WeiboCommentCursor | null;
  totalCount?: number;
  filters: WeiboCommentFilter[];
}

/** 转发和赞列表只保留该区域展示所需的内容。 */
export interface WeiboInteraction {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  rawText: string;
  createdAt: string;
}

/** 转发按服务器最大页数结束，赞按实际加载数与总数结束。 */
export interface WeiboInteractionsPage {
  items: WeiboInteraction[];
  totalCount: number;
  maxPage?: number;
}

/** 与已确认的各分类榜单一一对应。 */
export enum WeiboHotCategory {
  Hot = 'hot',
  Tech = 'tech',
  Entertainment = 'entertainment',
  Life = 'life',
  Social = 'social',
  Sports = 'sports',
  Animation = 'animation',
  Mine = 'mine',
}

/** 展示标题与真实查询词独立保存，缺失热度和置顶名次保持为空。 */
export interface WeiboHotTopic {
  rank: number | null;
  word: string;
  heat: number | null;
  description: string;
  label: string;
  query: string;
}

/** A public query suggestion from Weibo's desktop search sidebar. */
export interface WeiboSuggestion {
  word: string;
  count: number;
  isHot: boolean;
}
