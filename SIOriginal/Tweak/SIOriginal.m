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
#import <objc/message.h>
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
static BOOL     gListAccel = YES;    // TV/CV 列表全家桶（微信/顺丰骑士已硬保护）
static BOOL     gIsWeChat  = NO;     // 硬保护：TV/CV hook 对微信永远关闭
static BOOL     gIsSFKnight = NO;    // 硬保护：顺丰同城骑士（订单列表密集，同微信崩溃家族）
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

static void SIO_installiOS16Extras(void); // forward declaration

static void SIO_settingsChanged(CFNotificationCenterRef center, void *observer,
                                CFNotificationName name, const void *object,
                                CFDictionaryRef userInfo) {
    SIO_reload();
}

// ---------- 微信图片预览「放大态」全局旁路（v1.8.4） ----------
// v1.8.3 只保护了缩放相关的两个 UIScrollView hook，但用户实测仍有残留故障：
// 放大后顶/底工具栏自动隐藏，单击屏幕再也唤不出，返回/完成按钮跟着消失，
// 只能杀微信。微信图片浏览器（发图预览、聊天大图）的工具栏隐显走的是
// UIView 块动画 / UIViewPropertyAnimator / CAAnimation，瞬切模式把时长压到
// 0.01s、加速模式整体缩短，会破坏浏览器「隐显动画完成 → 清 isAnimating 锁 →
// 接受下一次单击切换」的状态配对，导致单击被丢弃，工具栏永远停在隐藏态。
// 该故障只在「放大态」出现（未放大时单击切换正常），因此：只要微信前台
// 存在一个启用了缩放且当前 zoomScale > minimumZoomScale 的 UIScrollView，
// 就令所有动画 hook 整体旁路（SIO_blocked 返回 YES），缩放/工具栏/手势全走
// 原生路径；缩回最小倍率后 0.25s 内自动恢复加速。探测限主线程、0.25s 节流，
// 对性能无实际影响。
static NSTimeInterval gZoomProbeAt = 0;
static BOOL           gZoomPreviewCached = NO;

static BOOL SIO_wechatZoomPreviewActive(void) {
    if (!gIsWeChat) return NO;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - gZoomProbeAt < 0.25) return gZoomPreviewCached;
    gZoomProbeAt = now;
    // 视图树只能在主线程碰；非主线程直接沿用上一次结果（最多滞后 0.25s）
    if (![NSThread isMainThread]) return gZoomPreviewCached;

    BOOL found = NO;
    @autoreleasepool {
        @try {
            NSMutableArray<UIView *> *roots = [NSMutableArray array];
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ws.windows) {
                    if (!w.hidden && w.alpha > 0.01 && w.rootViewController.view) {
                        [roots addObject:w];
                    }
                }
            }
            // 迭代 DFS，扫描整个前台视图树
            NSMutableArray<UIView *> *stack = roots;
            while (stack.count) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if ([v isKindOfClass:[UIScrollView class]]) {
                    UIScrollView *sv = (UIScrollView *)v;
                    if (sv.maximumZoomScale > sv.minimumZoomScale + 0.001 &&
                        sv.zoomScale > sv.minimumZoomScale + 0.001) {
                        found = YES;
                        break;
                    }
                }
                NSArray *subs = v.subviews;
                if (subs.count) [stack addObjectsFromArray:subs];
            }
        } @catch (__unused NSException *e) {}
    }
    gZoomPreviewCached = found;
    return found;
}

