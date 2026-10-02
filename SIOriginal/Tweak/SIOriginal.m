// SIOriginal — 原版重制
// 基于 pw5a29 Speed Intensifier 10.1-1 的机制还原（CAAnimation setDuration: 单基类 hook
// + CASpring 参数缩放 + 慢放模式），针对 TrollStore / iOS 16 全新实现：
//   · 无 CydiaSubstrate 依赖，纯 ObjC runtime swizzle（TrollFools 注入友好）
//   · 线程局部标记防 CATransaction/UIView 双重除法（原版未处理的问题）
//   · 慢放（原版 slowDownFactor）与瞬切模式
//   · Darwin 通知热重载配置，黑名单逐进程判断
// 不包含任何 SpeedIntensifier / SIFusion / SpeedsterTS 项目代码。
//
// ============================ v1.8.12 优化加强 ============================
// [真 bug 1] CALayer addAnimation:forKey: 兜底改为调用保存的原始 IMP。
//   原来用 objc_msgSend(anim, setDuration:) 回写，而 setDuration: 自己已被 hook，
//   于是 duration 被 SIO_targetDuration 连乘两次（加速 ×5 实际变成 ÷25），
//   恰好违反本文件声称的「防双重除法」设计。
// [真 bug 2] runningPropertyAnimatorWithDuration:delay:options:animations:completion:
//   原来写成 SIO_swizzleClass(object_getClass(pa), …)：class_getClassMethod 内部是
//   class_getInstanceMethod(object_getClass(cls), sel)，再传元类等于去根元类里找，
//   必然返回 NULL 静默跳过——该 hook 从上线起从未生效。改为 SIO_swizzleClass(pa, …)。
// [真 bug 3] Blacklist 兼容 NSString 格式。原来无条件 componentsJoinedByString:，
//   一旦 plist 里是字符串（手工编辑/旧版本/其他工具写入）即 unrecognized selector，
//   注入进程启动崩溃。FUBG 侧 v1.8.6 已修，动画侧这次补齐。
// [真 bug 4] 导航/模态转场时长改为按模式计算 SIO_targetDuration(0.35)。
//   原来硬编码 setAnimationDuration:0.0 —— 慢放模式下导航/弹窗依旧瞬间完成，
//   慢放对这类转场等于完全无效；现在慢放真的变慢，加速模式约 0.07s（几乎无感）。
// [隐患 5] ListAccel 缺键默认由 YES 改为 NO。危险功能不再 fail-open。
// [隐患 6] FUBGExcludeApps 与 Blacklist 合并。原来排除表赋值后立刻被 Blacklist
//   无条件覆盖，排除机制实际从未生效。
// [性能 7] 黑名单在重载时一次性解析为进程布尔值 gSelfBlacklisted。
//   SIO_blocked() 是全部动画/事务 hook 的必经热路径，原来每次都要
//   componentsSeparatedByString: 分配数组。
// [性能 8] 微信预览放大态探测器加 3000 节点上限，超大视图树不再拖慢主线程。
// [健壮 9] 所有原 IMP 调用前判空；swizzle 增加重复安装保护（绝不把自己的 IMP
//   存成 orig 导致自递归）；两处 constructor 安装全程 @try 包裹，异常放行原实现。
// [加强 10] 新增 5 个低风险 hook：
//   +[UIView animateKeyframesWithDuration:delay:options:animations:completion:]
//   -[UIViewPropertyAnimator initWithDuration:timingParameters:]（2 参指定初始化器，
//     带线程局部重入保护，避免与 3 参变体双重缩放）
//   -[UITabBarController setSelectedIndex:] / setSelectedViewController:
//   -[UIViewController transitionFromViewController:toViewController:duration:…]
//   +[UIView performSystemAnimation:onViews:options:animations:completion:]
// 全部沿用已验证的 CATransaction/时长改写机制，不触碰 TV/CV 列表状态机。
// =========================================================================
//
// ============================ v1.8.13 优化加强 ============================
// [加强] 补齐老式 UIView 动画 API 的时长/延迟接管：
//   +[UIView setAnimationDuration:] 与 +[UIView setAnimationDelay:]
//   这是 beginAnimations:context: / commitAnimations 时代的唯一时长入口。
//   本支一直缺失（父项目 SpeedIntensifier 的增强层早已包含），而老 SDK、部分
//   国产 App 内部与第三方库仍在用这套 API —— 它们此前完全不受加速影响。
//   两个都是纯 setter（只改一个数值），是本项目风险最低的一类 hook。
//   双重缩放防护：这两个 setter 很可能被 UIKit 落到 CATransaction.setAnimationDuration:
//   上，或反过来被 animateWithDuration: 内部回调，因此：
//     · 进入时若已在自己的一次块动画包裹内（SIO_inUIViewAnim）→ 原样透传；
//     · 调用原 IMP 期间置起同一线程局部标记 → 抑制内部再入。
// =========================================================================
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
static BOOL     gListAccel = NO;     // TV/CV 列表全家桶（v1.8.11 起纯开关控制，默认关）
static BOOL     gIsWeChat  = NO;     // 微信缩放预览守卫用（L104）
// v1.8.12：黑名单在重载时一次性解析成本进程布尔值，热路径零分配（见 SIO_reload）
static BOOL     gSelfBlacklisted = NO;
static NSString *gSelfBundle = nil;

static pthread_key_t gInUIViewAnimKey;
static pthread_key_t gInPAInitKey;   // v1.8.12：UIViewPropertyAnimator 初始化重入保护

static inline BOOL SIO_inUIViewAnim(void)   { return (BOOL)(intptr_t)pthread_getspecific(gInUIViewAnimKey); }
static inline void SIO_setUIViewAnim(BOOL v){ pthread_setspecific(gInUIViewAnimKey, (void *)(intptr_t)(v ? 1 : 0)); }
static inline BOOL SIO_inPAInit(void)       { return (BOOL)(intptr_t)pthread_getspecific(gInPAInitKey); }
static inline void SIO_setPAInit(BOOL v)    { pthread_setspecific(gInPAInitKey, (void *)(intptr_t)(v ? 1 : 0)); }

