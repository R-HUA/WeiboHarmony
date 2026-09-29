export interface WeiboApiResponse {
  ok?: number;
  msg?: string;
  url?: string;
  data?: WeiboResponseData;
}

/** The mobile status endpoint returns a post directly in its data field. */
export interface WeiboStatusApiResponse {
  ok?: number;
  data?: WeiboPostJson;
}

/**
 * 长文全文接口的 data 段。
 *
 * `/statuses/extend`（移动端）实际返回 `longTextContent`；不同端/版本还见过
 * `text`、`content` 两种承载字段，一起接住，免得换接口就没内容。
 */
export interface WeiboLongTextData {
  longTextContent?: string;
  text?: string;
  content?: string;
}

/** 长文全文接口响应（`/statuses/extend` 与 `/ajax/statuses/longtext` 共用）。 */
export interface WeiboLongTextResponse {
  ok?: number;
  msg?: string;
  data?: WeiboLongTextData;
}

/** Authenticated mobile configuration exposes the UID for the current Cookie. */
export interface WeiboConfigResponse {
  ok?: number;
  msg?: string;
  data?: WeiboConfigData;
}

export interface WeiboConfigData {
  login?: boolean;
  uid?: string;
}

/** Desktop web's authenticated friends feed is not wrapped in a `data` object. */
export interface WeiboFollowingTimelineResponse {
  ok?: number;
  msg?: string;
  statuses?: WeiboPostJson[];
  max_id?: string | number;
}

export interface WeiboResponseData {
  cards?: WeiboCardJson[];
  userInfo?: WeiboUserJson;
  data?: WeiboCommentJson[];
  max_id?: string;
  realtime?: WeiboHotTopicJson[];
  hotquery?: WeiboSuggestionJson[];
}

export interface WeiboHotTopicJson {
  rank?: number;
  realpos?: number;
  word?: string;
  num?: number;
  label_name?: string;
  word_scheme?: string;
}

export interface WeiboSuggestionJson {
  suggestion?: string;
  count?: number;
  top_flag?: number;
}

export interface WeiboCardJson {
  card_type?: number;
  mblog?: WeiboPostJson;
  card_group?: WeiboCardJson[];
}

export interface WeiboUserJson {
  /** Weibo returns numeric IDs on some timeline surfaces and strings on others. */
  id?: string | number;
  idstr?: string;
  screen_name?: string;
  description?: string;
  avatar_hd?: string;
  profile_image_url?: string;
  cover_image_phone?: string;
  followers_count?: string | number;
  follow_count?: string | number;
  statuses_count?: string | number;
  verified?: boolean;
  verified_reason?: string;
  following?: boolean | number;
}

export interface WeiboPictureJson {
  url?: string;
  large?: WeiboPictureSizeJson;
  largest?: WeiboPictureSizeJson;
  mw2000?: WeiboPictureSizeJson;
  original?: WeiboPictureSizeJson;
}

/** 桌面端接口（关注流 friendstimeline）pic_infos 字典项：单图多档尺寸。 */
export interface WeiboDesktopPicJson {
  thumbnail?: WeiboPictureSizeJson;
  bmiddle?: WeiboPictureSizeJson;
  large?: WeiboPictureSizeJson;
  largest?: WeiboPictureSizeJson;
  mw2000?: WeiboPictureSizeJson;
  original?: WeiboPictureSizeJson;
}

/**
 * 图文混排里的视频项。桌面端把视频也放进 `mixed_media_info.media_list`（type = video）时，
 * 顶层的 `page_info` 可能整个缺失——它是这种情况下视频地址与封面的唯一来源。
 */
export interface WeiboMixedMediaVideoJson {
  media_info?: WeiboVideoMediaInfoJson;
  urls?: WeiboVideoUrlsJson;
  page_pic?: WeiboPagePictureJson;
}

/** 桌面端 mixed_media_info.media_list 列表项；图文混排时按顺序承载图与视频。 */
export interface WeiboMixedMediaJson {
  type?: string;
  pic_info?: WeiboDesktopPicJson;
  video_info?: WeiboMixedMediaVideoJson;
}

export interface WeiboMixedMediaInfoJson {
  media_list?: WeiboMixedMediaJson[];
}

/**
 * `mix_media_info.items[].data.media_info`：视频项的播放信息。
 * 注意这套字段名和 `page_info.urls` 那套不一样（这里是 stream_url / mp4_hd_url）。
 */
export interface WeiboMixMediaVideoJson {
  name?: string;
  format?: string;
  stream_url?: string;
  stream_url_hd?: string;
  mp4_hd_url?: string;
  mp4_sd_url?: string;
  h265_mp4_hd?: string;
  h265_mp4_ld?: string;
  /** 网页版播放地址，仅作兜底。 */
  h5_url?: string;
}

