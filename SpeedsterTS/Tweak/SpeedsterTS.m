// SpeedsterTS v1.1.0 — Speedster 的 TrollStore 版移植（纯 ObjC runtime，无 Logos / 无 CydiaSubstrate）
//
// 基于 Speedster by Hoangdus (https://github.com/Hoangdus/Speedster)，GPLv3。
// v1.1.0 增强：原版只 hook CASpringAnimation 质量/阻尼，覆盖面窄（侧滑返回、弹窗、转场、
//   push/pop 等日常动画走的是 UIView block / CATransaction / CAAnimation，不是弹簧）。
//   现合并 12 个成熟的核心时长 hook（UIView 4 + CAAnimation + CALayer + CATransaction
//   + Nav push/pop/popTo×2 + present/dismiss），并在装载时检测 SpeedIntensifier：
//     · 已加载 → 只装 Speedster 独有的弹簧 mass/damping（互补模式，不双重缩放）
//     · 未加载 → 独立全套模式
//   CAAnimation 只 hook 基类 setDuration:（子类继承，重复 hook 会递归栈溢出）；
//   addAnimation 与 setDuration 之间用 associated-object 标记防二次缩放；
//   Nav/present 用 CATransaction 收窄时长（内部调用标记防自 hook），不包动画块，
//   不触碰 UIKit 状态机敏感的 setViewControllers:。
//
// 配置：/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist（键名兼容原版）
//   新增 STSSpeedPreset/STSBouncePreset（0-4），旧 DurationMassValue/DampingValue 仍可回退。
//   Darwin 通知 com.hoangdus.speedsterprefs-updated 即时重读。
//
// 桌面文件夹/App 开合/开关机/切换器等 SpringBoard 私有类 hook 仅在越狱注入 SpringBoard 时激活；
// TrollFools 注入普通 App 时这些类不存在，安全跳过。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

// ================================
// 配置
// ================================
static BOOL   gInApp = YES;             // App 内加速总开关（TS 优化默认开）
static BOOL   gInAppBounce = NO;        // 弹跳阻尼
static int    gPreset = 2;              // 0微快 1快 2很快(默认) 3极快 4秒开
static int    gBouncePreset = 2;

// 档位 → 时长乘数（增强层）与质量/阻尼削减量（Speedster 弹簧层）
static const double kDurFactors[5] = { 0.50, 0.30, 0.15, 0.05, 0.001 };
static const double kMassCuts[5]    = { 0.40, 0.55, 0.70, 0.85, 0.93 };
static const double kDampCuts[5]    = { 0.10, 0.25, 0.40, 0.60, 0.80 };

// SpringBoard 项（仅越狱环境有意义；配置 App 始终显式写 NO）
static BOOL   gSpeedEnable = NO, gBounceEnable = NO, gFineSpeed = NO, gFineBounce = NO;
static int    gSpeedPreset = 3, gBouncePresetSB = 3;
static double gFineSpeedValue = 0, gFineBounceValue = 0;
static double gSwitcherDismiss = -1;
static BOOL   gFolderEnable = NO, gFolderBounce = NO, gInstantFolder = NO;
static double gFolderDampingValue = 0, gFolderMassValue = 0;
static BOOL   gWakeEnable = NO, gSleepEnable = NO;
static double gWakeValue = 2.0, gSleepValue = 0.01;
static BOOL   gNoFly = NO, gNoIconZoom = NO, gNoWallZoom = NO, gNoShaking = NO;

static BOOL gIsOnSpringBoard = NO;
static BOOL gCompanion = NO;            // 检测到 SpeedIntensifier，互补模式
static BOOL gSTTxInternal = NO;         // 自家 CATransaction 调用标记

static double _clampMult(double v) {
    double m = 1.0 - v;
    if (m < 0.0001) m = 0.0001;
    if (m > 1.0) m = 1.0;
    return m;
}
static double _reverseSpeedSlider(double v)  { return 0.45 - v; }
static double _reverseBounceSlider(double v) { return 1.1 - v; }
static double _reverseTurnOff(double v)      { return 0.91 - v; }
static double _reverseFolderSlider(double v) { return 1.0 - v; }