static inline BOOL SIO_blocked(void) {
    if (!gEnabled) return YES;
    // v1.8.9：微信动画加速恢复（实验）——预览 bug 真凶已确认为悬浮球（v1.8.7 永久禁用），
    // 动画 hook 恢复生效；v1.8.4 放大态探测器首次真正启用作为安全网
    if (SIO_wechatZoomPreviewActive()) return YES;   // 微信预览放大态旁路
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

// ---- iOS 10+ UIViewPropertyAnimator（现代 App 主流动画 API） ----
static void   (*o_pa_setDuration)(id, SEL, double);
static id     (*o_pa_initWithDurTP)(id, SEL, double, id, void (^)(void));
static id     (*o_pa_initWithDurCP)(id, SEL, double, CGPoint, CGPoint, void (^)(void));
static id     (*o_pa_initWithDurSpring)(id, SEL, double, double, void (^)(void));
static id     (*o_pa_runningPA)(id, SEL, double, double, UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

// ---- UIScrollView 滚动动画 ----
static void   (*o_sv_setContentOffset)(id, SEL, CGPoint, BOOL);
static void   (*o_sv_scrollRect)(id, SEL, CGRect, BOOL);

// ---- CALayer addAnimation 补盲区 ----
static void   (*o_layer_addAnim)(id, SEL, id, NSString *);

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

#pragma mark - TV/CV 列表全家桶（ListAccel 控制；com.tencent.xin / com.sfic.knight 硬保护）

// v1.8.9：微信列表 hook 恢复（实验）；顺丰骑士保持硬保护
static BOOL SIO_listOK(void) { return gListAccel && !gIsSFKnight && !SIO_blocked(); }

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
    // 顺丰同城骑士：订单/任务列表密集型 App，TV/CV mutation hooks 会破坏列表状态机
    // 导致卡死（与微信同家族），且需与 SFKnightMax 共存，硬保护
    gIsSFKnight = [gSelfBundle isEqualToString:@"com.sfic.knight"];
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

    // TV/CV 列表全家桶 ×24（ListAccel 控制；微信/顺丰骑士硬保护）
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

    // iOS 16 优化增强：UIViewPropertyAnimator + UIScrollView + CALayer
    SIO_installiOS16Extras();
}

#pragma mark - UIViewPropertyAnimator（iOS 10+ 现代 App 主流动画 API）

// duration setter — 拦截已创建 animator 的时长修改
static void sio_PA_setDuration(id self, SEL _cmd, double d) {
    if (SIO_blocked()) { o_pa_setDuration(self, _cmd, d); return; }
    o_pa_setDuration(self, _cmd, SIO_targetDuration(d));
}

// initWithDuration:timingParameters:animations: — CA/CubicTimingParameters init
static id sio_PA_initWithDurTP(id self, SEL _cmd, double d, id tp, void (^a)(void)) {
    if (!SIO_blocked()) d = SIO_targetDuration(d);
    return o_pa_initWithDurTP(self, _cmd, d, tp, a);
}

// initWithDuration:controlPoint1:controlPoint2:animations: — Bezier init
static id sio_PA_initWithDurCP(id self, SEL _cmd, double d, CGPoint p1, CGPoint p2, void (^a)(void)) {
    if (!SIO_blocked()) d = SIO_targetDuration(d);
    return o_pa_initWithDurCP(self, _cmd, d, p1, p2, a);
}

// initWithDuration:springDampingRatio:animations: — Spring init
static id sio_PA_initWithDurSpring(id self, SEL _cmd, double d, double dr, void (^a)(void)) {
    if (!SIO_blocked()) d = SIO_targetDuration(d);
    return o_pa_initWithDurSpring(self, _cmd, d, dr, a);
}

// runningPropertyAnimatorWithDuration:delay:options:animations:completion: — 类方法
static id sio_PA_runningPA(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions opt, void (^a)(void), void (^c)(BOOL)) {
    if (!SIO_blocked()) d = SIO_targetDuration(d);
    return o_pa_runningPA(self, _cmd, d, delay, opt, a, c);
}

#pragma mark - UIScrollView 滚动动画

// 图片预览缩放保护（v1.8.3 修复微信发图预览放大后无法返回）：
// 微信图片预览浏览器基于 UIScrollView zooming 构建，双击/捏合缩放及回弹期间，
// UIKit 与浏览器自身会以 setContentOffset:animated:/scrollRectToVisible:animated:
// 驱动缩放复位与重新居中。此时：
//   · 瞬切模式把 animated:YES 改成 animated:NO 并 kCATransactionDisableActions，
//     会取消 UIKit 缩放动画事务——isZooming/isZoomBouncing 状态无法靠动画完成
//     回调收尾，浏览器的手势仲裁停在「缩放中」：返回按钮、单击工具栏、下拉/
//     侧滑退出全部失灵，卡在预览页回不到微信；
//   · 加速模式用外层 CATransaction 覆盖时长，同样可能打乱缩放事务内部时序。
// 因此只要该 scrollView 正处于缩放活动期（缩放动画中/回弹中/当前仍放大），
// 两个 hook 一律原样透传，不做任何时长/动画改写。普通滚动（非动画、未放大）
// 不受影响，滚动加速照常生效。
static BOOL SIO_svZoomEngaged(UIScrollView *sv) {
    if (![sv isKindOfClass:[UIScrollView class]]) return NO;
    @try {
        if (sv.isZooming || sv.isZoomBouncing) return YES;
        if (sv.maximumZoomScale > sv.minimumZoomScale + 0.001 &&
            sv.zoomScale > sv.minimumZoomScale + 0.001) {
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static void sio_SV_setContentOffset(id self, SEL _cmd, CGPoint p, BOOL animated) {
    if (SIO_blocked() || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_setContentOffset(self, _cmd, p, animated); return;
    }
    // 瞬切模式下直接跳过动画（性能最优）
    if (gEnabled && gMode == 2) {
        [CATransaction begin];
        [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
        o_sv_setContentOffset(self, _cmd, p, NO);
        [CATransaction commit];
        return;
    }
    // 加速/慢放：用 CATransaction 包裹改 duration
    [CATransaction begin];
    [CATransaction setAnimationDuration:SIO_targetDuration(0.35)];
    o_sv_setContentOffset(self, _cmd, p, YES);
    [CATransaction commit];
}

static void sio_SV_scrollRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    if (SIO_blocked() || !animated || SIO_svZoomEngaged((UIScrollView *)self)) {
        o_sv_scrollRect(self, _cmd, r, animated); return;
    }
    if (gEnabled && gMode == 2) {
        [CATransaction begin];
        [CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
        o_sv_scrollRect(self, _cmd, r, NO);
        [CATransaction commit];
        return;
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:SIO_targetDuration(0.35)];
    o_sv_scrollRect(self, _cmd, r, YES);
    [CATransaction commit];
}

#pragma mark - CALayer addAnimation:forKey:（补 CAAnimation setDuration 盲区）

static void sio_layer_addAnim(id self, SEL _cmd, id anim, NSString *key) {
    // CAAnimation setDuration 基类 hook 已经覆盖了绝大多数情况，
    // 但少数 app 在 addAnimation 后才设置 duration（顺序问题），
    // 这里二次兜底：直接修改传入 anim 的 duration 属性
    if (!SIO_blocked() && anim) {
        // 只对 CAAnimation 子类生效
        if ([anim respondsToSelector:@selector(setDuration:)]) {
            // 用 performSelector 绕过 AVFoundation setDuration: 歧义
            double origDur = ((CAAnimation *)anim).duration;
            if (origDur > 0) {
                double newDur = SIO_targetDuration(origDur);
                if (newDur != origDur) {
                    SEL sd = @selector(setDuration:);
                    ((void (*)(id, SEL, double))objc_msgSend)((CAAnimation *)anim, sd, newDur);
                }
            }
        }
    }
    o_layer_addAnim(self, _cmd, anim, key);
}

#pragma mark - SIO_install 新 hook 注册（iOS 16 优化增强）

static void SIO_installiOS16Extras(void) {
    Class pa = objc_getClass("UIViewPropertyAnimator");
    Class sv = objc_getClass("UIScrollView");
    Class layer = objc_getClass("CALayer");

    if (pa) {
        SIO_swizzleInstance(pa, @selector(setDuration:),
                            (IMP)sio_PA_setDuration, (IMP *)&o_pa_setDuration);
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:animations:),
                            (IMP)sio_PA_initWithDurTP, (IMP *)&o_pa_initWithDurTP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:controlPoint1:controlPoint2:animations:),
                            (IMP)sio_PA_initWithDurCP, (IMP *)&o_pa_initWithDurCP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:springDampingRatio:animations:),
                            (IMP)sio_PA_initWithDurSpring, (IMP *)&o_pa_initWithDurSpring);
        SIO_swizzleClass(object_getClass(pa), @selector(runningPropertyAnimatorWithDuration:delay:options:animations:completion:),
                         (IMP)sio_PA_runningPA, (IMP *)&o_pa_runningPA);
    }

    if (sv) {
        SIO_swizzleInstance(sv, @selector(setContentOffset:animated:),
                            (IMP)sio_SV_setContentOffset, (IMP *)&o_sv_setContentOffset);
        SIO_swizzleInstance(sv, @selector(scrollRectToVisible:animated:),
                            (IMP)sio_SV_scrollRect, (IMP *)&o_sv_scrollRect);
    }

    if (layer) {
        SIO_swizzleInstance(layer, @selector(addAnimation:forKey:),
                            (IMP)sio_layer_addAnim, (IMP *)&o_layer_addAnim);
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

// ---- 微信通知大弹窗（v1.9.0） ----
static BOOL    gWXBigNotif    = NO;    // 接管微信通知，弹自定义大窗
static double  gWXNotifDur    = 5.0;   // 大窗显示时长（秒）

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
            // 微信通知大弹窗
            if (d[@"WXBigNotif"])       gWXBigNotif = [d[@"WXBigNotif"] boolValue];
            if (d[@"WXNotifDur"]) {
                double dur = [d[@"WXNotifDur"] doubleValue];
                if (dur >= 1.0 && dur <= 30.0) gWXNotifDur = dur;
            }
            id ex = d[@"FUBGExcludeApps"];
            if ([ex isKindOfClass:[NSArray class]]) gExclude = ex;
            // 复用 SIOriginal 黑名单（v1.8.6：兼容字符串格式，原来只认 NSArray 导致黑名单对 FUBG 永远无效）
            id bl = d[@"Blacklist"];
            if ([bl isKindOfClass:[NSArray class]]) {
                gExclude = bl;
            } else if ([bl isKindOfClass:[NSString class]] && [(NSString *)bl length]) {
                gExclude = [(NSString *)bl componentsSeparatedByString:@","];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];
    gLocalOff = [[NSUserDefaults standardUserDefaults] boolForKey:kFBGLocalOff];
    // v1.8.8：微信自 v1.8.7 起无悬浮球，本地开关失去载体；
    // 若旧版本误触过球，fubg_local_off=YES 会永久残留导致微信永不保活，强制清零
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.tencent.xin"]) {
        gLocalOff = NO;
    }

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

// ---- 微信通知大弹窗（v1.9.0） ----
// 拦截微信通知，用自定义大窗替代系统横幅；配合真后台保活实现后台实时推送

@interface WXNotifBanner : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *body;
@property (nonatomic, copy) NSString *time;
@property (nonatomic, strong) UIImage *avatar;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation WXNotifBanner {
    UIImageView *_avatarView;
    UILabel *_titleLabel;
    UILabel *_bodyLabel;
    UILabel *_timeLabel;
    UIView *_card;
    NSTimer *_timer;
    BOOL _dismissing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        _card = [[UIView alloc] init];
        _card.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.92];
        _card.layer.cornerRadius = 16;
        _card.layer.shadowColor = [UIColor blackColor].CGColor;
        _card.layer.shadowOpacity = 0.4;
        _card.layer.shadowRadius = 12;
        _card.layer.shadowOffset = CGSizeMake(0, 4);
        [self addSubview:_card];

        _avatarView = [[UIImageView alloc] init];
        _avatarView.contentMode = UIViewContentModeScaleAspectFill;
        _avatarView.clipsToBounds = YES;
        _avatarView.layer.cornerRadius = 22;
        _avatarView.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
        [_card addSubview:_avatarView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont boldSystemFontOfSize:16];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.numberOfLines = 1;
        [_card addSubview:_titleLabel];

        _bodyLabel = [[UILabel alloc] init];
        _bodyLabel.font = [UIFont systemFontOfSize:14];
        _bodyLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
        _bodyLabel.numberOfLines = 3;
        [_card addSubview:_bodyLabel];

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont systemFontOfSize:11];
        _timeLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
        _timeLabel.textAlignment = NSTextAlignmentRight;
        [_card addSubview:_timeLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tapped)];
        [self addGestureRecognizer:tap];

        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(_swiped)];
        swipe.direction = UISwipeGestureRecognizerDirectionUp;
        [self addGestureRecognizer:swipe];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panned:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat cardW = w - 24;
    _card.frame = CGRectMake(12, 0, cardW, self.bounds.size.height);
    _avatarView.frame = CGRectMake(14, 14, 44, 44);
    _titleLabel.frame = CGRectMake(68, 14, cardW - 68 - 60, 20);
    _timeLabel.frame = CGRectMake(cardW - 60, 14, 50, 20);
    _bodyLabel.frame = CGRectMake(68, 38, cardW - 80, self.bounds.size.height - 52);
}

