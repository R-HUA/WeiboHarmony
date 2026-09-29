/*
 * 「检索某话题」的跨页面信号。
 *
 * 信息流首页有宿主回调，点 #话题# 可以直接切页签；但详情页、用户主页这些已经压在
 * Navigation 栈里的页面拿不到那个回调，只能走 AppStorage 通知宿主导航页。
 *
 * 之所以要带上自增序号：`@Watch` 只在值**变化**时触发，用户连着点同一个话题
 * （或先在别处搜过同一词）时纯文本值不变，宿主动作就会漏掉一次。
 */

import { TOPIC_REQUEST_KEY, TOPIC_REQUEST_TICK_KEY } from './Constants';

/** 请求宿主导航页切到搜索页并检索该话题。任何页面都可以调用。 */
export function requestTopicSearch(topic: string): void {
  const keyword: string = topic.trim();
  if (keyword.length === 0) {
    return;
  }
  const tick: number = (AppStorage.get<number>(TOPIC_REQUEST_TICK_KEY) ?? 0) + 1;
  AppStorage.setOrCreate<number>(TOPIC_REQUEST_TICK_KEY, tick);
  AppStorage.setOrCreate<string>(TOPIC_REQUEST_KEY, `${tick}|${keyword}`);
}

/** 从信号里取出话题词；格式不对或为空返回空串。 */
export function topicFromRequest(value: string): string {
  const separator: number = value.indexOf('|');
  if (separator < 0) {
    return '';
  }
  return value.substring(separator + 1).trim();
}
