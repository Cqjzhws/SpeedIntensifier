// SpeedIntensifier — 可注入动画加速 Tweak（纯 ObjC runtime，无 substrate）
// 默认最快档 0.001；可通过配置文件覆盖，TrollFools / 注入任意 App 生效。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ================================
// 全局配置（默认最快 0.001）
// ================================
static double gFactor = 0.001;
static BOOL   gEnabled = YES;
static BOOL   gInstantMode = NO;

#define kPrefPath "/var/Managed Preferences/mobile/com.local.speedintensifier.plist"

static void _loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@kPrefPath];
        if (d) {
            NSNumber *f = d[@"SpeedFactor"];
            NSNumber *e = d[@"Enabled"];
            if (f) gFactor = [f doubleValue];
            if (e) gEnabled = [e boolValue];
        }
    } @catch (__unused NSException *ex) { }
    if (gFactor <= 0.0) gFactor = 0.001;    // 保底最快
    if (gFactor > 1.0)  gFactor = 1.0;
}

// ================================
// 核心加速逻辑
// ================================
static double _effectiveFactor(void) {
    if (!gEnabled) return 1.0;   // 关闭 => 原速
    if (gInstantMode) return 0.0;
    return gFactor;
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
    [UIView animateWithDuration:_scaleVC(0.35, f, 50)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self as_Nav_pushViewController:vc animated:NO]; }
                     completion:nil];
}

- (UIViewController *)as_Nav_popViewControllerAnimated:(BOOL)an {
    if (!an || !gEnabled) return [self as_Nav_popViewControllerAnimated:an];
    double f = _effectiveFactor();
    __block UIViewController *result = nil;
    [UIView animateWithDuration:_scaleVC(0.35, f, 50)
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
    [UIView animateWithDuration:_scaleVC(0.35, f, 50)
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
    [UIView animateWithDuration:_scaleVC(0.35, f, 50)
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ result = [self as_Nav_popToRootViewControllerAnimated:NO]; }
                     completion:nil];
    return result;
}

- (void)as_Tab_setSelectedIndex:(NSUInteger)idx {
    if (!gEnabled) { [self as_Tab_setSelectedIndex:idx]; return; }
    double f = _effectiveFactor();
    [UIView animateWithDuration:_scaleVC(0.25, f, 50)
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
    NSTimeInterval d = _scaleVC(0.30, f, 100);
    [self as_VC_presentViewController:vc animated:NO completion:c];
    if (c) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), c);
    }
}

- (void)as_VC_dismissViewControllerAnimated:(BOOL)an completion:(void (^)(void))c {
    if (!an || !gEnabled) { [self as_VC_dismissViewControllerAnimated:an completion:c]; return; }
    double f = _effectiveFactor();
    NSTimeInterval d = _scaleVC(0.30, f, 100);
    [self as_VC_dismissViewControllerAnimated:NO completion:c];
    if (c) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), c);
    }
}

+ (void)as_CATrans_setDuration:(CFTimeInterval)d {
    double f = _effectiveFactor();
    [self as_CATrans_setDuration:_scaleVC(d, f, 16)];
}

+ (void)as_CAProp_setDuration:(CFTimeInterval)d {
    double f = _effectiveFactor();
    [self as_CAProp_setDuration:_scaleVC(d, f, 16)];
}

@end

__attribute__((constructor))
static void _si_install(void) {
    @autoreleasepool {
        _loadPref();
        double f = _effectiveFactor();
        NSLog(@"[SpeedIntensifier] factor=%.4f enabled=%d instant=%d", f, gEnabled, gInstantMode);

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

        total += 2;
        ok += _swizzleClass([CATransaction class], @selector(setAnimationDuration:),
                            @selector(as_CATrans_setDuration:));
        ok += _swizzleClass([CAPropertyAnimation class], @selector(setDuration:),
                            @selector(as_CAProp_setDuration:));

        NSLog(@"[SpeedIntensifier] installed %d/%d hooks", ok, total);
    }
}
