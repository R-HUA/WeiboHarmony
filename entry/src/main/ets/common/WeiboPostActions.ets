import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { WeiboPost } from '../model/WeiboModel';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService } from '../service/WeiboService';
import { ShareUtil } from './ShareUtil';

export async function setWeiboPostLike(ui: UIContext, post: WeiboPost, liked: boolean): Promise<void> {
  const generation: number = WeiboAuthManager.getInstance().getGeneration();
  try { await WeiboService.getInstance().setLike(post.id, liked); }
  catch (error) {
    if (generation === WeiboAuthManager.getInstance().getGeneration()) {
      ui.getPromptAction().showToast({ message: (error as Error).message ?? '点赞操作失败' });
    }
  }
}

export function shareWeiboPost(ui: UIContext, post: WeiboPost): void {
  ShareUtil.shareLink(ui, ui.getHostContext() as common.UIAbilityContext,
    `https://m.weibo.cn/detail/${post.id}`, post.userName, post.text);
}
