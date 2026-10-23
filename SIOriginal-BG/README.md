# SIOriginal-BG v3.0.0-BG — 真后台保活（源码）

打包时间：2026-10-23
来源：`WorkBuddy/2026-10-20-13-02-07/si/SIOriginal`（v2.4.1）的 FUBG 保活模块整体抽出重制

## 这是什么

SIOriginal v2.4.1 的精简版。按「只保留真后台，其他功能全部删除」重做——
**代码级移除**（不是加开关关掉），动画加速/手感/HUD/统计/安全模式一条不留。

| 保留（FUBG 真后台保活双引擎） | 已删除 |
| --- | --- |
| 引擎一 场景伪装：拦截 FrontBoard 后台化 scene diff（含快照类更新） | 动画加速：CAAnimation / CATransaction / UIView 块动画 / UISpring / UIViewPropertyAnimator / 转场 / 导航模态 Tab / LayerBoost / TransitionBoost |
| 引擎一 配套：`applicationState` 伪装（dladdr 识别调用者，推送框架拿真话）、通知横幅强制弹出 | 手感：decelerationRate / delaysContentTouches / setZoomScale |
| 引擎二 音频断言：静音白噪 + AVAudioSession（Playback + MixWithOthers）+ beginBackgroundTask 桥接 | HUD 快速显示：WKWebView / SVProgressHUD / MBProgressHUD / UIActivityIndicatorView |
| 看门狗自愈（周期 3s / 低电量 6s，连续 3 次失败退避约 30s）、来电中断与线路变化恢复 | 命中统计浮层、生效 toast、分享卡片 |
| 排除名单（精确 + `*` 前缀）、App 级覆盖、Darwin 热重载 | 安全启动自愈、安全模式、配置快照/预设/历史、微信预览放大态探测器 |

源码规模：dylib 585 行（原 3913 行），配置 App 422 行（原 177KB/约 3000 行）。

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
| `Blacklist` | Array | 空 | 排除名单；精确匹配，条目结尾 `*` 表示前缀匹配（如 `com.tencent.*`） |
| `AppOverrides` | Dict | 空 | App 级覆盖：`{ "bundle id" = { Enabled/SceneFake/AudioKeep = 0/1; }; }` |

热重载：配置 App 保存即发 Darwin 通知 `com.local.sioriginalbg.settingschanged`，dylib 主线程串行 reload，无需注销 App。删掉整个 plist 即回出厂默认（三项全开、名单清空）。

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
   `[SIOBG] v3.0.0-BG loaded in <bundle id>: active=1 scene=1 audio=1 audioMode=1`；
   后台化被拦截时打 `[SIOBG] swallowed backgrounding scene diff`。
   没装 audio 后台模式又关了场景伪装时，启动行尾会带 WARNING。

## 已知事项

- **微信「两个视频画面」**：v2.4.1 的疑似诱因是场景伪装（吞后台化 diff + 伪造 applicationState），
  本版按你的选择**保留**了该引擎。若复现且确认是它，不用改代码，App 里加一行覆盖即可关：
  `com.tencent.xin scene=0 audio=1`（只关场景伪装，保留音频断言）。
- 内置排除 `com.apple.springboard`（桌面进程是场景宿主，配置无法打开）。
- 音频引擎单独使用时要求宿主 App 自带 `UIBackgroundModes=audio`；配置 App 里「扫描」按钮可看哪些 App 有。
- 看门狗只在真后台运行，回前台立即卸载；低电量周期自动放宽到 6s。
