# WeiboHarmony 阶段性实现记录

各日期章节记录当时的实现与验证范围；早期未完成条目不代表当前状态。最新功能与验收限制见文末 2026-10-14 记录。

## 2026-09-29 转发媒体、@解析与用户关系修复

- 转发视频去重时保留在原帖引述块；列表/详情共享归属规则。移除外层 220vp 固定高度裁切，修正转发块满宽叠加 margin 的布局；空视频候选正确回退。
- 补全 @用户链接解析与富文本更新 key，新增截图转发链、可信主页/外站区别和文本保真回归。
- 用户主页提供关注/取关、未知关系刷新、未登录入口及会话隔离；资料与时间线错误分开处理。“我的微博”改用共用用户页，搜索/用户卡片补齐点赞和分享回调。
- 最终 81 项离线测试通过，API 26 无守护进程 assembleHap 构建通过；未安装设备、未验证真实关注/取关和视频触摸布局。
- 全仓审查结果、尚未修复事项与接口依据见 [CODE_REVIEW_2026-09-29.md](CODE_REVIEW_2026-09-29.md)。

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

## 2026-09-28 尚未完成及验收限制（历史检查点）

- 完整阶段 1 尚需会话过期/验证码错误分类、全部保留页面的退出清理与迟到回调审计、初始化失败体验、队列按单请求取消及真实接口检查。
- 旧凭据可离线加密迁移，但不凭 SUB 标识宣告登录；缺少已验证 UID 的旧账户需要重新网页登录。
- 首页、详情、用户页、我的/发现仍有直接调用兼容服务的代码；旧服务与贴吧展示适配尚未清理。
- 当时富文本语义呈现、媒体变体、长文展开、用户搜索、筛选、书签、草稿、订阅、导入导出、WebDAV 以及阶段 5 的远端互动均未完成。后续已实现富文本、长文、媒体混排及关注、点赞、评论、回复、评论转发等互动；不再以此条认定评论接口或全部远端互动未实现，线上验收仍独立待完成。
- 首页“加载更多”取到空页时不再弹 Toast（原实现会提示“暂无更多微博”），改为分页按钮随 hasMore=false 直接收起；其余加载失败仍保留 Toast 提示。
- 当时隐私政策、发布清单和部分应用文案仍有贴吧遗留。2026-10-14 已按微博代码修正政策、清单与相关文档；在线发布、完整政策入口及其余发布核对项仍见当前清单。
- 编译仍有原工程及新增平台调用的警告，包含图片保存权限上下文与 API 能力提示，需要后续逐项审查。
- 未执行真机、HUKS 实际加解密、UI/大屏回归、性能基线或微博真实账号接口冒烟。用户已选择先继续代码及离线测试。

## 平台依据

- HUKS 官方加解密指南：devecocli docs 的“安全/Universal Keystore Kit/本地密钥管理/密钥使用/加密解密/加解密 ArkTS”，并核对本机 @ohos.security.huks.d.ts。
- ArkData 官方指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/data-persistence-by-rdb-store 。已读取本机同名原文，并核对 getRdbStore、createTransaction、execute/querySql 和 ResultSet 的 SDK 定义。
- 阅读位置恢复所用滚动 API：devecocli docs 的“API参考/ArkUI/滚动与滑动/Scroll”（onScrollStop 为 API 9+；onScrollEnd 自 API 9 废弃；Scroller.scrollTo/currentOffset 签名与 OffsetResult 结构已核对）；onAreaChange 在拖动/滚动导致子组件窗口位置变化时触发，依据 FAQ arkui-599（Swiper 子组件拖动中坐标平滑变动）与 FAQ arkui-7（Scroll 容器曝光埋点结合 onScrollStop 与 onAreaChange），核对日期 2026-09-28。

## 2026-09-28 后续审查与媒体修复

