// AwemeFullScreen-Diag — 一次性诊断版（只上报，不隐藏任何东西）
// ============================================================================
// 目的：抖音 38.0.0 上我的全屏猜测全部失效。与其继续猜，不如让本体自己把
//       「真实的 VC 链、真实的 ivar 名、底部栏的真实类名」显示在屏幕上，
//       用户截图即可，我据此写死准确目标。
//
// 行为：
//   · 不 hook 任何方法，不隐藏任何视图，不改变抖音任何行为（零风险）。
//   · 在顶部叠一个自己的 UIWindow + UILabel（hitTest 返回 nil，不拦触摸）。
//   · 每秒刷新一次，报告：
//       1) bundle id
//       2) 当前 VC 链（presented / nav.top / tab.selected / children）
//       3) 链上每个 VC 的类名，以及名字里带 tab/bar/blur/progress/bottom 的 ivar
//       4) 屏幕底部区域（最后 200pt 内）所有可见视图的类名 + frame + 父视图类名
//   · 这是单独一个产物，别和正式的 AwemeFullScreen.dylib 同时注入。
// ============================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

// 触摸穿透：不能让这个诊断窗挡住抖音的操作
@interface AFSDWindow : UIWindow @end
@implementation AFSDWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

static AFSDWindow *gWin = nil;
static UILabel    *gLabel = nil;
static NSTimer    *gTimer = nil;

#pragma mark - 工具

static NSString *AFSD_clsName(id obj) {
    if (!obj) return @"(nil)";
    return [NSString stringWithUTF8String:class_getName(object_getClass(obj))] ?: @"?";
}

static UIWindowScene *AFSD_activeScene(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)sc;
        }
    }
    return nil;
}

// 名字里可能和"底栏/模糊/进度条底衬"有关的 ivar（这就是我要的真相）
static NSString *AFSD_ivarsOf(id obj, int maxN) {
    Class c = object_getClass(obj);
    if (!c) return @"";
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(c, &n);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n && (int)hits.count < maxN; i++) {
        const char *nm = ivar_getName(ivars[i]);
        if (!nm) continue;
        if (strstr(nm, "tab") || strstr(nm, "Tab") || strstr(nm, "bar") || strstr(nm, "Bar") ||
            strstr(nm, "blur")|| strstr(nm, "Blur")|| strstr(nm, "progress") ||
            strstr(nm, "bottom") || strstr(nm, "Bottom") || strstr(nm, "Tool")) {
            id v = nil;
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (t && t[0] == '@') { @try { v = object_getIvar(obj, ivars[i]); } @catch (...) {} }
            [hits addObject:[NSString stringWithFormat:@"%s=%@", nm, AFSD_clsName(v)]];
        }
    }
    if (ivars) free(ivars);
    return [hits componentsJoinedByString:@","];
}

// VC 链（presented / nav.top / tab.selected / children）
static NSArray *AFSD_vcChain(void) {
    UIWindowScene *ws = AFSD_activeScene();
    UIViewController *vc = nil;
    for (UIWindow *w in ws.windows) { if (w.isKeyWindow && w.rootViewController) { vc = w.rootViewController; break; } }
    if (!vc) for (UIWindow *w in ws.windows) { if (w.rootViewController) { vc = w.rootViewController; break; } }
    NSMutableArray *chain = [NSMutableArray array];
    int guard = 0;
    while (vc && guard++ < 12) {
        [chain addObject:vc];
        UIViewController *next = nil;
        if (vc.presentedViewController) next = vc.presentedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]]) next = ((UINavigationController *)vc).topViewController;
        else if ([vc isKindOfClass:[UITabBarController class]]) next = ((UITabBarController *)vc).selectedViewController;
        else { NSArray *kids = [vc childViewControllers]; if (kids.count) next = kids.lastObject; }
        if (!next || next == vc) break;
        vc = next;
    }
    return chain;
}

