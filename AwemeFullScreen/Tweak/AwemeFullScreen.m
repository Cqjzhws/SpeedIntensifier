// AwemeFullScreen — 抖音(Aweme) 全屏插件 v2.6.0
// ============================================================================
// 本版依据「诊断版在抖音 38.0.0 上实测回传的真实数据」，并修正 v2.3.0 的失误。
//
// v2.5.0 新增（几何诊断实测得出）：
//   隐藏 tabBar 后，UITabBarController **仍然**把 tabBar 高度（实测 83pt）算作子控制器
//   的底部安全区：诊断回传子 VC 的 sa.b 全是 83，而所有视图 frame 都是整屏、滚动视图
//   inset 全为 0 —— 所以底部黑边就是这 83pt 安全区逼出来的。
//   处理：给底栏本体挂一条 0 高约束（优先级 999），安全区贡献归零；
//         离开首页区时撤销约束并恢复显示。
//
// 实测事实（38.0.0）：
//   bid        = com.ss.iphone.ugc.Aweme
//   底栏        = AWENormalModeTabBar（内含 UITabBarButton / _UIBarBackground）
//   底栏皮肤    = AWETabBarSkinView（父 AWETabBarSkinContainerView）
//   VC 链       = AWENormalModeTabBarController_hmd_subfix_
//                 > AWEBasedRootNavigationController_hmd_subfix_
//                 > AWEFeedRootViewController_hmd_subfix_
//                 > ... > AWEFeedTableViewController > AWELiveNewPreStreamViewController
//   awemeBaseViewController / awe_tabBar / awe_blurView / progressSliderUnderView 在 38.0.0 均不存在
//   类名统一带 _hmd_subfix_ 混淆后缀
//
// v2.3.0 的教训：
//   为了消除底栏腾出的黑边，v2.3.0 在定时器里把首页 VC 的 view.frame 强设成整屏。
//   实测反而让视频区域缩到屏幕上部、下方出现更大的黑区 —— 说明该 VC 的 view 是
//   Auto Layout 驱动的，直接改 frame 会破坏它内部的约束求解。
//   所以 v2.4.0 **不再碰任何 frame**，只做“隐藏/恢复底栏”这一件已被验证有效的事；
//   黑边问题改为先用几何诊断量清楚再动手（见 AFS_DIAG）。
//
// 行为：
//   · -[UIView layoutSubviews] 热路径：一次类名缓存命中即早退；命中且当前在首页区
//     （VC 链上出现 AWEFeed / AWELive / AWEHPX / AWEAweme）→ 隐藏并登记。
//   · 0.4s 定时兜底：在首页区把登记过的底栏重新压下去；离开首页区则恢复。
//   · 隐藏登记用 NSHashTable 弱引用，视图释放自动置 nil，无悬垂指针风险。
//   · 屏幕文字：正式版无任何文字；诊断版（-DAFS_DIAG=1）才在顶部叠加几何报告。
//   · 纯 ObjC runtime，无 CydiaSubstrate。
// ============================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <string.h>

#ifndef AFS_DIAG
#define AFS_DIAG 0
#endif

#define kAFSPrefPath    @"/var/Managed Preferences/mobile/com.local.awemefullscreen.plist"
#define kAFSNotifyName  @"com.local.awemefullscreen.settingschanged"
#define kAFSBundleNew   @"com.ss.iphone.ugc.Aweme"
#define kAFSBundleOld   @"com.ss.iphone.aweme"

// ---------- 全局状态 ----------
static BOOL gEnabled    = YES;
static BOOL gFullScreen = YES;
static BOOL gVerbose    = NO;
static BOOL gIsAweme    = NO;
static BOOL gActive     = NO;
static BOOL gFirstHitLogged = NO;

#define kAFSClsCacheSize 1024
static Class  gClsKey[kAFSClsCacheSize];
static int8_t gClsVal[kAFSClsCacheSize];
static Class  gFeedKey[kAFSClsCacheSize];
static int8_t gFeedVal[kAFSClsCacheSize];

static NSHashTable *gHidden = nil;       // 我们隐藏过的视图（弱引用）

