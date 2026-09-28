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
}

export interface WeiboPictureJson {
  url?: string;
  large?: WeiboPictureSizeJson;
  largest?: WeiboPictureSizeJson;
  mw2000?: WeiboPictureSizeJson;
  original?: WeiboPictureSizeJson;
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
}

export interface WeiboPagePictureJson {
  url?: string;
}

export interface WeiboPageInfoJson {
  type?: string;
  urls?: WeiboVideoUrlsJson;
  media_info?: WeiboVideoMediaInfoJson;
  page_pic?: WeiboPagePictureJson;
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
  page_info?: WeiboPageInfoJson;
  video_url?: string;
  thumbnail_pic?: string;
  retweeted_status?: WeiboPostJson;
}

export interface WeiboCommentJson {
  id?: string;
  text?: string;
  created_at?: string;
  like_count?: number;
  user?: WeiboUserJson;
}