- (void)setTitle:(NSString *)title { _titleLabel.text = title; }
- (NSString *)title { return _titleLabel.text; }
- (void)setBody:(NSString *)body { _bodyLabel.text = body; }
- (NSString *)body { return _bodyLabel.text; }
- (void)setTime:(NSString *)time { _timeLabel.text = time; }
- (NSString *)time { return _timeLabel.text; }
- (void)setAvatar:(UIImage *)avatar {
    _avatarView.image = avatar;
    if (!avatar) {
        _avatarView.image = [WXNotifBanner _defaultAvatar];
    }
}
- (UIImage *)avatar { return _avatarView.image; }

+ (UIImage *)_defaultAvatar {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize s = CGSizeMake(88, 88);
        UIGraphicsBeginImageContextWithOptions(s, YES, 0);
        [[UIColor colorWithRed:0.08 green:0.5 blue:0.13 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, s.width, s.height));
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:36],
                                 NSForegroundColorAttributeName: [UIColor whiteColor] };
        NSString *t = @"微";
        CGSize ts = [t sizeWithAttributes:attrs];
        [t drawAtPoint:CGPointMake((s.width - ts.width) / 2, (s.height - ts.height) / 2)
        withAttributes:attrs];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return img;
}

- (void)_tapped {
    if (_dismissing) return;
    [self _dismissAnimated:YES];
    if (self.onTap) self.onTap();
}