- 详见 `CODE_REVIEW_2026-09-28.md`：审查了 4da04c5 后提交及工作区变更，统一播放器/图片网格，修正缓存分页、长文会话竞争和多列缓存通知。
- 当前离线测试 45 项通过，API 26 构建通过，API 24 connectOnly 仍保留；本轮未执行真机验收。
- 早期“富文本/长文未完成”等条目描述的是检查点状态；目前已有实现。阶段 3 尚不能整体验收：缓存裁剪与游标边界、后台刷新阅读连续性仍待处理，用户搜索及性能/无障碍/多设备验收也未全部完成。

## 2026-09-28 续轮：关闭阅读连续性两项发现

- 缓存增加版本化边界记录；截断、过期淘汰、其它 feed 挤出及旧版本无边界记录时，保留离线阅读并要求重新获取，禁用不可靠 cursor。
- 后台刷新暂存新首页，覆盖提示不占列表高度；用户接受或主动刷新成功才切换新流并回顶。新旧分页不混排，过时响应被丢弃。
- 54 项离线测试通过，API 26 构建通过。审查记录中的这两项已完成代码与离线回归；其余阶段验收以及真机交互验证仍按既有范围待完成。

## 2026-09-29 阅读界面降噪

- 移除图片上的“长图 · 点击查看”；原判定宽高比 < 0.65 会覆盖普通竖照。预览页长图阅读模式仍使用 < 0.5（高超过宽两倍）。
- 列表单图展示高度上限改为 min(卡片宽 × 1.25, 360vp)，顶端裁切；多图中宽高比 < 0.5 使用顶部裁切，避免缩成细条。列表不增加图片内滚动。数值为本项目选择。
- 后台更新取消正文悬浮按钮，推荐/关注标题旁显示点号；再次点当前标题接受更新，仍由用户决定何时回顶。屏幕朗读保留完整操作描述。
- 加载失败、重试、刷新信息流等文案精简。
- 依据：本地 CLI FAQ/UI框架/UI界面/折叠屏展开态_页面下方按钮显示在视窗外/faqs-arkui-1565 的 Contain/Cover 和尺寸说明；API 26 image.d.ts objectFit 定义。官网对应页面本次获取失败，使用已读取本地官方原文。
- 离线测试 54 项通过；真机图片裁切、标签交互和大字号仍待验收。
- API 26 无守护进程 assembleHap 构建通过（常规 CLI 构建停在 daemon 启动，取消后切换 --no-daemon）；未安装真机。

## 2026-09-29 视频控制样式

- 核对 CLI 官方 Video 原文（含 API 26.0.0 controllerAsync 等条目）与目标 SDK video.d.ts：controls 控制系统控制栏，其样式不支持自定义；自定义控制栏应设 false。继续使用现有 VideoController，不因样式调整迁移播放内核。
- 官方来源：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-media-components-video ，本地查询 documentId 为 API参考/ArkUI_方舟UI框架/ArkTS组件/图片与视频/Video/ts-media-components-video。
- 按钮设计来源：https://developer.huawei.com/consumer/cn/doc/design-guides/button-0000001929683228 ，本地 hwdocs/047.md 更新于 2026-06-12，内容上悬浮操作可使用图标按钮。官网读取及浏览器均超时，未核实最新在线图示。
- 本项目选择：中央三角 36×42vp、热区 72vp；行内暂停/继续与全屏使用 48vp 透明图标按钮，白色图标配底部渐变及时间，移除多余停止文字按钮。播放时 3 秒收起控制栏，点击画面显示；暂停时保留。全屏使用系统控制栏。尺寸和收起时长是项目选择，不是官方强制规格。
- 保留显式播放、8vp 点击移动阈值、全局单播放实例、离屏停止与后台释放。API 26 构建通过；真机滑动、全屏切换、控制栏显隐及屏幕朗读仍待验收。

## 2026-09-29 信息流进入与更新提示规则

