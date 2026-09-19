// SpeedsterTS v1.0.0 — Speedster 的 TrollStore 版移植（纯 ObjC runtime，无 Logos / 无 CydiaSubstrate）
//
// 基于 Speedster by Hoangdus (https://github.com/Hoangdus/Speedster)，GPLv3。
// 由 SpeedIntensifier 项目移植为可 TrollFools 注入的独立 dylib：
//   · 全部 14 个 hook 保留，按「目标类是否存在」安装——
//     第三方 App 内只有 CASpringAnimation 存在，自动只装 2 个 App 内弹簧 hook，
//     SBF*/SBIconView/CSCoverSheet* 等 SpringBoard 私有类不存在时安全跳过（no-op）。
//   · TrollStore 优化：App 内弹簧加速默认开启 + 激进快速默认值（原版默认全关）。
//   · 质量/阻尼乘数钳制下限 0.0001，防零值弹簧异常。
//   · 配置文件：/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist
//     （兼容 rootless 越狱路径 /var/jb/var/mobile/...），键名与原版完全一致；
//     Darwin 通知 com.hoangdus.speedsterprefs-updated 支持改配置后即时重读。
//
// 重要：桌面文件夹 / App 开合 / 开关机 / 切换器 / 锁屏动画的 hook 目标类只存在于
//       SpringBoard，纯 TrollStore 环境无法注入系统进程，这些功能仅在越狱环境生效；
//       TrollFools 注入普通 App 时本 dylib 提供 App 内弹簧动画加速。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ================================
// 配置（键名与原版 Speedster 一致）
// ================================
// App 内
static BOOL   gInApp = YES;             // TS 优化：默认开（原版 NO）
static BOOL   gInAppBounce = NO;
static double gMassValue = 0.7;         // 质量削减量：mass *= (1 - 0.7) = 0.3，弹簧更快
static double gDampingValue = 0.0;      // 阻尼削减量
// App 开合（SpringBoard）
static BOOL   gSpeedEnable = NO;
static int    gSpeedPreset = 3;
static BOOL   gBounceEnable = NO;
static int    gBouncePreset = 3;
static BOOL   gFineSpeed = NO;
static BOOL   gFineBounce = NO;
static double gFineSpeedValue = 0.0;
static double gFineBounceValue = 0.0;
static double gSwitcherDismiss = -1;
// 文件夹（SpringBoard）
static BOOL   gFolderEnable = NO;
static BOOL   gFolderBounce = NO;
static double gFolderDampingValue = 0.0;
static double gFolderMassValue = 0.0;
static BOOL   gInstantFolder = NO;
// 开关机（SpringBoard）
static BOOL   gWakeEnable = NO;
static BOOL   gSleepEnable = NO;
static double gWakeValue = 2.0;
static double gSleepValue = 0.01;
// 杂项开关（SpringBoard）
static BOOL   gNoFly = NO;
static BOOL   gNoIconZoom = NO;
static BOOL   gNoWallZoom = NO;
static BOOL   gNoShaking = NO;

static BOOL gIsOnSpringBoard = NO;

static double _clampMult(double v) {
    double m = 1.0 - v;
    if (m < 0.0001) m = 0.0001;
    if (m > 1.0) m = 1.0;
    return m;
}

// 原版滑块反转
static double _reverseSpeedSlider(double v)        { return 0.45 - v; }
static double _reverseBounceSlider(double v)       { return 1.1 - v; }
static double _reverseTurnOff(double v)            { return 0.91 - v; }
static double _reverseFolderSlider(double v)       { return 1.0 - v; }

