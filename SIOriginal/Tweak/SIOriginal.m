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
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <dlfcn.h>
#import <notify.h>
#import "FUBGNoiseData.h"

#define kPrefDomain  @"com.apple.UIKit"
#define kPrefPath    @"/var/Managed Preferences/mobile/com.apple.UIKit.plist"
#define kNotifyName  @"com.local.sioriginal.settingschanged"

// ---------- 配置 ----------
static BOOL     gEnabled   = YES;
static int      gMode      = 0;      // 0=加速 1=慢放 2=瞬切
static double   gSpeed     = 5.0;    // 加速倍率（时长 ÷ 倍率）
static double   gSlowFactor = 2.0;   // 慢放倍率（时长 × 因子）
static BOOL     gSpring    = YES;    // CASpring 参数缩放
static BOOL     gExtra     = YES;    // 导航/模态进阶转场
static BOOL     gListAccel = YES;    // TV/CV 列表全家桶（微信已硬保护）
static BOOL     gIsWeChat  = NO;     // 硬保护：TV/CV hook 对微信永远关闭
static NSString *gBlacklist = nil;   // 逗号拼接，逐进程缓存
static NSString *gSelfBundle = nil;

static pthread_key_t gInUIViewAnimKey;

static inline BOOL SIO_inUIViewAnim(void)   { return (BOOL)(intptr_t)pthread_getspecific(gInUIViewAnimKey); }
static inline void SIO_setUIViewAnim(BOOL v){ pthread_setspecific(gInUIViewAnimKey, (void *)(intptr_t)(v ? 1 : 0)); }

static inline double SIO_targetDuration(double orig) {
    if (!gEnabled) return orig;
    double d;
    switch (gMode) {
        case 1:  d = orig * gSlowFactor; break;            // 慢放
        case 2:  d = 0.01;               break;            // 瞬切 0.01s
        default:
            if (gSpeed <= 1.0001) return orig;
            d = orig / gSpeed;         break;              // 加速
    }
    if (d > 0.0 && d < 0.01) d = 0.01;                     // 时长下限 0.01s
    return d;
}

static inline double SIO_springScale(void) {
    // 弹簧时间缩放与倍率一致；慢放时反向放大
    if (!gEnabled) return 1.0;
    if (gMode == 1) return gSlowFactor;
    if (gMode == 2) return 20.0;
    return (gSpeed <= 1.0001) ? 1.0 : gSpeed;
}

static void SIO_reload(void) {
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
    gListAccel = d[@"ListAccel"] ? [d[@"ListAccel"] boolValue] : YES;
    gBlacklist = [d[@"Blacklist"] componentsJoinedByString:@","];
}

static void HFP_reload(void);
static void FPS_reload(void);

static void SIO_settingsChanged(CFNotificationCenterRef center, void *observer,
                                CFNotificationName name, const void *object,
                                CFDictionaryRef userInfo) {
    SIO_reload();
    HFP_reload();
    FPS_reload();
}

static inline BOOL SIO_blocked(void) {
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
static void SIO_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}
static void SIO_swizzleClass(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getClassMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

// ---------- 原始 IMP 指针（先声明后引用） ----------
static void   (*o_CAAnim_setDuration)(id, SEL, double);
static void   (*o_CATransaction_setDur)(id, SEL, double);
static void   (*o_UV_anim_d)(id, SEL, double, void (^)(void));
static void   (*o_UV_anim_dc)(id, SEL, double, void (^)(void), void (^)(BOOL));
static void   (*o_UV_anim_ddoc)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_anim_spring)(id, SEL, double, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_trans)(id, SEL, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_UV_transFrom)(id, SEL, UIView *, UIView *, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));
static void   (*o_CASpring_mass)(id, SEL, double);
static void   (*o_CASpring_stiff)(id, SEL, double);
static void   (*o_CASpring_damp)(id, SEL, double);
static void   (*o_nav_push)(id, SEL, UIViewController *, BOOL);
static void   (*o_nav_pop)(id, SEL, BOOL);
static void   (*o_nav_popTo)(id, SEL, UIViewController *, BOOL);
static void   (*o_nav_setVCs)(id, SEL, NSArray *, BOOL);
static void   (*o_nav_privDur)(id, SEL, double);
static void   (*o_vc_present)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void   (*o_vc_dismiss)(id, SEL, BOOL, void (^)(void));

#pragma mark - CAAnimation（核心：仅基类，子类自动继承）

static void sio_CAAnim_setDuration(id self, SEL _cmd, double d) {
    if (SIO_blocked()) { o_CAAnim_setDuration(self, _cmd, d); return; }
    o_CAAnim_setDuration(self, _cmd, SIO_targetDuration(d));
}

#pragma mark - CATransaction

static void sio_CATransaction_setDur(id self, SEL _cmd, double d) {
    if (SIO_inUIViewAnim() || SIO_blocked()) {
        o_CATransaction_setDur(self, _cmd, d);
        return;
    }
    o_CATransaction_setDur(self, _cmd, SIO_targetDuration(d));
}

#pragma mark - UIView 块动画（class methods）