/**
 * `mix_media_info.items[].data`：**图片项**是尺寸档字典（与 pic_infos 同形），
 * **视频项**带 `object_type: "video"` 与 `media_info`。
 */
export interface WeiboMixMediaDataJson extends WeiboDesktopPicJson {
  /** 视频项为 "video"；图片项为 "pic"。 */
  object_type?: string;
  page_id?: string;
  object_id?: string;
  /** 960 档封面，图片项也有。 */
  largecover?: WeiboPictureSizeJson;
  /** 视频项的播放信息。 */
  media_info?: WeiboMixMediaVideoJson;
  /** 视频项内部还会再嵌一层 page_info（抓包：analysis_card=page_info），封面多半在这里。 */
  page_info?: WeiboPageInfoJson;
  pic_info?: WeiboPagePicInfoJson;
  /**
   * 视频封面。抓包确认 mix 视频项里 `page_pic` 直接是 URL 字符串（不是 {url} 对象）；
   * 别的端给对象，所以按 `string | 对象` 都声明。
   */
  page_pic?: string | WeiboPagePictureJson;
  pic_big?: WeiboPagePictureJson;
  cover_image?: WeiboPagePictureJson;
  cover_image_url?: string;
  image?: string;
  /** 视频时长（秒），用于角标。 */
  duration?: number;
  /** 视频项兜底地址。 */
  media_url?: string;
  default_media_url?: string;
}

/** `mix_media_info.items[]` 单项。 */
export interface WeiboMixMediaItemJson {
  type?: string;
  id?: string;
  data?: WeiboMixMediaDataJson;
}

/**
 * 桌面端 `mix_media_info`：items 有序承载图与视频。
 *
 * **字段名没有 "ed"**（真实抓包，2026-09-28）：关注流里图文混排/视频混排帖的媒体都挂在这里。
 * 服务端另有一套 `mixed_media_info.media_list` 拼法，两套都要认。
 */
export interface WeiboMixMediaInfoJson {
  items?: WeiboMixMediaItemJson[];
}

export interface WeiboPictureSizeJson {
  url?: string;
}

/** The video URL variants used by the mobile status API. */
export interface WeiboVideoUrlsJson {
  mp4_1080p_60fps?: string;
  mp4_1080p_mp4?: string;
  mp4_hd_mp4?: string;
  mp4_720p_mp4?: string;
  mp4_sd_mp4?: string;
  mp4_ld_mp4?: string;
}

export interface WeiboVideoMediaInfoJson {
  stream_url_hd?: string;
  stream_url?: string;
  stream_url_h5?: string;
  mp4_hd_mp4?: string;
  mp4_720p_mp4?: string;
  /** 桌面端部分版本把视频封面图放在 media_info.image。 */
  image?: string;
}

export interface WeiboPagePictureJson {
  url?: string;
}

/** 桌面端视频卡片的封面档位（pic_info.pic_big / pic_small）。 */
export interface WeiboPagePicInfoJson {
  pic_big?: WeiboPagePictureJson;
  pic_small?: WeiboPagePictureJson;
}

export interface WeiboPageInfoJson {
  object_id?: string;
  page_id?: string;
  type?: string;
  urls?: WeiboVideoUrlsJson;
  media_info?: WeiboVideoMediaInfoJson;
  page_pic?: WeiboPagePictureJson;
  pic_info?: WeiboPagePicInfoJson;
}

export interface WeiboPostJson {
  /** Desktop timelines may use numbers while mobile endpoints use strings. */
  id?: string | number;
  idstr?: string;
  mid?: string | number;
  text?: string;
  isLongText?: boolean;
  created_at?: string;
  source?: string;
  attitudes_count?: number;
  comments_count?: number;
  reposts_count?: number;
  attitudes_status?: number;
  user?: WeiboUserJson;
  pics?: WeiboPictureJson[];
  /** 桌面端关注流的图片字典；键为图片 ID，无序。 */
  pic_infos?: Record<string, WeiboDesktopPicJson>;
  /** 桌面端图文混排列表；有序，优先于 pic_infos 消费。 */
  mixed_media_info?: WeiboMixedMediaInfoJson;
  /**
   * 桌面端关注流的图文混排字段——**真实字段名是 `mix_media_info`，没有 "ed"**。
   * 服务端同时存在两种拼法，两边都要接。
   */
  mix_media_info?: WeiboMixMediaInfoJson;
  page_info?: WeiboPageInfoJson;
  video_url?: string;
  thumbnail_pic?: string;
  /** 桌面端 status 顶层的中间档图片地址，视频帖常以此作封面兜底。 */
  bmiddle_pic?: string;
  retweeted_status?: WeiboPostJson;
}

export interface WeiboCommentJson {
  id?: string;
  text?: string;
  created_at?: string;
  like_count?: number;
  user?: WeiboUserJson;
}