static void _loadPrefs(__unused CFNotificationCenterRef c, __unused void *o,
                       __unused CFNotificationName n, __unused void *ui, __unused void *ud) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist"];
    if (!p) p = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/jb/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist"];

    NSNumber *(^num)(NSString *) = ^NSNumber *(NSString *k) {
        id v = p[k];
        return [v isKindOfClass:[NSNumber class]] ? v : nil;
    };
    NSNumber *x;
    if ((x = num(@"InAppAnimationEnabled")))    gInApp = x.boolValue;
    if ((x = num(@"isInAppBounceEnabled")))     gInAppBounce = x.boolValue;
    if ((x = num(@"DurationMassValue")))        gMassValue = x.doubleValue;
    if ((x = num(@"DampingValue")))             gDampingValue = x.doubleValue;
    if ((x = num(@"isSpeedEnable")))            gSpeedEnable = x.boolValue;
    if ((x = num(@"Speedvalue")))               gSpeedPreset = x.intValue;
    if ((x = num(@"isBounceEnable")))           gBounceEnable = x.boolValue;
    if ((x = num(@"Bouncevalue")))              gBouncePreset = x.intValue;
    if ((x = num(@"isFineTuneSpeedEnable")))    gFineSpeed = x.boolValue;
    if ((x = num(@"isFineTuneBounceEnable")))   gFineBounce = x.boolValue;
    if ((x = num(@"FineTuneSpeedValue")))       gFineSpeedValue = x.doubleValue;
    if ((x = num(@"FineTuneBounceValue")))      gFineBounceValue = x.doubleValue;
    if ((x = num(@"isFolderAnimationEnabled"))) gFolderEnable = x.boolValue;
    if ((x = num(@"isFolderBounceEnabled")))    gFolderBounce = x.boolValue;
    if ((x = num(@"FolderDampingValue")))       gFolderDampingValue = x.doubleValue;
    if ((x = num(@"FolderMassValue")))          gFolderMassValue = x.doubleValue;
    if ((x = num(@"InstantFolder")))            gInstantFolder = x.boolValue;
    if ((x = num(@"isScreenwakeEnable")))       gWakeEnable = x.boolValue;
    if ((x = num(@"isScreensleepEnable")))      gSleepEnable = x.boolValue;
    if ((x = num(@"Screenwakevalue")))          gWakeValue = x.doubleValue;
    if ((x = num(@"Screensleepvalue")))         gSleepValue = x.doubleValue;
    if ((x = num(@"nofly")))                    gNoFly = x.boolValue;
    if ((x = num(@"nozoom")))                   gNoIconZoom = x.boolValue;
    if ((x = num(@"noWPzoom")))                 gNoWallZoom = x.boolValue;
    if ((x = num(@"noshaking")))                gNoShaking = x.boolValue;
    NSLog(@"[SpeedsterTS] prefs reloaded: inApp=%d mass=%.2f bounce=%d", gInApp, gMassValue, gInAppBounce);
}

// ================================
// Swizzle 辅助（桥接实现，与 SpeedIntensifier 同款成熟模式）
// ================================
static BOOL _swiz(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getInstanceMethod(cls, orig);
    Method rm = class_getInstanceMethod(objc_getClass("SpeedsterTSHooks"), repl);
    if (!om || !rm) { NSLog(@"[SpeedsterTS] MISSING %@ on %@", NSStringFromSelector(orig), cls); return NO; }
    if (!class_addMethod(cls, repl, method_getImplementation(rm), method_getTypeEncoding(rm))) {
        Method e = class_getInstanceMethod(cls, repl);
        if (!e) return NO;
        method_exchangeImplementations(om, e);
        return YES;
    }
    Method added = class_getInstanceMethod(cls, repl);
    method_exchangeImplementations(om, added);
    return YES;
}

@interface SpeedsterTSHooks : NSObject
@end

@implementation SpeedsterTSHooks

#pragma mark ---------- App 内：CASpringAnimation（第三方 App 唯一生效的一组）----------
- (void)st_setMass:(double)m {
    if (gInApp && !gIsOnSpringBoard) {
        [self st_setMass:m * _clampMult(gMassValue)];
    } else {
        [self st_setMass:m];
    }
}

