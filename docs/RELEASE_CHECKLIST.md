# WeiboPura 发布自检清单

核对日期：2026-10-14。适用工程版本：`1.0.0`（`1000000`）。以下配置来自当前源码；构建通过不代表发布签名、真机功能或市场审核已通过。未完成项应在提交前逐项确认。

## 一、应用信息

| 字段 | 当前值 | 核对来源 |
| --- | --- | --- |
| 包名 | `com.weibopura.app` | `AppScope/app.json5` |
| 应用名称 | `WeiboPura` | `AppScope/resources/base/element/string.json` 的 `app_name` |
| 版本号 / 版本代码 | `1.0.0` / `1000000` | `AppScope/app.json5` |
| 工程 vendor | `a307608689-afk&haohao` | `AppScope/app.json5`；不能据此认定市场实名主体 |
| 兼容 SDK / 目标 SDK | `26.0.0` / `26.0.0` | 根 `build-profile.json5` |
| 设备形态 | 手机、平板（`phone`、`tablet`） | `entry/src/main/module.json5` |
| 应用图标 | `$media:app_icon_layered` | `AppScope/app.json5` 与媒体资源 |
| 隐私政策 | `https://github.com/R-HUA/WeiboHarmony/blob/main/docs/PRIVACY.md` | `common/Constants.ets` 的 `PRIVACY_POLICY_URL` |

- [ ] 市场后台应用名称、包名、版本、设备及 SDK 与最终发布包一致。
- [ ] 开发者实名主体、发布证书主体及后台账号一致；不沿用贴吧工程的证书结论或联系方式。
- [ ] 图标和截图符合市场规格；热搜、详情截图重新采集，展示分类榜单和当前互动区。

## 二、隐私政策与应用入口

- [ ] 更新后的 `docs/PRIVACY.md` 已发布到上述在线地址，未登录浏览器可正常查看，内容与本地一致。
- [ ] 首次数据使用说明、在线政策及市场后台的数据清单一致，覆盖登录会话、阅读缓存、搜索、评论回复、评论转发、关注、点赞和系统分享。
- [ ] 首启及设置页提供可访问的完整隐私政策入口。**当前微博 `Index.PrivacyGate` 只有说明、同意和退出按钮，`WeiboSettings` 未提供政策链接；修改 URL 常量不会自动增加入口。**
- [ ] 提供并验证维护者认可的有效联系渠道，按市场要求填写；当前仓库地址不等同于已验证的邮箱或投诉受理渠道。
- [ ] 对实质政策变更确认是否需要再次征得同意，并核对实现。**当前入口保存固定键 `weibopura_privacy_agreed_v1` 的同意状态，没有比较 `PRIVACY_POLICY_VERSION`；仅修改该常量不会触发再次同意。**
- [ ] 首次未同意时不初始化微博凭据、不启动微博内容请求；拒绝后退出，同意状态可正确保存。

## 三、权限与数据

当前 `module.json5` 声明四项权限及 `dataTransfer` 后台模式：

| 权限 | 当前用途或状态 | 发布核对 |
| --- | --- | --- |
| `ohos.permission.INTERNET` | 微博登录、内容、媒体及用户主动互动 | 与政策、后台说明一致 |
| `ohos.permission.VIBRATE` | 交互触感反馈 | 验证关闭反馈后的功能行为 |
| `ohos.permission.DETECT_GESTURE` | 系统手势分享 | 验证手机和平板的可用性及系统授权行为 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 保留的后台传输声明；当前微博流程未使用长时任务 | 核实保留必要性；不能填“贴吧签到”作为微博用途 |

- [ ] 核查未使用的后台权限与 `backgroundModes` 是否应移除；任何调整后同步政策和后台表单。
- [ ] 保存图片使用 `SaveButton` 的本次授权，不把它写成持续读写图库权限。
- [ ] 当前微博入口不触发旧签到、发帖、收藏或签到通知；不能以旧页面的存在宣称这些功能已支持。
- [ ] 登录页通过 `WebCookieManager` 获取会话，`/api/config` 确认登录和 UID 后才保存；取消登录和会话切换不接受过时回调。
- [ ] 平台上验证 HUKS 凭据加解密、网页 Cookie 清理、账户隔离和退出后的数据清理；阅读缓存清理失败会记录错误，不把“退出”描述为保证删除全部本地数据。
- [ ] 无登录凭据、证书私钥或口令进入源码、日志、截图及发布附件；核对依赖和实际网络目的地后填写第三方服务清单。

## 四、构建与签名

在仓库根目录使用 DevEco Studio 或已配置的工具链构建。签名材料由 `hvigorfile.ts` 的本机配置机制读取，根 `build-profile.json5` 的 `signingConfigs: []` 本身不证明最终包签名类型。

- [ ] 以发布模式构建，确认构建成功；调试 HAP 不能作为发布验收产物。
- [ ] 对最终提交的 HAP 验签，确认 release profile、证书、包名、版本及有效期；旧贴吧包的验证记录不能沿用。
- [ ] 核对包内设备、SDK、混淆配置及资源；发布包不包含调试源映射或敏感本机配置。
- [ ] 若归档或复制产物，对实际提交副本再次验签，不能只根据 `signed` 文件名判断。

可使用配套 SDK 的签名工具，在仓库根目录验证最终产物（工具位置以实际安装为准）：

```powershell
$devecoPath = '<DevEco Studio 安装目录>'
& "$devecoPath\jbr\bin\java.exe" -jar `
  "$devecoPath\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar" `
  verify-app -inFile entry\build\default\outputs\default\entry-default-signed.hap `
  -outCertChain "$env:TEMP\weibo-release-chain.cer" `
  -outProfile "$env:TEMP\weibo-release-profile.p7b"
```

## 五、发布包设备验收

- [ ] 首启同意与拒绝、重新启动、最大字号和深色模式。
- [ ] 未登录访问推荐、公开热搜分类、搜索及专题页；“我的”分类提示登录。
- [ ] 内嵌登录成功、退出、重新登录、登录过期与验证码提示。
- [ ] 推荐和关注流分页、缓存恢复、账户切换、用户主页及关注/取关。
- [ ] 图片与视频混排、图片预览及保存、视频暂停/继续/全屏、滚动离屏处理。
- [ ] 详情“转发 / 评论 / 赞”列表及括号总数、评论热门/最新排序、嵌套回复与自动分页。
- [ ] 从列表评论按钮进入详情时定位评论区，仍可滚动回原帖；评论菜单回复、转发和复制。
- [ ] 真实账号单次点赞/取消点赞、评论、回复及评论转发，验证取消编辑不提交、失败不显示成功。
- [ ] 系统分享、手势分享、剪贴板交接及外站链接。
- [ ] 手机、平板、横竖屏和分栏导航；网络失败、限流、空列表及重试。

本地离线测试只证明样本解析和业务逻辑；替身测试不能证明平台密钥、网页 Cookie、设备布局或微博线上写接口正常。市场提交前应记录最终发布包及实际设备验收结果。

## 六、每次版本更新

- [ ] 核对应用版本、SDK、权限、设备及签名配置，更新本清单。
- [ ] 功能和数据处理变化同步隐私政策、README、数据适配层文档和市场说明。
- [ ] 在线政策可访问，联系渠道有效，应用入口和同意机制与说明一致。
- [ ] 运行本次变更相关离线检查，并用最终发布包完成对应设备回归。
