// AwemeFullScreen — 抖音(Aweme) 全屏插件 v2.3.0
// ============================================================================
// 本版全部依据「诊断版在抖音 38.0.0 上实测回传的真实数据」，不再有任何猜测：
//
//   bid        = com.ss.iphone.ugc.Aweme          ← 之前写的 com.ss.iphone.aweme 完全不对
//   底栏类名    = AWENormalModeTabBar               （内含 UITabBarButton / _UIBarBackground，属 UITabBar 系）
//   底栏皮肤    = AWETabBarSkinView                 （父视图 AWETabBarSkinContainerView）
//   VC 链       = AWENormalModeTabBarController_hmd_subfix_
//                 > AWEBasedRootNavigationController_hmd_subfix_
//                 > AWEFeedRootViewController_hmd_subfix_
//                 > ... > AWEFeedTableViewController > AWELiveNewPreStreamViewController
//   awemeBaseViewController 在 38.0.0 不存在（诊断回传 aweBase=无）
//   awe_tabBar / awe_blurView / progressSliderUnderView 三个 ivar 在 38.0.0 均不存在
//   所有类名都带 _hmd_subfix_ 混淆后缀（不影响 strstr 子串匹配）
//
// 由此得到两个必须修正的点：
//   1) bundle id 门禁 —— 用实测值，并保留 CFBundleExecutable == "Aweme" 兜底；
//   2) 识别与隐藏目标 —— 放弃 ivar/awemeBase 路线，改为：
//        · 隐藏目标：类名含 NormalModeTabBar / TabBarSkin / TabBar / tabBar / blur 的视图
//        · 页面判定：VC 链上出现 AWEFeed / AWELive / AWEHPX / AWEAweme 视为「首页/视频/直播区」
//          其它 Tab（消息/我）不隐藏，并把之前隐藏过的恢复回来。
//
// 屏幕文字：本实现不显示任何屏幕文字，源码内无中文字符串字面量，
//          不引用 showText:withCenterPoint:。
// 环境：纯 ObjC runtime，无 CydiaSubstrate；install name 与外层一致。
// ============================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <string.h>

#define kAFSPrefPath    @"/var/Managed Preferences/mobile/com.local.awemefullscreen.plist"
#define kAFSNotifyName  @"com.local.awemefullscreen.settingschanged"
// v2.3.0：实测的真实 bundle id
#define kAFSBundleNew   @"com.ss.iphone.ugc.Aweme"
// 老版本 / 极速版兜底
#define kAFSBundleOld   @"com.ss.iphone.aweme"

// ---------- 全局状态 ----------
static BOOL gEnabled    = YES;
static BOOL gFullScreen = YES;
static BOOL gVerbose    = NO;
static BOOL gIsAweme    = NO;
static BOOL gActive     = NO;
static CGRect gScreenBounds;
static BOOL gFirstHitLogged = NO;

// 直接映射缓存：某 Class 是否属于「需要隐藏的类」
#define kAFSClsCacheSize 1024
static Class  gClsKey[kAFSClsCacheSize];
static int8_t gClsVal[kAFSClsCacheSize];

// 直接映射缓存：某 Class 是否属于「首页/视频/直播区的 VC」
static Class  gFeedKey[kAFSClsCacheSize];
static int8_t gFeedVal[kAFSClsCacheSize];

// 我们隐藏过的视图（弱引用，安全自动置 nil）
static NSHashTable *gHidden = nil;

// 页面判定的懒计算缓存
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

