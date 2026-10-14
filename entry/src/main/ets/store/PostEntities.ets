import { WeiboPost } from '../model/WeiboModel';
interface LikeState { liked: boolean; count: number; }
/** Session-scoped interaction source shared by every representation of a post. */
export class PostEntities {
  private static instance: PostEntities = new PostEntities();
  private posts: Map<string, WeiboPost> = new Map();
  private likes: Map<string, LikeState> = new Map();
  static shared(): PostEntities { return PostEntities.instance; }
  clear(): void { this.posts.clear(); this.likes.clear(); this.notify(); }
  adopt(post: WeiboPost): WeiboPost {
    const result: WeiboPost = this.apply(post);
    if (post.id.length > 0) { this.posts.set(post.id, result); }
    return result;
  }
  apply(post: WeiboPost): WeiboPost {
    const state: LikeState | undefined = this.likes.get(post.id);
    if (state === undefined) { return post; }
    return {
      rawText: post.rawText,
      rawCreatedAt: post.rawCreatedAt,
      createdAtTimestamp: post.createdAtTimestamp,
      fetchedAt: post.fetchedAt,
      isLongText: post.isLongText,
      id: post.id,
      userId: post.userId,
      userName: post.userName,
      userAvatar: post.userAvatar,
      text: post.text,
      pictures: post.pictures,
      previewPictures: post.previewPictures,
      videoUrl: post.videoUrl,
      videoId: post.videoId,
      videoCoverUrl: post.videoCoverUrl,
      createdAt: post.createdAt,
      source: post.source,
      likeCount: state.count,
      commentCount: post.commentCount,
      commentBulletinMode: post.commentBulletinMode,
      repostCount: post.repostCount,
      isLiked: state.liked,
      repost: post.repost
    };
  }
  confirmLike(id: string, liked: boolean): void {
    const post: WeiboPost | undefined = this.posts.get(id);
    if (post === undefined) { return; }
    const current: WeiboPost = this.apply(post);
    const delta: number = current.isLiked === liked ? 0 : (liked ? 1 : -1);
    this.likes.set(id, { liked: liked, count: Math.max(0, current.likeCount + delta) });
    this.posts.set(id, this.apply(post));
    this.notify();
  }
  private notify(): void {
    AppStorage.setOrCreate<number>('weiboPostTick', (AppStorage.get<number>('weiboPostTick') ?? 0) + 1);
  }
}