- (void)_swiped { [self _dismissAnimated:YES]; }

- (void)_panned:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self];
    if (pan.state == UIGestureRecognizerStateChanged) {
        if (t.y < 0) {
            self.transform = CGAffineTransformMakeTranslation(0, t.y);
            self.alpha = 1.0 + t.y / 200.0;
        }
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        if (t.y < -60) {
            [self _dismissAnimated:YES];
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                self.transform = CGAffineTransformIdentity;
                self.alpha = 1.0;
            }];
        }
    }
}

- (void)showInView:(UIView *)container duration:(NSTimeInterval)dur {
    self.frame = CGRectMake(0, -self.bounds.size.height, container.bounds.size.width, self.bounds.size.height);
    [container addSubview:self];
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8
          initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.frame = CGRectMake(0, 8, container.bounds.size.width, self.bounds.size.height);
    } completion:^(BOOL finished) {}];
    _timer = [NSTimer scheduledTimerWithTimeInterval:dur target:self
        selector:@selector(_dismissAnimatedTimer) userInfo:nil repeats:NO];
}

- (void)_dismissAnimatedTimer { [self _dismissAnimated:YES]; }

- (void)_dismissAnimated:(BOOL)animated {
    if (_dismissing) return;
    _dismissing = YES;
    [_timer invalidate]; _timer = nil;
    void (^anim)(void) = ^{
        self.frame = CGRectMake(0, -self.bounds.size.height - 20, self.bounds.size.width, self.bounds.size.height);
        self.alpha = 0;
    };
    void (^done)(BOOL) = ^(BOOL f){
        [self removeFromSuperview];
        if (self.onDismiss) self.onDismiss();
    };
    if (animated) [UIView animateWithDuration:0.3 animations:anim completion:done];
    else { anim(); done(YES); }
}