- 按用户修订：冷启动缓存先在顶部显示，网络首页返回后自动替换并回顶，不显示更新点号；失败保留缓存。
- 仅当前推荐/关注标签可显示更新点号，非当前标签隐藏。
- 切换进入标签即回顶：有待采用结果直接采用；请求在途则复用并在返回时采用；否则刷新首页。自动采用仅绑定本次请求代次，后续后台刷新仍暂存并等待用户。
- 回归增加冷启动、切换采用待更新、切换复用在途请求与后续后台刷新三个用例。57 项测试、API 26 构建通过；真机切换视觉待验收。

## 2026-09-29 媒体比例与播放图标坐标修复

- 真机截图显示 Path 图标偏小且偏左上；API 26 SDK component/path.d.ts:133–140 明确 commands 使用 px，而原外框使用 vp，之前未转换导致图形不占满布局框。改为带 viewBox 的 SVG 资源，由 Image 按 vp 布局缩放，移除按钮默认内边距。
- 中央播放图标使用 48vp 画布、72vp 热区；底部播放/暂停、居中时间、全屏均位于 48vp 高度行，图标画布统一 28vp，左右对称留白。
- 视频容器按封面比例计算尺寸，限高 260vp，窄内容左对齐收窄；单图达到高度限制时普通竖图按比例收窄，超长图保留顶部裁切。多图继续等尺寸九宫格。原始图片/视频自带黑边不自动识别裁切，封面比例与视频不一致时仍可能留边。
- 已沿用本会话 harmonyos-docs-workflow 的 Image/Contain 证据并核对 Path 本地 SDK 定义；尺寸与排列为项目选择。视觉效果仍需安装真机验收。

## 2026-09-29 视频尺寸回归与正文识别修复
- 视频不再沿用单图限高缩宽：保持可用宽度，高度按封面比例限制在 180–360vp，原生 Video、封面和点击层使用同一显式尺寸；图片布局保持独立。
- 点击播放画面暂停/继续；暂停显示中间播放按钮，底栏继续提供暂停、时间和全屏。保留 8vp 点击位移限制及离屏释放。
- 有内嵌播放器时隐藏“某某的微博视频/秒拍视频”重复链接；没有播放器仍保留原链接。普通网页链接保留。
- 纯文本转发链中的 @用户名支持中文、繁体、下划线和连字符；带 UID 的链接直接打开主页，无 UID 的名称进入站内搜索，不推断用户身份。
- 依据：本地 video-api-review.txt 的 VideoController.start/pause 与 controls 章节；API26 SDK component/video.d.ts。官方明确 pause 保留当前帧并从当前位置恢复，controls(false) 可自行实现控制栏。尺寸范围为本项目选择。
- 官网 ts-media-components-video 于本次读取超时，未宣称在线最新资料验证完成。
- 验证：61 项离线测试通过，API26 assembleHap 构建成功；尚待真机确认窄列、竖视频、暂停/继续及滑动手势。

## 2026-09-29 正文链接统一分流
- 首页、搜索、用户主页及详情正文/评论共用 WeiboLinkNavigation；保留“查看原文”按钮直达网页，避免循环打开同一详情。
- 原生识别移动 status/detail、桌面 UID/BID 正文、u/profile/数字 UID 主页；话题链接走站内搜索。用户名链接尝试公开页面的明确 oid，无法解析时搜索该名称。
- 视频链接含 mid 或公开页面 canonical/og:url 指向微博时进入所属微博详情，在 App 内播放。不把 1034 视频对象编号当帖子 ID，也不从推荐内容里猜测所属微博；无可靠元数据的页面回退网页。
- t.cn 使用不含账户 Cookie 的独立 RCP 会话；逐跳检查目标域，处理 HTTP 和 HTML refresh 跳转，最多 5 跳并检测循环。外站不在解析器内继续抓取。
- API 依据：本机 API26 @hms.collaboration.rcp.d.ts Response.headers.location、Session.fetch/close、autoRedirect。复用现有 Video 文档；未使用未验证的微博私有视频接口。
- 最新点击覆盖旧解析，退出会话或导航路径改变后丢弃迟到结果。解析仅由点击触发。
- 验证：离线链接分类/解析样本测试和 API26 构建；真实微博短链、视频网页随服务端变化的解析效果仍需真机验收。

