// SpeedIntensifier v1.3 — 可注入动画加速 Tweak（纯 ObjC runtime，无 substrate）
// 默认最快档 0.001；基础 20 hook；ExtraAcceleration（默认 YES）叠加 12 个增强 hook；
// 新增：UIWindow/CAAnimation子类/InteractiveTransition 加速 + 更低保底门槛（nav 30ms / tab 20ms / present 50ms / CA 10ms）。
// 黑名单 App（默认微信/企业微信）只走基础 hook，避免毛玻璃等不兼容问题。
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
#define kDefaultBlacklist @[ @"com.tencent.xin", @"com.tencent.wework" ]

static void _loadPref(void) {
    NSDictionary *d = nil;
    @try {
        d = [NSDictionary dictionaryWithContentsOfFile:@kPrefPath];
        if (d) {
            NSNumber *f = d[@"SpeedFactor"];
            NSNumber *e = d[@"Enabled"];
            NSNumber *x = d[@"ExtraAcceleration"];
            if (f) gFactor = [f doubleValue];
            if (e) gEnabled = [e boolValue];
            if (x) gExtra = [x boolValue];
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
    [UIView animateWithDuration:_scaleVC(0.35, f, 30)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_Nav_pushViewController:vc animated:NO]; }
                     completion:nil];
}

- (UIViewController *)as_Nav_popViewControllerAnimated:(BOOL)an {
    if (!an || !gEnabled) return [self as_Nav_popViewControllerAnimated:an];
    double f = _effectiveFactor();
    __block UIViewController *result = nil;
    [UIView animateWithDuration:_scaleVC(0.35, f, 30)
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
    [UIView animateWithDuration:_scaleVC(0.35, f, 30)
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
    [UIView animateWithDuration:_scaleVC(0.35, f, 30)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ result = [self as_Nav_popToRootViewControllerAnimated:NO]; }
                     completion:nil];
    return result;
}

- (void)as_Tab_setSelectedIndex:(NSUInteger)idx {
    if (!gEnabled) { [self as_Tab_setSelectedIndex:idx]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleVC(0.25, f, 20)
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
    NSTimeInterval d = _scaleVC(0.30, f, 50);
    [self as_VC_presentViewController:vc animated:NO completion:c];
    if (c) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), c);
    }
}

- (void)as_VC_dismissViewControllerAnimated:(BOOL)an completion:(void (^)(void))c {
    if (!an || !gEnabled) { [self as_VC_dismissViewControllerAnimated:an completion:c]; return; }
    double f = _effectiveFactor();
    NSTimeInterval d = _scaleVC(0.30, f, 50);
    [self as_VC_dismissViewControllerAnimated:NO completion:c];
    if (c) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), c);
    }
}

+ (void)as_CATrans_setDuration:(CFTimeInterval)d {
    double f = _effectiveFactor();
    [self as_CATrans_setDuration:_scaleVC(d, f, 16)];
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

// ---------- 增强层·CABasicAnimation ----------
- (void)as_CABasic_setDuration:(CFTimeInterval)d {
    if (!_extraOn()) { [self as_CABasic_setDuration:d]; return; }
    [self as_CABasic_setDuration:_scaleVC(d, _effectiveFactor(), 10)];
}

// ---------- 增强层·CAKeyframeAnimation ----------
- (void)as_CAKeyframe_setDuration:(CFTimeInterval)d {
    if (!_extraOn()) { [self as_CAKeyframe_setDuration:d]; return; }
    [self as_CAKeyframe_setDuration:_scaleVC(d, _effectiveFactor(), 10)];
}

// ---------- 增强层·CASpringAnimation ----------
- (void)as_CASpring_setDuration:(CFTimeInterval)d {
    if (!_extraOn()) { [self as_CASpring_setDuration:d]; return; }
    [self as_CASpring_setDuration:_scaleVC(d, _effectiveFactor(), 10)];
}

// ---------- 增强层·CATransition ----------
- (void)as_CATransition_setDuration:(CFTimeInterval)d {
    if (!_extraOn()) { [self as_CATransition_setDuration:d]; return; }
    [self as_CATransition_setDuration:_scaleVC(d, _effectiveFactor(), 10)];
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

            // ---------- 新增强层：CAAnimation 子类 ----------
            etotal += 1;
            eok += _swizzleInstance([CABasicAnimation class], @selector(setDuration:),
                                    @selector(as_CABasic_setDuration:));
            etotal += 1;
            eok += _swizzleInstance([CAKeyframeAnimation class], @selector(setDuration:),
                                    @selector(as_CAKeyframe_setDuration:));
            etotal += 1;
            eok += _swizzleInstance([CASpringAnimation class], @selector(setDuration:),
                                    @selector(as_CASpring_setDuration:));
            etotal += 1;
            eok += _swizzleInstance([CATransition class], @selector(setDuration:),
                                    @selector(as_CATransition_setDuration:));

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

            total += etotal;
            ok += eok;
            NSLog(@"[SpeedIntensifier] extra hooks %d/%d (ExtraAcceleration=ON)", eok, etotal);
        } else {
            NSLog(@"[SpeedIntensifier] extra hooks skipped (extra=%d blacklisted=%d)", gExtra, gBlacklisted);
        }

        NSLog(@"[SpeedIntensifier] installed %d/%d hooks", ok, total);
    }
}
