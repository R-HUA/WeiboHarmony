import { UIContext } from '@kit.ArkUI';
import { resolveWeiboLink } from '../service/WeiboLinkResolver';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { openExternalUrl } from './ExternalLink';
import { requestTopicSearch } from './TopicRequest';
import { ACTIVE_FEED_VIDEO_KEY } from './Constants';
import { syncWeiboSplitNavigation } from './WeiboNavigationLayout';
import { WeiboLinkTarget } from '../domain/WeiboLink';
interface LinkPostParam { postId: string; }
interface LinkUserParam { userId: string; userName: string; }
let revision: number = 0;
/** Latest tap wins; a late resolver must not navigate after logout or a route change. */
export async function openWeiboLink(ui: UIContext, stack: NavPathStack, url: string): Promise<void> {
  const current: number = ++revision;
  const generation: number = WeiboAuthManager.getInstance().getGeneration();
  const paths: string = stack.getAllPathName().join('|');
  const target: WeiboLinkTarget = await resolveWeiboLink(url);
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
  } else if (target.kind !== 'unsupported') {
    openExternalUrl(ui, target.url);
  } else {
    ui.getPromptAction().showToast({ message: '暂不支持此链接' });
  }
}