// v1.8.12：原 IMP 判空（红线规则 #4）。方法不存在时 hook 不会被安装，这里是纯防御：
// 万一 orig 为空，直接放弃本次拦截，绝不对空指针发消息。
#define SIO_REQUIRE_ORIG(imp)      do { if (__builtin_expect((imp) == NULL, 0)) return; } while (0)
#define SIO_REQUIRE_ORIG_NIL(imp)  do { if (__builtin_expect((imp) == NULL, 0)) return nil; } while (0)

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

// v1.8.12：设置事务时长的唯一正确入口。
// 本体代码里凡是自己构造 CATransaction 时长的地方（导航/模态/Tab/列表/滚动/系统动画），
// 都必须走这里：`[CATransaction setAnimationDuration:X]` 会再次进入已被 swizzle 的
// setAnimationDuration:，于是同一个 X 被 SIO_targetDuration 缩放第二次
// （例如期望 0.07s 实际 0.014s，慢放期望 0.7s 实际 1.4s）。
// 这里借线程局部标记抑制这一层，嵌套时原样恢复。
static inline void SIO_setTransactionDuration(double d) {
    BOOL was = SIO_inUIViewAnim();
    SIO_setUIViewAnim(YES);
    [CATransaction setAnimationDuration:d];
    SIO_setUIViewAnim(was);
}

static void SIO_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) { gSelfBlacklisted = NO; return; }
    gEnabled = [d[@"Enabled"] boolValue];
    int mode = [d[@"Mode"] intValue];
    gMode = (mode >= 0 && mode <= 2) ? mode : 0;
    double sp = [d[@"Speed"] doubleValue];
    gSpeed = (sp >= 1.0 && sp <= 50.0) ? sp : 5.0;
    double sf = [d[@"SlowFactor"] doubleValue];
    gSlowFactor = (sf > 1.0 && sf <= 10.0) ? sf : 2.0;
    gSpring = d[@"Spring"] ? [d[@"Spring"] boolValue] : YES;
    gExtra  = d[@"Extra"]  ? [d[@"Extra"] boolValue]  : YES;
    // v1.8.12：缺键默认 NO（原来 `: YES`）。配置 plist 一旦缺 ListAccel（旧版本写入的、
    // 手工编辑过的、被其他工具覆盖过的），原来会静默打开 24 个列表 hook，
    // 在重列表 App 上直接破坏列表状态机——危险功能必须 fail-safe。
    gListAccel = d[@"ListAccel"] ? [d[@"ListAccel"] boolValue] : NO;

    // v1.8.12：黑名单一次性解析为布尔值（兼容 NSArray / NSString 两种格式）
    gSelfBlacklisted = NO;
    id bl = d[@"Blacklist"];
    NSArray *items = nil;
    if ([bl isKindOfClass:[NSArray class]]) {
        items = bl;
    } else if ([bl isKindOfClass:[NSString class]]) {
        // 旧版这里直接对 NSString 调 componentsJoinedByString: → unrecognized selector 崩溃
        items = [(NSString *)bl componentsSeparatedByString:@","];
    }
    NSString *bid = gSelfBundle ?: @"";
    if (bid.length) {
        for (id it in items) {
            if (![it isKindOfClass:[NSString class]]) continue;
            NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            if (s.length && [bid isEqualToString:s]) { gSelfBlacklisted = YES; break; }
        }
    }
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
            // v1.8.12：节点上限保护。超大视图树（长列表 / 复杂 WebView 容器）下
            // 每 0.25s 一次的全树遍历会拖慢主线程；超过上限即按「未放大」放行，
            // 宁可少一层保护，不可卡住界面。
            NSMutableArray<UIView *> *stack = roots;
            NSUInteger visited = 0;
            while (stack.count) {
                if (++visited > 3000) break;
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
    // v1.8.12：热路径零分配。全部动画/事务 hook 都从这里过，
    // 顺序按「最便宜、最可能命中」排列：布尔 → 布尔 → 节流后的探测结果。
    if (!gEnabled) return YES;
    if (gSelfBlacklisted) return YES;
    // v1.8.9：微信动画加速恢复（实验）——预览 bug 真凶已确认为悬浮球（v1.8.7 永久禁用），
    // 动画 hook 恢复生效；v1.8.4 放大态探测器首次真正启用作为安全网
    if (SIO_wechatZoomPreviewActive()) return YES;   // 微信预览放大态旁路（非微信时立即返回 NO）
    return NO;
}

// ---------- swizzle 工具 ----------
// v1.8.12：增加重复安装保护。若目标 IMP 已经是我们的实现（同一 dylib 被重复注入、
// 或 constructor 被执行两次），绝不能再把它存进 orig —— 否则回调会自递归爆栈。
static void SIO_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
}
// 注意：必须传「类对象」而不是元类。class_getClassMethod 内部执行的是
// class_getInstanceMethod(object_getClass(cls), sel)，传元类会去根元类查找并返回 NULL。
static void SIO_swizzleClass(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getClassMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (orig) *orig = cur;
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

// ---- v1.8.12 新增 hook ----
static void   (*o_UV_anim_keyframes)(Class, SEL, double, double, NSUInteger, void (^)(void), void (^)(BOOL));
static void   (*o_UV_systemAnim)(Class, SEL, NSUInteger, NSArray *, NSUInteger, void (^)(void), void (^)(BOOL));
static id     (*o_pa_initWithDurTP2)(id, SEL, double, id);
static void   (*o_tab_setIndex)(id, SEL, NSUInteger);
static void   (*o_tab_setVC)(id, SEL, UIViewController *);
static void   (*o_vc_transitionFrom)(id, SEL, UIViewController *, UIViewController *, double,
                                     UIViewAnimationOptions, void (^)(void), void (^)(BOOL));

// ---- v1.8.13 新增：老式 beginAnimations 动画 API 时长/延迟 ----
static void   (*o_UV_setAnimDuration)(Class, SEL, double);
static void   (*o_UV_setAnimDelay)(Class, SEL, double);

#pragma mark - CAAnimation（核心：仅基类，子类自动继承）

static void sio_CAAnim_setDuration(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_CAAnim_setDuration);
    if (SIO_blocked()) { o_CAAnim_setDuration(self, _cmd, d); return; }
    o_CAAnim_setDuration(self, _cmd, SIO_targetDuration(d));
}