static void sio_UV_anim_d(Class self, SEL _cmd, double d, void (^a)(void)) {
    if (SIO_blocked()) { o_UV_anim_d(self, _cmd, d, a); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_d(self, _cmd, SIO_targetDuration(d), a);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_dc(Class self, SEL _cmd, double d, void (^a)(void), void (^c)(BOOL)) {
    if (SIO_blocked()) { o_UV_anim_dc(self, _cmd, d, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_dc(self, _cmd, SIO_targetDuration(d), a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_ddoc(Class self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                             void (^a)(void), void (^c)(BOOL)) {
    if (SIO_blocked()) { o_UV_anim_ddoc(self, _cmd, d, delay, o, a, c); return; }
    double f = (gMode == 1) ? gSlowFactor : (gMode == 2 ? 0.0 : (gSpeed <= 1.0001 ? 1.0 : 1.0 / gSpeed));
    SIO_setUIViewAnim(YES);
    o_UV_anim_ddoc(self, _cmd, SIO_targetDuration(d), delay * f, o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_spring(Class self, SEL _cmd, double d, double damp, double vel,
                               UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    if (SIO_blocked()) { o_UV_anim_spring(self, _cmd, d, damp, vel, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    double m = SIO_springScale();
    o_UV_anim_spring(self, _cmd, SIO_targetDuration(d),
                     1.0 - (1.0 - damp) / m, vel * m, o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_trans(Class self, SEL _cmd, UIView *v, double d, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    if (SIO_blocked()) { o_UV_trans(self, _cmd, v, d, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_trans(self, _cmd, v, SIO_targetDuration(d), o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_transFrom(Class self, SEL _cmd, UIView *a1, UIView *a2, double d,
                             UIViewAnimationOptions o, void (^an)(void), void (^c)(BOOL)) {
    if (SIO_blocked()) { o_UV_transFrom(self, _cmd, a1, a2, d, o, an, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_transFrom(self, _cmd, a1, a2, SIO_targetDuration(d), o, an, c);
    SIO_setUIViewAnim(NO);
}

#pragma mark - CASpring（原版灵魂功能：参数缩放保持物理一致性）

static void sio_CASpring_mass(id self, SEL _cmd, double v) {
    if (SIO_blocked() || !gSpring) { o_CASpring_mass(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_mass(self, _cmd, m > 0 ? v / (m * m) : v);
}

static void sio_CASpring_stiff(id self, SEL _cmd, double v) {
    if (SIO_blocked() || !gSpring) { o_CASpring_stiff(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_stiff(self, _cmd, v * m * m);
}

static void sio_CASpring_damp(id self, SEL _cmd, double v) {
    if (SIO_blocked() || !gSpring) { o_CASpring_damp(self, _cmd, v); return; }
    o_CASpring_damp(self, _cmd, v * SIO_springScale());
}

#pragma mark - 导航 / 模态（进阶：零时长事务包裹，转场动画交给事务时长统一控制）

static void sio_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    if (SIO_blocked() || !gExtra || !anim) { o_nav_push(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    o_nav_push(self, _cmd, vc, anim);
    [CATransaction commit];
}

static void sio_nav_pop(id self, SEL _cmd, BOOL anim) {
    if (SIO_blocked() || !gExtra || !anim) { o_nav_pop(self, _cmd, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    o_nav_pop(self, _cmd, anim);
    [CATransaction commit];
}

static void sio_nav_popTo(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    if (SIO_blocked() || !gExtra || !anim) { o_nav_popTo(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    o_nav_popTo(self, _cmd, vc, anim);
    [CATransaction commit];
}

static void sio_nav_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    if (SIO_blocked() || !gExtra || !anim) { o_nav_setVCs(self, _cmd, vcs, anim); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    o_nav_setVCs(self, _cmd, vcs, anim);
    [CATransaction commit];
}

static void sio_nav_privDur(id self, SEL _cmd, double d) {
    if (SIO_blocked() || !gExtra) { o_nav_privDur(self, _cmd, d); return; }
    o_nav_privDur(self, _cmd, SIO_targetDuration(d));
}

static void sio_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^c)(void)) {
    if (SIO_blocked() || !gExtra || !anim) { o_vc_present(self, _cmd, vc, anim, c); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    o_vc_present(self, _cmd, vc, anim, c);
    [CATransaction commit];
}

static void sio_vc_dismiss(id self, SEL _cmd, BOOL anim, void (^c)(void)) {
    if (SIO_blocked() || !gExtra || !anim) { o_vc_dismiss(self, _cmd, anim, c); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.0];
    o_vc_dismiss(self, _cmd, anim, c);
    [CATransaction commit];
}

#pragma mark - TV/CV 列表全家桶（ListAccel 控制；com.tencent.xin 硬保护）

static BOOL SIO_listOK(void) { return gListAccel && !gIsWeChat && !SIO_blocked(); }

static void SIO_listWrap(void (^block)(void)) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:SIO_targetDuration(0.25)];
    block();
    [CATransaction commit];
}

// ---- UITableView ----
static void (*o_tv_selectRow)(id, SEL, NSIndexPath *, BOOL, UITableViewScrollPosition);
static void sio_tv_selectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UITableViewScrollPosition pos) {
    if (!SIO_listOK()) { o_tv_selectRow(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_tv_selectRow(self, _cmd, ip, anim, pos); });
}
static void (*o_tv_deselectRow)(id, SEL, NSIndexPath *, BOOL);
static void sio_tv_deselectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    if (!SIO_listOK()) { o_tv_deselectRow(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_tv_deselectRow(self, _cmd, ip, anim); });
}
static void (*o_tv_scrollToRow)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollToRow(id self, SEL _cmd, NSIndexPath *ip, UITableViewScrollPosition pos, BOOL anim) {
    if (!SIO_listOK()) { o_tv_scrollToRow(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollToRow(self, _cmd, ip, pos, anim); });
}
static void (*o_tv_scrollNearest)(id, SEL, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollNearest(id self, SEL _cmd, UITableViewScrollPosition pos, BOOL anim) {
    if (!SIO_listOK()) { o_tv_scrollNearest(self, _cmd, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollNearest(self, _cmd, pos, anim); });
}
static void (*o_tv_reloadData)(id, SEL);
static void sio_tv_reloadData(id self, SEL _cmd) {
    if (!SIO_listOK()) { o_tv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_tv_reloadData(self, _cmd); });
}
static void (*o_tv_reloadRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_reloadRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    if (!SIO_listOK()) { o_tv_reloadRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_reloadRows(self, _cmd, ips, a); });
}
static void (*o_tv_reloadSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_reloadSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    if (!SIO_listOK()) { o_tv_reloadSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_reloadSections(self, _cmd, sec, a); });
}
static void (*o_tv_insertRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_insertRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    if (!SIO_listOK()) { o_tv_insertRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_insertRows(self, _cmd, ips, a); });
}
static void (*o_tv_deleteRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_deleteRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    if (!SIO_listOK()) { o_tv_deleteRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_deleteRows(self, _cmd, ips, a); });
}
static void (*o_tv_moveRow)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_tv_moveRow(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    if (!SIO_listOK()) { o_tv_moveRow(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveRow(self, _cmd, from, to); });
}
static void (*o_tv_insertSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_insertSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    if (!SIO_listOK()) { o_tv_insertSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_insertSections(self, _cmd, sec, a); });
}
static void (*o_tv_deleteSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_deleteSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    if (!SIO_listOK()) { o_tv_deleteSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_deleteSections(self, _cmd, sec, a); });
}
static void (*o_tv_moveSection)(id, SEL, NSUInteger, NSUInteger);
static void sio_tv_moveSection(id self, SEL _cmd, NSUInteger from, NSUInteger to) {
    if (!SIO_listOK()) { o_tv_moveSection(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveSection(self, _cmd, from, to); });
}
static void (*o_tv_setEditing)(id, SEL, BOOL, BOOL);
static void sio_tv_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    if (!SIO_listOK()) { o_tv_setEditing(self, _cmd, editing, anim); return; }
    SIO_listWrap(^{ o_tv_setEditing(self, _cmd, editing, anim); });
}
static void (*o_tv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
static void sio_tv_batchUpdates(id self, SEL _cmd, void (^updates)(void), void (^comp)(BOOL)) {
    if (!SIO_listOK()) { o_tv_batchUpdates(self, _cmd, updates, comp); return; }
    SIO_listWrap(^{ o_tv_batchUpdates(self, _cmd, updates, comp); });
}

// ---- UICollectionView ----
static void (*o_cv_reloadData)(id, SEL);
static void sio_cv_reloadData(id self, SEL _cmd) {
    if (!SIO_listOK()) { o_cv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_cv_reloadData(self, _cmd); });
}
static void (*o_cv_reloadItems)(id, SEL, NSArray *);
static void sio_cv_reloadItems(id self, SEL _cmd, NSArray *ips) {
    if (!SIO_listOK()) { o_cv_reloadItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_reloadItems(self, _cmd, ips); });
}
static void (*o_cv_reloadSections)(id, SEL, NSArray *);
static void sio_cv_reloadSections(id self, SEL _cmd, NSArray *secs) {
    if (!SIO_listOK()) { o_cv_reloadSections(self, _cmd, secs); return; }
    SIO_listWrap(^{ o_cv_reloadSections(self, _cmd, secs); });
}
static void (*o_cv_insertItems)(id, SEL, NSArray *);
static void sio_cv_insertItems(id self, SEL _cmd, NSArray *ips) {
    if (!SIO_listOK()) { o_cv_insertItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_insertItems(self, _cmd, ips); });
}
static void (*o_cv_deleteItems)(id, SEL, NSArray *);
static void sio_cv_deleteItems(id self, SEL _cmd, NSArray *ips) {
    if (!SIO_listOK()) { o_cv_deleteItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_deleteItems(self, _cmd, ips); });
}
static void (*o_cv_moveItem)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_cv_moveItem(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    if (!SIO_listOK()) { o_cv_moveItem(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_cv_moveItem(self, _cmd, from, to); });
}
static void (*o_cv_scrollToItem)(id, SEL, NSIndexPath *, UICollectionViewScrollPosition, BOOL);
static void sio_cv_scrollToItem(id self, SEL _cmd, NSIndexPath *ip, UICollectionViewScrollPosition pos, BOOL anim) {
    if (!SIO_listOK()) { o_cv_scrollToItem(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_cv_scrollToItem(self, _cmd, ip, pos, anim); });
}
static void (*o_cv_selectItem)(id, SEL, NSIndexPath *, BOOL, UICollectionViewScrollPosition);
static void sio_cv_selectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UICollectionViewScrollPosition pos) {
    if (!SIO_listOK()) { o_cv_selectItem(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_cv_selectItem(self, _cmd, ip, anim, pos); });
}
static void (*o_cv_deselectItem)(id, SEL, NSIndexPath *, BOOL);
static void sio_cv_deselectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    if (!SIO_listOK()) { o_cv_deselectItem(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_cv_deselectItem(self, _cmd, ip, anim); });
}

#pragma mark - 安装

__attribute__((constructor))
static void SIOriginalInit(void) {
    pthread_key_create(&gInUIViewAnimKey, NULL);
    gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    gIsWeChat = [gSelfBundle isEqualToString:@"com.tencent.xin"];
    SIO_reload();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    SIO_settingsChanged,
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
    SIO_swizzleInstance(caAnim, @selector(setDuration:),
                        (IMP)sio_CAAnim_setDuration, (IMP *)&o_CAAnim_setDuration);

    // 事务时长（UIView 包裹期间跳过，防双除）
    if (catx) SIO_swizzleInstance(object_getClass(catx), @selector(setAnimationDuration:),
                                  (IMP)sio_CATransaction_setDur, (IMP *)&o_CATransaction_setDur);

    // UIView 块动画 ×5 + 转场 ×2
    SIO_swizzleClass(uv, @selector(animateWithDuration:animations:),
                     (IMP)sio_UV_anim_d, (IMP *)&o_UV_anim_d);
    SIO_swizzleClass(uv, @selector(animateWithDuration:animations:completion:),
                     (IMP)sio_UV_anim_dc, (IMP *)&o_UV_anim_dc);
    SIO_swizzleClass(uv, @selector(animateWithDuration:delay:options:animations:completion:),
                     (IMP)sio_UV_anim_ddoc, (IMP *)&o_UV_anim_ddoc);
    SIO_swizzleClass(uv, @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                     (IMP)sio_UV_anim_spring, (IMP *)&o_UV_anim_spring);
    SIO_swizzleClass(uv, @selector(transitionWithView:duration:options:animations:completion:),
                     (IMP)sio_UV_trans, (IMP *)&o_UV_trans);
    SIO_swizzleClass(uv, @selector(transitionFromView:toView:duration:options:completion:),
                     (IMP)sio_UV_transFrom, (IMP *)&o_UV_transFrom);

    // 弹簧参数 ×3
    if (spring) {
        SIO_swizzleInstance(spring, @selector(setMass:),
                            (IMP)sio_CASpring_mass, (IMP *)&o_CASpring_mass);
        SIO_swizzleInstance(spring, @selector(setStiffness:),
                            (IMP)sio_CASpring_stiff, (IMP *)&o_CASpring_stiff);
        SIO_swizzleInstance(spring, @selector(setDamping:),
                            (IMP)sio_CASpring_damp, (IMP *)&o_CASpring_damp);
    }

    // 进阶转场 ×7
    if (nav && vc) {
        SIO_swizzleInstance(nav, @selector(pushViewController:animated:),
                            (IMP)sio_nav_push, (IMP *)&o_nav_push);
        SIO_swizzleInstance(nav, @selector(popViewControllerAnimated:),
                            (IMP)sio_nav_pop, (IMP *)&o_nav_pop);
        SIO_swizzleInstance(nav, @selector(popToViewController:animated:),
                            (IMP)sio_nav_popTo, (IMP *)&o_nav_popTo);
        SIO_swizzleInstance(nav, @selector(setViewControllers:animated:),
                            (IMP)sio_nav_setVCs, (IMP *)&o_nav_setVCs);
        if (class_getInstanceMethod(nav, @selector(_setTransitionDuration:))) {
            SIO_swizzleInstance(nav, @selector(_setTransitionDuration:),
                                (IMP)sio_nav_privDur, (IMP *)&o_nav_privDur);
        }
        SIO_swizzleInstance(vc, @selector(presentViewController:animated:completion:),
                            (IMP)sio_vc_present, (IMP *)&o_vc_present);
        SIO_swizzleInstance(vc, @selector(dismissViewControllerAnimated:completion:),
                            (IMP)sio_vc_dismiss, (IMP *)&o_vc_dismiss);
    }

    // TV/CV 列表全家桶 ×24（ListAccel 控制，微信硬保护）
    Class tv = objc_getClass("UITableView");
    Class cv = objc_getClass("UICollectionView");
    if (tv) {
        SIO_swizzleInstance(tv, @selector(selectRowAtIndexPath:animated:scrollPosition:),
                            (IMP)sio_tv_selectRow, (IMP *)&o_tv_selectRow);
        SIO_swizzleInstance(tv, @selector(deselectRowAtIndexPath:animated:),
                            (IMP)sio_tv_deselectRow, (IMP *)&o_tv_deselectRow);
        SIO_swizzleInstance(tv, @selector(scrollToRowAtIndexPath:atScrollPosition:animated:),
                            (IMP)sio_tv_scrollToRow, (IMP *)&o_tv_scrollToRow);
        SIO_swizzleInstance(tv, @selector(scrollToNearestSelectedRowAtScrollPosition:animated:),
                            (IMP)sio_tv_scrollNearest, (IMP *)&o_tv_scrollNearest);
        SIO_swizzleInstance(tv, @selector(reloadData),
                            (IMP)sio_tv_reloadData, (IMP *)&o_tv_reloadData);
        SIO_swizzleInstance(tv, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_reloadRows, (IMP *)&o_tv_reloadRows);
        SIO_swizzleInstance(tv, @selector(reloadSections:withRowAnimation:),
                            (IMP)sio_tv_reloadSections, (IMP *)&o_tv_reloadSections);
        SIO_swizzleInstance(tv, @selector(insertRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_insertRows, (IMP *)&o_tv_insertRows);
        SIO_swizzleInstance(tv, @selector(deleteRowsAtIndexPaths:withRowAnimation:),
                            (IMP)sio_tv_deleteRows, (IMP *)&o_tv_deleteRows);
        SIO_swizzleInstance(tv, @selector(moveRowAtIndexPath:toIndexPath:),
                            (IMP)sio_tv_moveRow, (IMP *)&o_tv_moveRow);
        SIO_swizzleInstance(tv, @selector(insertSections:withRowAnimation:),
                            (IMP)sio_tv_insertSections, (IMP *)&o_tv_insertSections);
        SIO_swizzleInstance(tv, @selector(deleteSections:withRowAnimation:),
                            (IMP)sio_tv_deleteSections, (IMP *)&o_tv_deleteSections);
        SIO_swizzleInstance(tv, @selector(moveSection:toSection:),
                            (IMP)sio_tv_moveSection, (IMP *)&o_tv_moveSection);
        SIO_swizzleInstance(tv, @selector(setEditing:animated:),
                            (IMP)sio_tv_setEditing, (IMP *)&o_tv_setEditing);
        SIO_swizzleInstance(tv, @selector(performBatchUpdates:completion:),
                            (IMP)sio_tv_batchUpdates, (IMP *)&o_tv_batchUpdates);
    }
    if (cv) {
        SIO_swizzleInstance(cv, @selector(reloadData),
                            (IMP)sio_cv_reloadData, (IMP *)&o_cv_reloadData);
        SIO_swizzleInstance(cv, @selector(reloadItemsAtIndexPaths:),
                            (IMP)sio_cv_reloadItems, (IMP *)&o_cv_reloadItems);
        SIO_swizzleInstance(cv, @selector(reloadSections:),
                            (IMP)sio_cv_reloadSections, (IMP *)&o_cv_reloadSections);
        SIO_swizzleInstance(cv, @selector(insertItemsAtIndexPaths:),
                            (IMP)sio_cv_insertItems, (IMP *)&o_cv_insertItems);
        SIO_swizzleInstance(cv, @selector(deleteItemsAtIndexPaths:),
                            (IMP)sio_cv_deleteItems, (IMP *)&o_cv_deleteItems);
        SIO_swizzleInstance(cv, @selector(moveItemAtIndexPath:toIndexPath:),
                            (IMP)sio_cv_moveItem, (IMP *)&o_cv_moveItem);
        SIO_swizzleInstance(cv, @selector(scrollToItemAtIndexPath:atScrollPosition:animated:),
                            (IMP)sio_cv_scrollToItem, (IMP *)&o_cv_scrollToItem);
        SIO_swizzleInstance(cv, @selector(selectItemAtIndexPath:animated:scrollPosition:),
                            (IMP)sio_cv_selectItem, (IMP *)&o_cv_selectItem);
        SIO_swizzleInstance(cv, @selector(deselectItemAtIndexPath:animated:),
                            (IMP)sio_cv_deselectItem, (IMP *)&o_cv_deselectItem);
    }
}

#pragma mark - HighFPS Max 整合（高刷新率强制）

static BOOL      gHighFPSEnabled = YES;
static NSInteger gHighFPSRate = 120;
static BOOL      gHighFPSMetal = YES;

static void HFP_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) return;
    // 键不存在时保持默认值（默认全开 120），避免 [nil boolValue]=NO 误关
    if (d[@"HighFPSEnabled"]) gHighFPSEnabled = [d[@"HighFPSEnabled"] boolValue];
    if (d[@"HighFPSRate"]) {
        gHighFPSRate = [d[@"HighFPSRate"] integerValue];
        if (gHighFPSRate <= 0) gHighFPSRate = 120;
    }
    if (d[@"HighFPSMetalTriple"]) gHighFPSMetal = [d[@"HighFPSMetalTriple"] boolValue];
}

static BOOL HFP_blocked(void) {
    if (!gSelfBundle) gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (gSelfBundle.length == 0 || !gBlacklist) return NO;
    for (NSString *s in [gBlacklist componentsSeparatedByString:@","]) {
        if ([gSelfBundle isEqualToString:[s stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]]]) return YES;
    }
    return NO;
}

// UIScreen maximumFramesPerSecond
static NSInteger (*o_hfp_maxFPS)(id, SEL) = NULL;
static NSInteger hfp_maxFPS(id self, SEL _cmd) {
    if (!gHighFPSEnabled || HFP_blocked()) return o_hfp_maxFPS(self, _cmd);
    return gHighFPSRate;
}

// CADisplayLink setFrameInterval:
static void (*o_hfp_setFI)(id, SEL, NSInteger) = NULL;
static void hfp_setFI(id self, SEL _cmd, NSInteger i) {
    if (!gHighFPSEnabled || HFP_blocked()) { o_hfp_setFI(self, _cmd, i); return; }
    o_hfp_setFI(self, _cmd, 1);
}

// CADisplayLink setPreferredFramesPerSecond:
static void (*o_hfp_setPFPS)(id, SEL, NSInteger) = NULL;
static void hfp_setPFPS(id self, SEL _cmd, NSInteger fps) {
    if (!gHighFPSEnabled || HFP_blocked()) { o_hfp_setPFPS(self, _cmd, fps); return; }
    o_hfp_setPFPS(self, _cmd, gHighFPSRate);
}

// CADisplayLink setPreferredFrameRateRange: (iOS 15+)
typedef struct { float minimum; float maximum; float preferred; } HFPFrameRateRange;
static void (*o_hfp_setPFRR)(id, SEL, HFPFrameRateRange) = NULL;
static void hfp_setPFRR(id self, SEL _cmd, HFPFrameRateRange r) {
    if (!gHighFPSEnabled || HFP_blocked()) { o_hfp_setPFRR(self, _cmd, r); return; }
    HFPFrameRateRange nr; nr.minimum = 60; nr.maximum = gHighFPSRate; nr.preferred = gHighFPSRate;
    o_hfp_setPFRR(self, _cmd, nr);
}

// CAMetalLayer setMaximumDrawableCount:
static void (*o_hfp_setMDC)(id, SEL, NSUInteger) = NULL;
static void hfp_setMDC(id self, SEL _cmd, NSUInteger c) {
    if (!gHighFPSEnabled || !gHighFPSMetal || HFP_blocked()) { o_hfp_setMDC(self, _cmd, c); return; }
    o_hfp_setMDC(self, _cmd, 3);
}

// NSBundle Info.plist 键伪装：
// iOS 15.4+ ProMotion 设备要求 App 声明 CADisableMinimumFrameDurationOnPhone=YES，
// 否则系统合成器把 App 锁死在 60Hz，hook CADisplayLink 也无效。微信等 App 未声明。
static id (*o_hfp_bundleObjForKey)(id, SEL, NSString *) = NULL;
static id hfp_bundleObjForKey(id self, SEL _cmd, NSString *key) {
    if (gHighFPSEnabled && !HFP_blocked() &&
        [key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"]) {
        return @YES;
    }
    return o_hfp_bundleObjForKey(self, _cmd, key);
}

static NSDictionary *(*o_hfp_bundleInfoDict)(id, SEL) = NULL;
static NSDictionary *hfp_bundleInfoDict(id self, SEL _cmd) {
    NSDictionary *orig = o_hfp_bundleInfoDict(self, _cmd);
    if (gHighFPSEnabled && !HFP_blocked() &&
        ![orig[@"CADisableMinimumFrameDurationOnPhone"] boolValue]) {
        NSMutableDictionary *m = [orig mutableCopy] ?: [NSMutableDictionary dictionary];
        m[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
        return m;
    }
    return orig;
}

__attribute__((constructor))
static void HighFPSInit(void) {
    @autoreleasepool {
        HFP_reload();

        // 必须最先安装：系统在 UIKit/CoreAnimation 初始化早期读取该键
        Class bundle = objc_getClass("NSBundle");
        if (bundle) {
            Method m1 = class_getInstanceMethod(bundle, @selector(objectForInfoDictionaryKey:));
            if (m1) { o_hfp_bundleObjForKey = (typeof(o_hfp_bundleObjForKey))method_getImplementation(m1);
                method_setImplementation(m1, (IMP)hfp_bundleObjForKey); }
            Method m2 = class_getInstanceMethod(bundle, @selector(infoDictionary));
            if (m2) { o_hfp_bundleInfoDict = (typeof(o_hfp_bundleInfoDict))method_getImplementation(m2);
                method_setImplementation(m2, (IMP)hfp_bundleInfoDict); }
        }

        Class screen = objc_getClass("UIScreen");
        if (screen) {
            SEL s = @selector(maximumFramesPerSecond);
            Method m = class_getInstanceMethod(screen, s);
            if (m) {
                o_hfp_maxFPS = (typeof(o_hfp_maxFPS))method_getImplementation(m);
                class_replaceMethod(screen, s, (IMP)hfp_maxFPS, method_getTypeEncoding(m));
            }
        }

        Class dl = objc_getClass("CADisplayLink");
        if (dl) {
            Method m1 = class_getInstanceMethod(dl, @selector(setFrameInterval:));
            if (m1) { o_hfp_setFI = (typeof(o_hfp_setFI))method_getImplementation(m1);
                class_replaceMethod(dl, @selector(setFrameInterval:), (IMP)hfp_setFI, method_getTypeEncoding(m1)); }
            Method m2 = class_getInstanceMethod(dl, @selector(setPreferredFramesPerSecond:));
            if (m2) { o_hfp_setPFPS = (typeof(o_hfp_setPFPS))method_getImplementation(m2);
                class_replaceMethod(dl, @selector(setPreferredFramesPerSecond:), (IMP)hfp_setPFPS, method_getTypeEncoding(m2)); }
            SEL s3 = NSSelectorFromString(@"setPreferredFrameRateRange:");
            Method m3 = class_getInstanceMethod(dl, s3);
            if (m3) { o_hfp_setPFRR = (typeof(o_hfp_setPFRR))method_getImplementation(m3);
                class_replaceMethod(dl, s3, (IMP)hfp_setPFRR, method_getTypeEncoding(m3)); }
        }

        Class ml = objc_getClass("CAMetalLayer");
        if (ml) {
            Method m = class_getInstanceMethod(ml, @selector(setMaximumDrawableCount:));
            if (m) { o_hfp_setMDC = (typeof(o_hfp_setMDC))method_getImplementation(m);
                class_replaceMethod(ml, @selector(setMaximumDrawableCount:), (IMP)hfp_setMDC, method_getTypeEncoding(m)); }
        }
    }
}

#pragma mark - 实时 FPS HUD（注入目标 App 后浮窗显示当前帧率）

@interface SIOFPSMonitor : NSObject
@end

static UILabel      *gFPSLabel   = nil;
static CADisplayLink *gFPSLink   = nil;
static int           gFPSCount   = 0;
static NSTimeInterval gFPSLastTs = 0;
static BOOL          gFPSEnabled = YES;
static int           gFPSCur     = 0;

static void FPS_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) return;
    if (d[@"FPSEnabled"]) gFPSEnabled = [d[@"FPSEnabled"] boolValue];
}

@implementation SIOFPSMonitor
- (void)tick:(CADisplayLink *)link {
    if (gFPSLastTs == 0) { gFPSLastTs = link.timestamp; return; }
    gFPSCount++;
    NSTimeInterval delta = link.timestamp - gFPSLastTs;
    if (delta >= 1.0) {
        gFPSCur = (int)(gFPSCount / delta);
        gFPSCount = 0;
        gFPSLastTs = link.timestamp;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gFPSEnabled) {
                if (gFPSLabel) { [gFPSLabel removeFromSuperview]; gFPSLabel = nil; }
                return;
            }
            if (!gFPSLabel) {
                gFPSLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, 64, 24)];
                gFPSLabel.font = [UIFont boldSystemFontOfSize:12];
                gFPSLabel.textColor = [UIColor whiteColor];
                gFPSLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
                gFPSLabel.layer.cornerRadius = 6;
                gFPSLabel.clipsToBounds = YES;
                gFPSLabel.textAlignment = NSTextAlignmentCenter;
                gFPSLabel.userInteractionEnabled = NO;
            }
            gFPSLabel.text = [NSString stringWithFormat:@"%d Hz", gFPSCur];
            UIWindow *w = nil;
            for (UIWindow *win in [UIApplication sharedApplication].windows)
                if (win.isKeyWindow) { w = win; break; }
            if (!w) w = [UIApplication sharedApplication].keyWindow;
            if (w && gFPSLabel.superview != w) [w addSubview:gFPSLabel];
            if (w) [w bringSubviewToFront:gFPSLabel];
        });
    }
}
@end

__attribute__((constructor))
static void SIOFPSHUDInit(void) {
    @autoreleasepool {
        FPS_reload();
        SIOFPSMonitor *m = [[SIOFPSMonitor alloc] init];
        objc_setAssociatedObject([UIApplication class], @selector(init), m, OBJC_ASSOCIATION_RETAIN);
        gFPSLink = [CADisplayLink displayLinkWithTarget:m selector:@selector(tick:)];
        [gFPSLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

#pragma mark - FUBackground v2.0.0 Max 整合（真后台保活）

static NSString *const kFBGLocalOff = @"fubg_local_off";

// ---- 全局状态 ----
static BOOL    gFUBGEnabled    = YES;
static BOOL    gSceneFake  = YES;
static BOOL    gAudioKeep  = YES;
static BOOL    gShowBall   = YES;
static NSArray *gExclude   = nil;
static BOOL    gLocalOff   = NO;

static BOOL    gActive    = NO;   // 本 App 最终是否参与保活（总开关∧名单∧本地开关）
static BOOL    gUseScene  = NO;   // 本 App 是否启用场景伪装
static BOOL    gUseAudio  = NO;   // 本 App 是否启用音频断言
static BOOL    gPhysBg    = NO;   // 物理上是否处于后台（由真实生命周期通知维护）
static BOOL    gHasAudioMode = NO;

static AVAudioPlayer *gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = 0;   // 0 = 无桥接任务（UIBackgroundTaskInvalid 非文件级编译期常量）
static NSTimer *gWatchdog = nil;

#pragma mark - 配置

static BOOL _fbg_isExcluded(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gExclude) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) return YES;
    }
    return NO;
}

static void _fbg_recalc(void) {
    gActive   = gFUBGEnabled && !gLocalOff && !_fbg_isExcluded();
    gUseScene = gActive && gSceneFake;
    gUseAudio = gActive && gAudioKeep;
}

static void _fbg_loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        if (d) {
            if (d[@"FUBGEnabled"])      gFUBGEnabled   = [d[@"FUBGEnabled"] boolValue];
            if (d[@"FUBGSceneFake"])    gSceneFake = [d[@"FUBGSceneFake"] boolValue];
            if (d[@"FUBGAudioKeep"])    gAudioKeep = [d[@"FUBGAudioKeep"] boolValue];
            if (d[@"FUBGFloatingBall"]) gShowBall  = [d[@"FUBGFloatingBall"] boolValue];
            id ex = d[@"FUBGExcludeApps"];
            if ([ex isKindOfClass:[NSArray class]]) gExclude = ex;
            // 复用 SIOriginal 黑名单
            id bl = d[@"Blacklist"];
            if ([bl isKindOfClass:[NSArray class]]) gExclude = bl;
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];
    gLocalOff = [[NSUserDefaults standardUserDefaults] boolForKey:kFBGLocalOff];

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];

    _fbg_recalc();
}

#pragma mark - 引擎一：场景伪装
// 移植/修改自 ImmortalizerJailed main.m（GPLv3, Serge Alagon），致谢 @khanhduytran0

static void (*gOrigSceneUpdate)(id, SEL, id, id, id, id);

// 由后台化 diff 的描述特征判断这是否是一条"让 App 退到后台"的场景更新
static BOOL _fbg_isBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;
    if ([desc containsString:@"foreground = NotSet"] ||
        [desc containsString:@"foreground = No"] ||
        [desc containsString:@"foreground = BSSettingFlagNo"] ||
        [desc containsString:@"foreground = NO"]) {
        return YES;
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露/状态推进
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void _fbg_sceneUpdate(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (gUseScene) {
        @try {
            if (_fbg_isBackgroundingDiff([arg2 description])) {
                NSLog(@"[FUBG] swallowed backgrounding scene diff");
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gOrigSceneUpdate(self, _cmd, arg1, arg2, arg3, arg4);
}

// ---- applicationState 伪装 ----
static UIApplicationState (*gOrigAppState)(id, SEL);

static UIApplicationState _fbg_appState(id self, SEL _cmd) {
    if (gUseScene && gPhysBg) {
        // 推送/通知框架需要真实答案：前台态时它们不会建立后台接收通道
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        Dl_info info;
        if (dladdr(ret, &info) && info.dli_fname) {
            NSString *image = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
            if ([image containsString:@"UserNotifications"] ||
                [image containsString:@"PushKit"]) {
                return UIApplicationStateBackground;
            }
        }
        return UIApplicationStateActive;
    }
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// ---- 通知横幅伪装 ----
static void (*gOrigWillPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                                void (^)(UNNotificationPresentationOptions));

static void _fbg_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center,
                             UNNotification *note,
                             void (^handler)(UNNotificationPresentationOptions)) {
    if (gUseScene && gPhysBg) {
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
    } else if (gOrigWillPresent) {
        gOrigWillPresent(self, _cmd, center, note, handler);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

static void _fbg_unSetDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    if (delegate) {
        Class dc = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(dc, sel);
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)_fbg_willPresent) {
                gOrigWillPresent = (void *)cur;
                method_setImplementation(m, (IMP)_fbg_willPresent);
            }
        }
    }
}

static void _fbg_installSceneHooks(void) {
    Class wsClass = objc_getClass("FBSWorkspaceScenesClient");
    Method sceneM = wsClass ? class_getInstanceMethod(
        wsClass, @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:)) : NULL;
    if (sceneM) {
        gOrigSceneUpdate = (void (*)(id, SEL, id, id, id, id))method_getImplementation(sceneM);
        method_setImplementation(sceneM, (IMP)_fbg_sceneUpdate);
        NSLog(@"[FUBG] scene hook installed");
    } else {
        NSLog(@"[FUBG] FBSWorkspaceScenesClient method not found, scene engine disabled");
    }

    Method stateM = class_getInstanceMethod([UIApplication class], @selector(applicationState));
    if (stateM) {
        gOrigAppState = (UIApplicationState (*)(id, SEL))method_getImplementation(stateM);
        method_setImplementation(stateM, (IMP)_fbg_appState);
    }

    Class unClass = [UNUserNotificationCenter class];
    Method delM = class_getInstanceMethod(unClass, @selector(setDelegate:));
    if (delM) {
        gOrigUNSetDelegate = (void (*)(id, SEL, id))method_getImplementation(delM);
        method_setImplementation(delM, (IMP)_fbg_unSetDelegate);
    }
}

#pragma mark - 引擎二：音频断言

static BOOL _fbg_activateSession(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback
            withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e] || e) {
        NSLog(@"[FUBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e] || e) {
        NSLog(@"[FUBG] setActive failed: %@", e); return NO;
    }
    return YES;
}

static void _fbg_buildAndPlay(void) {
    @try {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:data error:nil];
        if (!p) return;
        p.numberOfLoops = -1;
        p.volume = 0.0f;
        [p prepareToPlay];
        [p play];
        gPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void _fbg_startAudio(void) {
    if (!gUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == 0) {
            gTask = [app beginBackgroundTaskWithName:@"fubg-bridge" expirationHandler:^{
                NSLog(@"[FUBG] bridge task expired");
                if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
            }];
        }
        if (_fbg_activateSession() && (!gPlayer || !gPlayer.isPlaying)) {
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
        NSLog(@"[FUBG] audio keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void _fbg_stopAudio(BOOL releaseSession) {
    @try {
        if (gPlayer.isPlaying) [gPlayer pause];
        // 经验（Immortalizer 作者）：mix 模式下保持 session 激活、不主动 setActive:NO，
        // 可避免与目标 App 自身音频会话打架造成的卡顿；仅彻底关闭时通知他人恢复。
        if (releaseSession) {
            [[AVAudioSession sharedInstance] setActive:NO
                                          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                                error:nil];
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
    } @catch (__unused NSException *e) {}
}

// 自愈轮询：仅在停摆时重建，兼顾可靠与耗电
static void _fbg_watchdogFire(__unused NSTimer *t) {
    if (!gUseAudio || !gPhysBg) return;
    @try {
        if (!gPlayer || !gPlayer.isPlaying) {
            NSLog(@"[FUBG] watchdog: player stopped, rebuilding");
            _fbg_activateSession();
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
    } @catch (__unused NSException *e) {}
}

static void _fbg_onInterruption(NSNotification *note) {
    if (!gUseAudio) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
    if (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gUseAudio && gPhysBg) {
                _fbg_activateSession();
                if (gPlayer) { [gPlayer play]; } else { _fbg_buildAndPlay(); }
            }
        });
    }
}

#pragma mark - 悬浮球

@interface FBGToastView : UIView
+ (void)showIn:(UIView *)container title:(NSString *)title subtitle:(NSString *)subtitle
      iconName:(NSString *)iconName;
@end

@implementation FBGToastView
+ (void)showIn:(UIView *)container title:(NSString *)title subtitle:(NSString *)subtitle
      iconName:(NSString *)iconName {
    FBGToastView *blur = [[self alloc] initWithFrame:CGRectMake(0, -90, container.bounds.size.width, 80)];
    blur.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    blur.layer.cornerRadius = 18;
    blur.layer.masksToBounds = YES;

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName]];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *t = [[UILabel alloc] init];
    t.text = title;
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:15];
    UILabel *s = [[UILabel alloc] init];
    s.text = subtitle;
    s.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    s.font = [UIFont systemFontOfSize:12];
    UIStackView *txt = [[UIStackView alloc] initWithArrangedSubviews:@[t, s]];
    txt.axis = UILayoutConstraintAxisVertical;
    txt.spacing = 2;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iv, txt]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [blur addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [iv.widthAnchor constraintEqualToConstant:28], [iv.heightAnchor constraintEqualToConstant:28],
        [row.leadingAnchor constraintEqualToAnchor:blur.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:blur.trailingAnchor constant:-16],
        [row.centerYAnchor constraintEqualToAnchor:blur.centerYAnchor],
    ]];
    [container addSubview:blur];

    [UIView animateWithDuration:0.3 animations:^{
        blur.transform = CGAffineTransformMakeTranslation(0, 110);
    } completion:^(__unused BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                blur.alpha = 0;
                blur.transform = CGAffineTransformMakeTranslation(0, 40);
            } completion:^(__unused BOOL f2) { [blur removeFromSuperview]; }];
        });
    }];
}
@end

