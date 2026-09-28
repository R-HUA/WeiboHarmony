# WeiboHarmony 阶段性实现记录

基线：6ef9b2f636c4093df440c50bcbc009d1bbd99a4a。日期：2026-09-28。
远端：origin = R-HUA/WeiboHarmony；upstream = haohaoai0/WeiboPura。
本次是阶段性开发快照，阶段 0～5 均未宣告整体验收完成。

## 已实现

- 最低兼容版本与编译目标均为 API 26，保留 connectOnly 预连接。
- 清除构建配置中的个人签名材料；保留包名与 GPL 许可证、原作者署名。
- API 串行调度、写操作优先、会话代次取消、HTTPS 主机白名单；禁用自动重定向，避免凭据随重定向流出；移动站与桌面站请求头分开。
- 登录内部读取分域 Cookie，通过账号配置接口确认 login 和 UID；合并重复登录校验。
- HUKS AES-256-GCM 版本化凭据；旧 Cookie 本地迁移执行写入、读回解密校验、删除旧值。退出时先使运行时会话失效，清理凭据及 Web Cookie。
- 评论首页缓存带 TTL、失效代次和在途请求合并；发送后及结果未知时失效；同帖点赞互斥、共享互动实体同步。
- 首页刷新与分页的代次检查、ID 去重；详情评论分页；搜索分页、错误保留与竞态治理。
- 搜索完成 Page → 可观察 SearchStore → SearchRepository → 兼容服务闭环。DTO 与纯解析器拆出；保留原始文本、时间、长文标识，优先使用字符串 ID。
- ArkData ReaderDatabase 原型：账户隔离、信息流顺序、阅读锚点、事务写入、7 天/500 条缓存策略，以及独立本地记录表。
- 首页推荐/关注信息流迁移到 FeedStore → FeedRepository 闭环：本地缓存先上屏、网络首页后台刷新合并去重；版本化不透明游标（推荐页码/关注 max_id）支持断网下继续翻页；阅读位置以“帖子 ID＋相对视口偏移”在滚动停止/页面销毁时持久化，缓存恢复后按锚点卡片首次布局回滚到原位置；账户切换（登录/退出）丢弃旧内容。EntryAbility 在首帧前初始化阅读库；退出登录在会话失效后清理该账户缓存（尽力而为，失败告警不阻断凭据清理）；WeiboHomeTab 移除无实例化入口的用户时间线分支。

## 已验证

- Node 24.18.0：34 项离线回归通过，涵盖调度、取消、缓存、认证、迁移、篡改、搜索竞态、解析、互动同步、SQL 事务与隔离、信息流缓存先展示后刷新、分页终止、会话竞态与游标编解码。
- DevEco CLI 1.3.0-stable；项目 Hvigor 6.26.2；本机 CLT wrapper 6.26.8；API 26 构建成功，产物未签名。新增 FeedStore/FeedRepository 无编译警告；其余警告为原工程既有类别（Function may throw 等）。
- git diff --check 通过。
- HUKS/WebView/Preferences 测试使用替身；SQL 测试使用 Node SQLite。它们不证明平台实际行为或线上接口可用。阅读位置恢复的滚动几何（onAreaChange/onScrollStop/scrollTo）仅经离线测试与静态核对，未做真机验证。

## 复现

1. 安装 Node 22.13+（推荐 Node 24）及 DevEco CLI/CLT API 26。
2. npm install --ignore-scripts，然后 npm test。也可通过 WEIBO_TYPESCRIPT 指定本机 TypeScript 模块路径运行 node --test tests/*.test.cjs。
3. Windows PowerShell 执行 ./scripts/build.ps1；CLT 不在默认目录时传入 -CltRoot。
4. .npmrc 为 @ohos 指定官方 https://repo.harmonyos.com/npm 仓库。构建脚本按 wrapper 版本计算项目缓存路径，仅临时设置 NODE_PATH。
5. 本地签名按既有 hvigorfile.ts 的 tools/signing.local.json 机制配置，不提交证书、密钥、口令或登录 Cookie。

## 尚未完成及验收限制

- 完整阶段 1 尚需会话过期/验证码错误分类、全部保留页面的退出清理与迟到回调审计、初始化失败体验、队列按单请求取消及真实接口检查。
- 旧凭据可离线加密迁移，但不凭 SUB 标识宣告登录；缺少已验证 UID 的旧账户需要重新网页登录。
- 首页、详情、用户页、我的/发现仍有直接调用兼容服务的代码；旧服务与贴吧展示适配尚未清理。
- 富文本语义呈现、媒体变体、长文展开、用户搜索、筛选、书签、草稿、订阅、导入导出、WebDAV 以及阶段 5 的远端互动均未完成。
- 首页“加载更多”取到空页时不再弹 Toast（原实现会提示“暂无更多微博”），改为分页按钮随 hasMore=false 直接收起；其余加载失败仍保留 Toast 提示。
- 现有隐私政策、发布清单和部分应用文案仍有贴吧遗留，发布前必须更新。
- 编译仍有原工程及新增平台调用的警告，包含图片保存权限上下文与 API 能力提示，需要后续逐项审查。
- 未执行真机、HUKS 实际加解密、UI/大屏回归、性能基线或微博真实账号接口冒烟。用户已选择先继续代码及离线测试。

## 平台依据

- HUKS 官方加解密指南：devecocli docs 的“安全/Universal Keystore Kit/本地密钥管理/密钥使用/加密解密/加解密 ArkTS”，并核对本机 @ohos.security.huks.d.ts。
- ArkData 官方指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/data-persistence-by-rdb-store 。已读取本机同名原文，并核对 getRdbStore、createTransaction、execute/querySql 和 ResultSet 的 SDK 定义。
- 阅读位置恢复所用滚动 API：devecocli docs 的“API参考/ArkUI/滚动与滑动/Scroll”（onScrollStop 为 API 9+；onScrollEnd 自 API 9 废弃；Scroller.scrollTo/currentOffset 签名与 OffsetResult 结构已核对）；onAreaChange 在拖动/滚动导致子组件窗口位置变化时触发，依据 FAQ arkui-599（Swiper 子组件拖动中坐标平滑变动）与 FAQ arkui-7（Scroll 容器曝光埋点结合 onScrollStop 与 onAreaChange），核对日期 2026-09-28。