#pragma mark - CATransaction

static void sio_CATransaction_setDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_CATransaction_setDur);
    if (SIO_inUIViewAnim() || SIO_blocked()) {
        o_CATransaction_setDur(self, _cmd, d);
        return;
    }
    o_CATransaction_setDur(self, _cmd, SIO_targetDuration(d));
}

#pragma mark - UIView 块动画（class methods）

// v1.8.12：delay 缩放抽成独立函数，供块动画与关键帧动画共用
static inline double SIO_targetDelay(double delay) {
    if (!gEnabled) return delay;
    double f;
    switch (gMode) {
        case 1:  f = gSlowFactor;                               break;  // 慢放：延迟同倍放大
        case 2:  f = 0.0;                                       break;  // 瞬切：延迟归零
        default: f = (gSpeed <= 1.0001) ? 1.0 : 1.0 / gSpeed;    break;  // 加速：延迟同倍缩短
    }
    return delay * f;
}

static void sio_UV_anim_d(Class self, SEL _cmd, double d, void (^a)(void)) {
    SIO_REQUIRE_ORIG(o_UV_anim_d);
    if (SIO_blocked()) { o_UV_anim_d(self, _cmd, d, a); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_d(self, _cmd, SIO_targetDuration(d), a);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_dc(Class self, SEL _cmd, double d, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_dc);
    if (SIO_blocked()) { o_UV_anim_dc(self, _cmd, d, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_dc(self, _cmd, SIO_targetDuration(d), a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_ddoc(Class self, SEL _cmd, double d, double delay, UIViewAnimationOptions o,
                             void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_ddoc);
    if (SIO_blocked()) { o_UV_anim_ddoc(self, _cmd, d, delay, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_ddoc(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_anim_spring(Class self, SEL _cmd, double d, double damp, double vel,
                               UIViewAnimationOptions o, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_spring);
    if (SIO_blocked()) { o_UV_anim_spring(self, _cmd, d, damp, vel, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    double m = SIO_springScale();
    o_UV_anim_spring(self, _cmd, SIO_targetDuration(d),
                     1.0 - (1.0 - damp) / m, vel * m, o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_trans(Class self, SEL _cmd, UIView *v, double d, UIViewAnimationOptions o,
                         void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_trans);
    if (SIO_blocked()) { o_UV_trans(self, _cmd, v, d, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_trans(self, _cmd, v, SIO_targetDuration(d), o, a, c);
    SIO_setUIViewAnim(NO);
}

static void sio_UV_transFrom(Class self, SEL _cmd, UIView *a1, UIView *a2, double d,
                             UIViewAnimationOptions o, void (^an)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_transFrom);
    if (SIO_blocked()) { o_UV_transFrom(self, _cmd, a1, a2, d, o, an, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_transFrom(self, _cmd, a1, a2, SIO_targetDuration(d), o, an, c);
    SIO_setUIViewAnim(NO);
}

// ---- v1.8.12 新增：关键帧动画 ----
// +[UIView animateKeyframesWithDuration:delay:options:animations:completion:]
// 关键帧动画（微信/淘宝等大量使用）此前完全未覆盖：它不走 animateWithDuration 系，
// 也不走 CAAnimation setDuration（内部按相对时间比换算），所以时长必须在这里改。
// options 参数用 NSUInteger 承接（UIViewKeyframeAnimationOptions 底层即 NSUInteger，ABI 一致）。
static void sio_UV_anim_keyframes(Class self, SEL _cmd, double d, double delay, NSUInteger o,
                                  void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_anim_keyframes);
    if (SIO_blocked()) { o_UV_anim_keyframes(self, _cmd, d, delay, o, a, c); return; }
    SIO_setUIViewAnim(YES);
    o_UV_anim_keyframes(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), o, a, c);
    SIO_setUIViewAnim(NO);
}

// ---- v1.8.12 新增：系统动画（删除/插入/重排等系统内建动画） ----
// +[UIView performSystemAnimation:onViews:options:animations:completion:]
// UISystemAnimation 同为 NSUInteger 枚举。用 CATransaction 覆盖时长，
// 不改写 animated 语义，避免影响系统对视图生命周期的收尾。
static void sio_UV_systemAnim(Class self, SEL _cmd, NSUInteger anim, NSArray *views, NSUInteger o,
                              void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_UV_systemAnim);
    if (SIO_blocked()) { o_UV_systemAnim(self, _cmd, anim, views, o, a, c); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_targetDuration(0.35));
    o_UV_systemAnim(self, _cmd, anim, views, o, a, c);
    [CATransaction commit];
}

// ---- v1.8.13 新增：老式 beginAnimations 动画 API ----
// 用法： [UIView beginAnimations:nil context:NULL];
//        [UIView setAnimationDuration:0.3];   ← 这里
//        [UIView setAnimationDelay:0.1];      ← 和这里
//        ... 改属性 ...
//        [UIView commitAnimations];
// 这套 API 在 iOS 13 起被标记 deprecated，但从未失效，老代码/SDK/第三方库里仍然大量存在；
// 它不走 animateWithDuration: 系，我们此前的 8 个 UIView 块动画 hook 全部拦不到。
static void sio_UV_setAnimDuration(Class self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_UV_setAnimDuration);
    // 已在自己的一次块动画/转场包裹内 → 说明这次调用是 UIKit 内部转发出来的，原样透传防止二次缩放
    if (SIO_blocked() || SIO_inUIViewAnim()) { o_UV_setAnimDuration(self, _cmd, d); return; }
    // 置起标记后再调原 IMP：若 UIKit 把老式 API 落到 CATransaction.setAnimationDuration:
    // （或回调本方法自身），那一层会被自己的 hook 跳过，保证只缩放一次。
    SIO_setUIViewAnim(YES);
    o_UV_setAnimDuration(self, _cmd, SIO_targetDuration(d));
    SIO_setUIViewAnim(NO);
}

static void sio_UV_setAnimDelay(Class self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_UV_setAnimDelay);
    if (SIO_blocked() || SIO_inUIViewAnim()) { o_UV_setAnimDelay(self, _cmd, d); return; }
    // 延迟与块动画 animateWithDuration:delay: 保持同一套换算：
    // 加速 → d/speed，慢放 → d×slowFactor，瞬切 → 0
    SIO_setUIViewAnim(YES);
    o_UV_setAnimDelay(self, _cmd, SIO_targetDelay(d));
    SIO_setUIViewAnim(NO);
}

#pragma mark - CASpring（原版灵魂功能：参数缩放保持物理一致性）

static void sio_CASpring_mass(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_mass);
    if (SIO_blocked() || !gSpring) { o_CASpring_mass(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_mass(self, _cmd, m > 0 ? v / (m * m) : v);
}

static void sio_CASpring_stiff(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_stiff);
    if (SIO_blocked() || !gSpring) { o_CASpring_stiff(self, _cmd, v); return; }
    double m = SIO_springScale();
    o_CASpring_stiff(self, _cmd, v * m * m);
}

static void sio_CASpring_damp(id self, SEL _cmd, double v) {
    SIO_REQUIRE_ORIG(o_CASpring_damp);
    if (SIO_blocked() || !gSpring) { o_CASpring_damp(self, _cmd, v); return; }
    o_CASpring_damp(self, _cmd, v * SIO_springScale());
}

#pragma mark - 导航 / 模态（进阶：事务时长包裹，转场动画交给事务时长统一控制）
//
// v1.8.12 真 bug 修复：这里原来一律 `setAnimationDuration:0.0`，效果是无论
// 加速/慢放/瞬切，导航与模态转场都被强制瞬间完成——慢放模式对这类转场
// 等于完全失效（用户开慢放看转场细节，结果转场根本没有）。
// 现在统一走 SIO_targetDuration(0.35)：
//   加速 ×5 → 0.07s（肉眼几乎无感，保持原有"秒过"体验）
//   慢放 ×2 → 0.70s（慢放真正生效）
//   瞬切    → 0.01s（直达）
static inline double SIO_transitionDuration(void) { return SIO_targetDuration(0.35); }

static void sio_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_push);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_push(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_push(self, _cmd, vc, anim);
    [CATransaction commit];
}

static void sio_nav_pop(id self, SEL _cmd, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_pop);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_pop(self, _cmd, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_pop(self, _cmd, anim);
    [CATransaction commit];
}

static void sio_nav_popTo(id self, SEL _cmd, UIViewController *vc, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_popTo);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_popTo(self, _cmd, vc, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_popTo(self, _cmd, vc, anim);
    [CATransaction commit];
}

static void sio_nav_setVCs(id self, SEL _cmd, NSArray *vcs, BOOL anim) {
    SIO_REQUIRE_ORIG(o_nav_setVCs);
    if (SIO_blocked() || !gExtra || !anim) { o_nav_setVCs(self, _cmd, vcs, anim); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_nav_setVCs(self, _cmd, vcs, anim);
    [CATransaction commit];
}

static void sio_nav_privDur(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_nav_privDur);
    if (SIO_blocked() || !gExtra) { o_nav_privDur(self, _cmd, d); return; }
    o_nav_privDur(self, _cmd, SIO_targetDuration(d));
}

static void sio_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_vc_present);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_present(self, _cmd, vc, anim, c); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_vc_present(self, _cmd, vc, anim, c);
    [CATransaction commit];
}

static void sio_vc_dismiss(id self, SEL _cmd, BOOL anim, void (^c)(void)) {
    SIO_REQUIRE_ORIG(o_vc_dismiss);
    if (SIO_blocked() || !gExtra || !anim) { o_vc_dismiss(self, _cmd, anim, c); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_vc_dismiss(self, _cmd, anim, c);
    [CATransaction commit];
}

// ---- v1.8.12 新增：容器控制器子控制器转场 ----
// -[UIViewController transitionFromViewController:toViewController:duration:options:animations:completion:]
// 与已 hook 的 +[UIView transitionFromView:…] 属同一机制，但走的是 VC 容器路径，
// 此前完全未覆盖（分栏/自研 Tab/向导式页面大量使用）。duration 直接改写。
static void sio_vc_transitionFrom(id self, SEL _cmd, UIViewController *from, UIViewController *to,
                                  double d, UIViewAnimationOptions o,
                                  void (^an)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG(o_vc_transitionFrom);
    if (SIO_blocked() || !gExtra) { o_vc_transitionFrom(self, _cmd, from, to, d, o, an, c); return; }
    o_vc_transitionFrom(self, _cmd, from, to, SIO_targetDuration(d), o, an, c);
}

// ---- v1.8.12 新增：底部 Tab 切换转场 ----
// UITabBarController 的选中切换此前未 hook（父项目 README 把它列为基础层 hook，
// 但 SIOriginal 这一支一直缺失）。用 CATransaction 覆盖时长，不改动选中语义。
static void sio_tab_setIndex(id self, SEL _cmd, NSUInteger idx) {
    SIO_REQUIRE_ORIG(o_tab_setIndex);
    if (SIO_blocked() || !gExtra) { o_tab_setIndex(self, _cmd, idx); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tab_setIndex(self, _cmd, idx);
    [CATransaction commit];
}

static void sio_tab_setVC(id self, SEL _cmd, UIViewController *vc) {
    SIO_REQUIRE_ORIG(o_tab_setVC);
    if (SIO_blocked() || !gExtra) { o_tab_setVC(self, _cmd, vc); return; }
    [CATransaction begin];
    SIO_setTransactionDuration(SIO_transitionDuration());
    o_tab_setVC(self, _cmd, vc);
    [CATransaction commit];
}

#pragma mark - TV/CV 列表全家桶（ListAccel 纯开关控制）

// v1.8.11：移除 com.sfic.knight 硬编码保护，24 个列表 hook 完全由配置开关控制。
// 重列表 App（顺丰骑士/淘宝/京东等）务必在配置 App 关闭「列表加速」，否则会破坏列表状态机。
static BOOL SIO_listOK(void) { return gListAccel && !SIO_blocked(); }

static void SIO_listWrap(void (^block)(void)) {
    [CATransaction begin];
    // v1.8.12：改走 SIO_setTransactionDuration。原来直接调 setAnimationDuration:，
    // 被自己的 hook 再缩放一次（0.25 在 ×5 下变成 0.01 而非预期的 0.05）。
    SIO_setTransactionDuration(SIO_targetDuration(0.25));
    block();
    [CATransaction commit];
}

// ---- UITableView ----
static void (*o_tv_selectRow)(id, SEL, NSIndexPath *, BOOL, UITableViewScrollPosition);
static void sio_tv_selectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UITableViewScrollPosition pos) {
    SIO_REQUIRE_ORIG(o_tv_selectRow);
    if (!SIO_listOK()) { o_tv_selectRow(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_tv_selectRow(self, _cmd, ip, anim, pos); });
}
static void (*o_tv_deselectRow)(id, SEL, NSIndexPath *, BOOL);
static void sio_tv_deselectRow(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_deselectRow);
    if (!SIO_listOK()) { o_tv_deselectRow(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_tv_deselectRow(self, _cmd, ip, anim); });
}
static void (*o_tv_scrollToRow)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollToRow(id self, SEL _cmd, NSIndexPath *ip, UITableViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_scrollToRow);
    if (!SIO_listOK()) { o_tv_scrollToRow(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollToRow(self, _cmd, ip, pos, anim); });
}
static void (*o_tv_scrollNearest)(id, SEL, UITableViewScrollPosition, BOOL);
static void sio_tv_scrollNearest(id self, SEL _cmd, UITableViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_scrollNearest);
    if (!SIO_listOK()) { o_tv_scrollNearest(self, _cmd, pos, anim); return; }
    SIO_listWrap(^{ o_tv_scrollNearest(self, _cmd, pos, anim); });
}
static void (*o_tv_reloadData)(id, SEL);
static void sio_tv_reloadData(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_tv_reloadData);
    if (!SIO_listOK()) { o_tv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_tv_reloadData(self, _cmd); });
}
static void (*o_tv_reloadRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_reloadRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_reloadRows);
    if (!SIO_listOK()) { o_tv_reloadRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_reloadRows(self, _cmd, ips, a); });
}
static void (*o_tv_reloadSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_reloadSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_reloadSections);
    if (!SIO_listOK()) { o_tv_reloadSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_reloadSections(self, _cmd, sec, a); });
}
static void (*o_tv_insertRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_insertRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_insertRows);
    if (!SIO_listOK()) { o_tv_insertRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_insertRows(self, _cmd, ips, a); });
}
static void (*o_tv_deleteRows)(id, SEL, NSArray *, UITableViewRowAnimation);
static void sio_tv_deleteRows(id self, SEL _cmd, NSArray *ips, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_deleteRows);
    if (!SIO_listOK()) { o_tv_deleteRows(self, _cmd, ips, a); return; }
    SIO_listWrap(^{ o_tv_deleteRows(self, _cmd, ips, a); });
}
static void (*o_tv_moveRow)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_tv_moveRow(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_REQUIRE_ORIG(o_tv_moveRow);
    if (!SIO_listOK()) { o_tv_moveRow(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveRow(self, _cmd, from, to); });
}
static void (*o_tv_insertSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_insertSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_insertSections);
    if (!SIO_listOK()) { o_tv_insertSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_insertSections(self, _cmd, sec, a); });
}
static void (*o_tv_deleteSections)(id, SEL, NSIndexSet *, UITableViewRowAnimation);
static void sio_tv_deleteSections(id self, SEL _cmd, NSIndexSet *sec, UITableViewRowAnimation a) {
    SIO_REQUIRE_ORIG(o_tv_deleteSections);
    if (!SIO_listOK()) { o_tv_deleteSections(self, _cmd, sec, a); return; }
    SIO_listWrap(^{ o_tv_deleteSections(self, _cmd, sec, a); });
}
static void (*o_tv_moveSection)(id, SEL, NSUInteger, NSUInteger);
static void sio_tv_moveSection(id self, SEL _cmd, NSUInteger from, NSUInteger to) {
    SIO_REQUIRE_ORIG(o_tv_moveSection);
    if (!SIO_listOK()) { o_tv_moveSection(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_tv_moveSection(self, _cmd, from, to); });
}
static void (*o_tv_setEditing)(id, SEL, BOOL, BOOL);
static void sio_tv_setEditing(id self, SEL _cmd, BOOL editing, BOOL anim) {
    SIO_REQUIRE_ORIG(o_tv_setEditing);
    if (!SIO_listOK()) { o_tv_setEditing(self, _cmd, editing, anim); return; }
    SIO_listWrap(^{ o_tv_setEditing(self, _cmd, editing, anim); });
}
static void (*o_tv_batchUpdates)(id, SEL, void (^)(void), void (^)(BOOL));
static void sio_tv_batchUpdates(id self, SEL _cmd, void (^updates)(void), void (^comp)(BOOL)) {
    SIO_REQUIRE_ORIG(o_tv_batchUpdates);
    if (!SIO_listOK()) { o_tv_batchUpdates(self, _cmd, updates, comp); return; }
    SIO_listWrap(^{ o_tv_batchUpdates(self, _cmd, updates, comp); });
}

