// SpeedIntensifier v1.5.6 — 可注入动画加速 Tweak（纯 ObjC runtime，无 substrate）
// v1.5.6 增强：合并两个"微信实测不闪退"样本的全部精华（tongyong 分支 = 本 tweak v1.5.4 增强派生；
//              AnimationSpeedTweak v3.5 = developlab 独立实现），62 hooks：
//   · 恢复 17 个 hook（tongyong 在当前微信实测安全）：Nav 整栈替换 / Tab 直选 VC / PageVC 翻页 /
//     UISV 缩放×2 / TV 编辑·重载段·选中·取消选中 / CV 布局切换×2 / 三类栏 setItems / 控件×3
//   · 新增 CALayer actionForKey:（隐式动画瞬时化：极速/瞬切档对 position/bounds/opacity 等常用
//     隐式 key 返回 nil，正规返回值无副作用）——AnimationSpeedTweak 核心技巧
//   · 新增 CAPropertyAnimation setDuration: 二级链（仅当其 Method 与 CAAnimation 基类不同才安装，
//     防重复链；同类 hook 在 AnimationSpeedTweak 长期稳定）
// 默认最快档 0.001 + 火力全开；基础 19 hook；ExtraAcceleration（默认 YES）叠加 43 个增强 hook（共 62）；
// v1.5.1 修复：移除 CAAnimation 子类重复 setDuration: hook——子类继承基类实现，二次交换导致
//              无限递归栈溢出，非黑名单 App 启动即闪退；基类 hook 已覆盖全部子类。
//              addAnimation 仅收窄默认 0.25s 时长，避免对已缩放时长二次缩放。
// v1.4：- CALayer addAnimation:forKey: 加速（loading 转轮/CABasic 显式动画也极快，backdrop/visualeffect/blur 跳过）；
//       - 黑名单感知的保底门槛（黑名单 App 仍 50ms 兼容，非黑名单 nav/tab 16ms、present 30ms、CA 8ms）；
// v1.5 新增 23 hook：导航整栈替换/TabBar 直选 VC/翻页/容器转场、缩放、列表编辑与布局、栏项、控件、
//       PropertyAnimator 贝塞尔与延迟启动、performSystemAnimation、setAnimationDelay、InstantMode 瞬切模式。
// v1.5.3：微信（com.tencent.xin）移出默认黑名单，与其他 App 一样吃满全部 61 hook + 极速档位；
//         黑名单仅保留企业微信（com.tencent.wework）。v1.5.1 已修复递归闪退，且 addAnimation
//         hook 本就跳过 backdrop/visualeffect/blur/gaussian/snapshot 毛玻璃层，微信兼容性由用户实测验证。
// 黑名单 App（现仅默认企业微信）只走基础 hook。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ================================
// 全局配置（默认最快 0.001 + 额外加速全开）
// ================================
static double  gFactor = 0.001;
static BOOL    gEnabled = YES;
static BOOL    gInstantMode = NO;
static BOOL    gExtra = YES;            // 额外加速总开关（默认开）
static BOOL    gBlacklisted = NO;       // 当前 App 是否命中黑名单
static NSArray *gBlacklist = nil;

#define kPrefPath "/var/Managed Preferences/mobile/com.local.speedintensifier.plist"
#define kDefaultBlacklist @[ @"com.tencent.wework" ]   // v1.5.3：微信移出黑名单，仅保留企业微信

static void _loadPref(void) {
    NSDictionary *d = nil;
    @try {
        d = [NSDictionary dictionaryWithContentsOfFile:@kPrefPath];
        if (d) {
            NSNumber *f = d[@"SpeedFactor"];
            NSNumber *e = d[@"Enabled"];
            NSNumber *x = d[@"ExtraAcceleration"];
            NSNumber *m = d[@"InstantMode"];
            if (f) gFactor = [f doubleValue];
            if (e) gEnabled = [e boolValue];
            if (x) gExtra = [x boolValue];
            if (m) gInstantMode = [m boolValue];
            gBlacklist = d[@"Blacklist"];
        }
    } @catch (__unused NSException *ex) { }
    if (gFactor <= 0.0) gFactor = 0.001;    // 保底最快
    if (gFactor > 1.0)  gFactor = 1.0;
    if (!gBlacklist) gBlacklist = kDefaultBlacklist;

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gBlacklist) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) { gBlacklisted = YES; break; }
    }
}

// ================================
// 核心加速逻辑
// ================================
static double _effectiveFactor(void) {
    if (!gEnabled) return 1.0;   // 关闭 => 原速
    if (gInstantMode) return 0.0;
    return gFactor;
}

// 额外加速是否对当前 App 生效
static inline BOOL _extraOn(void) {
    return gEnabled && gExtra && !gBlacklisted;
}

static inline NSTimeInterval _scaleInterval(NSTimeInterval t, double f) {
    if (gInstantMode) return 0.0;
    if (t <= 0) return t;
    NSTimeInterval s = t * f;
    return (s < 0.016 && s > 0) ? 0.016 : s;
}

static inline NSTimeInterval _scaleVC(NSTimeInterval t, double f, double minMs) {
    if (gInstantMode) return 0.0;
    if (t <= 0) return t;
    NSTimeInterval scaled = t * f;
    double minSec = minMs / 1000.0;
    if (scaled < minSec) scaled = minSec;
    // never return > original (already scaled, just cap at original)
    return scaled;
}

// 黑名单感知的保底门槛：黑名单 App 保留兼容性，其余 App 极快
static inline double _pageMinMs(void)   { return gBlacklisted ? 50.0 : 16.0; }
static inline double _presentMinMs(void) { return gBlacklisted ? 50.0 : 30.0; }
static inline double _caMinMs(void)      { return gBlacklisted ? 16.0 :  8.0; }

