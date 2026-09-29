import { WeiboPost } from '../model/WeiboModel';

/** The same original video can also be attached to its forwarding status. */
export function ownVideoUrl(post: WeiboPost): string {
  const repost: WeiboPost | null = post.repost;
  if (repost !== null && repost.videoUrl.length > 0 && post.videoUrl.length > 0) {
    const sameId: boolean = (post.videoId ?? '').length > 0 && post.videoId === repost.videoId;
    const sameStream: boolean = post.videoUrl === repost.videoUrl;
    if (sameId || sameStream) { return ''; }
  }
  return post.videoUrl;
}