// 1 = 底栏类（含皮肤） 2 = 模糊类
static int8_t AFS_hideVerdictCompute(Class c) {
    const char *cn = class_getName(c);
    if (!cn) return 0;
    // 实测目标：AWENormalModeTabBar / AWETabBarSkinView
    if (strstr(cn, "NormalModeTabBar")) return 1;
    if (strstr(cn, "TabBarSkin"))       return 1;
    // 通用兜底（UITabBarButton、_UIBarBackground 等会被父视图一并隐藏）
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

// 该 VC 是否属于「首页 / 视频 / 直播区」（实测类名 + 老版本兜底）
static int8_t AFS_feedVerdictCompute(Class c) {
    const char *cn = class_getName(c);
    if (!cn) return 0;
    if (strstr(cn, "AWEFeed"))  return 1;
    if (strstr(cn, "AWELive"))  return 1;
    if (strstr(cn, "AWEHPX"))   return 1;
    if (strstr(cn, "AWEAweme")) return 1;
    // 老版本（≤ 某版本）兜底
    if (strstr(cn, "awemeBase") || strstr(cn, "AwemeBase")) return 1;
    if (strstr(cn, "AWEFamiliar") || strstr(cn, "AWEFollow")) return 1;
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
    // ivar / selector 兜底（老版本才有）
    if (class_getInstanceVariable(c, "awe_tabBar"))    return YES;
    if (class_getInstanceVariable(c, "awe_blurView"))  return YES;
    if ([vc respondsToSelector:@selector(isFromGeneralSearchOrVideoSearch)]) return YES;
    return NO;
}

#pragma mark - 当前 VC 链 / 是否在首页区

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

// 遍历 VC 链，返回第一个属于首页区的 VC（同时把整条链都看一遍）
static UIViewController *AFS_findFeedVC(void) {
    UIWindow *kw = AFS_keyWindow();
    UIViewController *vc = kw.rootViewController;
    int guard = 0;
    while (vc && guard++ < 16) {
        if (AFS_isFeedVC(vc)) return vc;
        UIViewController *next = nil;
        if (vc.presentedViewController) {
            next = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)vc).topViewController;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)vc).selectedViewController;
        } else {
            NSArray *kids = [vc childViewControllers];
            if ([kids count]) next = [kids lastObject];
        }
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

#pragma mark - 隐藏 / 恢复

static void AFS_hideTarget(UIView *v) {
    if (!v) return;
    if (!gHidden) gHidden = [NSHashTable weakObjectsHashTable];
    [gHidden addObject:v];
    if (!v.hidden) v.hidden = YES;
    if (!gFirstHitLogged) {
        gFirstHitLogged = YES;
        NSLog(@"[AwemeFullScreen] v2.3.0 first hit: hid %s",
              class_getName(object_getClass(v)));
    }
}

static void AFS_restoreAll(void) {
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

    // 热路径：一次类名判定缓存命中即可早退，绝大多数视图在这里就返回
    if (AFS_hideVerdict(object_getClass(self)) == 0) return;

    // 只是当前不在首页区就先不动（切换 Tab 时由定时器统一恢复）
    if (!AFS_inFeedNow()) return;
    AFS_hideTarget((UIView *)self);
}

#pragma mark - 定时兜底：跟着页面切换 隐藏 / 恢复

static void AFS_tick(__unused NSTimer *t) {
    if (!gActive) return;
    if (AFS_inFeedNow()) {
        // 首页区：把已记录的底栏重新压下去（抖音可能把它重新显示出来）
        if (gHidden) {
            for (UIView *v in gHidden.allObjects) {
                if (!v.hidden) v.hidden = YES;
            }
        }
        // 撑满：命中首页区的那个 VC 的根视图拉到全屏并清背景
        UIViewController *feed = AFS_findFeedVC();
        if (feed) {
            UIView *root = feed.view;
            if (root) {
                CGRect sf = gScreenBounds;
                if (CGRectIsEmpty(sf)) { sf = [UIScreen mainScreen].bounds; gScreenBounds = sf; }
                if (!CGRectIsEmpty(sf) && !CGRectEqualToRect(root.frame, sf)) root.frame = sf;
            }
        }
    } else {
        AFS_restoreAll();
    }
}

#pragma mark - 安装

static void AFS_swizzle(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;                 // 重复安装保护
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void AFS_init(void) {
    @try {
        gIsAweme = AFS_detectAweme();
        if (!gIsAweme) return;
        AFS_reload();
        gScreenBounds = [UIScreen mainScreen].bounds;

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, AFS_notifyCb, (__bridge CFStringRef)kAFSNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        AFS_swizzle([UIView class], @selector(layoutSubviews),
                    (IMP)afs_layoutSubviews, (IMP *)&o_afs_layoutSubviews);

        NSLog(@"[AwemeFullScreen] v2.3.0 installed in %@ active=%d layoutSubviews=%s "
              @"(pure runtime, no Substrate, no text)",
              [[NSBundle mainBundle] bundleIdentifier], gActive,
              o_afs_layoutSubviews ? "ok" : "FAILED");

        // 定时兜底：0.4s 一次，负责"切 Tab 后恢复"和"底栏被重新显示后再压下去"
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES
                                                        block:^(NSTimer *tt){ AFS_tick(tt); }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        });
    } @catch (NSException *e) {
        NSLog(@"[AwemeFullScreen] install failed (app unaffected): %@", e);
    }
}