@end

// ---- 通知横幅伪装 ----
static void (*gOrigWillPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                                void (^)(UNNotificationPresentationOptions));

// 微信通知大弹窗窗口管理（v1.9.1）
static UIWindow *gWXNotifWindow = nil;
static WXNotifBanner *gWXCurrentBanner = nil;
static NSMutableArray *gWXNotifQueue = nil;

// 获取当前活跃的 UIWindowScene（v1.9.1：修复无 scene 导致窗口间歇性不显示）
static UIWindowScene *_wx_activeScene(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (sc.activationState == UISceneActivationStateForegroundActive &&
            [sc isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)sc;
        }
    }
    // 退而求其次：取第一个 window scene
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)sc;
    }
    return nil;
}

static UIWindow *_wx_notif_window(void) {
    if (!gWXNotifWindow) {
        gWXNotifWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gWXNotifWindow.windowLevel = UIWindowLevelStatusBar + 100;
        gWXNotifWindow.backgroundColor = [UIColor clearColor];
        gWXNotifWindow.userInteractionEnabled = YES;
        gWXNotifWindow.hidden = NO;
    }
    // v1.9.1：每次显示前确保绑定到活跃 scene（多 App 并发时 scene 可能变化）
    UIWindowScene *sc = _wx_activeScene();
    if (sc && gWXNotifWindow.windowScene != sc) {
        gWXNotifWindow.windowScene = sc;
    }
    gWXNotifWindow.hidden = NO;
    return gWXNotifWindow;
}

