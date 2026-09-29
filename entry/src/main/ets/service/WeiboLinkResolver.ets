import { rcp } from '@kit.RemoteCommunicationKit';
import { parseWeiboLink, targetFromWeiboPage, shortlinkPageRedirect, WeiboLinkTarget } from '../domain/WeiboLink';

/** Public link resolution uses a disposable session without account credentials. */
export async function resolveWeiboLink(input: string): Promise<WeiboLinkTarget> {
  let target: WeiboLinkTarget = parseWeiboLink(input);
  if (!['short', 'video', 'name', 'page'].includes(target.kind)) { return target; }
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
        if (!['short', 'video', 'name', 'page'].includes(target.kind)) { return target; }
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        const html: string = (await response.toString() ?? '').substring(0, 1000000);
        if (target.kind === 'short') {
          const destination: string = shortlinkPageRedirect(html);
          if (destination.length > 0) {
            target = parseWeiboLink(destination);
            if (!['short', 'video', 'name', 'page'].includes(target.kind)) { return target; }
            continue;
          }
        }
        return targetFromWeiboPage(html, target);
      }
      break;
    }
  } catch (_) { /* The caller offers the original page as a fallback. */ }
  finally { session.close(); }
  return target;
}