// v2.5.0 试过给底栏挂 0 高约束 —— 几何诊断回传 sa.b 仍然是 83，**没用**。
// v2.6.0 改用最强手段：把底栏**整个从父视图移除**。只有它不在视图层级里，
// UITabBarController 才会重新计算，子控制器的 83pt 底部安全区才会归零。
// 离开首页区时按原父视图 + 原索引放回去。
static __weak UIView *gTabBarRef   = nil;
static __weak UIView *gTabBarSuper = nil;
static NSUInteger    gTabBarIndex  = 0;

// 自动进入全屏：截图证据 —— 合集/详情页里视频是 16:9 小窗（428x273pt，仅占屏幕 29%），
// 页面里自带一个「全屏观看」控件。命中标题含「全屏」的可见 UIControl 就替用户点一下。
static NSTimeInterval gLastTapAt = 0;
static int            gTapCount  = 0;

static BOOL           gInFeed = NO;
static NSTimeInterval gInFeedAt = 0;

#pragma mark - 配置

static void AFS_recalc(void) { gActive = (gEnabled && gFullScreen && gIsAweme); }

static void AFS_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kAFSPrefPath];
    if (d) {
        if (d[@"Enabled"])    gEnabled    = [d[@"Enabled"] boolValue];
        if (d[@"FullScreen"]) gFullScreen = [d[@"FullScreen"] boolValue];
        if (d[@"LogVerbose"]) gVerbose    = [d[@"LogVerbose"] boolValue];
    }
    AFS_recalc();
}

static void AFS_notifyCb(CFNotificationCenterRef c, void *o, CFNotificationName n,
                         const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    AFS_reload();
}

static BOOL AFS_detectAweme(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid hasPrefix:kAFSBundleNew]) return YES;
    if ([bid hasPrefix:kAFSBundleOld]) return YES;
    NSString *exe = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if ([exe isEqualToString:@"Aweme"]) return YES;
    return NO;
}

#pragma mark - 类名判定（每个 Class 只做一次 strstr）

static int8_t AFS_hideVerdictCompute(Class c) {
    const char *cn = class_getName(c);
    if (!cn) return 0;
    if (strstr(cn, "NormalModeTabBar")) return 1;
    if (strstr(cn, "TabBarSkin"))       return 1;
    if (strstr(cn, "tabBar") || strstr(cn, "TabBar") || strstr(cn, "tabbar")) return 1;
    if (strstr(cn, "blur")   || strstr(cn, "Blur")) return 2;
    return 0;
}

static inline int8_t AFS_hideVerdict(Class c) {
    if (!c) return 0;
    uintptr_t idx = (((uintptr_t)c) >> 3) & (kAFSClsCacheSize - 1);
    if (gClsKey[idx] == c) return gClsVal[idx];
    int8_t r = AFS_hideVerdictCompute(c);
    gClsKey[idx] = c;
    gClsVal[idx] = r;
    return r;
}

static int8_t AFS_feedVerdictCompute(Class c) {
    const char *cn = class_getName(c);
    if (!cn) return 0;
    if (strstr(cn, "AWEFeed"))  return 1;
    if (strstr(cn, "AWELive"))  return 1;
    if (strstr(cn, "AWEHPX"))   return 1;
    if (strstr(cn, "AWEAweme")) return 1;
    if (strstr(cn, "awemeBase") || strstr(cn, "AwemeBase")) return 1;
    return 0;
}

static inline int8_t AFS_feedVerdict(Class c) {
    if (!c) return 0;
    uintptr_t idx = (((uintptr_t)c) >> 3) & (kAFSClsCacheSize - 1);
    if (gFeedKey[idx] == c) return gFeedVal[idx];
    int8_t r = AFS_feedVerdictCompute(c);
    gFeedKey[idx] = c;
    gFeedVal[idx] = r;
    return r;
}

static inline BOOL AFS_isFeedVC(id vc) {
    Class c = object_getClass(vc);
    if (!c) return NO;
    if (AFS_feedVerdict(c)) return YES;
    if (class_getInstanceVariable(c, "awe_tabBar"))   return YES;
    if (class_getInstanceVariable(c, "awe_blurView")) return YES;
    if ([vc respondsToSelector:@selector(isFromGeneralSearchOrVideoSearch)]) return YES;
    return NO;
}

#pragma mark - 窗口 / VC 链