// 屏幕底部区域所有可见视图（底栏候选）
static void AFSD_collectBottom(UIView *v, CGFloat screenH, NSMutableArray *out, int depth) {
    if (!v || depth > 8 || out.count >= 6) return;
    if (!v.hidden && v.alpha > 0.01) {
        CGRect absRect = [v convertRect:v.frame toView:nil];
        CGFloat bottomGap = screenH - (absRect.origin.y + absRect.size.height);
        if (bottomGap < 200.0 && absRect.size.height > 20.0 && absRect.size.height < 220.0 &&
            absRect.size.width > 150.0) {
            [out addObject:[NSString stringWithFormat:@"%s h=%.0f y=%.0f in:%s",
                            class_getName(object_getClass(v)), absRect.size.height,
                            absRect.origin.y, class_getName(object_getClass(v.superview))]];
        }
    }
    for (UIView *s in v.subviews) AFSD_collectBottom(s, screenH, out, depth + 1);
}

#pragma mark - 报告

static void AFSD_refresh(void) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSArray *chain = AFSD_vcChain();
        NSMutableArray *names = [NSMutableArray array];
        for (UIViewController *vc in chain) [names addObject:AFSD_clsName(vc)];

        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"AFS-DIAG v2.2.0-d  bid=%@\n", bid];
        [s appendFormat:@"VC链: %@\n", [names componentsJoinedByString:@" > "]];

        // 链上每个 VC 的相关 ivar（最多报 3 个 VC）
        int k = 0;
        for (UIViewController *vc in chain) {
            if (k++ >= 3) break;
            NSString *iv = AFSD_ivarsOf(vc, 8);
            if (iv.length) [s appendFormat:@"  %@: %@\n", AFSD_clsName(vc), iv];
        }

        // 底部候选视图
        UIWindowScene *ws = AFSD_activeScene();
        UIView *root = nil;
        for (UIWindow *w in ws.windows) { if (w.isKeyWindow) { root = w; break; } }
        if (!root) for (UIWindow *w in ws.windows) { root = w; break; }
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        NSMutableArray *bottom = [NSMutableArray array];
        if (root) AFSD_collectBottom(root, screenH, bottom, 0);
        [s appendFormat:@"底部候选(%lu):\n", (unsigned long)bottom.count];
        for (NSString *b in bottom) [s appendFormat:@"  %@\n", b];

        // 常见类是否存在
        [s appendFormat:@"aweBase=%@ progSlider=%@\n",
            objc_getClass("awemeBaseViewController") ? @"有" : @"无",
            objc_getClass("AWEPlayInteractionProgressSliderView") ? @"有" : @"?"];

        dispatch_async(dispatch_get_main_queue(), ^{
            gLabel.text = s;
        });
    } @catch (__unused NSException *e) {}
}

#pragma mark - 叠加窗

static void AFSD_showOverlay(void) {
    UIWindowScene *ws = AFSD_activeScene();
    if (!ws || gWin) return;

    gWin = [[AFSDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWin.windowScene = ws;
    gWin.windowLevel = UIWindowLevelAlert + 1;
    gWin.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    gWin.rootViewController = [UIViewController new];
    gWin.hidden = NO;

    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    gLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 60, w - 12, 320)];
    gLabel.numberOfLines = 0;
    gLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    gLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
    gLabel.backgroundColor = [UIColor clearColor];
    [gWin.rootViewController.view addSubview:gLabel];

    AFSD_refresh();
    gTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t) {
        AFSD_refresh();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
    NSLog(@"[AFS-DIAG] overlay shown");
}

__attribute__((constructor))
static void AFSD_init(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid hasPrefix:@"com.ss.iphone.aweme"] &&
        ![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"] isEqualToString:@"Aweme"]) {
        return;
    }
    NSLog(@"[AFS-DIAG] loaded in %@", bid);
    // 等抖音界面起来再叠
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AFSD_showOverlay();
        // 场景可能还没就绪，再补几次
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!gWin) AFSD_showOverlay();
            });
        }
    });
}