static void _wx_show_banner(NSString *title, NSString *body) {
    if (!title.length && !body.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = _wx_notif_window();
        CGFloat w = win.bounds.size.width;
        CGFloat bodyH = [body boundingRectWithSize:CGSizeMake(w - 104, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14]} context:nil].size.height;
        CGFloat h = MAX(72, 38 + MIN(bodyH, 60) + 14);

        WXNotifBanner *banner = [[WXNotifBanner alloc] initWithFrame:CGRectMake(0, 0, w, h)];
        banner.title = title.length ? title : @"微信";
        banner.body = body;
        banner.avatar = nil;

        // 时间
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm";
        banner.time = [fmt stringFromDate:[NSDate date]];

        __weak WXNotifBanner *weakBanner = banner;
        banner.onTap = ^{
            // 点击跳转：打开微信
            NSURL *url = [NSURL URLWithString:@"weixin://"];
            if ([[UIApplication sharedApplication] canOpenURL:url]) {
                [[UIApplication sharedApplication] openURL:url];
            }
        };
        banner.onDismiss = ^{
            if (gWXCurrentBanner == weakBanner) {
                gWXCurrentBanner = nil;
                // 显示队列中下一个
                if (gWXNotifQueue.count > 0) {
                    WXNotifBanner *next = gWXNotifQueue.firstObject;
                    [gWXNotifQueue removeObjectAtIndex:0];
                    gWXCurrentBanner = next;
                    [next showInView:[weakBanner superview] ?: _wx_notif_window() duration:gWXNotifDur];
                }
            }
        };

        // 队列：若当前有显示，加入队列
        if (gWXCurrentBanner) {
            if (!gWXNotifQueue) gWXNotifQueue = [NSMutableArray array];
            [gWXNotifQueue addObject:banner];
            // 8 秒后如果队列还没处理完则丢弃
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [gWXNotifQueue removeObject:banner];
            });
        } else {
            gWXCurrentBanner = banner;
            [banner showInView:win duration:gWXNotifDur];
        }
    });
}