@interface FBGFloatingWindow : UIWindow
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, assign) BOOL docked;
@property (nonatomic, strong) NSTimer *dockTimer;
+ (instancetype)shared;
- (void)attachWhenSceneReady;
- (void)refreshState;
@end

@implementation FBGFloatingWindow

+ (instancetype)shared {
    static FBGFloatingWindow *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [[self alloc] initWithFrame:UIScreen.mainScreen.bounds]; });
    return one;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [UIViewController new];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        _ball = [UIButton buttonWithType:UIButtonTypeCustom];
        _ball.frame = CGRectMake(self.bounds.size.width - 70, 220, 52, 52);
        _ball.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
        _ball.layer.cornerRadius = 26;
        _ball.layer.masksToBounds = YES;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onPan:)];
        [_ball addGestureRecognizer:pan];
        [_ball addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [self.rootViewController.view addSubview:_ball];
        [self snap];

        _handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 46)];
        _handle.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
        _handle.layer.cornerRadius = 6;
        _handle.hidden = YES; _handle.alpha = 0;
        UIPanGestureRecognizer *hpan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(onHandlePan:)];
        UITapGestureRecognizer *htap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(undock)];
        [_handle addGestureRecognizer:hpan];
        [_handle addGestureRecognizer:htap];
        [self.rootViewController.view addSubview:_handle];

        [self refreshState];
    }
    return self;
}

