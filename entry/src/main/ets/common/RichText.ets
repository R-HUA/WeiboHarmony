/*
 * 微博正文富文本解析。
 *
 * 微博接口的 `text` 字段是 HTML：
 *   @用户名  -> <a href="https://weibo.com/u/1234567890">@某人</a>
 *   #话题#   -> <a href="https://s.weibo.com/weibo?q=%23话题%23">#话题#</a>
 *   网页链接 -> <a href="https://weibo.com/ttarticle/p/show?id=...">网页链接</a>
 *   表情     -> <span class="url-icon"><img alt="[笑cry]" src="https://...png"></span>
 *
 * 之前在 Mapper 里用 stripHtml 一刀切，把 href 与表情 <img> 全丢掉了：链接只剩
 * 「网页链接」四个字且点不开、表情直接消失。这里保留结构，产出分段交给
 * RichTextView 按段落样式渲染（@/话题/链接=品牌色可点击，表情=行内图片）。
 */

import { decodeHtmlEntities } from './Constants';

export enum RichKind {
  Text = 0,
  Mention = 1,
  Topic = 2,
  Link = 3,
  Emoji = 4,
  /** 长文正文末尾的「展开」。由列表卡片自己追加，点击后原地拉全文，不是接口给的正文。 */
  Expand = 5,
}

export interface RichSegment {
  kind: RichKind;
  /** 展示文本；表情为 alt 文本（如 [笑cry]），图片不可用时作为兜底文案。 */
  text: string;
  /** Mention: 用户 uid；Topic: 话题词（不含 # 号）；Link: 目标地址。 */
  target: string;
  /** 表情图片地址。 */
  imageUrl: string;
}

/** 零宽字符/软连字符是微博插入的排版噪声，直接清掉避免出现空段。 */
const INVISIBLE_CHARS: RegExp = /[\u200b-\u200d\ufeff\u00ad]/g;
const LINK_AT: RegExp = /^<a\b([^>]*)>([\s\S]*?)<\/a>/i;
const IMG_AT: RegExp = /^<img\b([^>]*?)\/?>/i;
const NEXT_SPECIAL: RegExp = /<a\b|<img\b/gi;
const ANY_TAG: RegExp = /<[^>]+>/g;
const PLAIN_URL: RegExp = /https?:\/\/[^\s\u4e00-\u9fa5，。；：！？、）】》"'<>]+/g;
const URL_TAIL_TRIM: RegExp = /[.,;:!?)\]]+$/;

function attrValue(attrs: string, name: string): string {
  const pattern: RegExp = new RegExp(`${name}\\s*=\\s*("([^"]*)"|'([^']*)')`, 'i');
  const matched: RegExpExecArray | null = pattern.exec(attrs);
  if (matched === null) {
    return '';
  }
  const doubleQuoted: string | undefined = matched[2];
  if (doubleQuoted !== undefined) {
    return decodeHtmlEntities(doubleQuoted).trim();
  }
  const singleQuoted: string | undefined = matched[3];
  return singleQuoted === undefined ? '' : decodeHtmlEntities(singleQuoted).trim();
}

/** 把一段 HTML 片段压成纯文本：保留换行、去标签、解码实体。 */
function plainText(raw: string): string {
  const withBreaks: string = raw.replace(/<br\s*\/?>/gi, '\n');
  const noTags: string = withBreaks.replace(ANY_TAG, '');
  return decodeHtmlEntities(noTags).replace(INVISIBLE_CHARS, '');
}

function uidFromHref(href: string): string {
  let matched: RegExpExecArray | null = /\/u\/(\d+)/.exec(href);
  if (matched !== null) {
    return matched[1];
  }
  matched = /[?&]uid=(\d+)/i.exec(href);
  if (matched !== null) {
    return matched[1];
  }
  matched = /sinaweibo:\/\/userinfo\?uid=(\d+)/i.exec(href);
  return matched === null ? '' : matched[1];
}

function isTopicAnchor(href: string, inner: string): boolean {
  if (inner.length >= 3 && inner.startsWith('#') && inner.endsWith('#')) {
    return true;
  }
  return /s\.weibo\.com\/(?:weibo|k)/i.test(href) || /%23/i.test(href);
}

/** 话题词：去掉首尾 # 与常见装饰后缀。 */
function topicKeyword(inner: string): string {
  const trimmed: string = inner.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('#') && trimmed.endsWith('#')) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

