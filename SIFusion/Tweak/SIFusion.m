// SIFusion v1.2.0 — SIClassic × SpeedsterTS 融合增强版（纯 ObjC runtime，无 substrate）
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
//      只安装弹簧物理层 hooks（互补，绝不双重缩放）；独立模式装全部 20 hooks。
//   5. 刻意不 hook 任何 UITableView/UICollectionView 选择/刷新/移动方法
//      （已证实是微信点链接闪退的根因类）。
//   6. v1.1.0 高级模式（对标 Speedy 的程序动画独立倍率）：
//      Advanced 开启后，持续时间倍数覆盖 5 档档位表，刚性/阻尼/质量/初始速率
//      按用户倍率直接缩放（1.0 = 不变）；关闭时保持 v1.0.1 物理公式行为。
//   7. v1.2.0 新增：UIView transitionWithView/FromView 容器转场 ×2、
//      UINavigationController _setTransitionDuration:（侧滑返回松手完成段，
//      私有 selector 缺失时安全跳过）、层时钟叠加 LayerSpeed（实验：在
//      addAnimation 里按档位倍数设置 CALayer.speed，兜底加速未被时长 hook
//      覆盖的私有动画路径；默认关，与档位叠乘）。
//
// 配置：/var/Managed Preferences/mobile/com.local.sifusion.plist
//   Enabled / Preset(0-4) / Spring / Blacklist
//   Advanced / DurMult / VelMult / StiffMult / DampMult / MassMult（高级模式倍率）
//   LayerSpeed（层时钟叠加，实验）
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

// 高级模式（Speedy 式独立倍率）：开启后覆盖档位表与弹簧物理公式
static BOOL    gAdvanced = NO;
static double  gDurMult   = 0.15;      // 持续时间倍数
static double  gVelMult   = 1.0;       // 初始速率倍数（setVelocity:）
static double  gStiffMult = 1.0;       // 刚性倍数
static double  gDampMult  = 1.0;       // 阻尼倍数
static double  gMassMult  = 1.0;       // 质量倍数
static BOOL    gLayerSpeed = NO;       // 层时钟叠加（实验，默认关）

// 档位 → 时长乘数（SpeedsterTS 实测数值）
static const double kDurFactors[5] = { 0.50, 0.30, 0.15, 0.05, 0.001 };

static inline double _factor(void) {
    if (gAdvanced) {
        double f = gDurMult;
        return (f < 0.001) ? 0.001 : (f > 1.0 ? 1.0 : f);
    }
    return kDurFactors[MAX(0, MIN(4, gPreset))];
}
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
            if (d[@"Advanced"]) gAdvanced = [d[@"Advanced"] boolValue];
            double dv;
            if ((dv = [d[@"DurMult"] doubleValue])   > 0) gDurMult   = dv;
            if ((dv = [d[@"VelMult"] doubleValue])   > 0) gVelMult   = dv;
            if ((dv = [d[@"StiffMult"] doubleValue]) > 0) gStiffMult = dv;
            if ((dv = [d[@"DampMult"] doubleValue])  > 0) gDampMult  = dv;
            if ((dv = [d[@"MassMult"] doubleValue])  > 0) gMassMult  = dv;
            if (d[@"LayerSpeed"]) gLayerSpeed = [d[@"LayerSpeed"] boolValue];
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
        // 层时钟叠加（实验）：按档位倍数加速本层的动画时钟，兜底覆盖
        // 未被时长 hook 触达的私有动画路径；与档位叠乘，上限 20 倍
        if (gLayerSpeed) {
            CGFloat sp = (CGFloat)(1.0 / _factor());
            if (sp > 20.0f) sp = 20.0f;
            if (sp > 1.0f) self.speed = sp;
        }
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