// ---- UICollectionView ----
static void (*o_cv_reloadData)(id, SEL);
static void sio_cv_reloadData(id self, SEL _cmd) {
    SIO_REQUIRE_ORIG(o_cv_reloadData);
    if (!SIO_listOK()) { o_cv_reloadData(self, _cmd); return; }
    SIO_listWrap(^{ o_cv_reloadData(self, _cmd); });
}
static void (*o_cv_reloadItems)(id, SEL, NSArray *);
static void sio_cv_reloadItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_reloadItems);
    if (!SIO_listOK()) { o_cv_reloadItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_reloadItems(self, _cmd, ips); });
}
static void (*o_cv_reloadSections)(id, SEL, NSArray *);
static void sio_cv_reloadSections(id self, SEL _cmd, NSArray *secs) {
    SIO_REQUIRE_ORIG(o_cv_reloadSections);
    if (!SIO_listOK()) { o_cv_reloadSections(self, _cmd, secs); return; }
    SIO_listWrap(^{ o_cv_reloadSections(self, _cmd, secs); });
}
static void (*o_cv_insertItems)(id, SEL, NSArray *);
static void sio_cv_insertItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_insertItems);
    if (!SIO_listOK()) { o_cv_insertItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_insertItems(self, _cmd, ips); });
}
static void (*o_cv_deleteItems)(id, SEL, NSArray *);
static void sio_cv_deleteItems(id self, SEL _cmd, NSArray *ips) {
    SIO_REQUIRE_ORIG(o_cv_deleteItems);
    if (!SIO_listOK()) { o_cv_deleteItems(self, _cmd, ips); return; }
    SIO_listWrap(^{ o_cv_deleteItems(self, _cmd, ips); });
}
static void (*o_cv_moveItem)(id, SEL, NSIndexPath *, NSIndexPath *);
static void sio_cv_moveItem(id self, SEL _cmd, NSIndexPath *from, NSIndexPath *to) {
    SIO_REQUIRE_ORIG(o_cv_moveItem);
    if (!SIO_listOK()) { o_cv_moveItem(self, _cmd, from, to); return; }
    SIO_listWrap(^{ o_cv_moveItem(self, _cmd, from, to); });
}
static void (*o_cv_scrollToItem)(id, SEL, NSIndexPath *, UICollectionViewScrollPosition, BOOL);
static void sio_cv_scrollToItem(id self, SEL _cmd, NSIndexPath *ip, UICollectionViewScrollPosition pos, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_scrollToItem);
    if (!SIO_listOK()) { o_cv_scrollToItem(self, _cmd, ip, pos, anim); return; }
    SIO_listWrap(^{ o_cv_scrollToItem(self, _cmd, ip, pos, anim); });
}
static void (*o_cv_selectItem)(id, SEL, NSIndexPath *, BOOL, UICollectionViewScrollPosition);
static void sio_cv_selectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim, UICollectionViewScrollPosition pos) {
    SIO_REQUIRE_ORIG(o_cv_selectItem);
    if (!SIO_listOK()) { o_cv_selectItem(self, _cmd, ip, anim, pos); return; }
    SIO_listWrap(^{ o_cv_selectItem(self, _cmd, ip, anim, pos); });
}
static void (*o_cv_deselectItem)(id, SEL, NSIndexPath *, BOOL);
static void sio_cv_deselectItem(id self, SEL _cmd, NSIndexPath *ip, BOOL anim) {
    SIO_REQUIRE_ORIG(o_cv_deselectItem);
    if (!SIO_listOK()) { o_cv_deselectItem(self, _cmd, ip, anim); return; }
    SIO_listWrap(^{ o_cv_deselectItem(self, _cmd, ip, anim); });
}