## 2026-09-29 图片链接与热搜交互

- 正文里的图片链接改为 App 内查看：`domain/WeiboLink` 增加图床判定（`sinaimg.cn` / `sinaimg.com` / `weibocdn.com` / `sinacdn.cn` 及其子域，且路径是图片扩展名或图床尺寸别名目录），命中即归为 `image`；`common/WeiboLinkNavigation` 把它交给 `pages/ImagePreview`（信息流点图同一个原图浏览页，缩放/切换/保存能力都在里面）。此前这类地址交系统浏览器，图床防盗链直接返回 403。
- 第二条信号：锚点文字。部分接口版本不把图床地址写进 href，只给「查看图片」这类文字锚点。`isImageViewText` 按展示文案判定（查看图片/查看原图/查看大图等，允许「共9张图 查看图片」这种前后缀），`openWeiboLink` 新增第二参数承接锚点文字；解析器只在要图时多请求一次落地页，用 `og:image`（`$CONFIG['page_pic']` 兜底）取配图，取不到仍回落到原本的帖子详情/外站行为。`post` 类型平时不打开落地页，只有带文字信号时才多这一次请求。
- 微博热搜词条可点：`WeiboHotSearch` 增加 `onOpenTopic`，`Index` 注入既有 `openTopicSearch`——切到搜索页并直接检索该词，与正文 `#话题#` 同一条路径（`weiboSearchQuery` + 自增 tick）。关键词优先取接口给的 `word_scheme`（`WeiboHotTopic.query`），缺失时退回展示词。
- 安全边界不变：白名单之外的 `.jpg` 仍是外站（交系统浏览器），外站 `og:image` 不被采纳；锚点文字只决定是否多取一次落地页配图，不参与域名信任判定。
- 验证：离线测试新增图床判定、文字判定、`og:image` 提取与解析器分流用例；API 26 assembleHap 构建通过。真机待核对：带图转发帖的「查看图片」、纯图床直链、热搜词条点击后的搜索结果。

## 2026-09-29 关注/取关写接口 403 治理

- 现象：他人主页的关注/取关总提示「微博拒绝了本次访问」（HTTP 403）。点赞与评论走同一套写链路，同样受影响，只是本轮由关注暴露。
- 依据（第三方第一手接口调查，不是微博官方稳定承诺）：
  - openweb 的 weibo 记录指出 `/ajax/*` 写接口只在浏览器页面上下文里被 CSRF 接受，`Origin: https://weibo.com` 与 `Referer` 需要「自然带上」；纯 Node 传输一律 403。
  - weiboSyncFollow 记录「新版关注接口 `https://www.weibo.com/ajax/friendships/create` 请求头必须带 xsrf token，否则报 403」；rainpenber/weiboBatchFollow 给出可用的旧接口 `POST /aj/f/followed`（带完整 `refer_*` 参数、不需要令牌）。
  - 路径与参数沿用既有记录：关注 `create` + `friend_uid`，取关 `destory` + `uid`（上游拼写）。
- 修复：
  1. 补 `Origin`：`WeiboHttpClient` 移动端与桌面端请求头都加上同源 `Origin`（此前只有 `Referer`）。真实浏览器的同源 POST 一定带它，微博的 CSRF 校验认它。
  2. 响应 Cookie 回流：`WeiboHttpClient` 每次响应（含失败响应）把 `Set-Cookie` 交给 `WeiboAuthManager`，按域合并进 mobile / desktop 两份 Cookie，落盘 30 秒节流。此前只保存登录时的一次快照，而微博的 `XSRF-TOKEN` 随响应轮换——快照过期后，写接口的「Cookie 值 == 请求头 X-XSRF-TOKEN」双提交校验必然失败。这正是 `CODE_REVIEW_2026-09-29.md` 中「客户端没有响应 Set-Cookie 的更新流程」那条待验证边界。
  3. 403 重试一次：`WeiboService.postAuthenticatedWrite`（关注/取关/点赞/评论共用）遇 HTTP 403 时用最新 Cookie 原样重发一次——这次 403 的响应通常已换发新令牌。只有 HTTP 层 403 才重试；`ok:0` 业务错误（需要验证码、次数超限）直接上抛，不重复请求以免加重风控。