- (void)makeKeyWindow {
    [super makeKeyWindow];
    // 不抢目标 App 的 keyWindow
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
            }
        }
        if (kw && kw != self) [kw makeKeyWindow];
    });
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_ball.hidden) {
        CGPoint p = [self convertPoint:point toView:_ball];
        if ([_ball pointInside:p withEvent:event]) return [super hitTest:point withEvent:event];
    }
    if (!_handle.hidden) {
        CGPoint p = [self convertPoint:point toView:_handle];
        if ([_handle pointInside:p withEvent:event]) return [super hitTest:point withEvent:event];
    }
    return nil;
}

- (void)attachWhenSceneReady {
    __block int tries = 0;
    __weak typeof(self) weakSelf = self;
    __block void (^attempt)(void);
    attempt = ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        UIWindowScene *target = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { target = (UIWindowScene *)sc; break; }
        }
        if (target) {
            me.windowScene = target;
            me.hidden = NO;
            [me makeKeyAndVisible];
            [me startDockClock];
            [me refreshState];
        } else if (++tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), attempt);
        }
    };
    dispatch_async(dispatch_get_main_queue(), attempt);
}

- (void)refreshState {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hidden = !gShowBall;
        if (!gShowBall) return;
        BOOL on = !gLocalOff && gFUBGEnabled;
        UIImage *icon = [UIImage systemImageNamed: on ? @"hourglass" : @"powersleep"];
        [self.ball setImage:icon forState:UIControlStateNormal];
        self.ball.tintColor = on ? [UIColor systemBlueColor] : [UIColor systemRedColor];
    });
}