function normaliseUrl(href: string): string {
  const value: string = href.trim();
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  return value;
}

function pushText(out: RichSegment[], raw: string): void {
  const text: string = plainText(raw);
  if (text.length === 0) {
    return;
  }
  // 纯文本里裸露的 http(s) 链接近年微博很少出现，但缓存/第三方渲染结果里会有，一并识别
  PLAIN_URL.lastIndex = 0;
  let cursor: number = 0;
  let matched: RegExpExecArray | null = PLAIN_URL.exec(text);
  while (matched !== null) {
    const start: number = matched.index;
    if (start > cursor) {
      appendText(out, text.substring(cursor, start));
    }
    const url: string = matched[0].replace(URL_TAIL_TRIM, '');
    appendLink(out, url, url);
    cursor = start + matched[0].length;
    matched = PLAIN_URL.exec(text);
  }
  if (cursor < text.length) {
    appendText(out, text.substring(cursor));
  }
}

function appendText(out: RichSegment[], text: string): void {
  if (text.length === 0) {
    return;
  }
  const last: RichSegment | undefined = out.length > 0 ? out[out.length - 1] : undefined;
  if (last !== undefined && last.kind === RichKind.Text) {
    last.text = last.text + text;
    return;
  }
  out.push({ kind: RichKind.Text, text: text, target: '', imageUrl: '' });
}

function appendLink(out: RichSegment[], text: string, url: string): void {
  if (text.length === 0) {
    return;
  }
  const last: RichSegment | undefined = out.length > 0 ? out[out.length - 1] : undefined;
  if (last !== undefined && last.kind === RichKind.Link && last.target === url) {
    last.text = last.text + text;
    return;
  }
  out.push({ kind: RichKind.Link, text: text, target: url, imageUrl: '' });
}

function findNextSpecial(source: string, from: number): number {
  NEXT_SPECIAL.lastIndex = from;
  const matched: RegExpExecArray | null = NEXT_SPECIAL.exec(source);
  return matched === null ? -1 : matched.index;
}

/** 解析一个 @ 或 <img>，返回其消耗的字符数；无法识别返回 0。 */
function consumeSpecial(source: string, at: number, out: RichSegment[]): number {
  const rest: string = source.substring(at);
  const anchor: RegExpExecArray | null = LINK_AT.exec(rest);
  if (anchor !== null) {
    const attrs: string = anchor[1];
    const inner: string = plainText(anchor[2]);
    const href: string = attrValue(attrs, 'href');
    if (inner.length === 0) {
      return anchor[0].length;
    }
    if (href.length === 0) {
      appendText(out, inner);
      return anchor[0].length;
    }
    const uid: string = uidFromHref(href);
    if (uid.length > 0) {
      out.push({ kind: RichKind.Mention, text: inner, target: uid, imageUrl: '' });
      return anchor[0].length;
    }
    if (isTopicAnchor(href, inner)) {
      out.push({ kind: RichKind.Topic, text: inner, target: topicKeyword(inner), imageUrl: '' });
      return anchor[0].length;
    }
    if (/^https?:/i.test(href) || href.startsWith('//')) {
      appendLink(out, inner, normaliseUrl(href));
      return anchor[0].length;
    }
    appendText(out, inner);
    return anchor[0].length;
  }
  const image: RegExpExecArray | null = IMG_AT.exec(rest);
  if (image !== null) {
    const attrs: string = image[1];
    const alt: string = attrValue(attrs, 'alt');
    const src: string = attrValue(attrs, 'src');
    const isEmoji: boolean = /(?:^|[?&/])(?:face|emoticon|url-icon)|sinaimg\.cn\/m\/emoticon/i.test(src)
      || (alt.startsWith('[') && alt.endsWith(']'));
    if (src.length > 0 && isEmoji) {
      out.push({ kind: RichKind.Emoji, text: alt, target: '', imageUrl: src });
    } else if (alt.length > 0) {
      appendText(out, alt);
    }
    return image[0].length;
  }
  return 0;
}

/**
 * 微博正文 HTML -> 分段。
 *
 * 入参也允许是纯文本（缓存里可能是 text_raw 的结果），此时退化为
 * 「一个文本段 + 裸露链接识别」。
 */