#pragma mark - 安装

__attribute__((constructor))
static void SIOriginalInit(void) {
    // v1.8.12：安装全程 @try 包裹。任何一步异常只丢功能，绝不影响目标 App 启动（红线规则 #2）。
    @try {
    pthread_key_create(&gInUIViewAnimKey, NULL);
    pthread_key_create(&gInPAInitKey, NULL);
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
    // v1.8.12 新增：关键帧动画 + 系统动画（同为 UIView 类方法，低风险）
    SIO_swizzleClass(uv, @selector(animateKeyframesWithDuration:delay:options:animations:completion:),
                     (IMP)sio_UV_anim_keyframes, (IMP *)&o_UV_anim_keyframes);
    SIO_swizzleClass(uv, @selector(performSystemAnimation:onViews:options:animations:completion:),
                     (IMP)sio_UV_systemAnim, (IMP *)&o_UV_systemAnim);
    // v1.8.13 新增：老式 beginAnimations/commitAnimations 时代的时长与延迟入口
    SIO_swizzleClass(uv, @selector(setAnimationDuration:),
                     (IMP)sio_UV_setAnimDuration, (IMP *)&o_UV_setAnimDuration);
    SIO_swizzleClass(uv, @selector(setAnimationDelay:),
                     (IMP)sio_UV_setAnimDelay, (IMP *)&o_UV_setAnimDelay);

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
        // v1.8.12 新增：容器控制器子控制器转场（与 UIView 转场同机制，此前未覆盖）
        SIO_swizzleInstance(vc, @selector(transitionFromViewController:toViewController:duration:options:animations:completion:),
                            (IMP)sio_vc_transitionFrom, (IMP *)&o_vc_transitionFrom);
    }

    // v1.8.12 新增：底部 Tab 切换转场（父项目基础层有，SIOriginal 这一支一直缺失）
    Class tab = objc_getClass("UITabBarController");
    if (tab) {
        SIO_swizzleInstance(tab, @selector(setSelectedIndex:),
                            (IMP)sio_tab_setIndex, (IMP *)&o_tab_setIndex);
        SIO_swizzleInstance(tab, @selector(setSelectedViewController:),
                            (IMP)sio_tab_setVC, (IMP *)&o_tab_setVC);
    }

    // TV/CV 列表全家桶 ×24（ListAccel 纯开关控制；重列表 App 默认关闭）
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

    // v1.8.12：启动指纹日志，便于测试时在 Console 确认注入的版本与生效配置
    NSLog(@"[SIOriginal] v1.8.13 hooks installed in %@ (enabled=%d mode=%d speed=%.1f spring=%d extra=%d list=%d)",
          gSelfBundle, gEnabled, gMode, gSpeed, gSpring, gExtra, gListAccel);
    } @catch (NSException *e) {
        NSLog(@"[SIOriginal] hook install failed (feature degraded, app unaffected): %@", e);
    }
}

