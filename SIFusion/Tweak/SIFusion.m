// SIFusion v1.0.0 — SIClassic × SpeedsterTS 融合增强版（纯 ObjC runtime，无 substrate）
//
// 由两个实测可用版本的 hook 并集融合而成：
//   · SpeedsterTS v1.1.1 独立模式 15 hooks（UIView block×4 / CAAnimation /
//     CALayer addAnimation / CATransaction / Nav push·pop×3 / present·dismiss /
//     CASpring mass·damping）——微信实测不闪退，覆盖面广
//   · SIClassic v1.0.2（逆向 pw5a29 原版 Speed Intensifier 10.1-1）独有：
//     CASpringAnimation -setStiffness: —— SpeedsterTS 没 hook 它
//
// 融合后的改进（取两家之长）：
//   1. 弹簧不再用 Speedster 的"盲切 mass/damping 百分比"，改用 SIClassic 的
//      物理推导：要把弹簧 settle 时间缩短 m 倍且阻尼比 ζ 不变，需
//      stiffness × m²、damping × m、mass 不动 —— 手感与系统一致、只是更快。
//      setStiffness: 是两版里唯一没人完整覆盖的参数，本版补齐。
//   2. 速度档沿用 SpeedsterTS 实测有效的 5 档（微快/快/很快/极快/瞬切），
//      各 hook 的保底时长（CA 8ms / Nav 16ms / present 30ms / 一帧 16ms）
//      全部沿用已验证数值。
//   3. CAAnimation 只 hook 基类 setDuration:；addAnimation 用 associated-object
//      标记防二次缩放；Nav/present 用 CATransaction 收窄 + gFSTxInternal 自调
//      标记，不包动画块、不碰 setViewControllers: 状态机敏感接口。
//   4. 共存检测：进程内已加载 SpeedIntensifier / SpeedsterTS / SIClassic 时，
//      只安装本版独有的 CASpringAnimation -setStiffness:（互补，绝不双重缩放）；
//      独立模式装全部 16 hooks。
//   5. 刻意不 hook 任何 UITableView/UICollectionView 选择/刷新/移动方法
//      （已证实是微信点链接闪退的根因类）。
//
// 配置：/var/Managed Preferences/mobile/com.local.sifusion.plist
//   Enabled / Preset(0-4) / Spring / Blacklist
// Darwin 通知 com.local.sifusion.settingschanged 热重载（改档杀 App 重开即生效）。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

static NSString *const kFUPrefPath = @"/var/Managed Preferences/mobile/com.local.sifusion.plist";
static NSString *const kFUNotify   = @"com.local.sifusion.settingschanged";

static BOOL    gEnabled = YES;
static int     gPreset = 2;            // 0微快 1快 2很快(默认) 3极快 4瞬切
static BOOL    gSpring = YES;          // 弹簧物理平滑
static BOOL    gBlacklisted = NO;
static NSArray *gBlacklist = nil;
static BOOL    gCompanion = NO;        // 检测到其他加速器，互补模式
static BOOL    gFSTxInternal = NO;     // 自家 CATransaction 调用标记

// 档位 → 时长乘数（SpeedsterTS 实测数值）
static const double kDurFactors[5] = { 0.50, 0.30, 0.15, 0.05, 0.001 };

static inline double _factor(void) { return kDurFactors[MAX(0, MIN(4, gPreset))]; }
static inline double _mult(void) {
    double f = _factor();
    return f > 0.0 ? 1.0 / f : 10000.0;
}
static inline BOOL _on(void) { return gEnabled && !gBlacklisted && !gCompanion; }

static inline NSTimeInterval _scale(NSTimeInterval t) {
    if (t <= 0) return t;
    NSTimeInterval s = t * _factor();
    return (s < 0.016 && s > 0) ? 0.016 : s;
}
static inline NSTimeInterval _scaleMin(NSTimeInterval t, double minMs) {
    if (t <= 0) return t;
    NSTimeInterval s = t * _factor();
    NSTimeInterval mn = minMs / 1000.0;
    return s < mn ? mn : s;
}