// ================================
// Swizzle 辅助（替换方法桥接到目标类）
// ================================
static BOOL _swizzleInstance(Class cls, SEL orig, SEL repl) {
    if (!cls) { NSLog(@"[SI] skip nil cls for %@", NSStringFromSelector(orig)); return NO; }
    Method origMethod = class_getInstanceMethod(cls, orig);
    Method replMethod = class_getInstanceMethod(objc_getClass("SpeedIntensifierTweak"), repl);
    if (!origMethod) { NSLog(@"[SI] MISSING orig %@ on %@", NSStringFromSelector(orig), cls); return NO; }
    if (!replMethod) { NSLog(@"[SI] MISSING repl %@ on SpeedIntensifierTweak", NSStringFromSelector(repl)); return NO; }
    IMP replImp = method_getImplementation(replMethod);
    const char *types = method_getTypeEncoding(replMethod);
    if (!class_addMethod(cls, repl, replImp, types)) {
        Method existing = class_getInstanceMethod(cls, repl);
        if (existing) { method_exchangeImplementations(origMethod, existing); return YES; }
        NSLog(@"[SI] FAIL add %@ to %@", NSStringFromSelector(repl), cls);
        return NO;
    }
    Method replInCls = class_getInstanceMethod(cls, repl);
    method_exchangeImplementations(origMethod, replInCls);
    return YES;
}

static BOOL _swizzleClass(Class cls, SEL orig, SEL repl) {
    if (!cls) { NSLog(@"[SI] skip nil cls for %@", NSStringFromSelector(orig)); return NO; }
    Method origMethod = class_getClassMethod(cls, orig);
    Method replMethod = class_getClassMethod(objc_getClass("SpeedIntensifierTweak"), repl);
    if (!origMethod) { NSLog(@"[SI] MISSING orig %@ on %@", NSStringFromSelector(orig), cls); return NO; }
    if (!replMethod) { NSLog(@"[SI] MISSING repl %@ on SpeedIntensifierTweak", NSStringFromSelector(repl)); return NO; }
    IMP replImp = method_getImplementation(replMethod);
    const char *types = method_getTypeEncoding(replMethod);
    Class meta = object_getClass(cls);
    if (!class_addMethod(meta, repl, replImp, types)) {
        Method existing = class_getClassMethod(cls, repl);
        if (existing) { method_exchangeImplementations(origMethod, existing); return YES; }
        NSLog(@"[SI] FAIL add %@ to meta %@", NSStringFromSelector(repl), cls);
        return NO;
    }
    Method replInMeta = class_getClassMethod(cls, repl);
    method_exchangeImplementations(origMethod, replInMeta);
    return YES;
}

// ================================
// 替换实现（定义在 SpeedIntensifierTweak 上，运行时桥接到目标类）
// ================================
@interface SpeedIntensifierTweak : NSObject
@end

@implementation SpeedIntensifierTweak

// ---------- 基础层 ----------
+ (void)as_UIView_animate:(NSTimeInterval)d
               animations:(void (^)(void))a {
    double f = _effectiveFactor();
    [self as_UIView_animate:_scaleInterval(d, f) animations:a];
}

+ (void)as_UIView_animate:(NSTimeInterval)d
               animations:(void (^)(void))a
               completion:(void (^)(BOOL))c {
    double f = _effectiveFactor();
    [self as_UIView_animate:_scaleInterval(d, f) animations:a completion:c];
}

+ (void)as_UIView_animate:(NSTimeInterval)d
                     delay:(NSTimeInterval)dl
                   options:(UIViewAnimationOptions)o
                animations:(void (^)(void))a
                completion:(void (^)(BOOL))c {
    double f = _effectiveFactor();
    [self as_UIView_animate:_scaleInterval(d, f)
                       delay:dl * f
                     options:o
                  animations:a
                  completion:c];
}

+ (void)as_UIView_animate:(NSTimeInterval)d
                     delay:(NSTimeInterval)dl
      usingSpringWithDamping:(CGFloat)dr
       initialSpringVelocity:(CGFloat)v
                     options:(UIViewAnimationOptions)o
                  animations:(void (^)(void))a
                  completion:(void (^)(BOOL))c {
    double f = _effectiveFactor();
    [self as_UIView_animate:_scaleInterval(d, f)
                       delay:dl * f
        usingSpringWithDamping:dr
         initialSpringVelocity:v * f
                     options:o
                  animations:a
                  completion:c];
}

+ (void)as_UIView_transitionWithView:(UIView *)vw
                             duration:(NSTimeInterval)d
                              options:(UIViewAnimationOptions)o
                           animations:(void (^)(void))a
                           completion:(void (^)(BOOL))c {
    double f = _effectiveFactor();
    [self as_UIView_transitionWithView:vw duration:_scaleInterval(d, f) options:o animations:a completion:c];
}

+ (void)as_UIView_transitionFromView:(UIView *)fv
                               toView:(UIView *)tv
                             duration:(NSTimeInterval)d
                              options:(UIViewAnimationOptions)o
                           completion:(void (^)(BOOL))c {
    double f = _effectiveFactor();
    [self as_UIView_transitionFromView:fv toView:tv duration:_scaleInterval(d, f) options:o completion:c];
}

- (instancetype)as_UIPA_initDuration:(NSTimeInterval)d
                    timingParameters:(id<UITimingCurveProvider>)tp {
    double f = _effectiveFactor();
    return [self as_UIPA_initDuration:_scaleInterval(d, f) timingParameters:tp];
}