- (void)snap {
    CGFloat w = self.bounds.size.width;
    CGPoint c = _ball.center;
    c.x = c.x < w / 2 ? 26 : w - 26;
    c.y = MAX(26, MIN(self.bounds.size.height - 26, c.y));
    [UIView animateWithDuration:0.25 animations:^{ _ball.center = c; }];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    [self resetDockClock];
    CGPoint tr = [g translationInView:self];
    g.view.center = CGPointMake(g.view.center.x + tr.x, g.view.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) { [self snap]; [self startDockClock]; }
}

- (void)onHandlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { [self undock]; return; }
    CGPoint tr = [g translationInView:self];
    _ball.center = CGPointMake(_ball.center.x + tr.x, _ball.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) { [self snap]; [self startDockClock]; }
}

- (void)startDockClock {
    [_dockTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _dockTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(__unused NSTimer *t) {
        [weakSelf dock];
    }];
}
- (void)resetDockClock {
    if (_docked) return;
    [_dockTimer invalidate];
    [self startDockClock];
}

- (void)dock {
    if (_docked) return;
    _docked = YES;
    BOOL left = _ball.center.x < self.bounds.size.width / 2;
    _handle.frame = CGRectMake(left ? 0 : self.bounds.size.width - 14,
                               _ball.frame.origin.y + 3, 14, 46);
    [UIView animateWithDuration:0.25 animations:^{
        _ball.alpha = 0;
        _ball.transform = CGAffineTransformMakeScale(0.5, 0.5);
    } completion:^(__unused BOOL f) {
        _ball.hidden = YES;
        _handle.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ _handle.alpha = 1; }];
    }];
}

