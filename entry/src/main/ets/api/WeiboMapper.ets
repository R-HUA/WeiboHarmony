import { formatWeiboTime, stripHtml } from '../common/Constants';
import { WeiboUser, WeiboPost, WeiboComment } from '../model/WeiboModel';
import { WeiboApiResponse, WeiboStatusApiResponse, WeiboConfigResponse, WeiboConfigData, WeiboFollowingTimelineResponse, WeiboResponseData, WeiboHotTopicJson, WeiboSuggestionJson, WeiboCardJson, WeiboUserJson, WeiboPictureJson, WeiboPictureSizeJson, WeiboDesktopPicJson, WeiboMixedMediaJson, WeiboVideoUrlsJson, WeiboVideoMediaInfoJson, WeiboPagePictureJson, WeiboPageInfoJson, WeiboPostJson, WeiboCommentJson } from './WeiboDtos';

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
  /**
   * 列表档改写：微博图床（*.sinaimg.cn）的路径尺寸段可替换为任意档位，
   * 统一改写为 wap720 中图。原图档（orj1080/large 可达数 MB）在信息流弱网下
   * 加载超时失败率高，是实机"图片不显示"的直接原因；同一 hash 的各尺寸共享
   * 同一文件，仅缩放不同。非微博图床域名原样返回。
   */
  private static listPicture(url: string): string {
    // 命中微博图床的 URL 统一输出 https，避免桌面端老响应的 http 明文图被网络策略拦截
    return url.replace(
      /^https?:\/\/([^\/]*\.sinaimg\.cn\/)(large|largest|mw2000|original|orj1080|bmiddle|wap360|wap720|thumbnail|square)(\/.+)$/i,
      'https://$1wap720$3');
  }
  /** 按两档收集一张图：高清档留原始地址，列表档改写为 wap720。 */
  private static collectPicture(url: string, pictures: string[], previewPictures: string[]): void {
    if (url.length === 0) { return; }
    previewPictures.push(url);
    pictures.push(WeiboMapper.listPicture(url));
  }
  /** 桌面端关注流的单图字典项：多档中取最高画质地址。 */
  private static desktopPicUrl(pic: WeiboDesktopPicJson | undefined): string {
    if (pic === undefined) { return ''; }
    return WeiboMapper.firstUrl([pic.original?.url, pic.largest?.url, pic.mw2000?.url, pic.large?.url, pic.bmiddle?.url, pic.thumbnail?.url]);
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
    const previewPictures: string[] = [];
    const pictureSource: WeiboPictureJson[] = source.pics ?? [];
    for (let index: number = 0; index < pictureSource.length; index++) {
      const picture: WeiboPictureJson = pictureSource[index];
      // The mobile endpoint normally returns the original file in `original`.
      // Keep high-quality fallbacks for cards whose original field is omitted.
      const imageUrl: string = WeiboMapper.firstUrl([picture.original?.url, picture.largest?.url, picture.mw2000?.url, picture.large?.url, picture.url]);
      WeiboMapper.collectPicture(imageUrl, pictures, previewPictures);
    }
    // 桌面端关注流（friendstimeline）用两组独立字段承载图片：
    // 有序的 mixed_media_info 列表优先，无序的 pic_infos 字典兜底。
    if (pictures.length === 0) {
      const mediaList: WeiboMixedMediaJson[] = source.mixed_media_info?.media_list ?? [];
      for (let index: number = 0; index < mediaList.length; index++) {
        WeiboMapper.collectPicture(WeiboMapper.desktopPicUrl(mediaList[index].pic_info), pictures, previewPictures);
      }
    }
    if (pictures.length === 0) {
      const infos: Record<string, WeiboDesktopPicJson> = source.pic_infos ?? {};
      const keys: string[] = Object.keys(infos);
      for (let index: number = 0; index < keys.length; index++) {
        WeiboMapper.collectPicture(WeiboMapper.desktopPicUrl(infos[keys[index]]), pictures, previewPictures);
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
    // 视频封面：移动端在 page_pic / thumbnail_pic；桌面端关注流常缺失这两个字段，
    // 依次从 media_info.image、pic_info.pic_big、顶层 bmiddle_pic 兜底，避免黑色封面。
    const videoCoverUrl: string = WeiboMapper.listPicture(WeiboMapper.firstUrl([
      pageInfo?.page_pic?.url,
      mediaInfo?.image,
      pageInfo?.pic_info?.pic_big?.url,
      source.thumbnail_pic,
      source.bmiddle_pic,
    ]));
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
      previewPictures: previewPictures,
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