- (instancetype)as_UIPA_initDuration:(NSTimeInterval)d
                        dampingRatio:(CGFloat)r
                          animations:(void (^)(void))a {
    double f = _effectiveFactor();
    return [self as_UIPA_initDuration:_scaleInterval(d, f) dampingRatio:r animations:a];
}

- (void)as_UIPA_setDuration:(NSTimeInterval)d {
    double f = _effectiveFactor();
    [self as_UIPA_setDuration:_scaleInterval(d, f)];
}

- (void)as_UISV_setContentOffset:(CGPoint)o animated:(BOOL)an {
    if (!an || !gEnabled) { [self as_UISV_setContentOffset:o animated:an]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleInterval(0.25, f)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_UISV_setContentOffset:o animated:NO]; }
                     completion:nil];
}

- (void)as_UISV_scrollRectToVisible:(CGRect)r animated:(BOOL)an {
    if (!an || !gEnabled) { [self as_UISV_scrollRectToVisible:r animated:an]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleInterval(0.25, f)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_UISV_scrollRectToVisible:r animated:NO]; }
                     completion:nil];
}

- (void)as_Nav_pushViewController:(UIViewController *)vc animated:(BOOL)an {
    if (!an || !gEnabled) { [self as_Nav_pushViewController:vc animated:an]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleVC(0.35, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_Nav_pushViewController:vc animated:NO]; }
                     completion:nil];
}

- (UIViewController *)as_Nav_popViewControllerAnimated:(BOOL)an {
    if (!an || !gEnabled) return [self as_Nav_popViewControllerAnimated:an];
    double f = _effectiveFactor();
    __block UIViewController *result = nil;
    [UIView animateWithDuration:_scaleVC(0.35, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ result = [self as_Nav_popViewControllerAnimated:NO]; }
                     completion:nil];
    return result;
}

- (NSArray<UIViewController *> *)as_Nav_popToViewController:(UIViewController *)vc animated:(BOOL)an {
    if (!an || !gEnabled) return [self as_Nav_popToViewController:vc animated:an];
    double f = _effectiveFactor();
    __block NSArray *result = nil;
    [UIView animateWithDuration:_scaleVC(0.35, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ result = [self as_Nav_popToViewController:vc animated:NO]; }
                     completion:nil];
    return result;
}

- (NSArray<UIViewController *> *)as_Nav_popToRootViewControllerAnimated:(BOOL)an {
    if (!an || !gEnabled) return [self as_Nav_popToRootViewControllerAnimated:an];
    double f = _effectiveFactor();
    __block NSArray *result = nil;
    [UIView animateWithDuration:_scaleVC(0.35, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ result = [self as_Nav_popToRootViewControllerAnimated:NO]; }
                     completion:nil];
    return result;
}

- (void)as_Tab_setSelectedIndex:(NSUInteger)idx {
    if (!gEnabled) { [self as_Tab_setSelectedIndex:idx]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleVC(0.25, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_Tab_setSelectedIndex:idx]; }
                     completion:nil];
}

- (void)as_VC_presentViewController:(UIViewController *)vc
                           animated:(BOOL)an
                         completion:(void (^)(void))c {
    if (!an || !gEnabled) { [self as_VC_presentViewController:vc animated:an completion:c]; return; }
    double f = _effectiveFactor();
    NSTimeInterval d = _scaleVC(0.30, f, _presentMinMs());
    [self as_VC_presentViewController:vc animated:NO completion:c];
    if (c) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), c);
    }
}

- (void)as_VC_dismissViewControllerAnimated:(BOOL)an completion:(void (^)(void))c {
    if (!an || !gEnabled) { [self as_VC_dismissViewControllerAnimated:an completion:c]; return; }
    double f = _effectiveFactor();
    NSTimeInterval d = _scaleVC(0.30, f, _presentMinMs());
    [self as_VC_dismissViewControllerAnimated:NO completion:c];
    if (c) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), c);
    }
}

+ (void)as_CATrans_setDuration:(CFTimeInterval)d {
    double f = _effectiveFactor();
    [self as_CATrans_setDuration:_scaleVC(d, f, _caMinMs())];
}

// ---------- 增强层（ExtraAcceleration，默认开；黑名单 App 不装） ----------
// 1) UIView 关键帧动画
+ (void)as_UIView_animateKeyframesWithDuration:(NSTimeInterval)d
                                         delay:(NSTimeInterval)dl
                                       options:(UIViewKeyframeAnimationOptions)o
                                    animations:(void (^)(void))a
                                    completion:(void (^)(BOOL))c {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    [self as_UIView_animateKeyframesWithDuration:_scaleInterval(d, f)
                                           delay:dl * f
                                         options:o
                                      animations:a
                                      completion:c];
}

// 2) 老式 begin/commit 动画 API 的时长
+ (void)as_UIView_setAnimationDuration:(NSTimeInterval)d {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    [self as_UIView_setAnimationDuration:_scaleInterval(d, f)];
}

// 3) CAAnimation 基类时长（覆盖 CABasic/CAKeyframe/CASpring/CATransition 等全部子类）
// v1.5.1 修复：只 hook 基类。此前同时 hook 子类 setDuration:，但子类未重写该方法（继承基类），
// 二次 method_exchangeImplementations 造成"原方法↔替换方法"互相指向形成无限递归 → 栈溢出闪退。
- (void)as_CAAnimation_setDuration:(CFTimeInterval)d {
    if (!_extraOn()) { [self as_CAAnimation_setDuration:d]; return; }
    double f = _effectiveFactor();
    [self as_CAAnimation_setDuration:_scaleVC(d, f, 10)];
}