- 边界：Cookie 只接受 `m.weibo.cn` 与 `weibo.com` 两个来源域，外站 `Set-Cookie` 丢弃；合并只处理 `name=value`，不实现属性里的删除语义（服务端换发都是新值，删掉旧值更危险）。RCP 自带的 `CookieRepository`（API 23+，本机 API 26 可用）可作为后续替代实现，本次未引入。
- 验证：离线测试新增 403 重试、非 403 不重试、连续 403 止步两次、跨域 Cookie 不串、属性不入表等用例；API 26 assembleHap 构建通过。真机需用真实账号手动关注/取关一次确认（会真实改变关注关系）。
- 若真机仍为 403，下一批候选（按证据强度）：`client-version` 请求头、浏览器 `Sec-Fetch-*` 三件套，或把写请求放进已登录的 ArkWeb 页面上下文执行；届时先记录状态码与响应体再决定，不做盲目重试。

## 2026-09-29 评审四条（P1×1 / P2×1 / P3×2）整改

上一节「Cookie 回流 + Origin」引入的改动被评审挑出四处，逐条处理。

1. **P1 未登录不再合并、也不再落盘响应 Cookie。** `WeiboAuthManager.mergeResponseCookies` 开头加 `if (this.session.uid.length === 0) { return; }`，`persistRefreshedCookies` 同样加一道（写盘是唯一持久化入口，做双保险）。
   - 理由：`m.weibo.cn/api/config`、热搜这类公开接口在访客态也会返回 `Set-Cookie`（匿名 `ti`、访客 `SUB`）。此前无差别合并会把它们当成登录态加密写进 HUKS 凭据文件，`hasCookie()` 为 false 但磁盘上躺着脏数据。登录的真实来源是 `captureAndValidate` 里从 `WebCookieManager` 取的那份快照（是网页自己请求后的结果，比我们旁路合并的更权威），所以登录期间丢掉响应 Cookie 没有损失。
   - 顺带堵住第二个洞：退出登录后迟到的响应此前会往已经清空的会话里塞 Cookie，并在 `vault.clear()` 之后又写一次盘；现在被同一道闸门挡掉。
2. **P2 短链中转页重定向优先于配图提取。** `WeiboLinkResolver` 把 `shortlinkPageRedirect(html)` 的判断整体移到 `imageFromWeiboPage(html)` 之前。
   - 理由：`meta refresh` 过渡页自己也有 `og:image`（站方 logo、商品图、分享卡片图），先取图会把「查看图片」的意图钉死在中转页上，永远走不到真正的正文。现在的顺序是：先判是否还要跳（跳了就 continue 去取下一跳），确认是落地页之后才取 `og:image`，取不到仍回落到 `post` / `external`。
3. **P3 `Origin` 只给写请求。** 从 `buildMobileHeaders` / `buildDesktopHeaders` 里摘掉 `Origin`，改在 `performPost` 里按目标域补上。
   - 理由：同源 GET 本来就不发 `Origin`，凭空多一个自定义头只会扩大与线上浏览器的差异，而微博对异常头部组合的容错不可预期。写请求（POST）带 `Origin` 是上一节 403 治理的核心依据，保留。
4. **P3 `set-cookie` 大小写兜底。** `absorbResponseCookies` 先读 `headers['set-cookie']`，取不到再读 `headers['Set-Cookie']`。
   - 理由：HTTP/1.1 头名字大小写不敏感，RCP 内部用哪种大小写没有承诺（历史版本两种都出现过）。漏读一次就是漏掉一次令牌轮换，后续写请求会被判 403。