// 增强层状态
static inline BOOL _enhOn(void) { return gInApp && !gIsOnSpringBoard && !gCompanion; }
static inline double _durFactor(void) {
    if (!gInApp || gIsOnSpringBoard || gCompanion) return 1.0;
    return kDurFactors[gPreset];
}
static inline NSTimeInterval _scale(NSTimeInterval t) {
    if (t <= 0) return t;
    NSTimeInterval s = t * _durFactor();
    return (s < 0.016 && s > 0) ? 0.016 : s;       // 保底一帧 16ms
}
static inline NSTimeInterval _scaleMin(NSTimeInterval t, double minMs) {
    if (t <= 0) return t;
    NSTimeInterval s = t * _durFactor();
    NSTimeInterval mn = minMs / 1000.0;
    return s < mn ? mn : s;
}
static inline BOOL _isBlurKey(NSString *k) {
    static NSArray *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[@"backdrop", @"visualeffect", @"blur", @"gaussian", @"snapshot"];
    });
    NSString *low = k.lowercaseString;
    for (NSString *b in bad) if ([low containsString:b]) return YES;
    return NO;
}

static int _presetFromDouble(double v, const double *table) {
    for (int i = 0; i < 5; i++) if (fabs(v - table[i]) < 0.01) return i;
    return 2;
}

static void _loadPrefs(CFNotificationCenterRef center, void *observer,
                       CFNotificationName name, const void *object,
                       CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
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
    if ((x = num(@"STSSpeedPreset")))           gPreset = MAX(0, MIN(4, x.intValue));
    else if ((x = num(@"DurationMassValue")))   gPreset = _presetFromDouble(x.doubleValue, kMassCuts);
    if ((x = num(@"STSBouncePreset")))          gBouncePreset = MAX(0, MIN(4, x.intValue));
    else if ((x = num(@"DampingValue")))        gBouncePreset = _presetFromDouble(x.doubleValue, kDampCuts);
    if ((x = num(@"isSpeedEnable")))            gSpeedEnable = x.boolValue;
    if ((x = num(@"Speedvalue")))               gSpeedPreset = x.intValue;
    if ((x = num(@"isBounceEnable")))           gBounceEnable = x.boolValue;
    if ((x = num(@"Bouncevalue")))              gBouncePresetSB = x.intValue;
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
    NSLog(@"[SpeedsterTS] prefs: inApp=%d preset=%d bounce=%d companion=%d",
          gInApp, gPreset, gInAppBounce, gCompanion);
}

// ================================
// Swizzle 辅助
// ================================
static BOOL _swiz(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getInstanceMethod(cls, orig);
    Method rm = class_getInstanceMethod(objc_getClass("SpeedsterTSHooks"), repl);
    if (!om || !rm) { NSLog(@"[SpeedsterTS] MISSING -%@ on %@", NSStringFromSelector(orig), cls); return NO; }
    if (!class_addMethod(cls, repl, method_getImplementation(rm), method_getTypeEncoding(rm))) {
        Method e = class_getInstanceMethod(cls, repl);
        if (!e) return NO;
        method_exchangeImplementations(om, e);
        return YES;
    }
    method_exchangeImplementations(om, class_getInstanceMethod(cls, repl));
    return YES;
}

static BOOL _swizClass(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getClassMethod(cls, orig);
    Method rm = class_getClassMethod(objc_getClass("SpeedsterTSHooks"), repl);
    if (!om || !rm) { NSLog(@"[SpeedsterTS] MISSING +%@ on %@", NSStringFromSelector(orig), cls); return NO; }
    Class meta = object_getClass(cls);
    if (!class_addMethod(meta, repl, method_getImplementation(rm), method_getTypeEncoding(rm))) {
        Method e = class_getClassMethod(cls, repl);
        if (!e) return NO;
        method_exchangeImplementations(om, e);
        return YES;
    }
    method_exchangeImplementations(om, class_getClassMethod(cls, repl));
    return YES;
}

static char kSTInternalDurKey;