- (void)st_setDamping:(double)d {
    if (gInApp && gInAppBounce && !gIsOnSpringBoard) {
        [self st_setDamping:d * _clampMult(gDampingValue)];
    } else {
        [self st_setDamping:d];
    }
}

#pragma mark ---------- SpringBoard：App 开合 SBFFluidBehaviorSettings ----------
- (void)st_setResponse:(double)arg1 {
    if (gSpeedEnable) {
        double v;
        if (gFineSpeed) {
            v = _reverseSpeedSlider(gFineSpeedValue);
            double sd = -1;
            if (v < 0.4  && v >= 0.37) sd = 0.2;
            else if (v < 0.37 && v >= 0.25) sd = 0.17;
            else if (v < 0.25 && v >= 0.19) sd = 0.15;
            else if (v < 0.19 && v >= 0.1)  sd = 0.12;
            else if (v < 0.1) sd = 0.1;
            gSwitcherDismiss = sd;
        } else {
            switch (gSpeedPreset) {
                case 1: v = 0.37; gSwitcherDismiss = 0.2;  break;
                case 2: v = 0.25; gSwitcherDismiss = 0.17; break;
                case 3: v = 0.19; gSwitcherDismiss = 0.15; break;
                case 4: v = 0.1;  gSwitcherDismiss = 0.12; break;
                case 5: v = 0.07; gSwitcherDismiss = 0.1;  break;
                default: v = arg1; gSwitcherDismiss = -1;   break;
            }
        }
        [self st_setResponse:v];
    } else {
        gSwitcherDismiss = -1;
        [self st_setResponse:arg1];
    }
}

- (void)st_setDampingRatio:(double)arg1 {
    if (gBounceEnable) {
        double v;
        if (gFineBounce) {
            v = _reverseBounceSlider(gFineBounceValue);
        } else {
            switch (gBouncePreset) {
                case 1: v = 0.9; break;
                case 2: v = 0.8; break;
                case 3: v = 0.6; break;
                case 4: v = 0.4; break;
                case 5: v = 0.2; break;
                default: v = arg1; break;
            }
        }
        [self st_setDampingRatio:v];
    } else {
        [self st_setDampingRatio:arg1];
    }
}

#pragma mark ---------- SpringBoard：文件夹 SBFAnimationSettings ----------
- (void)st_sbf_setDamping:(double)arg1 {
    if (gInstantFolder) {
        [self st_sbf_setDamping:arg1];
    } else if (gFolderEnable && gFolderBounce) {
        [self st_sbf_setDamping:arg1 * _reverseFolderSlider(gFolderDampingValue)];
    } else {
        [self st_sbf_setDamping:arg1];
    }
}

- (void)st_sbf_setMass:(double)arg1 {
    if (gInstantFolder) {
        [self st_sbf_setMass:arg1 * 0.0001];
    } else if (gFolderEnable) {
        [self st_sbf_setMass:arg1 * _reverseFolderSlider(gFolderMassValue)];
    } else {
        [self st_sbf_setMass:arg1];
    }
}

#pragma mark ---------- SpringBoard：开关机 SBFWakeAnimationSettings ----------
- (double)st_backlightFadeDuration {
    if (gSleepEnable) return _reverseTurnOff(gSleepValue);
    return [self st_backlightFadeDuration];
}

- (double)st_speedMultiplierForWake {
    if (gWakeEnable) return gWakeValue;
    return [self st_speedMultiplierForWake];
}

- (double)st_speedMultiplierForLiftToWake {
    if (gWakeEnable) return gWakeValue;
    return [self st_speedMultiplierForLiftToWake];
}

#pragma mark ---------- SpringBoard：切换器 SBFluidSwitcherAnimationSettings ----------
- (void)st_setWallpaperScaleInSwitcher:(double)arg1 {
    [self st_setWallpaperScaleInSwitcher:gNoWallZoom ? 1 : arg1];
}

- (void)st_setHomeScreenScaleInSwitcher:(double)arg1 {
    [self st_setHomeScreenScaleInSwitcher:gNoIconZoom ? 1 : arg1];
}

