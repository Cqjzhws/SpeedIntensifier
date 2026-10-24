# SIOriginal-BG v3.0.2-BG — 真后台保活（源码）

打包时间：2026-10-24
来源：`WorkBuddy/2026-10-20-13-02-07/si/SIOriginal`（v2.4.1）的 FUBG 保活模块整体抽出重制

> v3.0.2：新增「后台定时刷新」，修「锁屏来消息 → 解锁进微信不刷新、秒开、
> 要杀进程才有消息」的问题。详见文末「已知事项」。
> v3.0.1：新增「通话感知避让」，修掉与黄白助手「忙线拒接」的冲突，以及
> 「停留在微信页面来电不通知、过一会才通知」的问题。

## 这是什么

SIOriginal v2.4.1 的精简版。按「只保留真后台，其他功能全部删除」重做——
**代码级移除**（不是加开关关掉），动画加速/手感/HUD/统计/安全模式一条不留。

| 保留（FUBG 真后台保活双引擎） | 已删除 |
| --- | --- |
| 引擎一 场景伪装：拦截 FrontBoard 后台化 scene diff（含快照类更新） | 动画加速：CAAnimation / CATransaction / UIView 块动画 / UISpring / UIViewPropertyAnimator / 转场 / 导航模态 Tab / LayerBoost / TransitionBoost |
| 引擎一 配套：`applicationState` 伪装（dladdr 识别调用者，推送框架拿真话）、通知横幅强制弹出 | 手感：decelerationRate / delaysContentTouches / setZoomScale |
| 引擎二 音频断言：静音白噪 + AVAudioSession（Playback + MixWithOthers）+ beginBackgroundTask 桥接 | HUD 快速显示：WKWebView / SVProgressHUD / MBProgressHUD / UIActivityIndicatorView |
| 看门狗自愈（周期 3s / 低电量 6s，连续 3 次失败退避约 30s）、来电中断与线路变化恢复 | 命中统计浮层、生效 toast、分享卡片 |
| 通话感知避让（v3.0.1）：别人占用音频会话时立刻让位 15s | 安全启动自愈、安全模式、配置快照/预设/历史、微信预览放大态探测器 |
| 后台定时刷新（v3.0.2）：真后台期间周期性补投 WillEnterForeground，触发 App 自己的同步分支 | 排除名单（精确 + `*` 前缀）、App 级覆盖、Darwin 热重载（v3.0.2 仍在，此行仅为表格对齐） |

源码规模：dylib 约 730 行（原 3913 行），配置 App 约 500 行（原 177KB/约 3000 行）。

## 目录结构

```
SIOriginal-BG/
├── Tweak/
│   ├── SIOriginalBG.m        # dylib 主体
│   └── FUBGNoiseData.h       # 静音白噪 base64（GPLv3, ImmortalizerJailed）
├── App/
│   ├── main.m                # 配置 App（TrollStore 安装）
│   ├── Info.plist            # bundle id com.local.sioriginalbg
│   ├── AppIcon.png / Icon-*.png
├── entitlements.plist
└── .github/workflows/build-sioriginalbg.yml
```

## 配置

配置文件：`/var/Managed Preferences/mobile/com.local.sioriginalbg.plist`（**新路径，不再读旧的 `com.apple.UIKit.plist`**）

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `Enabled` | BOOL | YES | 总开关 |
| `SceneFake` | BOOL | YES | 引擎一 场景伪装 |
| `AudioKeep` | BOOL | YES | 引擎二 音频断言 |
| `CallAware` | BOOL | YES | v3.0.1 通话感知避让：检测到别人占用音频会话（PlayAndRecord/Record）时让位 15s |
| `BgRefresh` | BOOL | YES | v3.0.2 后台定时刷新开关 |
| `BgRefreshInterval` | Double | 30 | v3.0.2 刷新周期（秒）。钳制 10–600；`<=0` = 关闭刷新 |
| `Blacklist` | Array | 空 | 排除名单；精确匹配，条目结尾 `*` 表示前缀匹配（如 `com.tencent.*`） |
| `AppOverrides` | Dict | 空 | App 级覆盖：`{ "bundle id" = { Enabled/SceneFake/AudioKeep/CallAware/BgRefresh = 0/1; BgRefreshInterval = 秒; }; }` |

热重载：配置 App 保存即发 Darwin 通知 `com.local.sioriginalbg.settingschanged`，dylib 主线程串行 reload，无需注销 App。删掉整个 plist 即回出厂默认（五项全开、周期 30s、名单清空）。

## 构建

`push tag sioriginalbg-v*` 或手动 `workflow_dispatch` 触发 workflow（macos-14 / Xcode）。
产物：`SIOriginalBG.dylib`（TrollFools 注入）+ `SIOriginalBG.ipa`（配置 App，TrollStore）。