- (void)undock {
    if (!_docked) return;
    _docked = NO;
    _ball.hidden = NO;
    BOOL left = _handle.frame.origin.x < self.bounds.size.width / 2;
    _ball.center = CGPointMake(left ? 26 + 7 : self.bounds.size.width - 26 - 7, _handle.center.y);
    [UIView animateWithDuration:0.25 animations:^{
        _handle.alpha = 0;
        _ball.alpha = 1;
        _ball.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL f) {
        _handle.hidden = YES;
        [self startDockClock];
    }];
}

- (void)onTap {
    [self resetDockClock];
    BOOL newOff = !gLocalOff;
    [[NSUserDefaults standardUserDefaults] setBool:newOff forKey:kFBGLocalOff];
    gLocalOff = newOff;
    _fbg_recalc();
    notify_post([kNotifyName UTF8String]);

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];

    [self refreshState];
    [UIView animateWithDuration:0.1 animations:^{
        _ball.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(__unused BOOL f) {
        [UIView animateWithDuration:0.1 animations:^{
            _ball.transform = CGAffineTransformIdentity;
        }];
    }];

    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"App";
    [FBGToastView showIn:self.rootViewController.view
                   title:appName
                subtitle:(newOff ? @"真后台 已暂停（本 App）" : @"真后台 已开启")
                iconName:(newOff ? @"powersleep" : @"hourglass")];

    if (newOff && gPhysBg) _fbg_stopAudio(YES);
}

