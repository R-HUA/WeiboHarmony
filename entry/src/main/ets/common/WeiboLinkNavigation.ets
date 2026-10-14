import { UIContext } from '@kit.ArkUI';
import { resolveWeiboLink } from '../service/WeiboLinkResolver';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { openExternalUrl } from './ExternalLink';
import { requestTopicSearch } from './TopicRequest';
import { ACTIVE_FEED_VIDEO_KEY } from './Constants';
import { syncWeiboSplitNavigation } from './WeiboNavigationLayout';
import { isImageViewText, WeiboLinkTarget } from '../domain/WeiboLink';
interface LinkPostParam { postId: string; }
interface LinkUserParam { userId: string; userName: string; }
let revision: number = 0;

/**
 * 原图浏览复用信息流点图同一个页面 `pages/ImagePreview`（缩放/切换/保存都在里面），
 * 不再为正文里的图片链接另写一个查看器。
 */
function openImagePreview(ui: UIContext, urls: string[], index: number): void {
  if (urls.length === 0) { return; }
  ui.getRouter().pushUrl({ url: 'pages/ImagePreview', params: { urls: urls, index: index } })
    .catch((): void => {
      ui.getPromptAction().showToast({ message: '图片预览打开失败，请稍后重试' });
    });
}

/**
 * Latest tap wins; a late resolver must not navigate after logout or a route change.
 *
 * `label` 是锚点的展示文字（如「查看图片」）：地址判断之外的第二条信号，
 * 有些接口版本只给文字锚点、href 指向微博页面，只在地址上判图会漏掉这类帖子。
 */
export async function openWeiboLink(ui: UIContext, stack: NavPathStack, url: string, label: string = ''): Promise<void> {
  const current: number = ++revision;
  const generation: number = WeiboAuthManager.getInstance().getGeneration();
  const paths: string = stack.getAllPathName().join('|');
  const target: WeiboLinkTarget = await resolveWeiboLink(url, isImageViewText(label));
  if (current !== revision || generation !== WeiboAuthManager.getInstance().getGeneration()
    || paths !== stack.getAllPathName().join('|')) { return; }
  if (target.kind === 'post' || target.kind === 'user') {
    AppStorage.setOrCreate<string>(ACTIVE_FEED_VIDEO_KEY, '');
    if (target.kind === 'post') {
      const param: LinkPostParam = { postId: target.id };
      stack.pushPath({ name: 'WeiboPostDetail', param: param });
    } else {
      const param: LinkUserParam = { userId: target.id, userName: '' };
      stack.pushPath({ name: 'WeiboUserProfile', param: param });
    }
    syncWeiboSplitNavigation(stack);
  } else if (target.kind === 'topic' || target.kind === 'name') {
    requestTopicSearch(target.id);
  } else if (target.kind === 'image') {
    // 图床直链在 App 内看图：交系统浏览器会被防盗链挡成 403（图床判定见 domain/WeiboLink）。
    openImagePreview(ui, [target.url], 0);
  } else if (target.kind !== 'unsupported') {
    openExternalUrl(ui, target.url);
  } else {
    ui.getPromptAction().showToast({ message: '暂不支持此链接' });
  }
}