export function parseWeiboRich(input: string | undefined): RichSegment[] {
  const out: RichSegment[] = [];
  const source: string = input === undefined ? '' : input;
  if (source.length === 0) {
    return out;
  }
  let index: number = 0;
  while (index < source.length) {
    const at: number = findNextSpecial(source, index);
    if (at < 0) {
      pushText(out, source.substring(index));
      break;
    }
    if (at > index) {
      pushText(out, source.substring(index, at));
    }
    const consumed: number = consumeSpecial(source, at, out);
    if (consumed <= 0) {
      // 认不出的标签按单字符推进，避免死循环
      pushText(out, source.charAt(at));
      index = at + 1;
      continue;
    }
    index = at + consumed;
  }
  return out;
}

/** 去掉 @/# 等标记，得到纯文本形态（用于兜底、分享文案等）。 */
export function richToPlainText(segments: RichSegment[]): string {
  let text: string = '';
  for (let index: number = 0; index < segments.length; index++) {
    const segment: RichSegment = segments[index];
    if (segment.kind === RichKind.Expand) {
      continue;
    }
    text = text + segment.text;
  }
  return text;
}

/**
 * 长文帖在列表接口里只返回截断到约 140 字的 HTML，末尾自带一个「展开 / 全文」标记：
 * 移动端接口给 `全文`，桌面端关注流给 `展开`。**它不是正文**——正文要继续调
 * `/statuses/extend` 才有。这里把标记摘掉，免得卡片上留一个点不动的假按钮。
 *
 * 标记可能被包成 `<a>`（解析后是 Link 段），也可能直接拼在文本尾部，
 * 所以两处都要处理；顺带抹掉它前面那个省略号。
 */
const EXPAND_MARKERS: string[] = ['...展开', '…展开', '展开', '...全文', '…全文', '全文', '收起', '...收起'];
const TRAILING_ELLIPSIS: RegExp = /(?:\.{2,}|…)\s*$/;

export function stripExpandMarker(segments: RichSegment[]): RichSegment[] {
  const result: RichSegment[] = [];
  for (let index: number = 0; index < segments.length; index++) {
    result.push({ kind: segments[index].kind, text: segments[index].text, target: segments[index].target, imageUrl: segments[index].imageUrl });
  }
  while (result.length > 0) {
    const last: RichSegment = result[result.length - 1];
    // 纯标记段（Link(展开) / Text(展开)）整段丢掉
    if (isExpandMarkerText(last.text)) {
      result.pop();
      continue;
    }
    // 标记拼在正文尾巴上的情况：只摘尾巴
    const trimmed: string = last.text.replace(TRAILING_ELLIPSIS, '');
    const marker: string = matchedExpandSuffix(trimmed);
    if (marker.length > 0) {
      last.text = trimmed.substring(0, trimmed.length - marker.length).replace(TRAILING_ELLIPSIS, '');
      if (last.text.length === 0) {
        result.pop();
      }
      continue;
    }
    break;
  }
  return result;
}

function isExpandMarkerText(text: string): boolean {
  const trimmed: string = text.trim();
  for (let index: number = 0; index < EXPAND_MARKERS.length; index++) {
    if (trimmed === EXPAND_MARKERS[index]) {
      return true;
    }
  }
  return false;
}

/** 返回 `text` 结尾命中的标记（最长的那个），没命中返回空串。 */
function matchedExpandSuffix(text: string): string {
  let best: string = '';
  for (let index: number = 0; index < EXPAND_MARKERS.length; index++) {
    const marker: string = EXPAND_MARKERS[index];
    if (text.length > marker.length && text.endsWith(marker) && marker.length > best.length) {
      best = marker;
    }
  }
  return best;
}

/**
 * 在正文末尾追加可点的「展开」，交给卡片点击后拉全文。
 *
 * `target` 放**要展开哪条帖的 postId**：转发原文也可能被截断，它的「展开」要拉的是
 * 原帖的全文而不是当前帖的，所以不能只有一个无参的「展开」回调。
 */
export function appendExpandAction(segments: RichSegment[], target: string = ''): RichSegment[] {
  const result: RichSegment[] = stripExpandMarker(segments);
  // 与上文之间留个省略号，观感同官方
  result.push({ kind: RichKind.Text, text: '...', target: '', imageUrl: '' });
  result.push({ kind: RichKind.Expand, text: '展开', target: target, imageUrl: '' });
  return result;
}