// ---------- 增强层·UIWindow 动画时长 ----------
+ (void)as_UIWindow_setAnimationDuration:(NSTimeInterval)d {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    [self as_UIWindow_setAnimationDuration:_scaleInterval(d, f)];
}

// v1.5.1：移除 CABasic/CAKeyframe/CASpring/CATransition 子类的 setDuration: hook（防递归闪退，基类已覆盖）。

// ---------- 增强层·CALayer addAnimation:forKey: (转轮/CABasic/Keyframe/Spring 都走这里) ----------
- (void)as_CALayer_addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (!_extraOn() || !anim) { [self as_CALayer_addAnimation:anim forKey:key]; return; }
    // 跳过毛玻璃/模糊层，避免蒙版卡死（黑名单 App 本就不装，这里双保险）
    NSString *cn = NSStringFromClass([self class]).lowercaseString ?: @"";
    if ([cn containsString:@"backdrop"] || [cn containsString:@"visualeffect"] ||
        [cn containsString:@"blur"] || [cn containsString:@"gaussian"] ||
        [cn containsString:@"snapshot"]) {
        [self as_CALayer_addAnimation:anim forKey:key]; return;
    }
    @try {
        // 仅收窄"未被 setDuration: hook 处理过的默认时长"(0.25s)动画，避免对已缩放时长二次缩放
        if (anim.duration > 0.03 && anim.duration < 60.0) {
            anim.duration = _scaleVC(anim.duration, _effectiveFactor(), _caMinMs());
        }
        // 保留 repeatCount：转轮动画是 HUGE_VALF（无限循环），缩小时不变周期仍能转但超快
    } @catch (__unused NSException *e) {}
    [self as_CALayer_addAnimation:anim forKey:key];
}

// ---------- 增强层·Interactive Transition ----------
- (void)as_UIPDIT_updateInteractiveTransition:(double)pct {
    // 交互式转场进度更新：直接传，不做延迟
    [self as_UIPDIT_updateInteractiveTransition:pct];
}

- (void)as_UIPDIT_cancelInteractiveTransition {
    [self as_UIPDIT_cancelInteractiveTransition];
}

- (void)as_UIPDIT_finishInteractiveTransition {
    [self as_UIPDIT_finishInteractiveTransition];
}

// ---------- 增强层·UIPresentationController（弹窗蒙版） ----------
- (void)as_UIPrC_containerViewWillLayoutSubviews {
    [self as_UIPrC_containerViewWillLayoutSubviews];
}

// ---------- 增强层·UIScrollView 减速参数（滚动手势松开后） ----------
- (void)as_UISV_decelerate {
    [self as_UISV_decelerate];
}

// ---------- 增强层·UIContextMenuInteraction ----------
- (void)as_UICMUI_presentMenuAtLocation:(CGPoint)loc inView:(UIView *)vw {
    if (!gEnabled) { [self as_UICMUI_presentMenuAtLocation:loc inView:vw]; return; }
    double f = _effectiveFactor();
    NSTimeInterval d = _scaleInterval(0.25, f);
    [self as_UICMUI_presentMenuAtLocation:loc inView:vw];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // menu appears nearly instantly
    });
}

// 4) UIViewPropertyAnimator 延迟因子
- (void)as_UIPA_addAnimations:(void (^)(void))a delayFactor:(CGFloat)df {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    CGFloat nd = (f >= 1.0) ? df : (df * f);
    [self as_UIPA_addAnimations:a delayFactor:nd];
}

// 5) UITableView 列表动画（用 CATransaction 收窄时长）
- (void)as_TV_performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))c {
    if (!_extraOn()) { [self as_TV_performBatchUpdates:updates completion:c]; return; }
    double f = _effectiveFactor();
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, f)];
    @try { [self as_TV_performBatchUpdates:updates completion:c]; }
    @finally { [CATransaction commit]; }
}

- (void)as_TV_insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)ip withRowAnimation:(UITableViewRowAnimation)an {
    if (!_extraOn()) { [self as_TV_insertRowsAtIndexPaths:ip withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_TV_insertRowsAtIndexPaths:ip withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}

- (void)as_TV_deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)ip withRowAnimation:(UITableViewRowAnimation)an {
    if (!_extraOn()) { [self as_TV_deleteRowsAtIndexPaths:ip withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_TV_deleteRowsAtIndexPaths:ip withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}

- (void)as_TV_reloadRowsAtIndexPaths:(NSArray<NSIndexPath *> *)ip withRowAnimation:(UITableViewRowAnimation)an {
    if (!_extraOn()) { [self as_TV_reloadRowsAtIndexPaths:ip withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_TV_reloadRowsAtIndexPaths:ip withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}

// 6) UICollectionView 列表动画
- (void)as_CV_performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))c {
    if (!_extraOn()) { [self as_CV_performBatchUpdates:updates completion:c]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_CV_performBatchUpdates:updates completion:c]; }
    @finally { [CATransaction commit]; }
}

- (void)as_CV_insertItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ip {
    if (!_extraOn()) { [self as_CV_insertItemsAtIndexPaths:ip]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_CV_insertItemsAtIndexPaths:ip]; }
    @finally { [CATransaction commit]; }
}

- (void)as_CV_deleteItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ip {
    if (!_extraOn()) { [self as_CV_deleteItemsAtIndexPaths:ip]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_CV_deleteItemsAtIndexPaths:ip]; }
    @finally { [CATransaction commit]; }
}

- (void)as_CV_reloadItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ip {
    if (!_extraOn()) { [self as_CV_reloadItemsAtIndexPaths:ip]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_CV_reloadItemsAtIndexPaths:ip]; }
    @finally { [CATransaction commit]; }
}

#pragma mark - v1.5 增强层（23 个新 hook）