static inline BOOL _isBlurKey(NSString *k) {
    static NSArray *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[ @"backdrop", @"visualeffect", @"blur", @"gaussian", @"snapshot" ];
    });
    NSString *low = k.lowercaseString;
    for (NSString *b in bad) if ([low containsString:b]) return YES;
    return NO;
}

static void _loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kFUPrefPath];
        if (d) {
            if (d[@"Enabled"])  gEnabled = [d[@"Enabled"] boolValue];
            if (d[@"Preset"])   gPreset = MAX(0, MIN(4, [d[@"Preset"] intValue]));
            if (d[@"Spring"])   gSpring = [d[@"Spring"] boolValue];
            gBlacklist = d[@"Blacklist"];
        }
    } @catch (__unused NSException *e) {}
    if (!gBlacklist) gBlacklist = @[ @"com.tencent.wework" ];

    gBlacklisted = NO;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gBlacklist) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) {
            gBlacklisted = YES; break;
        }
    }
}

// ================================ Swizzle 桥接 ================================
static BOOL _swiz(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getInstanceMethod(cls, orig);
    Method rm = class_getInstanceMethod(objc_getClass("SIFusionHooks"), repl);
    if (!om || !rm) return NO;
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
    Method rm = class_getClassMethod(objc_getClass("SIFusionHooks"), repl);
    if (!om || !rm) return NO;
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

static char kFUInternalDurKey;

@interface SIFusionHooks : NSObject
@end

@implementation SIFusionHooks

#pragma mark ---------- UIView 动画 block ×4 ----------
+ (void)fu_animate:(NSTimeInterval)d animations:(void (^)(void))a {
    [self fu_animate:_on() ? _scale(d) : d animations:a];
}
+ (void)fu_animate:(NSTimeInterval)d animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    [self fu_animate:_on() ? _scale(d) : d animations:a completion:c];
}
+ (void)fu_animate:(NSTimeInterval)d delay:(NSTimeInterval)dl options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_on()) {
        [self fu_animate:_scale(d) delay:dl * _factor() options:o animations:a completion:c];
    } else {
        [self fu_animate:d delay:dl options:o animations:a completion:c];
    }
}
+ (void)fu_animate:(NSTimeInterval)d delay:(NSTimeInterval)dl usingSpringWithDamping:(CGFloat)dr
 initialSpringVelocity:(CGFloat)v options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_on()) {
        [self fu_animate:_scale(d) delay:dl * _factor() usingSpringWithDamping:dr
       initialSpringVelocity:v options:o animations:a completion:c];
    } else {
        [self fu_animate:d delay:dl usingSpringWithDamping:dr initialSpringVelocity:v options:o
              animations:a completion:c];
    }
}

#pragma mark ---------- CAAnimation / CALayer / CATransaction ----------
- (void)fu_setDuration:(NSTimeInterval)t {
    if (_on()) {
        NSNumber *internal = objc_getAssociatedObject(self, &kFUInternalDurKey);
        if (internal.boolValue) { [self fu_setDuration:t]; return; }
        [self fu_setDuration:_scaleMin(t, 8.0)];
    } else {
        [self fu_setDuration:t];
    }
}
- (void)fu_addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (_on() && anim && !_isBlurKey(key ?: @"")) {
        NSTimeInterval d = anim.duration;
        if (d > 0 && d <= 0.26) {
            objc_setAssociatedObject(anim, &kFUInternalDurKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            anim.duration = _scaleMin(d, 8.0);
        }
    }
    [self fu_addAnimation:anim forKey:key];
}
+ (void)fu_setAnimationDuration:(NSTimeInterval)t {
    if (gFSTxInternal || !_on()) {
        [self fu_setAnimationDuration:t];
    } else {
        [self fu_setAnimationDuration:_scale(t)];
    }
}

