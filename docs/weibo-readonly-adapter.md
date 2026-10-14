# 微博数据与交互适配层

核对日期：2026-10-14。本文记录当前微博入口使用的登录、数据读取和用户互动链路；文件名沿用历史路径，适配层已包含写操作。

## 实现组成

| 模块 | 职责 |
| --- | --- |
| `pages/WeiboLogin.ets`、`service/WeiboAuthManager.ets` | 可见内嵌登录页、网页登录会话读取、账号校验及退出 |
| `service/CredentialVault.ets` | HUKS AES-256-GCM 加密保存账号会话；迁移旧本地凭据 |
| `service/WeiboVisitorSession.ets`、`components/WeiboVisitorBootstrap.ets` | 无痕 ArkWeb 建立访客会话，Cookie 仅存在进程内存 |
| `network/WeiboHttpClient.ets` | 微博移动端与桌面端请求、串行调度和最小 800ms 请求间隔；写请求优先 |
| `service/WeiboService.ets`、`api/WeiboDtos.ets`、`api/WeiboMapper.ets` | 接口请求及响应映射，转换为页面模型 |
| `store/FeedStore.ets`、`store/SearchStore.ets`、`store/WeiboCommentsStore.ets` | 信息流、搜索、评论分页与异步状态 |
| `pages/WeiboPostDetail.ets`、`components/WeiboCommentThread.ets` | 原帖、互动列表、评论排序、嵌套回复与评论操作 |
| `pages/WeiboHotSearch.ets`、`pages/WeiboTopicContent.ets` | 分类榜单及独立专题内容页 |

页面通过内部模型展示内容，不直接依赖上游原始 JSON。信息流快照和阅读位置按账户保存在加密阅读库；搜索查询及结果状态保留在内存。

## 登录与会话

1. 用户在内嵌的 `https://passport.weibo.com/` 登录页自行完成登录或验证，不需要手动粘贴 Cookie。
2. 登录页触发检测后，`WebCookieManager` 读取 `https://m.weibo.cn/` 和 `https://weibo.com/` 的 Cookie。
3. 使用移动站 Cookie 请求 `GET https://m.weibo.cn/api/config`，确认 `ok === 1`、`login === true` 及有效 UID；仅出现 `SUB` 字段不代表登录验证通过。
4. 成功后加密保存两域会话和 UID，更新页面账号状态。会话代次用于丢弃取消登录或退出后的迟到结果。
5. 登录态响应 Cookie 按域合并并节流持久化；访客响应及退出后的迟到响应不写入账号凭据。
6. 退出登录先使会话失效，再尝试清理账户阅读缓存，清除凭据及 Web Cookie；缓存清理失败有告警，不阻断后续凭据清理。

公开内容可使用访客访问；关注流、“我的”热搜分类及写操作需要账号。微博侧仍可能要求登录、验证码或限制公开访问。

## 当前接口

除另行标注外，移动站基址为 `https://m.weibo.cn`，桌面站基址为 `https://weibo.com`。

| 功能 | 请求 |
| --- | --- |
| 用户资料 | 移动站 `GET /api/container/getIndex?containerid=100505{uid}` |
| 用户动态 | 移动站 `GET /api/container/getIndex?containerid=230413{uid}&page={page}&count=20` |
| 推荐流 | 移动站 `GET /api/container/getIndex?containerid=102803&page={page}` |
| 关注流 | 桌面站 `GET /ajax/feed/friendstimeline?count=20&max_id={cursor}` |
| 搜索与专题内容 | 移动站 `GET /api/container/getIndex`，使用查询词对应的搜索容器及页码 |
| 评论与子回复 | 桌面站 `GET /ajax/statuses/buildComments`，使用微博或根评论 ID、排序参数及 `max_id` / `max_id_type` |
| 转发列表 | 桌面站 `GET /ajax/statuses/repostTimeline?id={id}&page={page}&count=20&moduleID=feed` |
| 赞列表 | 桌面站 `GET /ajax/statuses/likeShow?id={id}&page={page}&count=20&attitude_type=0&attitude_enable=1` |
| 搜索联想 | 桌面站 `GET /ajax/side/search?q={query}` |
| 点赞 / 取消点赞 | 桌面站 `POST /ajax/statuses/setLike` / `POST /ajax/statuses/destroyLike` |
| 评论 | 移动站 `POST /api/comments/create` |
| 评论回复 | 桌面站 `POST /ajax/comments/reply` |
| 评论转发 | 桌面站 `POST /ajax/statuses/normal_repost`，提交原帖 `id`、实际评论 `cid`、用户输入的 `comment` 及 `is_comment` |
| 关注 / 取关 | 桌面站 `POST /ajax/friendships/create` / `POST /ajax/friendships/destory`；取关路径拼写沿用上游 |

热搜分类分别请求以下桌面站接口：

| 分类 | 请求路径 | 登录要求 |
| --- | --- | --- |
| 综合 | `/ajax/side/hotSearch` | 可公开访问 |
| 科技 | `/ajax/statuses/technology` | 可公开访问 |
| 娱乐 | `/ajax/statuses/entertainment` | 可公开访问 |
| 生活 | `/ajax/statuses/life` | 可公开访问 |
| 社会 | `/ajax/statuses/social` | 可公开访问 |
| 体育 | `/ajax/statuses/sport` | 可公开访问 |
| 动漫 | `/ajax/statuses/acg` | 可公开访问 |
| 我的 | `/ajax/statuses/mineBand` | 需要当前桌面登录态 |

## 页面行为

- 详情互动区以“转发 / 评论 / 赞”切换实际列表，标题后以较小字号显示括号及总数；评论热门/最新排序位于右上角，采用服务端排序参数。
- 主评论与根评论子回复独立分页，按上游游标继续加载；详情和回复页滚动触发下一页，失败时提供重试。
- 从列表评论按钮打开详情时默认定位到评论区，原帖保留在上方。评论时间位于用户名下方；点击评论提供回复、转发和复制操作。
- 评论、回复与评论转发都在用户确认发送后提交；转发草稿取消时清理。点赞、取消点赞、关注和取关也由用户单次操作触发。
- 热搜点击进入独立专题内容页，保留查询与滚动状态；正文话题链接仍走站内搜索。
- 媒体映射支持 `mix_media_info.items`、`mixed_media_info.media_list` 及 `pic_infos`，列表和详情共用混排组件，按顺序展示图片与视频。

## 请求与验证边界

写请求携带相应微博域的登录会话、同源 Origin 和所需令牌。既有写链路在 HTTP 403 时使用更新后的 Cookie 重发一次；业务拒绝、验证码或限流不因此循环重试。读写能力均不包含自动、定时或批量互动，系统分享通过系统面板交接。

这些网页接口不是微博公开承诺稳定的第三方 API，返回结构、访问要求及参数可改变。当前路径以工程实现为准；离线解析和状态测试、ArkTS 构建通过不能证明真实账号线上读写成功。HUKS、WebCookieManager、界面滚动及真实互动仍需分别在设备上验证。

数据保存和系统交接范围见 [隐私政策](PRIVACY.md)，发布前验证见 [发布清单](RELEASE_CHECKLIST.md)。
