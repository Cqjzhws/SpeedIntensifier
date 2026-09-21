// SIOriginal — 原版重制
// 基于 pw5a29 Speed Intensifier 10.1-1 的机制还原（CAAnimation setDuration: 单基类 hook
// + CASpring 参数缩放 + 慢放模式），针对 TrollStore / iOS 16 全新实现：
//   · 无 CydiaSubstrate 依赖，纯 ObjC runtime swizzle（TrollFools 注入友好）
//   · 线程局部标记防 CATransaction/UIView 双重除法（原版未处理的问题）
//   · 慢放（原版 slowDownFactor）与瞬切模式
//   · Darwin 通知热重载配置，黑名单逐进程判断
// 不包含任何 SpeedIntensifier / SIFusion / SpeedsterTS 项目代码，无 TV/CV 变更类 hook。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

#define kPrefDomain  @"com.local.sioriginal"
#define kPrefPath    @"/var/Managed Preferences/mobile/com.local.sioriginal.plist"
#define kNotifyName  @"com.local.sioriginal.settingschanged"

// ---------- 配置 ----------
static BOOL     gEnabled   = YES;
static int      gMode      = 0;      // 0=加速 1=慢放 2=瞬切
static double   gSpeed     = 5.0;    // 加速倍率（时长 ÷ 倍率）
static double   gSlowFactor = 2.0;   // 慢放倍率（时长 × 因子）
static BOOL     gSpring    = YES;    // CASpring 参数缩放
static BOOL     gExtra     = YES;    // 导航/模态进阶转场
static NSString *gBlacklist = nil;   // 逗号拼接，逐进程缓存
static NSString *gSelfBundle = nil;

static pthread_key_t gInUIViewAnimKey;

static inline BOOL FUOR_inUIViewAnim(void)  { return (BOOL)(intptr_t)pthread_getspecific(gInUIViewAnimKey); }
static inline void FUOR_setUIViewAnim(BOOL v){ pthread_setspecific(gInUIViewAnimKey, (void *)(intptr_t)(v ? 1 : 0)); }

static inline double FUOR_targetDuration(double orig) {
    if (!gEnabled) return orig;
    double d;
    switch (gMode) {
        case 1:  d = orig * gSlowFactor; break;            // 慢放
        case 2:  d = 0.0;                  break;           // 瞬切
        default: if (gSpeed <= 1.0001) return orig;
                 d = orig / gSpeed;        break;           // 加速
    }
    if (gMode == 2) d = 0.0;
    if (d > 0.0 && d < 0.02) d = 0.02;                     // 防零时长渲染异常
    return d;
}

static inline double FUOR_springScale(void) {
    // 弹簧时间缩放与倍率一致；慢放时反向放大
    if (!gEnabled) return 1.0;
    if (gMode == 1) return gSlowFactor;
    if (gMode == 2) return 20.0;
    return (gSpeed <= 1.0001) ? 1.0 : gSpeed;
}

static void FUOR_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) return;
    gEnabled = [d[@"Enabled"] boolValue];
    int mode = [d[@"Mode"] intValue];
    gMode = (mode >= 0 && mode <= 2) ? mode : 0;
    double sp = [d[@"Speed"] doubleValue];
    gSpeed = (sp >= 1.0 && sp <= 50.0) ? sp : 5.0;
    double sf = [d[@"SlowFactor"] doubleValue];
    gSlowFactor = (sf > 1.0 && sf <= 10.0) ? sf : 2.0;
    gSpring = d[@"Spring"] ? [d[@"Spring"] boolValue] : YES;
    gExtra  = d[@"Extra"]  ? [d[@"Extra"] boolValue]  : YES;
    gBlacklist = [d[@"Blacklist"] componentsJoinedByString:@","];
}

static void FUOR_settingsChanged(CFNotificationCenterRef center, void *observer,
                                 CFNotificationName name, const void *object,
                                 CFDictionaryRef userInfo) {
    FUOR_reload();
}

static inline BOOL FUOR_blocked(void) {
    if (!gEnabled) return YES;
    if (!gSelfBundle) gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (gSelfBundle.length == 0) return NO;
    if (!gBlacklist) return NO;
    for (NSString *s in [gBlacklist componentsSeparatedByString:@","]) {
        if ([gSelfBundle isEqualToString:[s stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]]]) return YES;
    }
    return NO;
}

