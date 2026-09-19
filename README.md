# Speed Intensifier (iOS 动画加速)

面向 iOS 14–17（含 iOS 16/17）的动画加速方案，默认最快档 **0.001**，适配 TrollStore / TrollFools，无需 CydiaSubstrate。v1.5.3 共 **61 个 Hook**（v1.5.1 修复注入闪退：仅 hook CAAnimation 基类；v1.5.2 修复注销无效：原生 kill SpringBoard；v1.5.3 微信移出黑名单吃满全量加速，黑名单仅保留企业微信）。

## 产物
- `SpeedIntensifier.dylib` — 核心加速 Tweak（已 ad-hoc 签名），用 TrollFools 注入目标 App（建议注入微信、抖音、淘宝、QQ、美团等）。
- `SpeedIntensifier.ipa` — 配置 App，用 TrollStore 安装；用于写入速度档位 / 瞬切模式、注销 SpringBoard / 重启设备。

## 原理
纯 Objective-C runtime 方法交换（`method_exchangeImplementations`），Hook 以下动画入口，把时长统一乘系数 `factor`（默认 0.001）：

**基础层（19 hook，所有 App 生效）**
- `UIView`：animateWithDuration 全系列、transition 系列
- `UIViewPropertyAnimator`：initWithDuration / setDuration
- `UIScrollView`：setContentOffset:animated / scrollRectToVisible:animated
- `UINavigationController`：push/pop/popTo/popToRoot
- `UITabBarController`：setSelectedIndex
- `UIViewController`：present/dismiss（保底 30ms，避免状态机错乱）
- `CATransaction`：setAnimationDuration

**增强层 ExtraAcceleration（42 hook，默认开；黑名单 App（仅企业微信）不装）**
- 关键帧 / 老式 beginAnimations（setAnimationDuration / setAnimationDelay）/ performSystemAnimation
- `CAAnimation` 全家族：CABasic / CAKeyframe / CASpring / CATransition + `CALayer addAnimation:forKey:`（loading 转轮也极速，自动跳过 backdrop/blur 层）
- `UIViewPropertyAnimator`：addAnimations:delayFactor: / 贝塞尔初始化 / runningPropertyAnimator / startAnimationAfterDelay:
- 页面：`setViewControllers:`、`setSelectedViewController:`、UIPageViewController 翻页、自定义容器转场
- 列表：UITableView / UICollectionView 批量更新、增删改、setEditing、select/deselect、reloadSections、setCollectionViewLayout:
- 栏：UITabBar / UIToolbar / UINavigationBar 的 setItems:
- 控件：UIProgressView / UISwitch / UISlider 动画化设值瞬时到位
- UIWindow / InteractiveTransition / UIContextMenu 等

**保底设计**：页面跳转 / present / dismiss 按 App 类型保底（黑名单 50ms，普通 App 8–30ms），避免 iOS「动画完成信号早于状态机就绪」导致的闪退。

## 配置（可选）
App 会写入 `/var/Managed Preferences/mobile/com.local.speedintensifier.plist`：
```xml
<key>SpeedFactor</key><real>0.001</real>
<key>Enabled</key><true/>
<key>ExtraAcceleration</key><true/>
<key>InstantMode</key><false/>
<key>Blacklist</key><array><string>com.tencent.xin</string><string>com.tencent.wework</string></array>
```
- `InstantMode`：瞬切模式，所有动画时长直接归零（最快；个别 App 异常时关闭即可）。
- dylib 启动时读取；缺省即 0.001 全速 + 增强全开。

## 构建
GitHub Actions 自动构建（`.github/workflows/build.yml`，macos-15）：
- dylib：纯 clang 直编（-O2）+ ad-hoc 签名
- IPA：clang 直编 .app + `codesign --entitlements`（含 no-sandbox）后打包 Payload
- 推送 `v*` tag 自动发布 GitHub Release（含 IPA + dylib）

## 安装
1. TrollStore 安装 `SpeedIntensifier.ipa`（可选，用于调档/注销）。
2. TrollFools 选择目标 App → 注入 `SpeedIntensifier.dylib` → 重开 App 生效。
3. 想全局（含桌面）→ 注入 SpringBoard。