#pragma mark ---------- 容器转场（v1.2.0：transitionWithView/FromView） ----------
+ (void)fu_transitionWithView:(UIView *)view duration:(NSTimeInterval)d options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    [self fu_transitionWithView:view duration:_on() ? _scale(d) : d
                        options:o animations:a completion:c];
}
+ (void)fu_transitionFromView:(UIView *)from toView:(UIView *)to duration:(NSTimeInterval)d
                      options:(UIViewAnimationOptions)o completion:(void (^)(BOOL))c {
    [self fu_transitionFromView:from toView:to duration:_on() ? _scale(d) : d
                        options:o completion:c];
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
// v1.2.0：侧滑返回松手后的完成段走这里（私有时长 setter）；selector 缺失时
// _swiz 安全跳过。交互转场不走 push/pop hook，这是该段的唯一收窄点。
- (void)fu_setTransitionDuration:(NSTimeInterval)t {
    if (_on() && t > 0) {
        [self fu_setTransitionDuration:_scaleMin(t, 16.0)];
    } else {
        [self fu_setTransitionDuration:t];
    }
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

// stiffness：高级模式按用户倍率直接缩放；普通模式用物理推导 × m²：
// ω=√(k/m)，k 乘 m² → ω 乘 m → settle 缩到 1/m，ζ 不变
- (void)fu_setStiffness:(CGFloat)v {
    if (_stiffnessOn() && v > 0.0f) {
        CGFloat k;
        if (gAdvanced) {
            k = v * (CGFloat)gStiffMult;
        } else {
            double m = _mult();
            k = v * (CGFloat)(m * m);
        }
        if (k > 1.0e5f) k = 1.0e5f;
        [self fu_setStiffness:k];
    } else {
        [self fu_setStiffness:v];
    }
}
// damping：高级模式按用户倍率；普通模式 × m 与 stiffness 配套保持阻尼比
// ζ = c/(2√(km)) 不变
- (void)fu_setDamping:(CGFloat)v {
    if (_springPhysicsOn() && v > 0.0f) {
        CGFloat c;
        if (gAdvanced) {
            c = v * (CGFloat)gDampMult;
        } else {
            double m = _mult();
            c = v * (CGFloat)m;
        }
        if (c > 1.0e5f) c = 1.0e5f;
        [self fu_setDamping:c];
    } else {
        [self fu_setDamping:v];
    }
}
// mass：高级模式按用户倍率；普通模式仅瞬切档压到极小（settle 趋近 0）
- (void)fu_setMass:(CGFloat)v {
    if (gAdvanced && _springPhysicsOn() && v > 0.0f) {
        CGFloat mv = v * (CGFloat)gMassMult;
        if (mv > 1.0e5f) mv = 1.0e5f;
        [self fu_setMass:mv];
    } else if (gEnabled && !gBlacklisted && gSpring && gPreset == 4 && v > 0.0f) {
        [self fu_setMass:0.0001f];
    } else {
        [self fu_setMass:v];
    }
}
// 初始速率：仅高级模式生效（Speedy 对标项）；velocity 可为负（方向），保号缩放
- (void)fu_setVelocity:(CGFloat)v {
    if (gAdvanced && _springPhysicsOn() && v != 0.0f) {
        CGFloat nv = v * (CGFloat)gVelMult;
        if (nv > 1.0e5f) nv = 1.0e5f;
        if (nv < -1.0e5f) nv = -1.0e5f;
        [self fu_setVelocity:nv];
    } else {
        [self fu_setVelocity:v];
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

        // 弹簧物理层 4 个 hook 始终安装（stiffness/damping/mass/velocity；
        // mass/damping/velocity 与 SpeedsterTS 行为不同时仅在独立模式做物理缩放
        // ——见 _springPhysicsOn 内的 companion 守卫；stiffness 互补模式也生效）。
        // 注意：与 SpeedsterTS 同时注入时，SpeedsterTS 的 mass/damping hook 也在，
        // 但互补模式下本版 damping 走原速分支，不叠加；stiffness 独家。
        total += 4;
        ok += _swiz(spring, @selector(setStiffness:), @selector(fu_setStiffness:));
        ok += _swiz(spring, @selector(setDamping:),   @selector(fu_setDamping:));
        ok += _swiz(spring, @selector(setMass:),      @selector(fu_setMass:));
        ok += _swiz(spring, @selector(setVelocity:),  @selector(fu_setVelocity:));

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

            // v1.2.0：容器转场 ×2
            total += 2;
            ok += _swizClass([UIView class], @selector(transitionWithView:duration:options:animations:completion:),
                             @selector(fu_transitionWithView:duration:options:animations:completion:));
            ok += _swizClass([UIView class], @selector(transitionFromView:toView:duration:options:completion:),
                             @selector(fu_transitionFromView:toView:duration:options:completion:));

            Class nav = [UINavigationController class];
            total += 5;
            ok += _swiz(nav, @selector(pushViewController:animated:),     @selector(fu_pushViewController:animated:));
            ok += _swiz(nav, @selector(popViewControllerAnimated:),       @selector(fu_popViewControllerAnimated:));
            ok += _swiz(nav, @selector(popToViewController:animated:),    @selector(fu_popToViewController:animated:));
            ok += _swiz(nav, @selector(popToRootViewControllerAnimated:), @selector(fu_popToRootViewControllerAnimated:));
            // 私有时长（侧滑完成段）；缺失时安全跳过
            ok += _swiz(nav, @selector(_setTransitionDuration:), @selector(fu_setTransitionDuration:));

            Class vc = [UIViewController class];
            total += 2;
            ok += _swiz(vc, @selector(presentViewController:animated:completion:),
                        @selector(fu_presentViewController:animated:completion:));
            ok += _swiz(vc, @selector(dismissViewControllerAnimated:completion:),
                        @selector(fu_dismissViewControllerAnimated:completion:));
        }

        NSLog(@"[SIFusion] v1.2.0 loaded in %@: %@ mode, hooks %d/%d (preset=%d spring=%d adv=%d dur=%.3f lspeed=%d blacklisted=%d)",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gCompanion ? @"COMPANION (stiffness-only)" : @"STANDALONE (full 20)",
              ok, total, gPreset, gSpring, gAdvanced, gDurMult, gLayerSpeed, gBlacklisted);
    }
}