- (double)st_emptySwitcherDismissDelay {
    if (gSwitcherDismiss != -1) return gSwitcherDismiss;
    return [self st_emptySwitcherDismissDelay];
}

#pragma mark ---------- SpringBoard：锁屏 CSCoverSheetTransitionSettings ----------
- (BOOL)st_iconsFlyIn {
    if (gNoFly) return NO;
    return YES;
}

#pragma mark ---------- SpringBoard：图标抖动 SBIconView ----------
- (void)st_setEditingAnimationStrength:(CGFloat)arg1 {
    [self st_setEditingAnimationStrength:gNoShaking ? 0 : arg1];
}

@end

// ================================
// 装载
// ================================
__attribute__((constructor))
static void SpeedsterTSCtor(void) {
    @autoreleasepool {
        gIsOnSpringBoard = [[[NSBundle mainBundle] bundleIdentifier]
                            isEqualToString:@"com.apple.springboard"];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, _loadPrefs,
            CFSTR("com.hoangdus.speedsterprefs-updated"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        _loadPrefs(NULL, NULL, NULL, NULL, NULL);

        int ok = 0, total = 0;

        // ① App 内（类在所有 UIKit 进程存在）
        Class spring = [CASpringAnimation class];
        total += 2;
        ok += _swiz(spring, @selector(setMass:),    @selector(st_setMass:));
        ok += _swiz(spring, @selector(setDamping:), @selector(st_setDamping:));

        // ② SpringBoard 私有类（普通 App 内为 nil，安全跳过；越狱注入 SpringBoard 时激活）
        Class fluid = NSClassFromString(@"SBFFluidBehaviorSettings");
        if (fluid) {
            total += 2;
            ok += _swiz(fluid, @selector(setResponse:),     @selector(st_setResponse:));
            ok += _swiz(fluid, @selector(setDampingRatio:), @selector(st_setDampingRatio:));
        }
        Class sbfAnim = NSClassFromString(@"SBFAnimationSettings");
        if (sbfAnim) {
            total += 2;
            ok += _swiz(sbfAnim, @selector(setDamping:), @selector(st_sbf_setDamping:));
            ok += _swiz(sbfAnim, @selector(setMass:),    @selector(st_sbf_setMass:));
        }
        Class wake = NSClassFromString(@"SBFWakeAnimationSettings");
        if (wake) {
            total += 3;
            ok += _swiz(wake, @selector(backlightFadeDuration),          @selector(st_backlightFadeDuration));
            ok += _swiz(wake, @selector(speedMultiplierForWake),         @selector(st_speedMultiplierForWake));
            ok += _swiz(wake, @selector(speedMultiplierForLiftToWake),   @selector(st_speedMultiplierForLiftToWake));
        }
        Class sw = NSClassFromString(@"SBFluidSwitcherAnimationSettings");
        if (sw) {
            total += 3;
            ok += _swiz(sw, @selector(setWallpaperScaleInSwitcher:), @selector(st_setWallpaperScaleInSwitcher:));
            ok += _swiz(sw, @selector(setHomeScreenScaleInSwitcher:), @selector(st_setHomeScreenScaleInSwitcher:));
            ok += _swiz(sw, @selector(emptySwitcherDismissDelay),     @selector(st_emptySwitcherDismissDelay));
        }
        Class cover = NSClassFromString(@"CSCoverSheetTransitionSettings");
        if (cover) {
            total += 1;
            ok += _swiz(cover, @selector(iconsFlyIn), @selector(st_iconsFlyIn));
        }
        Class icon = NSClassFromString(@"SBIconView");
        if (icon) {
            total += 1;
            ok += _swiz(icon, @selector(setEditingAnimationStrength:), @selector(st_setEditingAnimationStrength:));
        }

        NSLog(@"[SpeedsterTS] loaded in %@ (springboard=%d): hooks %d/%d",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?", gIsOnSpringBoard, ok, total);
    }
}