static UIWindowScene *AFS_activeScene(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            sc.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)sc;
        }
    }
    return nil;
}

static UIWindow *AFS_keyWindow(void) {
    UIWindowScene *ws = AFS_activeScene();
    if (!ws) return nil;
    for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
    for (UIWindow *w in ws.windows) return w;
    return nil;
}

static UIViewController *AFS_nextVC(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController) return vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        return ((UINavigationController *)vc).topViewController;
    if ([vc isKindOfClass:[UITabBarController class]])
        return ((UITabBarController *)vc).selectedViewController;
    NSArray *kids = [vc childViewControllers];
    return [kids count] ? [kids lastObject] : nil;
}

static UIViewController *AFS_findFeedVC(void) {
    UIViewController *vc = AFS_keyWindow().rootViewController;
    int guard = 0;
    while (vc && guard++ < 16) {
        if (AFS_isFeedVC(vc)) return vc;
        UIViewController *next = AFS_nextVC(vc);
        if (!next || next == vc) break;
        vc = next;
    }
    return nil;
}

static inline BOOL AFS_inFeedNow(void) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gInFeedAt < 0.2) return gInFeed;
    gInFeedAt = now;
    gInFeed = (AFS_findFeedVC() != nil);
    return gInFeed;
}

#pragma mark - 自动进入全屏（点「全屏观看」）

static BOOL AFS_titleIsFullscreen(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    return ([s rangeOfString:@"全屏"].location != NSNotFound);
}

// 找标题/无障碍标签含「全屏」的可见 UIControl
static UIControl *AFS_findFullscreenControl(UIView *v, int depth, int *budget) {
    if (!v || depth > 12 || *budget <= 0) return nil;
    (*budget)--;
    if (v.hidden || v.alpha < 0.01 || !v.window) return nil;
    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *c = (UIControl *)v;
        NSString *t = nil;
        if ([c isKindOfClass:[UIButton class]]) t = [(UIButton *)c titleForState:c.state];
        if (!AFS_titleIsFullscreen(t)) t = c.accessibilityLabel;
        if (AFS_titleIsFullscreen(t)) return c;
    }
    for (UIView *s in v.subviews) {
        UIControl *r = AFS_findFullscreenControl(s, depth + 1, budget);
        if (r) return r;
    }
    return nil;
}

static void AFS_tryEnterFullscreen(void) {
    if (gTapCount >= 8) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastTapAt < 2.0) return;
    gLastTapAt = now;
    UIWindow *kw = AFS_keyWindow();
    if (!kw) return;
    int budget = 4000;
    UIControl *c = AFS_findFullscreenControl(kw, 0, &budget);
    if (!c) return;
    gTapCount++;
    NSLog(@"[AwemeFullScreen] auto-tap fullscreen control #%d: %s",
          gTapCount, class_getName(object_getClass(c)));
    @try {
        [c sendActionsForControlEvents:UIControlEventTouchUpInside];
    } @catch (__unused NSException *e) {}
}

#pragma mark - 隐藏 / 恢复

static void AFS_hideTarget(UIView *v) {
    if (!v) return;
    if (!gHidden) gHidden = [NSHashTable weakObjectsHashTable];
    [gHidden addObject:v];
    if (!v.hidden) v.hidden = YES;
    // 底栏本体（AWENormalModeTabBar 是 UITabBar 系）：整个移出视图层级，
    // 这是唯一能让 UITabBarController 重新计算、把子控制器 83pt 底部安全区归零的办法。
    if ([v isKindOfClass:[UITabBar class]] && !gTabBarRef) {
        @try {
            UIView *sup = v.superview;
            if (sup) {
                gTabBarSuper = sup;
                gTabBarIndex = [sup.subviews indexOfObject:v];
                gTabBarRef = v;
                [v removeFromSuperview];
                NSLog(@"[AwemeFullScreen] tabBar detached from hierarchy (drops the 83pt bottom inset)");
            }
        } @catch (__unused NSException *e) { gTabBarRef = nil; gTabBarSuper = nil; }
    }
    if (!gFirstHitLogged) {
        gFirstHitLogged = YES;
        NSLog(@"[AwemeFullScreen] v2.6.0 first hit: hid %s",
              class_getName(object_getClass(v)));
    }
}