// ---------- UIView：系统动画（如行删除），用 CATransaction 收窄时长 ----------
+ (void)as_UIView_performSysAnim:(UISystemAnimation)sa
                         onViews:(NSArray<UIView *> *)views
                         options:(UIViewAnimationOptions)opts
                      animations:(void (^)(void))a
                      completion:(void (^)(BOOL))c {
    if (!_extraOn()) {
        [self as_UIView_performSysAnim:sa onViews:views options:opts animations:a completion:c];
        return;
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.30, _effectiveFactor())];
    @try { [self as_UIView_performSysAnim:sa onViews:views options:opts animations:a completion:c]; }
    @finally { [CATransaction commit]; }
}

// ---------- UIView：老式 beginAnimations 上下文的延迟 ----------
+ (void)as_UIView_setAnimationDelay:(NSTimeInterval)d {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    [self as_UIView_setAnimationDelay:(f >= 1.0 ? d : d * f)];
}

// ---------- UIViewPropertyAnimator：贝塞尔曲线初始化 ----------
- (instancetype)as_UIPA_initDuration:(NSTimeInterval)d
                        controlPoint1:(CGPoint)p1
                        controlPoint2:(CGPoint)p2
                           animations:(void (^)(void))a {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    return [self as_UIPA_initDuration:_scaleInterval(d, f) controlPoint1:p1 controlPoint2:p2 animations:a];
}

// ---------- UIViewPropertyAnimator：类方法一次性运行动画器 ----------
+ (instancetype)as_UIPA_runningAnimatorWithDuration:(NSTimeInterval)d
                                              delay:(NSTimeInterval)dl
                                            options:(UIViewAnimationOptions)o
                                         animations:(void (^)(void))a
                                         completion:(void (^)(UIViewAnimatingPosition))c {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    return [self as_UIPA_runningAnimatorWithDuration:_scaleInterval(d, f)
                                               delay:(f >= 1.0 ? dl : dl * f)
                                             options:o
                                          animations:a
                                          completion:c];
}

// ---------- UIViewPropertyAnimator：延迟启动 ----------
- (void)as_UIPA_startAnimationAfterDelay:(NSTimeInterval)d {
    double f = _extraOn() ? _effectiveFactor() : 1.0;
    [self as_UIPA_startAnimationAfterDelay:(f >= 1.0 ? d : d * f)];
}

// ==================== v1.5.6 恢复 Hook（tongyong 分支在当前微信实测安全） ====================

// Nav 整栈替换
- (void)as_Nav_setViewControllers:(NSArray<UIViewController *> *)vcs animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_Nav_setViewControllers:vcs animated:an]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleVC(0.35, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_Nav_setViewControllers:vcs animated:NO]; }
                     completion:nil];
}

// Tab 直选 VC
- (void)as_Tab_setSelectedViewController:(UIViewController *)vc {
    if (!gEnabled || !_extraOn()) { [self as_Tab_setSelectedViewController:vc]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleVC(0.25, f, _pageMinMs())
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_Tab_setSelectedViewController:vc]; }
                     completion:nil];
}

// PageVC 翻页
- (void)as_PageVC_setViewControllers:(NSArray<UIViewController *> *)vcs
                           direction:(UIPageViewControllerNavigationDirection)dir
                            animated:(BOOL)an
                          completion:(void (^)(BOOL))c {
    if (!an || !gEnabled || !_extraOn()) { [self as_PageVC_setViewControllers:vcs direction:dir animated:an completion:c]; return; }
    [self as_PageVC_setViewControllers:vcs direction:dir animated:NO completion:c];
}

// UIScrollView 缩放
- (void)as_UISV_setZoomScale:(CGFloat)zs animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_UISV_setZoomScale:zs animated:an]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleInterval(0.25, f)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_UISV_setZoomScale:zs animated:NO]; }
                     completion:nil];
}

- (void)as_UISV_zoomToRect:(CGRect)r animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_UISV_zoomToRect:r animated:an]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleInterval(0.25, f)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_UISV_zoomToRect:r animated:NO]; }
                     completion:nil];
}

// UITableView 编辑 / 重载段 / 选中 / 取消选中
- (void)as_TV_setEditing:(BOOL)ed animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_TV_setEditing:ed animated:an]; return; }
    [self as_TV_setEditing:ed animated:NO];
}

- (void)as_TV_reloadSections:(NSIndexSet *)sec withRowAnimation:(UITableViewRowAnimation)an {
    if (!gEnabled || !_extraOn()) { [self as_TV_reloadSections:sec withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scaleInterval(0.25, _effectiveFactor())];
    @try { [self as_TV_reloadSections:sec withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}

- (void)as_TV_selectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)an scrollPosition:(UITableViewScrollPosition)sp {
    if (!an || !gEnabled || !_extraOn()) { [self as_TV_selectRowAtIndexPath:ip animated:an scrollPosition:sp]; return; }
    [self as_TV_selectRowAtIndexPath:ip animated:NO scrollPosition:sp];
}

- (void)as_TV_deselectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_TV_deselectRowAtIndexPath:ip animated:an]; return; }
    [self as_TV_deselectRowAtIndexPath:ip animated:NO];
}

// CollectionView 布局切换（两个重载）
- (void)as_CV_setLayout:(UICollectionViewLayout *)nl animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_CV_setLayout:nl animated:an]; return; }
    [self as_CV_setLayout:nl animated:NO];
}

- (void)as_CV_setLayout:(UICollectionViewLayout *)nl animated:(BOOL)an completion:(void (^)(BOOL))c {
    if (!an || !gEnabled || !_extraOn()) { [self as_CV_setLayout:nl animated:an completion:c]; return; }
    [self as_CV_setLayout:nl animated:NO completion:c];
}