@interface SpeedsterTSHooks : NSObject
@end

@implementation SpeedsterTSHooks

#pragma mark ==================== 增强层：UIView 动画 block（4） ====================
+ (void)st_animate:(NSTimeInterval)d animations:(void (^)(void))a {
    [self st_animate:_enhOn() ? _scale(d) : d animations:a];
}
+ (void)st_animate:(NSTimeInterval)d animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    [self st_animate:_enhOn() ? _scale(d) : d animations:a completion:c];
}
+ (void)st_animate:(NSTimeInterval)d delay:(NSTimeInterval)dl options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_enhOn()) {
        [self st_animate:_scale(d) delay:dl * _durFactor() options:o animations:a completion:c];
    } else {
        [self st_animate:d delay:dl options:o animations:a completion:c];
    }
}
+ (void)st_animate:(NSTimeInterval)d delay:(NSTimeInterval)dl usingSpringWithDamping:(CGFloat)dr
 initialSpringVelocity:(CGFloat)v options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_enhOn()) {
        [self st_animate:_scale(d) delay:dl * _durFactor() usingSpringWithDamping:dr
       initialSpringVelocity:v options:o animations:a completion:c];
    } else {
        [self st_animate:d delay:dl usingSpringWithDamping:dr initialSpringVelocity:v options:o
              animations:a completion:c];
    }
}

#pragma mark ==================== 增强层：CAAnimation / CALayer / CATransaction ====================
// 只 hook CAAnimation 基类（子类继承实现，重复交换会无限递归）
- (void)st_setDuration:(NSTimeInterval)t {
    if (_enhOn()) {
        NSNumber *internal = objc_getAssociatedObject(self, &kSTInternalDurKey);
        if (internal.boolValue) {
            [self st_setDuration:t];                 // addAnimation 内部收窄，不再二次缩放
            return;
        }
        [self st_setDuration:_scaleMin(t, 8.0)];
    } else {
        [self st_setDuration:t];
    }
}

- (void)st_addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (_enhOn() && anim && !_isBlurKey(key ?: @"")) {
        NSTimeInterval d = anim.duration;
        if (d > 0 && d <= 0.26) {                    // 仅收窄系统默认短动画，避开自定义长动画
            objc_setAssociatedObject(anim, &kSTInternalDurKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            anim.duration = _scaleMin(d, 8.0);
        }
    }
    [self st_addAnimation:anim forKey:key];
}

+ (void)st_setAnimationDuration:(NSTimeInterval)t {
    if (gSTTxInternal || !_enhOn()) {
        [self st_setAnimationDuration:t];
    } else {
        [self st_setAnimationDuration:_scale(t)];
    }
}

#pragma mark ==================== 增强层：导航转场（侧滑返回松手完成段走这里） ====================
- (void)st_pushViewController:(UIViewController *)vc animated:(BOOL)flag {
    if (!_enhOn() || !flag) { [self st_pushViewController:vc animated:flag]; return; }
    @try {
        gSTTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        [self st_pushViewController:vc animated:flag];
        [CATransaction commit];
    } @finally { gSTTxInternal = NO; }
}
- (UIViewController *)st_popViewControllerAnimated:(BOOL)flag {
    if (!_enhOn() || !flag) return [self st_popViewControllerAnimated:flag];
    UIViewController *r;
    @try {
        gSTTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self st_popViewControllerAnimated:flag];
        [CATransaction commit];
    } @finally { gSTTxInternal = NO; }
    return r;
}
- (NSArray<UIViewController *> *)st_popToViewController:(UIViewController *)vc animated:(BOOL)flag {
    if (!_enhOn() || !flag) return [self st_popToViewController:vc animated:flag];
    NSArray *r;
    @try {
        gSTTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self st_popToViewController:vc animated:flag];
        [CATransaction commit];
    } @finally { gSTTxInternal = NO; }
    return r;
}
- (NSArray<UIViewController *> *)st_popToRootViewControllerAnimated:(BOOL)flag {
    if (!_enhOn() || !flag) return [self st_popToRootViewControllerAnimated:flag];
    NSArray *r;
    @try {
        gSTTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self st_popToRootViewControllerAnimated:flag];
        [CATransaction commit];
    } @finally { gSTTxInternal = NO; }
    return r;
}