static void AFS_restoreAll(void) {
    // 先把底栏放回原处，再恢复显示
    UIView *tb = gTabBarRef;
    UIView *sup = gTabBarSuper;
    if (tb && sup && !tb.superview) {
        @try {
            NSUInteger n = sup.subviews.count;
            [sup insertSubview:tb atIndex:(gTabBarIndex <= n ? gTabBarIndex : n)];
        } @catch (__unused NSException *e) {}
    }
    gTabBarRef = nil;
    gTabBarSuper = nil;
    if (tb && tb.hidden) tb.hidden = NO;
    if (!gHidden || gHidden.count == 0) return;
    for (UIView *v in gHidden.allObjects) {
        if (v.hidden) v.hidden = NO;
    }
    if (gVerbose) NSLog(@"[AwemeFullScreen] restored %lu view(s)",
                        (unsigned long)gHidden.count);
    [gHidden removeAllObjects];
}

#pragma mark - 主力：-[UIView layoutSubviews]

static void (*o_afs_layoutSubviews)(id, SEL);

static void afs_layoutSubviews(id self, SEL _cmd) {
    if (o_afs_layoutSubviews) o_afs_layoutSubviews(self, _cmd);
    if (!gActive) return;
    if (AFS_hideVerdict(object_getClass(self)) == 0) return;   // 热路径早退
    if (!AFS_inFeedNow()) return;
    AFS_hideTarget((UIView *)self);
}

#pragma mark - 定时兜底

static void AFS_tick(__unused NSTimer *t) {
    if (!gActive) return;
    if (AFS_inFeedNow()) {
        if (gHidden) {
            for (UIView *v in gHidden.allObjects) {
                if (!v.hidden) v.hidden = YES;
            }
        }
        // 底栏被重新加回层级时再摘一次
        UIView *tb = gTabBarRef;
        if (tb && tb.superview) [tb removeFromSuperview];
        // 合集/详情页里视频是小窗时，替用户点「全屏观看」
        AFS_tryEnterFullscreen();
    } else {
        AFS_restoreAll();
    }
}

#if AFS_DIAG
#pragma mark - 诊断叠加（-DAFS_DIAG=1 才编进来；正式产物无任何文字）

@interface AFSDWindow : UIWindow @end
@implementation AFSDWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

static AFSDWindow *gWin = nil;
static UILabel    *gLabel = nil;

static NSString *AFSD_short(id obj) {
    if (!obj) return @"(nil)";
    NSString *s = [NSString stringWithUTF8String:class_getName(object_getClass(obj))];
    s = [s stringByReplacingOccurrencesOfString:@"_hmd_subfix_" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"NSKVONotifying_" withString:@"KVO:"];
    if (s.length > 30) s = [s substringToIndex:30];
    return s;
}