#pragma mark - UIViewPropertyAnimator（iOS 10+ 现代 App 主流动画 API）
//
// v1.8.12 覆盖补强：新增 2 参指定初始化器 initWithDuration:timingParameters:。
// App 常见写法是 `[[UIViewPropertyAnimator alloc] initWithDuration:tp]` 之后再
// addAnimations:，这条路径此前完全没被拦到（旧的三个 hook 都是带 animations: 的变体）。
// 同时 3 参变体内部大概率会回调到 2 参初始化器，所以用线程局部 gInPAInit 做重入保护，
// 避免同一次初始化被缩放两次（÷speed²）。

// duration setter — 拦截已创建 animator 的时长修改
static void sio_PA_setDuration(id self, SEL _cmd, double d) {
    SIO_REQUIRE_ORIG(o_pa_setDuration);
    if (SIO_blocked()) { o_pa_setDuration(self, _cmd, d); return; }
    o_pa_setDuration(self, _cmd, SIO_targetDuration(d));
}

// v1.8.12：2 参指定初始化器（唯一在 App 代码里直接可见的 duration 入口）
static id sio_PA_initWithDurTP2(id self, SEL _cmd, double d, id tp) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurTP2);
    if (!SIO_blocked() && !SIO_inPAInit()) d = SIO_targetDuration(d);
    return o_pa_initWithDurTP2(self, _cmd, d, tp);
}

