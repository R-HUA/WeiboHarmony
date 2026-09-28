import { formatWeiboTime, stripHtml } from '../common/Constants';
import { WeiboUser, WeiboPost, WeiboComment } from '../model/WeiboModel';
import { WeiboApiResponse, WeiboStatusApiResponse, WeiboConfigResponse, WeiboConfigData, WeiboFollowingTimelineResponse, WeiboResponseData, WeiboHotTopicJson, WeiboSuggestionJson, WeiboCardJson, WeiboUserJson, WeiboPictureJson, WeiboPictureSizeJson, WeiboVideoUrlsJson, WeiboVideoMediaInfoJson, WeiboPagePictureJson, WeiboPageInfoJson, WeiboPostJson, WeiboCommentJson } from './WeiboDtos';

export class WeiboMapper {
  private static id(value: string | number | undefined): string {
    if (typeof value === 'string') { return value; }
    return typeof value === 'number' && Number.isSafeInteger(value) ? String(value) : '';
  }
  private static timestamp(value: string): number | null {
    // Relative strings such as “刚刚” are deliberately not interpreted as exact timestamps.
    if (!/[0-9]{4}/.test(value)) { return null; }
    const time: number = Date.parse(value);
    return Number.isFinite(time) ? time : null;
  }
  private static firstUrl(values: Array<string | undefined>): string {
    for (const value of values) { if (value !== undefined && value.trim().length > 0) { return value; } }
    return '';
  }
  static toUser(source: WeiboUserJson): WeiboUser {
    const hdAvatar: string = source.avatar_hd?.trim() ?? '';
    const avatar: string = hdAvatar.length > 0 ? hdAvatar : (source.profile_image_url?.trim() ?? '');
    const rawId: string | number | undefined = source.id;
    const rawFollowersCount: string | number | undefined = source.followers_count;
    const rawFollowingCount: string | number | undefined = source.follow_count;
    const rawStatusesCount: string | number | undefined = source.statuses_count;
    const userId: string = source.idstr ?? WeiboMapper.id(rawId);
    const followersCount: string = rawFollowersCount === undefined ? '' : `${rawFollowersCount}`;
    const followingCount: number = rawFollowingCount === undefined ? 0 : Number(rawFollowingCount);
    const statusesCount: number = rawStatusesCount === undefined ? 0 : Number(rawStatusesCount);
    return {
      id: userId,
      screenName: source.screen_name ?? '',
      description: source.description ?? '',
      avatarUrl: avatar,
      coverUrl: source.cover_image_phone ?? '',
      followersCount: followersCount,
      followingCount: followingCount,
      statusesCount: statusesCount,
      verified: source.verified ?? false,
      verifiedReason: source.verified_reason ?? '',
    };
  }

  static toPost(source: WeiboPostJson): WeiboPost {
    const author: WeiboUser = WeiboMapper.toUser(source.user ?? {});
    const pictures: string[] = [];
    const pictureSource: WeiboPictureJson[] = source.pics ?? [];
    for (let index: number = 0; index < pictureSource.length; index++) {
      const picture: WeiboPictureJson = pictureSource[index];
      // The mobile endpoint normally returns the original file in `original`.
      // Keep high-quality fallbacks for cards whose original field is omitted.
      const imageUrl: string = WeiboMapper.firstUrl([picture.original?.url, picture.largest?.url, picture.mw2000?.url, picture.large?.url, picture.url]);
      if (imageUrl.length > 0) {
        pictures.push(imageUrl);
      }
    }
    const pageInfo: WeiboPageInfoJson | undefined = source.page_info;
    const mediaInfo: WeiboVideoMediaInfoJson | undefined = pageInfo?.media_info;
    const videoUrls: WeiboVideoUrlsJson | undefined = pageInfo?.urls;
    const videoUrl: string = mediaInfo?.stream_url_hd
      ?? mediaInfo?.stream_url
      ?? videoUrls?.mp4_1080p_60fps
      ?? videoUrls?.mp4_1080p_mp4
      ?? videoUrls?.mp4_hd_mp4
      ?? mediaInfo?.mp4_hd_mp4
      ?? videoUrls?.mp4_720p_mp4
      ?? mediaInfo?.mp4_720p_mp4
      ?? videoUrls?.mp4_sd_mp4
      ?? videoUrls?.mp4_ld_mp4
      ?? source.video_url
      ?? '';
    const videoCoverUrl: string = pageInfo?.page_pic?.url ?? source.thumbnail_pic ?? '';
    const repostSource: WeiboPostJson | undefined = source.retweeted_status;
    const rawPostId: string | number | undefined = source.id ?? source.mid;
    const postId: string = source.idstr ?? WeiboMapper.id(rawPostId);
    return {
      id: postId,
      userId: author.id,
      userName: author.screenName,
      userAvatar: author.avatarUrl,
      text: stripHtml(source.text ?? ''),
      rawText: source.text ?? '',
      rawCreatedAt: source.created_at ?? '',
      createdAtTimestamp: WeiboMapper.timestamp(source.created_at ?? ''),
      fetchedAt: Date.now(),
      isLongText: source.isLongText ?? false,
      pictures: pictures,
      videoUrl: videoUrl,
      videoCoverUrl: videoCoverUrl,
      createdAt: formatWeiboTime(source.created_at ?? ''),
      source: stripHtml(source.source ?? ''),
      likeCount: source.attitudes_count ?? 0,
      commentCount: source.comments_count ?? 0,
      repostCount: source.reposts_count ?? 0,
      isLiked: source.attitudes_status === 1,
      repost: repostSource === undefined ? null : WeiboMapper.toPost(repostSource),
    };
  }

  static toComment(source: WeiboCommentJson): WeiboComment {
    const author: WeiboUser = WeiboMapper.toUser(source.user ?? {});
    return {
      id: WeiboMapper.id(source.id),
      userId: author.id,
      userName: author.screenName,
      userAvatar: author.avatarUrl,
      text: stripHtml(source.text ?? ''),
      createdAt: formatWeiboTime(source.created_at ?? ''),
      likeCount: source.like_count ?? 0,
    };
  }
}