本地复现：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -arch arm64 -dynamiclib -O2 -install_name @rpath/SIOriginalBG.dylib \
  -isysroot "$SDK" -ITweak -miphoneos-version-min=14.0 -undefined dynamic_lookup -fobjc-arc \
  -framework Foundation -framework UIKit -framework AVFoundation -framework UserNotifications \
  -o SIOriginalBG.dylib Tweak/SIOriginalBG.m
```

## 用法

1. TrollStore 安装配置 App，设好开关/名单 → 保存。
2. TrollFools 把 `SIOriginalBG.dylib` 注入目标 App（原来注入 `SIOriginal.dylib` 的位置换成它即可；两个 dylib 不要同时注入同一个 App）。
3. 生效观察：控制台日志前缀 `[SIOBG]`。启动一行
   `[SIOBG] v3.0.2-BG loaded in <bundle id>: active=1 scene=1 audio=1 callAware=1 refresh=1 interval=30 audioMode=1`；
   后台化被拦截时打 `[SIOBG] swallowed backgrounding scene diff`；
   每次补刷新打 `[SIOBG] background refresh fired`（想验证功能就看这行，间隔 = 你设的周期）。
   没装 audio 后台模式又关了场景伪装时，启动行尾会带 WARNING。

## 已知事项

- **v3.0.2 修的「解锁后消息不刷新」**（真机反馈：锁屏来微信消息 → 解锁进微信没有那条消息，
  界面秒开不刷新，杀进程重进才有）：
  根因是场景伪装把「后台→前台」转场整条吞了 —— UIKit 不再投递
  `UIApplicationWillEnterForegroundNotification`，App 自己的同步分支等不到触发点；
  同时 `applicationState` 被伪装成 Active，App 更认为「我一直在前台，没有新消息要拉」。
  杀进程走的是冷启动全量同步，所以有消息。
  v3.0.2 的「后台定时刷新」是对症解法：真后台期间每 30s（可调 10–600s，置 0 关闭）
  补投一次 WillEnterForeground 通知，直接触发 App 自己的刷新分支。安全性：
  只在**物理真后台**投递（真实状态走原始 IMP 取，不递归进我们自己的 hook）；
  复用 v3.0.1 通话避让，来电/录音/忙线拒接期间不刷；音频引擎停摆会先自愈再刷。
  若个别 App 被刷得不舒服，App 级覆盖单独关：`com.tencent.xin bgrefresh=0`。
- **v3.0.1 修的两个问题**（真机反馈，与黄白助手「忙线拒接」相关）：
  1. **与忙线拒接冲突**：根因是音频断言在前台只 pause 不释放会话 —— 我们的静音 Playback
     会话长期激活，会推迟微信自身激活 PlayAndRecord 响铃，也干扰插件的忙线/通话检测。
     现在：会话归属跟踪（只关自己激活的）+ 回前台彻底释放 + 看门狗/线路变化/中断恢复
     三处「通话感知让位」（默认开，`CallAware=NO` 可退回旧行为）。
  2. **停留在微信页面来电不通知、过一会才通知**：同一个根因，修法同上。
     若仍复现，按优先级试：`com.tencent.xin scene=0 audio=1`（只关场景伪装）→
     `com.tencent.xin audio=0 scene=1`（只留场景伪装）→ 整体拉黑微信。
     日志佐证：`[SIOBG] yielded audio session to a foreign (call/record) session`。
- **微信「两个视频画面」**：v2.4.1 的疑似诱因是场景伪装（吞后台化 diff + 伪造 applicationState），
  本版按你的选择**保留**了该引擎。若复现且确认是它，不用改代码，App 里加一行覆盖即可关：
  `com.tencent.xin scene=0 audio=1`（只关场景伪装，保留音频断言）。
- **「锁屏有通知、打开微信就没了」是 iOS 正常行为**：打开 App 会清掉它已送达的通知中心条目，
  不是插件造成的；消息本身还在微信聊天列表里。
- 内置排除 `com.apple.springboard`（桌面进程是场景宿主，配置无法打开）。
- 音频引擎单独使用时要求宿主 App 自带 `UIBackgroundModes=audio`；配置 App 里「扫描」按钮可看哪些 App 有。
- 看门狗只在真后台运行，回前台立即卸载；低电量周期自动放宽到 6s。
- 构建 workflow 在**仓库根** `.github/workflows/build-sioriginalbg.yml`（GitHub 不认子目录里的 workflow），
  本地另有一份 `SIOriginal-BG/build.py`（Windows / zig 交叉编译）可离线出包。