@end

#pragma mark - 生命周期 / Darwin

static void _fbg_onEnterBackground(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    gPhysBg = YES;
    _fbg_startAudio();
}

static void _fbg_onEnterForeground(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    gPhysBg = NO;
    // 回前台只暂停播放、保留会话（mix 模式下不与 App 音频冲突）
    if (gPlayer.isPlaying) [gPlayer pause];
    if (gTask != 0) {
        [[UIApplication sharedApplication] endBackgroundTask:gTask];
        gTask = 0;
    }
}

static void _fbg_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    _fbg_loadPref();
    NSLog(@"[FUBG] prefs reloaded: active=%d scene=%d audio=%d ball=%d",
          gActive, gUseScene, gUseAudio, gShowBall);
    [[FBGFloatingWindow shared] refreshState];
    if (!gUseAudio && gPhysBg) _fbg_stopAudio(NO);
    if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) _fbg_startAudio();
}

#pragma mark - 入口

__attribute__((constructor))
static void FUBGEntry(void) {
    @autoreleasepool {
        _fbg_loadPref();

        // hook 一次性安装，内部按全局开关决定行为
        dispatch_async(dispatch_get_main_queue(), ^{
            _fbg_installSceneHooks();
        });

        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onEnterBackground,
            (__bridge CFStringRef)UIApplicationDidEnterBackgroundNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onEnterForeground,
            (__bridge CFStringRef)UIApplicationWillEnterForegroundNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onPrefReload,
            (__bridge CFStringRef)kNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ _fbg_onInterruption(n); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *n){
                if (gUseAudio && gPhysBg) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (gPlayer && !gPlayer.isPlaying) [gPlayer play];
                    });
                }
            }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gUseAudio) {
                gWatchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                              block:^(NSTimer *t){ _fbg_watchdogFire(t); }];
                [[NSRunLoop mainRunLoop] addTimer:gWatchdog forMode:NSRunLoopCommonModes];
            }
            if (gShowBall) [[FBGFloatingWindow shared] attachWhenSceneReady];
        });

        NSLog(@"[FUBG] v2.0.0 loaded in %@: active=%d scene=%d audio=%d ball=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gActive, gUseScene, gUseAudio, gShowBall, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    }
}