// 三类栏 setItems
- (void)as_NavBar_setItems:(NSArray<UINavigationItem *> *)items animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_NavBar_setItems:items animated:an]; return; }
    [self as_NavBar_setItems:items animated:NO];
}

- (void)as_TabBar_setItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_TabBar_setItems:items animated:an]; return; }
    [self as_TabBar_setItems:items animated:NO];
}

- (void)as_Toolbar_setItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_Toolbar_setItems:items animated:an]; return; }
    [self as_Toolbar_setItems:items animated:NO];
}

// 控件：进度 / 开关 / 滑杆
- (void)as_Progress_setProgress:(float)p animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_Progress_setProgress:p animated:an]; return; }
    [self as_Progress_setProgress:p animated:NO];
}

- (void)as_Switch_setOn:(BOOL)on animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_Switch_setOn:on animated:an]; return; }
    [self as_Switch_setOn:on animated:NO];
}

- (void)as_Slider_setValue:(float)v animated:(BOOL)an {
    if (!an || !gEnabled || !_extraOn()) { [self as_Slider_setValue:v animated:an]; return; }
    [self as_Slider_setValue:v animated:NO];
}

// ==================== v1.5.6 新技术（源自 AnimationSpeedTweak v3.5 实测样本） ====================

// CALayer 隐式动画动作：极速/瞬切档对常用隐式 key 返回 nil（无 action = 瞬时到位，正规返回值）
- (id)as_CALayer_actionForKey:(NSString *)key {
    if (gEnabled && _extraOn() && _effectiveFactor() <= 0.01) {
        NSString *k = key.lowercaseString ?: @"";
        if ([k isEqualToString:@"position"] || [k isEqualToString:@"bounds"] ||
            [k isEqualToString:@"frame"] || [k isEqualToString:@"opacity"] ||
            [k isEqualToString:@"contents"] || [k isEqualToString:@"contentsrect"] ||
            [k isEqualToString:@"backgroundcolor"] || [k isEqualToString:@"cornerradius"] ||
            [k isEqualToString:@"hidden"] || [k isEqualToString:@"sublayers"]) {
            return nil;
        }
    }
    return [self as_CALayer_actionForKey:key];
}

// CAPropertyAnimation 二级链（安装时校验 Method 与基类不同，防重复链）
- (void)as_CAProp_setDuration:(CFTimeInterval)d {
    if (!_extraOn()) { [self as_CAProp_setDuration:d]; return; }
    [self as_CAProp_setDuration:_scaleVC(d, _effectiveFactor(), 10)];
}

// v1.5.5 移除的 transitionFromViewController hook（deprecated API，状态机最重）不再恢复。

@end

