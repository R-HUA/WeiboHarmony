/*
 * 打开外部网页链接的统一入口。
 *
 * 原来 Settings.ets 里有一份私有实现，现在正文/评论里的「网页链接」也要用同一条路径，
 * 所以提出来共用。走 `startAbility(viewData)` 拉起系统浏览器，而不是内置 Web 组件——
 * 微博的正文链接会跳到各种域名，内置 Web 既拿不到登录态也拦不住跳转。
 */

import { common, Want } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';

/** 打开 http(s) 链接；失败时以 Toast 明确反馈，不静默失败。 */
export function openExternalUrl(uiContext: UIContext, url: string): void {
  const target: string = typeof url === 'string' ? url.trim() : '';
  if (target.length === 0) {
    return;
  }
  const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
  if (!context) {
    uiContext.getPromptAction().showToast({ message: '链接打开失败，请稍后重试' });
    return;
  }
  const want: Want = { uri: target, action: 'ohos.want.action.viewData', type: 'text/plain' };
  context.startAbility(want).catch((): void => {
    uiContext.getPromptAction().showToast({ message: '链接打开失败，请稍后重试' });
  });
}