#pragma mark ==================== 增强层：present / dismiss ====================
- (void)st_presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))c {
    if (!_enhOn() || !flag) { [self st_presentViewController:vc animated:flag completion:c]; return; }
    @try {
        gSTTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.30, 30.0)];
        [self st_presentViewController:vc animated:flag completion:c];
        [CATransaction commit];
    } @finally { gSTTxInternal = NO; }
}
- (void)st_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))c {
    if (!_enhOn() || !flag) { [self st_dismissViewControllerAnimated:flag completion:c]; return; }
    @try {
        gSTTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.25, 30.0)];
        [self st_dismissViewControllerAnimated:flag completion:c];
        [CATransaction commit];
    } @finally { gSTTxInternal = NO; }
}

#pragma mark ==================== Speedster 原版：App 内 CASpringAnimation ====================
- (void)st_setMass:(double)m {
    if (gInApp && !gIsOnSpringBoard) {
        [self st_setMass:m * _clampMult(kMassCuts[gPreset])];
    } else {
        [self st_setMass:m];
    }
}
- (void)st_setDamping:(double)d {
    if (gInApp && gInAppBounce && !gIsOnSpringBoard) {
        [self st_setDamping:d * _clampMult(kDampCuts[gBouncePreset])];
    } else {
        [self st_setDamping:d];
    }
}

#pragma mark ==================== Speedster 原版：SpringBoard（类存在才装） ====================
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
        if (gFineBounce) v = _reverseBounceSlider(gFineBounceValue);
        else switch (gBouncePresetSB) {
            case 1: v = 0.9; break; case 2: v = 0.8; break; case 3: v = 0.6;
            case 4: v = 0.4; break; case 5: v = 0.2; break; default: v = arg1; break;
        }
        [self st_setDampingRatio:v];
    } else {
        [self st_setDampingRatio:arg1];
    }
}
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
- (double)st_backlightFadeDuration {
    return gSleepEnable ? _reverseTurnOff(gSleepValue) : [self st_backlightFadeDuration];
}
- (double)st_speedMultiplierForWake {
    return gWakeEnable ? gWakeValue : [self st_speedMultiplierForWake];
}
- (double)st_speedMultiplierForLiftToWake {
    return gWakeEnable ? gWakeValue : [self st_speedMultiplierForLiftToWake];
}
- (void)st_setWallpaperScaleInSwitcher:(double)arg1 {
    [self st_setWallpaperScaleInSwitcher:gNoWallZoom ? 1 : arg1];
}
- (void)st_setHomeScreenScaleInSwitcher:(double)arg1 {
    [self st_setHomeScreenScaleInSwitcher:gNoIconZoom ? 1 : arg1];
}
- (double)st_emptySwitcherDismissDelay {
    return (gSwitcherDismiss != -1) ? gSwitcherDismiss : [self st_emptySwitcherDismissDelay];
}
- (BOOL)st_iconsFlyIn {
    return gNoFly ? NO : YES;
}
- (void)st_setEditingAnimationStrength:(CGFloat)arg1 {
    [self st_setEditingAnimationStrength:gNoShaking ? 0 : arg1];
}

@end

// ================================
// 装载
// ================================
static BOOL _speedIntensifierLoaded(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *img = _dyld_get_image_name(i);
        if (img && strstr(img, "SpeedIntensifier")) return YES;
    }
    return NO;
}