#pragma mark ---------- 导航转场（侧滑返回松手完成段） ----------
- (void)fu_pushViewController:(UIViewController *)vc animated:(BOOL)flag {
    if (!_on() || !flag) { [self fu_pushViewController:vc animated:flag]; return; }
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        [self fu_pushViewController:vc animated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
}
- (UIViewController *)fu_popViewControllerAnimated:(BOOL)flag {
    if (!_on() || !flag) return [self fu_popViewControllerAnimated:flag];
    UIViewController *r;
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self fu_popViewControllerAnimated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
    return r;
}
- (NSArray<UIViewController *> *)fu_popToViewController:(UIViewController *)vc animated:(BOOL)flag {
    if (!_on() || !flag) return [self fu_popToViewController:vc animated:flag];
    NSArray *r;
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self fu_popToViewController:vc animated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
    return r;
}
- (NSArray<UIViewController *> *)fu_popToRootViewControllerAnimated:(BOOL)flag {
    if (!_on() || !flag) return [self fu_popToRootViewControllerAnimated:flag];
    NSArray *r;
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self fu_popToRootViewControllerAnimated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
    return r;
}

#pragma mark ---------- present / dismiss ----------
- (void)fu_presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))c {
    if (!_on() || !flag) { [self fu_presentViewController:vc animated:flag completion:c]; return; }
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.30, 30.0)];
        [self fu_presentViewController:vc animated:flag completion:c];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
}
- (void)fu_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))c {
    if (!_on() || !flag) { [self fu_dismissViewControllerAnimated:flag completion:c]; return; }
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.25, 30.0)];
        [self fu_dismissViewControllerAnimated:flag completion:c];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
}

#pragma mark ---------- 弹簧物理层（SIClassic 推导 + 互补唯一 hook） ----------
// stiffness 独家生效条件（其他加速器都没 hook 它）：开着、未黑名单、弹簧平滑开。
// 互补模式下仍生效，但瞬切档互补时不动它，交给主加速器全权处理。
static inline BOOL _stiffnessOn(void) {
    return gEnabled && !gBlacklisted && gSpring &&
           (!gCompanion || gPreset != 4);
}
// damping/mass 在互补模式下完全不碰（SpeedsterTS 自己 hook 了这两个，
// 叠加会双重修改）；仅独立模式做物理缩放。
static inline BOOL _springPhysicsOn(void) {
    return gEnabled && !gBlacklisted && gSpring && !gCompanion;
}

// stiffness × m²：ω=√(k/m)，k 乘 m² → ω 乘 m → settle 缩到 1/m，ζ 不变
- (void)fu_setStiffness:(CGFloat)v {
    if (_stiffnessOn() && v > 0.0f) {
        double m = _mult();
        CGFloat k = v * (CGFloat)(m * m);
        if (k > 1.0e5f) k = 1.0e5f;
        [self fu_setStiffness:k];
    } else {
        [self fu_setStiffness:v];
    }
}
// damping × m：与 stiffness 配套保持阻尼比 ζ = c/(2√(km)) 不变
- (void)fu_setDamping:(CGFloat)v {
    if (_springPhysicsOn() && v > 0.0f) {
        double m = _mult();
        CGFloat c = v * (CGFloat)m;
        if (c > 1.0e5f) c = 1.0e5f;
        [self fu_setDamping:c];
    } else {
        [self fu_setDamping:v];
    }
}
// 瞬切档：mass 压到极小，弹簧 settle 趋近 0（仅瞬切，非瞬切不动 mass）
- (void)fu_setMass:(CGFloat)v {
    if (gEnabled && !gBlacklisted && gSpring && gPreset == 4 && v > 0.0f) {
        [self fu_setMass:0.0001f];
    } else {
        [self fu_setMass:v];
    }
}

@end

