import { rcp } from '@kit.RemoteCommunicationKit';
import { imageFromWeiboPage, parseWeiboLink, targetFromWeiboPage, shortlinkPageRedirect, WeiboLinkTarget } from '../domain/WeiboLink';

/**
 * 需要打开落地页才知道去哪的链接类型。
 *
 * `post` 平时不进这里（地址里已经有帖子 ID，直接开详情最快）；只有当锚点文字在说
 * 「查看图片」时才多花一次请求去落地页取配图，取不到仍然回落到帖子详情。
 */
function needsLandingPage(target: WeiboLinkTarget, wantsImage: boolean): boolean {
  if (['short', 'video', 'name', 'page'].includes(target.kind)) { return true; }
  return wantsImage && target.kind === 'post';
}

/** Public link resolution uses a disposable session without account credentials. */
export async function resolveWeiboLink(input: string, wantsImage: boolean = false): Promise<WeiboLinkTarget> {
  let target: WeiboLinkTarget = parseWeiboLink(input);
  if (target.kind === 'image' || !needsLandingPage(target, wantsImage)) { return target; }
  const session: rcp.Session = rcp.createSession({ requestConfiguration: {
    transfer: { autoRedirect: false, timeout: { connectMs: 5000, transferMs: 8000 } }
  } });
  const visited: string[] = [];
  try {
    for (let count: number = 0; count < 5; count++) {
      if (visited.includes(target.url)) { break; }
      visited.push(target.url);
      const response: rcp.Response = await session.fetch(new rcp.Request(target.url, 'GET'));
      if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
        let location: string = response.headers.location ?? '';
        if (location.length === 0) { break; }
        if (location.startsWith('/') && !location.startsWith('//')) {
          const origin: RegExpExecArray | null = /^https:\/\/[^/]+/.exec(target.url);
          if (origin === null) { break; }
          location = origin[0] + location;
        }
        target = parseWeiboLink(location);
        // Reclassify every redirect, never fetch an outside destination with this client.
        if (!needsLandingPage(target, wantsImage)) { return target; }
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        const html: string = (await response.toString() ?? '').substring(0, 1000000);
        // 先判中转页，再取配图。`meta refresh` 的过渡页自己也有 og:image（常是站方 logo、
        // 商品图或分享卡片图），先取图会把「看图片」的意图钉死在中转页上，永远走不到正文。
        if (target.kind === 'short') {
          const destination: string = shortlinkPageRedirect(html);
          if (destination.length > 0) {
            target = parseWeiboLink(destination);
            if (!needsLandingPage(target, wantsImage)) { return target; }
            continue;
          }
        }
        // 走到这里才是真正的落地页：文字锚点在要图时，og:image 就是用户想看的那张。
        if (wantsImage) {
          const picture: string = imageFromWeiboPage(html);
          if (picture.length > 0) { return { kind: 'image', id: '', url: picture }; }
        }
        return targetFromWeiboPage(html, target);
      }
      break;
    }
  } catch (_) { /* The caller offers the original page as a fallback. */ }
  finally { session.close(); }
  return target;
}