// ---------- swizzle 工具 ----------
static void FUOR_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}
static void FUOR_swizzleClass(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getClassMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - CAAnimation（核心：仅基类，子类自动继承）

static void (*sio_CAAnim_setDuration_orig)(id, SEL, double);
static void sio_CAAnim_setDuration(id self, SEL _cmd, double d) {
    if (FUOR_blocked()) { sio_CAAnim_setDuration_orig(self, _cmd, d); return; }
    sio_CAAnim_setDuration_orig(self, _cmd, FUOR_targetDuration(d));
}

#pragma mark - CATransaction

static void sio_CATransaction_setDur(id self, SEL _cmd, double d) {
    if (FUOR_inUIViewAnim() || FUOR_blocked()) {
        sio_CATransaction_setDur_orig(self, _cmd, d);
        return;
    }
    sio_CATransaction_setDur_orig(self, _cmd, FUOR_targetDuration(d));
}
static double (*sio_CATransaction_setDur_orig)(id, SEL, double);

#pragma mark - UIView 块动画（class methods）

static void sio_UV_anim_d(id self, SEL _cmd, double d, void (^a)(void)) {
    if (FUOR_blocked()) { sio_UV_anim_d_orig(self, _cmd, d, a); return; }
    FUOR_setUIViewAnim(YES);
    sio_UV_anim_d_orig(self, _cmd, FUOR_targetDuration(d), a);
    FUOR_setUIViewAnim(NO);
}
static void (*sio_UV_anim_d_orig)(id, SEL, double, void (^)(void));

static void sio_UV_anim_dc(id self, SEL _cmd, double d, void (^a)(void), void (^c)(BOOL)) {
    if (FUOR_blocked()) { sio_UV_anim_dc_orig(self, _cmd, d, a, c); return; }
    FUOR_setUIViewAnim(YES);
    sio_UV_anim_dc_orig(self, _cmd, FUOR_targetDuration(d), a, c);
    FUOR_setUIViewAnim(NO);
}
static void (*sio_UV_anim_dc_orig)(id, SEL, double, void (^)(void), void (^)(BOOL));

static void sio_UV_anim_ddoc(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                             void (^a)(void), void (^c)(BOOL)) {
    if (FUOR_blocked()) { sio_UV_anim_ddoc_orig(self, _cmd, d, delay, o, a, c); return; }
    double f = (gMode == 1) ? gSlowFactor : (gMode == 2 ? 0.0 : (gSpeed <= 1.0001 ? 1.0 : 1.0 / gSpeed));
    FUOR_setUIViewAnim(YES);
    sio_UV_anim_ddoc_orig(self, _cmd, FUOR_targetDuration(d), delay * f, o, a, c);
    FUOR_setUIViewAnim(NO);
}
static void (*sio_UV_anim_ddoc_orig)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

static void sio_UV_anim_spring(id self, SEL _cmd, double d, double damp, double vel,
                               UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    if (FUOR_blocked()) { sio_UV_anim_spring_orig(self, _cmd, d, damp, vel, o, a, c); return; }
    FUOR_setUIViewAnim(YES);
    double m = FUOR_springScale();
    sio_UV_anim_spring_orig(self, _cmd, FUOR_targetDuration(d),
                            1.0 - (1.0 - damp) / m, vel * m, o, a, c);
    FUOR_setUIViewAnim(NO);
}
static void (*sio_UV_anim_spring_orig)(id, SEL, double, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

static void sio_UV_trans(id self, SEL _cmd, UIView *v, double d, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    if (FUOR_blocked()) { sio_UV_trans_orig(self, _cmd, v, d, o, a, c); return; }
    FUOR_setUIViewAnim(YES);
    sio_UV_trans_orig(self, _cmd, v, FUOR_targetDuration(d), o, a, c);
    FUOR_setUIViewAnim(NO);
}
static void (*sio_UV_trans_orig)(id, SEL, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

static void sio_UV_transFrom(id self, SEL _cmd, UIView *a1, UIView *a2, double d,
                             UIViewAnimationOptions o, void (^an)(void), void (^c)(BOOL)) {
    if (FUOR_blocked()) { sio_UV_transFrom_orig(self, _cmd, a1, a2, d, o, an, c); return; }
    FUOR_setUIViewAnim(YES);
    sio_UV_transFrom_orig(self, _cmd, a1, a2, FUOR_targetDuration(d), o, an, c);
    FUOR_setUIViewAnim(NO);
}
static void (*sio_UV_transFrom_orig)(id, SEL, UIView *, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

#pragma mark - CASpring（原版灵魂功能：参数缩放保持物理一致性）

static void sio_CASpring_mass(id self, SEL _cmd, double v) {
    if (FUOR_blocked() || !gSpring) { sio_CASpring_mass_orig(self, _cmd, v); return; }
    double m = FUOR_springScale();
    sio_CASpring_mass_orig(self, _cmd, m > 0 ? v / (m * m) : v);
}
static void (*sio_CASpring_mass_orig)(id, SEL, double);

static void sio_CASpring_stiff(id self, SEL _cmd, double v) {
    if (FUOR_blocked() || !gSpring) { sio_CASpring_stiff_orig(self, _cmd, v); return; }
    double m = FUOR_springScale();
    sio_CASpring_stiff_orig(self, _cmd, v * m * m);
}
static void (*sio_CASpring_stiff_orig)(id, SEL, double);

static void sio_CASpring_damp(id self, SEL _cmd, double v) {
    if (FUOR_blocked() || !gSpring) { sio_CASpring_damp_orig(self, _cmd, v); return; }
    sio_CASpring_damp_orig(self, _cmd, v * FUOR_springScale());
}
static void (*sio_CASpring_damp_orig)(id, SEL, double);

#pragma mark - 导航 / 模态（进阶）

static void sio_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    if (FUOR_blocked() || !gExtra || !anim) { sio_nav_push_orig(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    sio_nav_push_orig(self, _cmd, vc, anim);
    [CATransaction commit];
}
static void (*sio_nav_push_orig)(id, SEL, UIViewController *, BOOL);

static void sio_nav_pop(id self, SEL _cmd, BOOL anim) {
    if (FUOR_blocked() || !gExtra || !anim) { sio_nav_pop_orig(self, _cmd, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    sio_nav_pop_orig(self, _cmd, anim);
    [CATransaction commit];
}
static void (*sio_nav_pop_orig)(id, SEL, BOOL);

static void sio_nav_popTo(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    if (FUOR_blocked() || !gExtra || !anim) { sio_nav_popTo_orig(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    sio_nav_popTo_orig(self, _cmd, vc, anim);
    [CATransaction commit];
}
static void (*sio_nav_popTo_orig)(id, SEL, UIViewController *, BOOL);

static void sio_nav_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    if (FUOR_blocked() || !gExtra || !anim) { sio_nav_setVCs_orig(self, _cmd, vcs, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    sio_nav_setVCs_orig(self, _cmd, vcs, anim);
    [CATransaction commit];
}
static void (*sio_nav_setVCs_orig)(id, SEL, NSArray *, BOOL);

static void sio_nav_privDur(id self, SEL _cmd, double d) {
    if (FUOR_blocked() || !gExtra) { sio_nav_privDur_orig(self, _cmd, d); return; }
    sio_nav_privDur_orig(self, _cmd, FUOR_targetDuration(d));
}
static void (*sio_nav_privDur_orig)(id, SEL, double);

static void sio_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^c)(void)) {
    if (FUOR_blocked() || !gExtra || !anim) { sio_vc_present_orig(self, _cmd, vc, anim, c); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    sio_vc_present_orig(self, _cmd, vc, anim, c);
    [CATransaction commit];
}
static void (*sio_vc_present_orig)(id, SEL, UIViewController *, BOOL, void (^)(void));

static void sio_vc_dismiss(id self, SEL _cmd, BOOL anim, void (^c)(void)) {
    if (FUOR_blocked() || !gExtra || !anim) { sio_vc_dismiss_orig(self, _cmd, anim, c); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    sio_vc_dismiss_orig(self, _cmd, anim, c);
    [CATransaction commit];
}
static void (*sio_vc_dismiss_orig)(id, SEL, BOOL, void (^)(void));

#pragma mark - 安装

__attribute__((constructor))
static void SIOriginalInit(void) {
    pthread_key_create(&gInUIViewAnimKey, NULL);
    gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    FUOR_reload();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    FUOR_settingsChanged,
                                    (__bridge CFStringRef)kNotifyName, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class caAnim = objc_getClass("CAAnimation");
    Class catx   = objc_getClass("CATransaction");
    Class uv     = objc_getClass("UIView");
    Class spring = objc_getClass("CASpringAnimation");
    Class nav    = objc_getClass("UINavigationController");
    Class vc     = objc_getClass("UIViewController");
    if (!caAnim || !uv) return;

    // 核心：CAAnimation setDuration:（仅基类，子类继承，避免 hook 冲突）
    FUOR_swizzleInstance(caAnim, @selector(setDuration:),
                         (IMP)sio_CAAnim_setDuration, (IMP *)&sio_CAAnim_setDuration_orig);

    // 事务时长（UIView 包裹期间跳过，防双除）
    if (catx) FUOR_swizzleInstance(object_getClass(catx), @selector(setAnimationDuration:),
                                   (IMP)sio_CATransaction_setDur, (IMP *)&sio_CATransaction_setDur_orig);

    // UIView 块动画 ×5 + 转场 ×2
    FUOR_swizzleClass(uv, @selector(animateWithDuration:animations:),
                      (IMP)sio_UV_anim_d, (IMP *)&sio_UV_anim_d_orig);
    FUOR_swizzleClass(uv, @selector(animateWithDuration:animations:completion:),
                      (IMP)sio_UV_anim_dc, (IMP *)&sio_UV_anim_dc_orig);
    FUOR_swizzleClass(uv, @selector(animateWithDuration:delay:options:animations:completion:),
                      (IMP)sio_UV_anim_ddoc, (IMP *)&sio_UV_anim_ddoc_orig);
    FUOR_swizzleClass(uv, @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                      (IMP)sio_UV_anim_spring, (IMP *)&sio_UV_anim_spring_orig);
    FUOR_swizzleClass(uv, @selector(transitionWithView:duration:options:animations:completion:),
                      (IMP)sio_UV_trans, (IMP *)&sio_UV_trans_orig);
    FUOR_swizzleClass(uv, @selector(transitionFromView:toView:duration:options:completion:),
                      (IMP)sio_UV_transFrom, (IMP *)&sio_UV_transFrom_orig);

    // 弹簧参数 ×3
    if (spring) {
        FUOR_swizzleInstance(spring, @selector(setMass:),
                             (IMP)sio_CASpring_mass, (IMP *)&sio_CASpring_mass_orig);
        FUOR_swizzleInstance(spring, @selector(setStiffness:),
                             (IMP)sio_CASpring_stiff, (IMP *)&sio_CASpring_stiff_orig);
        FUOR_swizzleInstance(spring, @selector(setDamping:),
                             (IMP)sio_CASpring_damp, (IMP *)&sio_CASpring_damp_orig);
    }

    // 进阶转场 ×7
    if (nav && vc) {
        FUOR_swizzleInstance(nav, @selector(pushViewController:animated:),
                             (IMP)sio_nav_push, (IMP *)&sio_nav_push_orig);
        FUOR_swizzleInstance(nav, @selector(popViewControllerAnimated:),
                             (IMP)sio_nav_pop, (IMP *)&sio_nav_pop_orig);
        FUOR_swizzleInstance(nav, @selector(popToViewController:animated:),
                             (IMP)sio_nav_popTo, (IMP *)&sio_nav_popTo_orig);
        FUOR_swizzleInstance(nav, @selector(setViewControllers:animated:),
                             (IMP)sio_nav_setVCs, (IMP *)&sio_nav_setVCs_orig);
        if (class_getInstanceMethod(nav, @selector(_setTransitionDuration:))) {
            FUOR_swizzleInstance(nav, @selector(_setTransitionDuration:),
                                 (IMP)sio_nav_privDur, (IMP *)&sio_nav_privDur_orig);
        }
        FUOR_swizzleInstance(vc, @selector(presentViewController:animated:completion:),
                             (IMP)sio_vc_present, (IMP *)&sio_vc_present_orig);
        FUOR_swizzleInstance(vc, @selector(dismissViewControllerAnimated:completion:),
                             (IMP)sio_vc_dismiss, (IMP *)&sio_vc_dismiss_orig);
    }
}