__attribute__((constructor))
static void _si_install(void) {
    @autoreleasepool {
        _loadPref();
        double f = _effectiveFactor();
        NSLog(@"[SpeedIntensifier] factor=%.4f enabled=%d instant=%d extra=%d blacklisted=%d bundle=%@",
              f, gEnabled, gInstantMode, gExtra, gBlacklisted, [[NSBundle mainBundle] bundleIdentifier]);

        int ok = 0, total = 0;

        Class UIView_cls = [UIView class];
        total += 6;
        ok += _swizzleClass(UIView_cls, @selector(animateWithDuration:animations:),
                            @selector(as_UIView_animate:animations:));
        ok += _swizzleClass(UIView_cls, @selector(animateWithDuration:animations:completion:),
                            @selector(as_UIView_animate:animations:completion:));
        ok += _swizzleClass(UIView_cls, @selector(animateWithDuration:delay:options:animations:completion:),
                            @selector(as_UIView_animate:delay:options:animations:completion:));
        ok += _swizzleClass(UIView_cls, @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                            @selector(as_UIView_animate:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:));
        ok += _swizzleClass(UIView_cls, @selector(transitionWithView:duration:options:animations:completion:),
                            @selector(as_UIView_transitionWithView:duration:options:animations:completion:));
        ok += _swizzleClass(UIView_cls, @selector(transitionFromView:toView:duration:options:completion:),
                            @selector(as_UIView_transitionFromView:toView:duration:options:completion:));

        Class UIPA_cls = [UIViewPropertyAnimator class];
        total += 3;
        ok += _swizzleInstance(UIPA_cls, @selector(initWithDuration:timingParameters:),
                               @selector(as_UIPA_initDuration:timingParameters:));
        ok += _swizzleInstance(UIPA_cls, @selector(initWithDuration:dampingRatio:animations:),
                               @selector(as_UIPA_initDuration:dampingRatio:animations:));
        ok += _swizzleInstance(UIPA_cls, @selector(setDuration:),
                               @selector(as_UIPA_setDuration:));

        Class UISV_cls = [UIScrollView class];
        total += 2;
        ok += _swizzleInstance(UISV_cls, @selector(setContentOffset:animated:),
                               @selector(as_UISV_setContentOffset:animated:));
        ok += _swizzleInstance(UISV_cls, @selector(scrollRectToVisible:animated:),
                               @selector(as_UISV_scrollRectToVisible:animated:));

        Class Nav_cls = [UINavigationController class];
        total += 4;
        ok += _swizzleInstance(Nav_cls, @selector(pushViewController:animated:),
                               @selector(as_Nav_pushViewController:animated:));
        ok += _swizzleInstance(Nav_cls, @selector(popViewControllerAnimated:),
                               @selector(as_Nav_popViewControllerAnimated:));
        ok += _swizzleInstance(Nav_cls, @selector(popToViewController:animated:),
                               @selector(as_Nav_popToViewController:animated:));
        ok += _swizzleInstance(Nav_cls, @selector(popToRootViewControllerAnimated:),
                               @selector(as_Nav_popToRootViewControllerAnimated:));

        Class Tab_cls = [UITabBarController class];
        total += 1;
        ok += _swizzleInstance(Tab_cls, @selector(setSelectedIndex:),
                               @selector(as_Tab_setSelectedIndex:));

        Class VC_cls = [UIViewController class];
        total += 2;
        ok += _swizzleInstance(VC_cls, @selector(presentViewController:animated:completion:),
                               @selector(as_VC_presentViewController:animated:completion:));
        ok += _swizzleInstance(VC_cls, @selector(dismissViewControllerAnimated:completion:),
                               @selector(as_VC_dismissViewControllerAnimated:completion:));

        total += 1;
        ok += _swizzleClass([CATransaction class], @selector(setAnimationDuration:),
                            @selector(as_CATrans_setDuration:));

        // ---------- 增强层（ExtraAcceleration） ----------
        if (_extraOn()) {
            int eok = 0, etotal = 0;

            etotal += 1;
            eok += _swizzleClass(UIView_cls, @selector(animateKeyframesWithDuration:delay:options:animations:completion:),
                                 @selector(as_UIView_animateKeyframesWithDuration:delay:options:animations:completion:));
            etotal += 1;
            eok += _swizzleClass(UIView_cls, @selector(setAnimationDuration:),
                                 @selector(as_UIView_setAnimationDuration:));

            etotal += 1;
            eok += _swizzleInstance([CAAnimation class], @selector(setDuration:),
                                    @selector(as_CAAnimation_setDuration:));

            etotal += 1;
            eok += _swizzleInstance(UIPA_cls, @selector(addAnimations:delayFactor:),
                                    @selector(as_UIPA_addAnimations:delayFactor:));

            Class TV_cls = [UITableView class];
            etotal += 4;
            eok += _swizzleInstance(TV_cls, @selector(performBatchUpdates:completion:),
                                    @selector(as_TV_performBatchUpdates:completion:));
            eok += _swizzleInstance(TV_cls, @selector(insertRowsAtIndexPaths:withRowAnimation:),
                                    @selector(as_TV_insertRowsAtIndexPaths:withRowAnimation:));
            eok += _swizzleInstance(TV_cls, @selector(deleteRowsAtIndexPaths:withRowAnimation:),
                                    @selector(as_TV_deleteRowsAtIndexPaths:withRowAnimation:));
            eok += _swizzleInstance(TV_cls, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                                    @selector(as_TV_reloadRowsAtIndexPaths:withRowAnimation:));

            Class CV_cls = [UICollectionView class];
            etotal += 4;
            eok += _swizzleInstance(CV_cls, @selector(performBatchUpdates:completion:),
                                    @selector(as_CV_performBatchUpdates:completion:));
            eok += _swizzleInstance(CV_cls, @selector(insertItemsAtIndexPaths:),
                                    @selector(as_CV_insertItemsAtIndexPaths:));
            eok += _swizzleInstance(CV_cls, @selector(deleteItemsAtIndexPaths:),
                                    @selector(as_CV_deleteItemsAtIndexPaths:));
            eok += _swizzleInstance(CV_cls, @selector(reloadItemsAtIndexPaths:),
                                    @selector(as_CV_reloadItemsAtIndexPaths:));

            // ---------- 新增强层：UIWindow ----------
            Class Win_cls = [UIWindow class];
            etotal += 1;
            eok += _swizzleClass(Win_cls, @selector(setAnimationDuration:),
                                 @selector(as_UIWindow_setAnimationDuration:));

            // v1.5.1：不再 hook CABasic/CAKeyframe/CASpring/CATransition 的 setDuration:
            //（子类继承基类实现，重复交换导致无限递归闪退；基类 hook 已覆盖全部子类）

            // ---------- 新增强层：Interactive Transition ----------
            Class ITT_cls = [UIPercentDrivenInteractiveTransition class];
            etotal += 3;
            eok += _swizzleInstance(ITT_cls, @selector(updateInteractiveTransition:),
                                    @selector(as_UIPDIT_updateInteractiveTransition:));
            eok += _swizzleInstance(ITT_cls, @selector(cancelInteractiveTransition),
                                    @selector(as_UIPDIT_cancelInteractiveTransition));
            eok += _swizzleInstance(ITT_cls, @selector(finishInteractiveTransition),
                                    @selector(as_UIPDIT_finishInteractiveTransition));

            // ---------- 新增强层：UIPresentationController ----------
            Class PrC_cls = [UIPresentationController class];
            etotal += 1;
            eok += _swizzleInstance(PrC_cls, @selector(containerViewWillLayoutSubviews),
                                    @selector(as_UIPrC_containerViewWillLayoutSubviews));

            // ---------- 新增强层：UIContextMenu ----------
            Class CM_cls = [UIContextMenuInteraction class];
            etotal += 1;
            eok += _swizzleInstance(CM_cls, @selector(presentMenuAtLocation:inView:),
                                    @selector(as_UICMUI_presentMenuAtLocation:inView:));

            // ---------- v1.4 新增强层：CALayer addAnimation:forKey:（转轮/CABasic/Keyframe/Spring 等显式动画） ----------
            etotal += 1;
            eok += _swizzleInstance([CALayer class], @selector(addAnimation:forKey:),
                                    @selector(as_CALayer_addAnimation:forKey:));

            // ==================== v1.5 新增 23 hook ====================
            // --- UIView：系统动画 / 老式动画延迟 ---
            etotal += 1;
            eok += _swizzleClass(UIView_cls, @selector(performSystemAnimation:onViews:options:animations:completion:),
                                 @selector(as_UIView_performSysAnim:onViews:options:animations:completion:));
            etotal += 1;
            eok += _swizzleClass(UIView_cls, @selector(setAnimationDelay:),
                                 @selector(as_UIView_setAnimationDelay:));

            // --- UIViewPropertyAnimator：贝塞尔初始化 / 一次性类方法 / 延迟启动 ---
            etotal += 1;
            eok += _swizzleInstance(UIPA_cls, @selector(initWithDuration:controlPoint1:controlPoint2:animations:),
                                    @selector(as_UIPA_initDuration:controlPoint1:controlPoint2:animations:));
            etotal += 1;
            eok += _swizzleClass(UIPA_cls, @selector(runningPropertyAnimatorWithDuration:delay:options:animations:completion:),
                                 @selector(as_UIPA_runningAnimatorWithDuration:delay:options:animations:completion:));
            etotal += 1;
            eok += _swizzleInstance(UIPA_cls, @selector(startAnimationAfterDelay:),
                                    @selector(as_UIPA_startAnimationAfterDelay:));

            // ==================== v1.5.6 恢复 + 新增 19 hook ====================
            Class PageVC_cls = [UIPageViewController class];

            // --- 导航/Tab/翻页 ---
            etotal += 1;
            eok += _swizzleInstance(Nav_cls, @selector(setViewControllers:animated:),
                                    @selector(as_Nav_setViewControllers:animated:));
            etotal += 1;
            eok += _swizzleInstance(Tab_cls, @selector(setSelectedViewController:),
                                    @selector(as_Tab_setSelectedViewController:));
            etotal += 1;
            eok += _swizzleInstance(PageVC_cls, @selector(setViewControllers:direction:animated:completion:),
                                    @selector(as_PageVC_setViewControllers:direction:animated:completion:));

            // --- UIScrollView 缩放 ---
            etotal += 2;
            eok += _swizzleInstance(UISV_cls, @selector(setZoomScale:animated:),
                                    @selector(as_UISV_setZoomScale:animated:));
            eok += _swizzleInstance(UISV_cls, @selector(zoomToRect:animated:),
                                    @selector(as_UISV_zoomToRect:animated:));

            // --- UITableView 编辑/选中/重载 ---
            etotal += 4;
            eok += _swizzleInstance(TV_cls, @selector(setEditing:animated:),
                                    @selector(as_TV_setEditing:animated:));
            eok += _swizzleInstance(TV_cls, @selector(reloadSections:withRowAnimation:),
                                    @selector(as_TV_reloadSections:withRowAnimation:));
            eok += _swizzleInstance(TV_cls, @selector(selectRowAtIndexPath:animated:scrollPosition:),
                                    @selector(as_TV_selectRowAtIndexPath:animated:scrollPosition:));
            eok += _swizzleInstance(TV_cls, @selector(deselectRowAtIndexPath:animated:),
                                    @selector(as_TV_deselectRowAtIndexPath:animated:));

            // --- CollectionView 布局切换 ---
            Class CVL_cls = [UICollectionView class];
            etotal += 2;
            eok += _swizzleInstance(CVL_cls, @selector(setCollectionViewLayout:animated:),
                                    @selector(as_CV_setLayout:animated:));
            eok += _swizzleInstance(CVL_cls, @selector(setCollectionViewLayout:animated:completion:),
                                    @selector(as_CV_setLayout:animated:completion:));

            // --- 三类栏 setItems ---
            etotal += 3;
            eok += _swizzleInstance([UINavigationBar class], @selector(setItems:animated:),
                                    @selector(as_NavBar_setItems:animated:));
            eok += _swizzleInstance([UITabBar class], @selector(setItems:animated:),
                                    @selector(as_TabBar_setItems:animated:));
            eok += _swizzleInstance([UIToolbar class], @selector(setItems:animated:),
                                    @selector(as_Toolbar_setItems:animated:));

            // --- 控件 ---
            etotal += 3;
            eok += _swizzleInstance([UIProgressView class], @selector(setProgress:animated:),
                                    @selector(as_Progress_setProgress:animated:));
            eok += _swizzleInstance([UISwitch class], @selector(setOn:animated:),
                                    @selector(as_Switch_setOn:animated:));
            eok += _swizzleInstance([UISlider class], @selector(setValue:animated:),
                                    @selector(as_Slider_setValue:animated:));

            // --- AnimationSpeedTweak v3.5 同款新技术 ---
            etotal += 1;
            eok += _swizzleInstance([CALayer class], @selector(actionForKey:),
                                    @selector(as_CALayer_actionForKey:));
            // CAPropertyAnimation 二级链：仅当其 setDuration: Method 与基类不同才装（防重复链）
            Method baseSetDurM = class_getInstanceMethod([CAAnimation class], @selector(setDuration:));
            Method propSetDurM = class_getInstanceMethod([CAPropertyAnimation class], @selector(setDuration:));
            if (propSetDurM && baseSetDurM != propSetDurM) {
                etotal += 1;
                eok += _swizzleInstance([CAPropertyAnimation class], @selector(setDuration:),
                                        @selector(as_CAProp_setDuration:));
            }

            total += etotal;
            ok += eok;
            NSLog(@"[SpeedIntensifier] extra hooks %d/%d (ExtraAcceleration=ON)", eok, etotal);
        } else {
            NSLog(@"[SpeedIntensifier] extra hooks skipped (extra=%d blacklisted=%d)", gExtra, gBlacklisted);
        }

        NSLog(@"[SpeedIntensifier] installed %d/%d hooks", ok, total);
    }
}