// initWithDuration:timingParameters:animations: — CA/CubicTimingParameters init
static id sio_PA_initWithDurTP(id self, SEL _cmd, double d, id tp, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurTP);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurTP(self, _cmd, d, tp, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurTP(self, _cmd, SIO_targetDuration(d), tp, a);
    SIO_setPAInit(NO);
    return r;
}

// initWithDuration:controlPoint1:controlPoint2:animations: — Bezier init
static id sio_PA_initWithDurCP(id self, SEL _cmd, double d, CGPoint p1, CGPoint p2, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurCP);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurCP(self, _cmd, d, p1, p2, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurCP(self, _cmd, SIO_targetDuration(d), p1, p2, a);
    SIO_setPAInit(NO);
    return r;
}

// initWithDuration:springDampingRatio:animations: — Spring init
static id sio_PA_initWithDurSpring(id self, SEL _cmd, double d, double dr, void (^a)(void)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_initWithDurSpring);
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_initWithDurSpring(self, _cmd, d, dr, a);
    SIO_setPAInit(YES);
    id r = o_pa_initWithDurSpring(self, _cmd, SIO_targetDuration(d), dr, a);
    SIO_setPAInit(NO);
    return r;
}

// runningPropertyAnimatorWithDuration:delay:options:animations:completion: — 类方法
// v1.8.12：真 bug 修复。原来安装处写成 SIO_swizzleClass(object_getClass(pa), …)，
// class_getClassMethod 内部会再做一次 object_getClass，等于在根元类里找这个方法，
// 必然返回 NULL —— 该 hook 从未生效。安装处现已改为 SIO_swizzleClass(pa, …)。
// 同时补上 delay 的同比缩放（原来 delay 完全没动，与块动画行为不一致）。
static id sio_PA_runningPA(id self, SEL _cmd, double d, double delay, UIViewAnimationOptions opt, void (^a)(void), void (^c)(BOOL)) {
    SIO_REQUIRE_ORIG_NIL(o_pa_runningPA);
    // 该便捷构造器内部同样会走 initWithDuration:timingParameters:，
    // 必须加同一把重入锁，否则时长被缩放两次。
    if (SIO_blocked() || SIO_inPAInit()) return o_pa_runningPA(self, _cmd, d, delay, opt, a, c);
    SIO_setPAInit(YES);
    id r = o_pa_runningPA(self, _cmd, SIO_targetDuration(d), SIO_targetDelay(delay), opt, a, c);
    SIO_setPAInit(NO);
    return r;
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
    SIO_REQUIRE_ORIG(o_sv_setContentOffset);
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
    SIO_setTransactionDuration(SIO_targetDuration(0.35));
    o_sv_setContentOffset(self, _cmd, p, YES);
    [CATransaction commit];
}

static void sio_SV_scrollRect(id self, SEL _cmd, CGRect r, BOOL animated) {
    SIO_REQUIRE_ORIG(o_sv_scrollRect);
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
    SIO_setTransactionDuration(SIO_targetDuration(0.35));
    o_sv_scrollRect(self, _cmd, r, YES);
    [CATransaction commit];
}