static void _fbg_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center,
                             UNNotification *note,
                             void (^handler)(UNNotificationPresentationOptions)) {
    // v1.9.0：微信通知大弹窗接管
    if (gWXBigNotif && [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.tencent.xin"]) {
        UNNotificationContent *c = note.request.content;
        NSString *title = c.title.length ? c.title : (c.subtitle.length ? c.subtitle : @"微信");
        NSString *body = c.body;
        _wx_show_banner(title, body);
        // 抑制系统横幅，但保留声音和角标
        handler(UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
        return;
    }

    if (gUseScene && gPhysBg) {
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
    } else if (gOrigWillPresent) {
        gOrigWillPresent(self, _cmd, center, note, handler);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

// v1.9.1 前向声明
static void _fbg_installRemoteNotifHook(void);
static void _fbg_installNotifHooks(void);

// v1.9.1：统一的 delegate hook 逻辑，供 setDelegate 和初始化时主动调用
static void _fbg_hookNotifDelegate(id<UNUserNotificationCenterDelegate> delegate) {
    if (!delegate) return;
    Class dc = [delegate class];
    SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method m = class_getInstanceMethod(dc, sel);
    if (m) {
        IMP cur = method_getImplementation(m);
        if (cur != (IMP)_fbg_willPresent) {
            gOrigWillPresent = (void *)cur;
            method_setImplementation(m, (IMP)_fbg_willPresent);
            NSLog(@"[FUBG] hooked willPresentNotification on %@", NSStringFromClass(dc));
        }
    }
}

static void _fbg_unSetDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    _fbg_hookNotifDelegate(delegate);
}

static void _fbg_installNotifHooks(void) {
    Class unClass = [UNUserNotificationCenter class];
    Method delM = class_getInstanceMethod(unClass, @selector(setDelegate:));
    if (delM) {
        gOrigUNSetDelegate = (void (*)(id, SEL, id))method_getImplementation(delM);
        method_setImplementation(delM, (IMP)_fbg_unSetDelegate);
    }

    // 主动 hook 当前已设置的 delegate（修复竞态：微信可能在我们 swizzle 前就设好了 delegate）
    UNUserNotificationCenter *unc = [UNUserNotificationCenter currentNotificationCenter];
    if (unc.delegate) {
        _fbg_hookNotifDelegate(unc.delegate);
        NSLog(@"[FUBG] proactively hooked existing notif delegate");
    }
    // 延迟重试：有些 App 会在启动后期才设 delegate
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
        if (c.delegate) _fbg_hookNotifDelegate(c.delegate);
    });

    // hook 后台远程推送（willPresent 在后台不触发，需要从这里兜底）
    _fbg_installRemoteNotifHook();
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
}

#pragma mark - 后台远程推送 hook（v1.9.1）

static void (*gOrigDidReceiveRemote)(id, SEL, UIApplication *, NSDictionary *, void (^)(UIBackgroundFetchResult));

static void _fbg_didReceiveRemote(id self, SEL _cmd, UIApplication *app,
                                   NSDictionary *userInfo,
                                   void (^handler)(UIBackgroundFetchResult)) {
    // 微信通知大弹窗：后台推送时也弹自定义窗
    if (gWXBigNotif && [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.tencent.xin"]) {
        NSDictionary *aps = userInfo[@"aps"];
        if ([aps isKindOfClass:[NSDictionary class]]) {
            id alert = aps[@"alert"];
            NSString *title = nil, *body = nil;
            if ([alert isKindOfClass:[NSDictionary class]]) {
                title = alert[@"title"];
                body = alert[@"body"];
            } else if ([alert isKindOfClass:[NSString class]]) {
                body = alert;
            }
            if (title.length || body.length) {
                _wx_show_banner(title.length ? title : @"微信", body);
            }
        }
    }
    if (gOrigDidReceiveRemote) {
        gOrigDidReceiveRemote(self, _cmd, app, userInfo, handler);
    } else if (handler) {
        handler(UIBackgroundFetchResultNoData);
    }
}

static void _fbg_installRemoteNotifHook(void) {
    // 微信的 AppDelegate 可能不实现 didReceiveRemoteNotification，需要动态添加
    // 先尝试 hook UIApplication 的 delegate 方法
    Class appClass = [UIApplication class];
    SEL sel = @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:);
    Method m = class_getInstanceMethod(appClass, sel);
    // 这个方法实际在 delegate 上，不在 UIApplication 上
    // 我们通过 method exchange 在 AppDelegate 上添加
    // 由于无法预知 delegate 类名，采用另一种方式：hook UIApplication sendAction 或直接监听
    // 更可靠的方式：hook UIApplicationDelegate 协议方法的实现
    // 这里使用 +load 时机太晚，改用动态方式：遍历 window 的 delegate

    // 方案：hook UIApplication 的 _setDelegate: 或在 delegate 设置时拦截
    // 简化方案：直接 hook AppDelegate 的方法（通过 class_getInstanceMethod on delegate class）
    dispatch_async(dispatch_get_main_queue(), ^{
        id<UIApplicationDelegate> del = [UIApplication sharedApplication].delegate;
        if (del) {
            Class dc = [del class];
            Method rm = class_getInstanceMethod(dc, sel);
            if (rm) {
                IMP cur = method_getImplementation(rm);
                if (cur != (IMP)_fbg_didReceiveRemote) {
                    gOrigDidReceiveRemote = (void *)cur;
                    method_setImplementation(rm, (IMP)_fbg_didReceiveRemote);
                    NSLog(@"[FUBG] hooked didReceiveRemoteNotification on %@", NSStringFromClass(dc));
                }
            } else {
                // delegate 没实现这个方法，动态添加
                class_addMethod(dc, sel, (IMP)_fbg_didReceiveRemote, "v@:@@?");
                NSLog(@"[FUBG] added didReceiveRemoteNotification to %@", NSStringFromClass(dc));
            }
        }
    });
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
    // 微信里永不实例化悬浮窗（v1.8.7）
    BOOL _wc = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.tencent.xin"];
    if (!_wc) [[FBGFloatingWindow shared] refreshState];
    if (!gUseAudio && gPhysBg) _fbg_stopAudio(NO);
    if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) _fbg_startAudio();
}

#pragma mark - 入口

__attribute__((constructor))
static void FUBGEntry(void) {
    @autoreleasepool {
        // v1.8.7：微信恢复保活（场景伪装+音频断言），但永不创建悬浮球。
        // 悬浮球是常驻全屏透明 UIWindow（alert+1 层级），会抢占状态栏外观控制权，
        // 是预览页工具栏唤不出的直接元凶。场景伪装/音频断言只在后台活跃，不影响前台 UI。
        NSString *_bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        BOOL _isWC = [_bid isEqualToString:@"com.tencent.xin"];
        _fbg_loadPref();

        // v1.9.1：通知 hook 同步安装（修复竞态：dispatch_async 可能晚于微信设置 delegate）
        _fbg_installNotifHooks();

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
            if (gShowBall && !_isWC) [[FBGFloatingWindow shared] attachWhenSceneReady];   // 微信不装悬浮球
        });

        NSLog(@"[FUBG] v2.0.0 loaded in %@: active=%d scene=%d audio=%d ball=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gActive, gUseScene, gUseAudio, (gShowBall && !_isWC), gHasAudioMode,
              _isWC ? @" (WeChat: ball disabled)" :
              ((gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)"));
    }
}

