import { formatWeiboTime, stripHtml } from '../common/Constants';
import { WeiboUser, WeiboPost, WeiboComment } from '../model/WeiboModel';
import { WeiboApiResponse, WeiboStatusApiResponse, WeiboConfigResponse, WeiboConfigData, WeiboFollowingTimelineResponse, WeiboResponseData, WeiboHotTopicJson, WeiboSuggestionJson, WeiboCardJson, WeiboUserJson, WeiboPictureJson, WeiboPictureSizeJson, WeiboDesktopPicJson, WeiboMixedMediaJson, WeiboMixedMediaInfoJson, WeiboMixedMediaVideoJson, WeiboMixMediaItemJson, WeiboMixMediaDataJson, WeiboMixMediaInfoJson, WeiboMixMediaVideoJson, WeiboVideoUrlsJson, WeiboVideoMediaInfoJson, WeiboPagePictureJson, WeiboPageInfoJson, WeiboPostJson, WeiboCommentJson, WeiboLongTextData, WeiboLongTextResponse } from './WeiboDtos';

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
    if (url.length === 0 || pictures.indexOf(WeiboMapper.listPicture(url)) >= 0) { return; }
    previewPictures.push(url);
    pictures.push(WeiboMapper.listPicture(url));
  }
  /** 桌面端关注流的单图字典项：多档中取最高画质地址。 */
  private static desktopPicUrl(pic: WeiboDesktopPicJson | undefined): string {
    if (pic === undefined) { return ''; }
    return WeiboMapper.firstUrl([pic.original?.url, pic.largest?.url, pic.mw2000?.url, pic.large?.url, pic.bmiddle?.url, pic.thumbnail?.url]);
  }

  /** 该 mix 项是否为视频：type 与 data.object_type 任一命中即算（抓包两者都为 video）。 */
  private static isMixVideoItem(item: WeiboMixMediaItemJson): boolean {
    return item.type === 'video' || (item.data !== undefined && item.data.object_type === 'video');
  }

  /** mix_media_info 里第一个视频项的 data。 */
  private static firstMixVideoData(info: WeiboMixMediaInfoJson | undefined): WeiboMixMediaDataJson | undefined {
    const items: WeiboMixMediaItemJson[] = info?.items ?? [];
    for (let index: number = 0; index < items.length; index++) {
      if (WeiboMapper.isMixVideoItem(items[index])) {
        return items[index].data;
      }
    }
    return undefined;
  }

  /** mix 视频项的封面：字段名各端不一致，按可靠度依次兜底。 */
  private static mixVideoCover(data: WeiboMixMediaDataJson | undefined): string {
    if (data === undefined) { return ''; }
    return WeiboMapper.firstUrl([
      // 抓包：mix 视频项里 page_pic 是**字符串**（不是 {url} 对象），两种形态都要收
      typeof data.page_pic === 'string' ? data.page_pic : undefined,
      data.page_info?.page_pic?.url,
      data.page_info?.pic_info?.pic_big?.url,
      data.pic_info?.pic_big?.url,
      data.pic_info?.pic_small?.url,
      data.pic_big?.url,
      data.cover_image?.url,
      data.cover_image_url,
      data.image,
      data.original?.url,
      data.largest?.url,
      data.mw2000?.url,
      data.large?.url,
      data.bmiddle?.url,
      data.thumbnail?.url,
    ]);
  }

  /** mix 视频项的播放信息 -> 与 page_info 那套统一的内部结构，后续逻辑只认一种。 */
  private static toVideoMediaInfo(video: WeiboMixMediaVideoJson): WeiboVideoMediaInfoJson {
    const result: WeiboVideoMediaInfoJson = {};
    result.stream_url_hd = video.stream_url_hd;
    result.stream_url = video.stream_url ?? video.mp4_hd_url;
    result.mp4_hd_mp4 = video.mp4_hd_url;
    result.mp4_720p_mp4 = video.mp4_sd_url;
    return result;
  }

  /** 从图文混排列表里挑出视频项；没有视频返回 undefined。 */
  private static firstMixedVideo(info: WeiboMixedMediaInfoJson | undefined): WeiboMixedMediaVideoJson | undefined {
    const list: WeiboMixedMediaJson[] = info?.media_list ?? [];
    for (let index: number = 0; index < list.length; index++) {
      const item: WeiboMixedMediaJson = list[index];
      if (item.video_info !== undefined) {
        return item.video_info;
      }
    }
    return undefined;
  }

  /** 长文全文 HTML；三个字段都为空说明这次没拿到全文。 */
  static longTextContent(response: WeiboLongTextResponse): string {
    const data: WeiboLongTextData | undefined = response.data;
    if (data === undefined) { return ''; }
    return WeiboMapper.firstUrl([data.longTextContent, data.text, data.content]);
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
    // 桌面端关注流（friendstimeline）用三组独立字段承载媒体：
    //   ① mix_media_info.items[]——**真实字段名，没有 "ed"**，图文混排/视频混排帖全部挂这里；
    //   ② mixed_media_info.media_list[]——另一套拼法，接口不同版本会换；
    //   ③ pic_infos 字典——无序，最后兜底。
    const mixItems: WeiboMixMediaItemJson[] = source.mix_media_info?.items ?? [];
    for (let index: number = 0; index < mixItems.length; index++) {
      const mixData: WeiboMixMediaDataJson | undefined = mixItems[index].data;
      // 视频项没有图片尺寸档，直接跳过（它的地址在下面视频那一段取）
      if (mixData === undefined || WeiboMapper.isMixVideoItem(mixItems[index])) {
        continue;
      }
      WeiboMapper.collectPicture(WeiboMapper.desktopPicUrl(mixData), pictures, previewPictures);
    }
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
    // 视频地址三条来源，按可靠度排：
    //   ① mix_media_info 的视频项（关注流里「图 + 视频并排」的帖子只在这里给地址，
    //      page_info 整个不存在——2026-09-28 抓包确认）；
    //   ② page_info（移动端容器 / 单视频帖）；
    //   ③ 老拼法 mixed_media_info.media_list 的 video_info。
    const mixVideo: WeiboMixMediaDataJson | undefined = WeiboMapper.firstMixVideoData(source.mix_media_info);
    const mixedVideo: WeiboMixedMediaVideoJson | undefined = WeiboMapper.firstMixedVideo(source.mixed_media_info);
    const mixMediaInfo: WeiboMixMediaVideoJson | undefined = mixVideo?.media_info;
    const mediaInfo: WeiboVideoMediaInfoJson | undefined =
      (mixMediaInfo === undefined ? undefined : WeiboMapper.toVideoMediaInfo(mixMediaInfo))
        ?? pageInfo?.media_info
        ?? mixedVideo?.media_info;
    const videoUrls: WeiboVideoUrlsJson | undefined = pageInfo?.urls ?? mixedVideo?.urls;
    const videoUrl: string = WeiboMapper.firstUrl([
      mediaInfo?.stream_url_hd, mediaInfo?.stream_url,
      videoUrls?.mp4_1080p_60fps, videoUrls?.mp4_1080p_mp4, videoUrls?.mp4_hd_mp4,
      mediaInfo?.mp4_hd_mp4, videoUrls?.mp4_720p_mp4, mediaInfo?.mp4_720p_mp4,
      videoUrls?.mp4_sd_mp4, videoUrls?.mp4_ld_mp4, source.video_url
    ]);
    // 视频封面：移动端在 page_pic / thumbnail_pic；桌面端关注流常缺失这两个字段，
    // 依次从 media_info.image、pic_info.pic_big、顶层 bmiddle_pic 兜底，避免黑色封面。
    const videoCoverUrl: string = WeiboMapper.listPicture(WeiboMapper.firstUrl([
      WeiboMapper.mixVideoCover(mixVideo),
      pageInfo?.page_pic?.url,
      mixedVideo?.page_pic?.url,
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
      // 保留原始 HTML：@用户名/#话题#/链接/表情的标签结构只能从这里还原
      rawText: source.text ?? '',
      createdAt: formatWeiboTime(source.created_at ?? ''),
      likeCount: source.like_count ?? 0,
    };
  }
}
