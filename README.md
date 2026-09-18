# Speed Intensifier (iOS 动画加速)

面向 iOS 14–17（含 iOS 16）的动画加速方案，默认最快档 **0.001**，适配 TrollStore / TrollFools，无需 CydiaSubstrate。

## 产物
- `SpeedIntensifier.dylib` — 核心加速 Tweak，用 TrollFools 注入目标 App（建议注入微信、抖音、淘宝、QQ、美团等）。
- `SpeedIntensifier.ipa` — 配置 App，用 TrollStore 安装；用于写入速度档位、注销 SpringBoard / 重启设备。

## 原理
纯 Objective-C runtime 方法交换（`method_exchangeImplementations`），Hook 以下动画入口，把时长统一乘系数 `factor`（默认 0.001）：
- `UIView`：animateWithDuration 系列、transition 系列
- `UIViewPropertyAnimator`：initWithDuration / setDuration
- `UIScrollView`：setContentOffset:animated / scrollRectToVisible:animated
- `UINavigationController`：push/pop/popTo/popToRoot
- `UITabBarController`：setSelectedIndex
- `UIViewController`：present/dismiss（保底 100ms，避免状态机错乱）
- `CATransaction` / `CAPropertyAnimation`：setDuration（保底 16ms = 1 帧）

**保底设计**：页面跳转 / present / dismiss 保底 50–100ms，避免 iOS「动画完成信号早于状态机就绪」导致的闪退（微信尤其敏感）。

## 配置（可选）
App 会写入 `/var/Managed Preferences/mobile/com.local.speedintensifier.plist`：
```xml
<key>SpeedFactor</key><real>0.001</real>
<key>Enabled</key><true/>
```
dylib 启动时读取；缺省即 0.001 全速。

## 构建
GitHub Actions 自动构建（`.github/workflows/build.yml`，macos-15）：
- dylib：纯 clang 直编
- IPA：clang 直编 .app + `codesign --entitlements`（含 no-sandbox）后打包 Payload

## 安装
1. TrollStore 安装 `SpeedIntensifier.ipa`（可选，用于调档/注销）。
2. TrollFools 选择目标 App → 注入 `SpeedIntensifier.dylib` → 重开 App 生效。
3. 想全局（含桌面）→ 注入 SpringBoard。