__attribute__((constructor))
static void SpeedsterTSCtor(void) {
    @autoreleasepool {
        gIsOnSpringBoard = [[[NSBundle mainBundle] bundleIdentifier]
                            isEqualToString:@"com.apple.springboard"];
        gCompanion = _speedIntensifierLoaded();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, _loadPrefs,
            CFSTR("com.hoangdus.speedsterprefs-updated"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        _loadPrefs(NULL, NULL, NULL, NULL, NULL);

        int ok = 0, total = 0;

        // ① Speedster 独有：CASpringAnimation 质量/阻尼（任何模式都装，与 SI 互补不冲突）
        Class spring = [CASpringAnimation class];
        total += 2;
        ok += _swiz(spring, @selector(setMass:),    @selector(st_setMass:));
        ok += _swiz(spring, @selector(setDamping:), @selector(st_setDamping:));

        // ② 增强层：仅独立模式安装（companion 模式下这些由 SpeedIntensifier 负责）
        if (!gCompanion) {
            total += 4;
            ok += _swizClass([UIView class], @selector(animateWithDuration:animations:),
                             @selector(st_animate:animations:));
            ok += _swizClass([UIView class], @selector(animateWithDuration:animations:completion:),
                             @selector(st_animate:animations:completion:));
            ok += _swizClass([UIView class], @selector(animateWithDuration:delay:options:animations:completion:),
                             @selector(st_animate:delay:options:animations:completion:));
            ok += _swizClass([UIView class],
                             @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                             @selector(st_animate:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:));

            total += 3;
            ok += _swiz([CAAnimation class], @selector(setDuration:), @selector(st_setDuration:));
            ok += _swiz([CALayer class], @selector(addAnimation:forKey:), @selector(st_addAnimation:forKey:));
            ok += _swizClass([CATransaction class], @selector(setAnimationDuration:),
                             @selector(st_setAnimationDuration:));

            Class nav = [UINavigationController class];
            total += 4;
            ok += _swiz(nav, @selector(pushViewController:animated:),        @selector(st_pushViewController:animated:));
            ok += _swiz(nav, @selector(popViewControllerAnimated:),          @selector(st_popViewControllerAnimated:));
            ok += _swiz(nav, @selector(popToViewController:animated:),       @selector(st_popToViewController:animated:));
            ok += _swiz(nav, @selector(popToRootViewControllerAnimated:),    @selector(st_popToRootViewControllerAnimated:));

            Class vc = [UIViewController class];
            total += 2;
            ok += _swiz(vc, @selector(presentViewController:animated:completion:),
                        @selector(st_presentViewController:animated:completion:));
            ok += _swiz(vc, @selector(dismissViewControllerAnimated:completion:),
                        @selector(st_dismissViewControllerAnimated:completion:));
        }

        // ③ SpringBoard 私有类（普通 App 不存在→跳过；越狱注入 SpringBoard 时激活）
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
            ok += _swiz(wake, @selector(backlightFadeDuration),        @selector(st_backlightFadeDuration));
            ok += _swiz(wake, @selector(speedMultiplierForWake),       @selector(st_speedMultiplierForWake));
            ok += _swiz(wake, @selector(speedMultiplierForLiftToWake), @selector(st_speedMultiplierForLiftToWake));
        }
        Class sw = NSClassFromString(@"SBFluidSwitcherAnimationSettings");
        if (sw) {
            total += 3;
            ok += _swiz(sw, @selector(setWallpaperScaleInSwitcher:), @selector(st_setWallpaperScaleInSwitcher:));
            ok += _swiz(sw, @selector(setHomeScreenScaleInSwitcher:), @selector(st_setHomeScreenScaleInSwitcher:));
            ok += _swiz(sw, @selector(emptySwitcherDismissDelay),     @selector(st_emptySwitcherDismissDelay));
        }
        Class cover = NSClassFromString(@"CSCoverSheetTransitionSettings");
        if (cover) { total += 1; ok += _swiz(cover, @selector(iconsFlyIn), @selector(st_iconsFlyIn)); }
        Class icon = NSClassFromString(@"SBIconView");
        if (icon) {
            total += 1;
            ok += _swiz(icon, @selector(setEditingAnimationStrength:), @selector(st_setEditingAnimationStrength:));
        }

        NSLog(@"[SpeedsterTS] v1.1.0 loaded in %@ (SB=%d): %@ mode, hooks %d/%d",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?", gIsOnSpringBoard,
              gCompanion ? @"COMPANION (spring only)" : @"STANDALONE (full)", ok, total);
    }
}