static NSString *AFSD_rect(CGRect r) {
    return [NSString stringWithFormat:@"(%.0f,%.0f,%.0f,%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

// 底部候选（正确的坐标换算：把视图 bounds 转到 window 坐标系）
static void AFSD_bottom(UIView *v, CGFloat screenH, NSMutableArray *out, int depth) {
    if (!v || depth > 10 || out.count >= 7) return;
    if (!v.hidden && v.alpha > 0.01) {
        CGRect w = [v convertRect:v.bounds toView:nil];
        CGFloat gap = screenH - (w.origin.y + w.size.height);
        if (gap >= -1.0 && w.size.height > 8.0 && w.size.width > 80.0) {
            [out addObject:[NSString stringWithFormat:@"%@ h=%.0f gap=%.0f",
                            AFSD_short(v), w.size.height, gap]];
        }
    }
    for (UIView *s in v.subviews) AFSD_bottom(s, screenH, out, depth + 1);
}

// 找第一个 UIScrollView（表格详情页的黑边通常来自它的 frame/inset）
static UIScrollView *AFSD_firstScroll(UIView *v, int depth) {
    if (!v || depth > 10) return nil;
    if ([v isKindOfClass:[UIScrollView class]]) return (UIScrollView *)v;
    for (UIView *s in v.subviews) {
        UIScrollView *r = AFSD_firstScroll(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

static void AFSD_refresh(void) {
    @try {
        UIWindow *kw = AFS_keyWindow();
        if (!kw) return;
        CGRect sb = kw.bounds;
        UIEdgeInsets sa = kw.safeAreaInsets;
        UIViewController *vc = kw.rootViewController;

        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"AFS-GEO v2.6.0  screen=%@ safe=(%.0f,%.0f)\n",
                         AFSD_rect(sb), sa.top, sa.bottom];

        int guard = 0;
        while (vc && guard++ < 6) {
            UIView *v = vc.view;
            [s appendFormat:@"%@ f=%@ ai.b=%.0f sa.b=%.0f\n",
                AFSD_short(vc), v ? AFSD_rect(v.frame) : @"nil",
                vc.additionalSafeAreaInsets.bottom, v ? v.safeAreaInsets.bottom : 0];
            UIViewController *n = AFS_nextVC(vc);
            if (!n || n == vc) break;
            vc = n;
        }

        NSMutableArray *bot = [NSMutableArray array];
        AFSD_bottom(kw, sb.size.height, bot, 0);
        [s appendFormat:@"底部可见(%lu):\n", (unsigned long)bot.count];
        for (NSString *b in bot) [s appendFormat:@"  %@\n", b];

        UIViewController *feed = AFS_findFeedVC();
        if (feed && feed.view) {
            UIScrollView *sv = AFSD_firstScroll(feed.view, 0);
            if (sv) {
                [s appendFormat:@"scroll %@ f=%@ ci=%@ adj=%@ beh=%ld\n",
                    AFSD_short(sv), AFSD_rect(sv.frame),
                    NSStringFromUIEdgeInsets(sv.contentInset),
                    NSStringFromUIEdgeInsets(sv.adjustedContentInset),
                    (long)sv.contentInsetAdjustmentBehavior];
            }
        }
        [s appendFormat:@"feedVC=%@ hidden=%lu\n",
            feed ? AFSD_short(feed) : @"(nil)",
            (unsigned long)(gHidden ? gHidden.count : 0)];
        int b2 = 4000;
        UIControl *fc = AFS_findFullscreenControl(kw, 0, &b2);
        [s appendFormat:@"fsCtrl=%@ taps=%d tabDetached=%d\n",
            fc ? AFSD_short(fc) : @"none", gTapCount, gTabBarRef ? 1 : 0];

        dispatch_async(dispatch_get_main_queue(), ^{ gLabel.text = s; });
    } @catch (__unused NSException *e) {}
}

static void AFSD_show(void) {
    UIWindowScene *ws = AFS_activeScene();
    if (!ws || gWin) return;
    gWin = [[AFSDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWin.windowScene = ws;
    gWin.windowLevel = UIWindowLevelAlert + 1;
    gWin.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.80];
    gWin.rootViewController = [UIViewController new];
    gWin.hidden = NO;
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    gLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 55, w - 10, 430)];
    gLabel.numberOfLines = 0;
    gLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    gLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
    [gWin.rootViewController.view addSubview:gLabel];
    AFSD_refresh();
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES
                                                block:^(__unused NSTimer *tt){ AFSD_refresh(); }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
#endif

#pragma mark - 安装

static void AFS_swizzle(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void AFS_init(void) {
    @try {
        gIsAweme = AFS_detectAweme();
        if (!gIsAweme) return;
        AFS_reload();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, AFS_notifyCb, (__bridge CFStringRef)kAFSNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        AFS_swizzle([UIView class], @selector(layoutSubviews),
                    (IMP)afs_layoutSubviews, (IMP *)&o_afs_layoutSubviews);

        NSLog(@"[AwemeFullScreen] v2.6.0%s installed in %@ active=%d layoutSubviews=%s",
              AFS_DIAG ? "-diag" : "", [[NSBundle mainBundle] bundleIdentifier], gActive,
              o_afs_layoutSubviews ? "ok" : "FAILED");

        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES
                                                        block:^(NSTimer *tt){ AFS_tick(tt); }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
#if AFS_DIAG
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ AFSD_show(); });
            for (int i = 1; i <= 6; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ if (!gWin) AFSD_show(); });
            }
#endif
        });
    } @catch (NSException *e) {
        NSLog(@"[AwemeFullScreen] install failed (app unaffected): %@", e);
    }
}