- 验证：新增 `tests/http-client.test.cjs`（用假 `rcp.Session` 记录真实发出去的头）锁定第 3、4 条——GET 不带 `Origin` 且保留 `Referer`、POST 带 `Origin` 与 `X-XSRF-TOKEN`、两种大小写都能收到刷新令牌、403 响应仍交出令牌并报 403、两个微博域之外的地址在开 socket 前就拒绝；`tests/auth.test.cjs` 增加「未登录不种访客 Cookie、不写盘，退出后迟到 Cookie 不复活」；`tests/weibo-link.test.cjs` 增加「过渡页配图不得劫持重定向」。全部 98 项离线测试通过，API 26 `assembleHap --no-daemon` 构建成功（`BUILD SUCCESSFUL in 21 s 889 ms`），产物 `entry/build/default/outputs/default/entry-default-signed.hap`。
- 未做：真机验收。三条用户可见行为（真实账号关注/取关、「查看图片」内联预览、热搜词条点击进搜索）仍需装包确认；离线替身不证明微博线上接口可用。

## 2026-10-14 评论、分类榜单与媒体混排

- 评论读取使用桌面站 `/ajax/statuses/buildComments`，主评论与根评论子回复各自维护游标；热门/最新采用上游排序参数，详情和展开回复支持滚动续载、失败重试及会话切换取消。评论发送、评论回复和评论转发均已有实现，真实账号验收仍待完成。
- 详情互动区标题改为“转发 / 评论 / 赞”实际列表切换，总数及括号使用较小字号；热门/最新位于右上角。转发与赞列表分别使用 `repostTimeline` 和 `likeShow`。
- 列表图标采用空心样式，点赞后爱心变实心；从列表评论按钮进入详情时默认定位到评论区，保留上方原帖。评论时间移到用户名下方，收紧条目间距，移除独立回复按钮，点击评论提供回复、转发和复制菜单；评论转发保留原帖和评论标识，仅确认发送后提交。
- 热搜提供综合、科技、娱乐、生活、社会、体育、动漫及“我的”八个分类；“我的”需要登录，其余榜单可公开访问。热搜词条进入独立专题页，专题查询和滚动状态与普通搜索分开。
- 媒体映射支持 `mix_media_info.items`、`mixed_media_info.media_list` 与 `pic_infos`；列表和详情使用共用混排组件，保留图片、视频顺序与转发媒体归属。
- 与评论、榜单和互动接口相关的 `node --test tests/comments-hot.test.cjs tests/follow.test.cjs` 共 23 项离线测试通过；API 26 无守护进程 `assembleHap` 调试构建通过，生成签名调试 HAP。此处不是全仓测试、发布签名或线上接口验收结论。
- 尚待设备验证：评论区进入位置、排序与嵌套回复滚动、三类互动列表及计数、真实账号评论回复/转发、分类榜单和专题返回状态、媒体混排及手机/平板布局。本轮未安装设备，离线测试不能证明上述真实表现。

## 2026-10-14 文档与发布信息同步

- 隐私政策改为微博实际登录、凭据保存、阅读缓存、搜索、互动和系统分享说明；发布清单以 `com.weibopura.app`、`WeiboPura`、版本 `1.0.0` / `1000000`、四项声明权限及 SDK `26.0.0` / `26.0.0` 为准，不沿用贴吧签名与验收结果。
- `Constants.ets` 修正项目头与在线政策地址，保留原版权声明；明确当前微博入口未以政策版本常量触发再次同意。
- README 补充评论排序、嵌套回复、转发/赞列表、分类榜单、专题页和媒体混排；构建入口改为仓库根目录。旧热搜、详情截图不含当前布局，已撤出 README 预览，原文件保留。
- 数据适配层文档更新为内嵌网页登录、`WebCookieManager` 读取并验证会话，以及当前读写接口；历史文档路径保持不变。
- 完整隐私政策入口、有效维护者联系渠道、保留后台权限必要性、线上政策更新和发布包设备验收仍待完成，具体检查项见 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。