#pragma mark - CALayer addAnimation:forKey:（补 CAAnimation setDuration 盲区）

static void sio_layer_addAnim(id self, SEL _cmd, id anim, NSString *key) {
    SIO_REQUIRE_ORIG(o_layer_addAnim);
    // CAAnimation setDuration 基类 hook 已经覆盖了绝大多数情况，
    // 但少数 app 在 addAnimation 后才设置 duration（顺序问题），这里二次兜底。
    //
    // v1.8.12 真 bug 修复：原来用 objc_msgSend(anim, setDuration:, newDur) 回写，
    // 而 setDuration: 的 IMP 此时已经是我们自己的 sio_CAAnim_setDuration，
    // 于是同一次时长被 SIO_targetDuration 处理两次（加速 ×5 实际变成 ÷25），
    // 与文件开头声称的「防双重除法」正好相反。
    // 正确做法：直接调用 swizzle 时保存下来的原始 IMP，绕过自己的 hook。
    if (!SIO_blocked() && anim && o_CAAnim_setDuration &&
        [anim isKindOfClass:[CAAnimation class]]) {
        @try {
            double origDur = ((CAAnimation *)anim).duration;
            if (origDur > 0) {
                double newDur = SIO_targetDuration(origDur);
                if (newDur != origDur) {
                    o_CAAnim_setDuration(anim, @selector(setDuration:), newDur);
                }
            }
        } @catch (__unused NSException *e) {}
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
        // v1.8.12 新增：2 参指定初始化器（App 直接使用的时长入口）
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:),
                            (IMP)sio_PA_initWithDurTP2, (IMP *)&o_pa_initWithDurTP2);
        SIO_swizzleInstance(pa, @selector(initWithDuration:timingParameters:animations:),
                            (IMP)sio_PA_initWithDurTP, (IMP *)&o_pa_initWithDurTP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:controlPoint1:controlPoint2:animations:),
                            (IMP)sio_PA_initWithDurCP, (IMP *)&o_pa_initWithDurCP);
        SIO_swizzleInstance(pa, @selector(initWithDuration:springDampingRatio:animations:),
                            (IMP)sio_PA_initWithDurSpring, (IMP *)&o_pa_initWithDurSpring);
        // v1.8.12 真 bug 修复：必须传类对象 pa，不能传 object_getClass(pa)（元类）。
        // class_getClassMethod 内部会执行 class_getInstanceMethod(object_getClass(cls), sel)，
        // 传元类等于去根元类查找，必然 NULL —— 原来这一行是静默失效的死代码。
        SIO_swizzleClass(pa, @selector(runningPropertyAnimatorWithDuration:delay:options:animations:completion:),
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
            // v1.8.12 隐患修复：FUBGExcludeApps 与 Blacklist 取并集。
            // 原实现先赋 FUBGExcludeApps、紧接着被 Blacklist 无条件覆盖——只要配置里
            // 存在 Blacklist（配置 App 默认就会写入 com.tencent.wework），排除表永久失效。
            NSMutableArray *ex = [NSMutableArray array];
            id exRaw = d[@"FUBGExcludeApps"];
            if ([exRaw isKindOfClass:[NSArray class]]) [ex addObjectsFromArray:exRaw];
            // 复用 SIOriginal 黑名单（v1.8.6：兼容字符串格式，原来只认 NSArray 导致黑名单对 FUBG 永远无效）
            id bl = d[@"Blacklist"];
            if ([bl isKindOfClass:[NSArray class]]) {
                [ex addObjectsFromArray:bl];
            } else if ([bl isKindOfClass:[NSString class]] && [(NSString *)bl length]) {
                [ex addObjectsFromArray:[(NSString *)bl componentsSeparatedByString:@","]];
            }
            // 清洗：只保留非空字符串。_fbg_isExcluded 会对元素调 hasPrefix:，
            // plist 里一旦混入 NSNumber/NSNull（手工编辑）就会 unrecognized selector 崩溃。
            NSMutableArray *clean = [NSMutableArray array];
            for (id it in ex) {
                if (![it isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
                if (s.length) [clean addObject:s];
            }
            gExclude = clean;
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];
    gLocalOff = [[NSUserDefaults standardUserDefaults] boolForKey:kFBGLocalOff];
    // v1.8.10：悬浮球全局禁用，本地开关失去载体；
    // 若旧版本误触过球，fubg_local_off=YES 永久残留导致保活永不生效，全部清零
    gLocalOff = NO;

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
    // v1.8.10：悬浮球全局禁用，无需刷新
    if (!gUseAudio && gPhysBg) _fbg_stopAudio(NO);
    if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) _fbg_startAudio();
}

#pragma mark - 入口

__attribute__((constructor))
static void FUBGEntry(void) {
    @autoreleasepool {
    // v1.8.12：与动画侧同样全程 @try 包裹，保活引擎装不上也不能拖垮目标 App。
    @try {
        // v1.8.10：全 App 通用保活（场景伪装+音频断言），悬浮球全局禁用。
        // 悬浮球是常驻全屏透明 UIWindow（alert+1 层级），会拦截触摸/抢占状态栏。
        // 场景伪装/音频断言只在后台活跃，不影响前台 UI。
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
            // v1.8.10：悬浮球全局禁用（常驻透明 UIWindow 会拦截触摸/抢占状态栏）
        });

        NSLog(@"[FUBG] v2.0.0 (SIOriginal v1.8.13) loaded in %@: active=%d scene=%d audio=%d ball=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gActive, gUseScene, gUseAudio, gShowBall, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    } @catch (NSException *e) {
        NSLog(@"[FUBG] keep-alive install failed (app unaffected): %@", e);
    }
    }
}