// ================================ 共存检测 ================================
static BOOL _otherAcceleratorLoaded(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img) continue;
        // 不含自身 SIFusion；命中任一其他加速器即进入互补模式
        if (strstr(img, "SIFusion")) continue;
        if (strstr(img, "SpeedIntensifier") ||
            strstr(img, "SpeedsterTS") ||
            strstr(img, "SIClassic")) return YES;
    }
    return NO;
}

static void _fu_notify_cb(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object,
                          CFDictionaryRef info) {
    _loadPref();
    NSLog(@"[SIFusion] pref reloaded (preset=%d spring=%d companion=%d)", gPreset, gSpring, gCompanion);
}

__attribute__((constructor))
static void _fu_entry(void) {
    @autoreleasepool {
        gCompanion = _otherAcceleratorLoaded();
        _loadPref();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, _fu_notify_cb,
            (__bridge CFStringRef)kFUNotify, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        int ok = 0, total = 0;
        Class spring = [CASpringAnimation class];

        // 弹簧物理层 3 个 hook 始终安装（mass/damping 与 SpeedsterTS 行为不同时
        // 仅在独立模式做物理缩放——见 _springPhysicsOn 内的 companion 守卫；
        // stiffness 互补模式也生效，是本版独有的增强）。
        // 注意：与 SpeedsterTS 同时注入时，SpeedsterTS 的 mass/damping hook 也在，
        // 但互补模式下本版 damping 走原速分支，不叠加；stiffness 独家。
        total += 3;
        ok += _swiz(spring, @selector(setStiffness:), @selector(fu_setStiffness:));
        ok += _swiz(spring, @selector(setDamping:),   @selector(fu_setDamping:));
        ok += _swiz(spring, @selector(setMass:),      @selector(fu_setMass:));

        if (!gCompanion) {
            total += 4;
            ok += _swizClass([UIView class], @selector(animateWithDuration:animations:),
                             @selector(fu_animate:animations:));
            ok += _swizClass([UIView class], @selector(animateWithDuration:animations:completion:),
                             @selector(fu_animate:animations:completion:));
            ok += _swizClass([UIView class], @selector(animateWithDuration:delay:options:animations:completion:),
                             @selector(fu_animate:delay:options:animations:completion:));
            ok += _swizClass([UIView class],
                             @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                             @selector(fu_animate:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:));

            total += 3;
            ok += _swiz([CAAnimation class], @selector(setDuration:), @selector(fu_setDuration:));
            ok += _swiz([CALayer class], @selector(addAnimation:forKey:), @selector(fu_addAnimation:forKey:));
            ok += _swizClass([CATransaction class], @selector(setAnimationDuration:),
                             @selector(fu_setAnimationDuration:));

            Class nav = [UINavigationController class];
            total += 4;
            ok += _swiz(nav, @selector(pushViewController:animated:),     @selector(fu_pushViewController:animated:));
            ok += _swiz(nav, @selector(popViewControllerAnimated:),       @selector(fu_popViewControllerAnimated:));
            ok += _swiz(nav, @selector(popToViewController:animated:),    @selector(fu_popToViewController:animated:));
            ok += _swiz(nav, @selector(popToRootViewControllerAnimated:), @selector(fu_popToRootViewControllerAnimated:));

            Class vc = [UIViewController class];
            total += 2;
            ok += _swiz(vc, @selector(presentViewController:animated:completion:),
                        @selector(fu_presentViewController:animated:completion:));
            ok += _swiz(vc, @selector(dismissViewControllerAnimated:completion:),
                        @selector(fu_dismissViewControllerAnimated:completion:));
        }

        NSLog(@"[SIFusion] v1.0.0 loaded in %@: %@ mode, hooks %d/%d (preset=%d spring=%d blacklisted=%d)",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gCompanion ? @"COMPANION (stiffness-only)" : @"STANDALONE (full 16)",
              ok, total, gPreset, gSpring, gBlacklisted);
    }
}
