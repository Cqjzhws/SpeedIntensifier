// AwemeFullScreen — 抖音(Aweme) 全屏插件 v2.1.0
// ============================================================================
// 为什么 v2.0.0 完全不生效（用户实测：移除旧注入、注入新版，毫无效果）
// ----------------------------------------------------------------------------
// v2.0.0 把主要工作挂在 -[UIViewController viewDidLayoutSubviews] 上，由它去填充
// 一个「监视表」，而 -[UIView layoutSubviews] 只对监视表内的视图生效。
// 只要抖音的视频VC重写了 viewDidLayoutSubviews 且**没有调用 super**，
// 我们的 hook 就永远不会为它执行 → 监视表恒为空 → 整个插件静默失效（零日志、零效果）。
//
// 这也是参考 dylib 为什么引用 _viewControllerForAncestor / parentViewController /
// superview —— 它在 -[UIView layoutSubviews] 里从视图沿响应者链上溯找宿主 VC，
// **完全不依赖 VC 那个 hook**。
//
// v2.1.0 的架构：所有判断都在 -[UIView layoutSubviews] 里自给自足
// ----------------------------------------------------------------------------
//   1. O(1) 早退：被监视 root view 的裸指针比较（≤8 次）。
//   2. 按 Class 缓存的"类名是否属于该隐藏的类"判定 —— 每个 Class 只做一次 strstr，
//      之后是一次 1024 槽直接映射表命中（几个 ns），启动/滚动开销可忽略。
//   3. 命中后判定"当前是否视频页"，两条独立通路（任一成立即隐藏）：
//        (a) 沿 superview/nextResponder 上溯找到宿主 VC，判断它是不是视频VC
//            （每视图只算一次，结果与时间无关，可安全缓存）；
//        (b) **遍历当前窗口的 VC 层级链**（presented / nav.top / tab.selected /
//            children），只要链上任一层是视频VC就算在视频页。
//            带 0.2s TTL 懒计算，同样不依赖任何 VC hook。
//      (b) 这条是关键：即使要隐藏的视图（例如根 UITabBar）并不属于视频VC，
//      只要用户当前在视频页，也会被隐藏；离开视频页（消息/我）则自动恢复。
//   4. VC hook 仍然保留，但降级为辅助路径（撑满 frame、刷新屏幕 bounds、缓存隐藏清单）。
//
// 其它
// ----------------------------------------------------------------------------
//   · 不再包含 v2.0.0 里我自行推断的 isFromChat 否决 —— 已工作过的旧版本
//     (AwemeFull v1.1.0) 没有这一层，极性猜反就是"整体失效"，不能留。
//   · 视频VC识别增加 isMemberOfClass: 到 NSClassFromString(@"awemeBaseViewController")
//     （参考 dylib 的 selrefs 里同时有 isMemberOfClass: 和 awemeBaseViewController）。
//   · 屏幕文字：本实现**不显示任何文字**，源码内不存在中文字符串字面量，
//     也不引用 showText:withCenterPoint:（旧版的 "Inject Success v1-1.8" 就是它弹的）。
//   · 纯 ObjC runtime，无 CydiaSubstrate —— 纯 TrollStore / Bootstrap / 越狱都能加载。
// ============================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <string.h>

#define kAFSPrefPath    @"/var/Managed Preferences/mobile/com.local.awemefullscreen.plist"
#define kAFSNotifyName  @"com.local.awemefullscreen.settingschanged"
#define kAFSBundleID    @"com.ss.iphone.aweme"

// ---------- 全局状态 ----------
static BOOL gEnabled    = YES;
static BOOL gFullScreen = YES;
static BOOL gVerbose    = NO;
static BOOL gIsAweme    = NO;
static BOOL gActive     = NO;
static CGRect gScreenBounds;

// 关联对象键
static const void *kAFSClassVerdictKey = &kAFSClassVerdictKey;  // NSNumber on Class：是否视频VC
static const void *kAFSHideListKey     = &kAFSHideListKey;      // NSArray  on watched root view
static const void *kAFSSecondPassKey   = &kAFSSecondPassKey;    // NSNumber on watched root view
static const void *kAFSViewVerdictKey  = &kAFSViewVerdictKey;   // NSNumber on pattern view：宿主VC是否视频VC

// 被监视的 root view（裸指针，不 retain）
#define kAFSWatchMax 8
static void *gWatch[kAFSWatchMax];
static int   gWatchCount = 0;

// 类名判定直接映射缓存；冲突就重算，正确性不受影响
// 键用 Class 类型（不是 void*）：ARC 下 ObjC 指针转 void* 需要桥接，用 Class 免去麻烦
#define kAFSClsCacheSize 1024
static Class  gClsKey[kAFSClsCacheSize];
static int8_t gClsVal[kAFSClsCacheSize];

// "当前是否视频页"的懒计算缓存
static BOOL           gOnVideoPage = NO;
static NSTimeInterval gVideoPageAt = 0;

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
    if ([bid hasPrefix:kAFSBundleID]) return YES;
    NSString *exe = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if ([exe isEqualToString:@"Aweme"]) return YES;
    return NO;
}

#pragma mark - 监视表（纯指针）

static inline void AFS_watchAdd(UIView *v) {
    void *p = (__bridge void *)v;
    for (int i = 0; i < gWatchCount; i++) if (gWatch[i] == p) return;
    if (gWatchCount < kAFSWatchMax) { gWatch[gWatchCount++] = p; return; }
    memmove(gWatch, gWatch + 1, sizeof(void *) * (kAFSWatchMax - 1));
    gWatch[kAFSWatchMax - 1] = p;
}

static inline void AFS_watchRemoveAt(int idx) {
    if (idx < 0 || idx >= gWatchCount) return;
    memmove(gWatch + idx, gWatch + idx + 1, sizeof(void *) * (gWatchCount - idx - 1));
    gWatchCount--;
}

#pragma mark - 类名判定（每个 Class 只做一次字符串匹配）

// 0=不处理 1=tabbar类 2=blur类 3=progressSliderUnder类
static int8_t AFS_hideNameVerdictCompute(Class c) {
    const char *cn = class_getName(c);
    if (!cn) return 0;
    if (strstr(cn, "progressSliderUnder")) return 3;
    if (strstr(cn, "awe_tabBar") || strstr(cn, "AWETabBar") || strstr(cn, "AWEFeedTabBar")) return 1;
    if (strstr(cn, "blur") || strstr(cn, "Blur")) return 2;
    // 通用兜底：是否误伤由第 3 步的"视频页"闸门决定
    if (strstr(cn, "tabBar") || strstr(cn, "TabBar") || strstr(cn, "tabbar")) return 1;
    if (strstr(cn, "BottomBar") || strstr(cn, "bottomBar")) return 1;
    return 0;
}

static inline int8_t AFS_hideNameVerdict(Class c) {
    if (!c) return 0;
    uintptr_t idx = (((uintptr_t)c) >> 3) & (kAFSClsCacheSize - 1);
    if (gClsKey[idx] == c) return gClsVal[idx];
    int8_t r = AFS_hideNameVerdictCompute(c);
    gClsKey[idx] = c;
    gClsVal[idx] = r;
    return r;
}

#pragma mark - 视频VC识别（每 Class 只判定一次，结果缓存于关联对象）

static BOOL AFS_videoVCCompute(id vc) {
    Class c = object_getClass(vc);
    if (!c) return NO;

    // 1) 强匹配：抖音视频VC特有 ivar
    if (class_getInstanceVariable(c, "awe_tabBar"))              return YES;
    if (class_getInstanceVariable(c, "awe_blurView"))            return YES;
    if (class_getInstanceVariable(c, "progressSliderUnderView")) return YES;

    // 2) 参考 dylib 用过的类名精确比对
    Class base = objc_getClass("awemeBaseViewController");
    if (base && c == base) return YES;

    // 3) 弱匹配：专属 selector 或类名模式
    if ([vc respondsToSelector:@selector(isFromGeneralSearchOrVideoSearch)]) return YES;
    const char *cn = class_getName(c);
    if (cn) {
        if (strstr(cn, "awemeBase") || strstr(cn, "AwemeBase") || strstr(cn, "AWEBase")) return YES;
        if ((strstr(cn, "Video") || strstr(cn, "video")) &&
            (strstr(cn, "Detail") || strstr(cn, "Feed") || strstr(cn, "Player") ||
             strstr(cn, "Base")   || strstr(cn, "Controller"))) return YES;
    }
    return NO;
}

static inline BOOL AFS_isVideoVC(id vc) {
    Class c = object_getClass(vc);
    if (!c) return NO;
    NSNumber *v = objc_getAssociatedObject(c, kAFSClassVerdictKey);
    if (v) return v.boolValue;
    BOOL r = AFS_videoVCCompute(vc);
    objc_setAssociatedObject(c, kAFSClassVerdictKey, r ? @YES : @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}

#pragma mark - 视图 → 宿主 VC（沿响应者链上溯）

static UIViewController *AFS_ownerVCWalk(UIView *start) {
    SEL ancSel = @selector(_viewControllerForAncestor);
    for (UIView *cur = start; cur; cur = cur.superview) {
        if ([cur respondsToSelector:ancSel]) {
            Method m = class_getInstanceMethod(object_getClass(cur), ancSel);
            if (m) {
                @try {
                    id r = ((id (*)(id, SEL))method_getImplementation(m))(cur, ancSel);
                    if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
                } @catch (__unused NSException *e) {}
            }
        }
        id nr = cur.nextResponder;
        if ([nr isKindOfClass:[UIViewController class]]) return (UIViewController *)nr;
    }
    return nil;
}

#pragma mark - 当前是否视频页（遍历窗口 VC 层级链，带 TTL 懒计算）

static UIViewController *AFS_rootVC(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && w.rootViewController) return w.rootViewController;
        }
    }
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.rootViewController) return w.rootViewController;
        }
    }
    return nil;
}

// 沿 presented / nav.top / tab.selected / children 一路向下，
// **只要链上任一层是视频VC**就算处于视频页（比只看最顶层更稳）
static BOOL AFS_hierarchyHasVideoVC(void) {
    UIViewController *vc = AFS_rootVC();
    int guard = 0;
    while (vc && guard++ < 16) {
        if (AFS_isVideoVC(vc)) return YES;
        UIViewController *next = nil;
        if (vc.presentedViewController) {
            next = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)vc).topViewController;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)vc).selectedViewController;
        } else {
            // 用消息语法取子控制器（避免个别 SDK 上 children 属性解析不到的兼容问题）
            NSArray *kids = [vc childViewControllers];
            if ([kids count]) next = [kids lastObject];
        }
        if (!next || next == vc) break;
        vc = next;
    }
    return NO;
}

static inline BOOL AFS_onVideoPageNow(void) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gVideoPageAt < 0.2) return gOnVideoPage;
    gVideoPageAt = now;
    gOnVideoPage = AFS_hierarchyHasVideoVC();
    return gOnVideoPage;
}

#pragma mark - 隐藏清单解析（被监视 root view 只做一次）

static void AFS_addIvarView(NSMutableArray *out, id obj, const char *iname) {
    Class c = object_getClass(obj);
    if (!c) return;
    Ivar iv = class_getInstanceVariable(c, iname);
    if (!iv) return;
    const char *type = ivar_getTypeEncoding(iv);      // 只读对象类型，避免野指针
    if (!type || type[0] != '@') return;
    id raw = nil;
    @try { raw = object_getIvar(obj, iv); } @catch (__unused NSException *e) { return; }
    if ([raw isKindOfClass:[UIView class]] && ![out containsObject:raw]) [out addObject:raw];
}

// 深度 <= 6、节点预算 <= 200；刻意不用 [subviews copy]（旧版每节点分配一个数组）
static void AFS_scanPattern(UIView *v, NSMutableArray *out, int depth, int *budget) {
    if (!v || depth > 6 || *budget <= 0) return;
    (*budget)--;
    if (AFS_hideNameVerdict(object_getClass(v)) > 0) {
        if (![out containsObject:v]) [out addObject:v];
    }
    for (UIView *s in v.subviews) AFS_scanPattern(s, out, depth + 1, budget);
}

static NSArray *AFS_resolveHideList(UIViewController *vc, UIView *root) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:6];
    AFS_addIvarView(out, vc, "awe_tabBar");
    AFS_addIvarView(out, vc, "awe_blurView");
    AFS_addIvarView(out, vc, "progressSliderUnderView");
    int budget = 200;
    AFS_scanPattern(root, out, 0, &budget);
    UITabBarController *tbc = vc.tabBarController;
    if ([tbc isKindOfClass:[UITabBarController class]]) {
        UIView *tb = tbc.tabBar;
        if (tb && ![out containsObject:tb]) [out addObject:tb];
    }
    return out;
}

static void AFS_applyList(UIView *root, NSArray *list) {
    for (NSUInteger i = 0; i < list.count; i++) {
        UIView *v = list[i];
        if (!v.hidden) v.hidden = YES;
    }
    CGRect sf = gScreenBounds;
    if (!CGRectIsEmpty(sf) && !CGRectEqualToRect(root.frame, sf)) root.frame = sf;
    root.backgroundColor = [UIColor clearColor];
}

#pragma mark - 主力：-[UIView layoutSubviews]（自给自足，不依赖任何 VC hook）

static void (*o_afs_layoutSubviews)(id, SEL);
static BOOL gLoggedFirstHit = NO;

static void afs_layoutSubviews(id self, SEL _cmd) {
    if (o_afs_layoutSubviews) o_afs_layoutSubviews(self, _cmd);
    if (!gActive) return;

    UIView *v = (UIView *)self;

    // ---- A：被监视的 root view → 重设隐藏 + 撑满（纯指针比较，最快） ----
    if (gWatchCount) {
        void *p = (__bridge void *)v;
        int found = -1;
        for (int i = 0; i < gWatchCount; i++) {
            if (gWatch[i] == p) { found = i; break; }
        }
        if (found >= 0) {
            NSArray *list = objc_getAssociatedObject(v, kAFSHideListKey);
            if (!list) {
                AFS_watchRemoveAt(found);
            } else {
                for (NSUInteger i = 0; i < list.count; i++) {
                    UIView *t = list[i];
                    if (!t.hidden) t.hidden = YES;
                }
                CGRect sf = gScreenBounds;
                if (!CGRectIsEmpty(sf) && !CGRectEqualToRect(v.frame, sf)) v.frame = sf;
            }
        }
    }

    // ---- B：这个视图的类名是否属于"该隐藏的类"（每类只算一次） ----
    if (AFS_hideNameVerdict(object_getClass(v)) == 0) return;

    // ---- C：判定是否视频页（两条独立通路，任一成立即隐藏） ----
    NSNumber *ov = objc_getAssociatedObject(v, kAFSViewVerdictKey);
    BOOL ownerOk;
    if (ov) {
        ownerOk = ov.boolValue;
    } else {
        UIViewController *owner = AFS_ownerVCWalk(v);
        ownerOk = (owner != nil) && AFS_isVideoVC(owner);
        // 只缓存"宿主VC是否视频VC"——它与时间无关，可以安全缓存；
        // "当前是否视频页"会随时间变化，必须每次现算（TTL 内是纯 BOOL 读取）。
        objc_setAssociatedObject(v, kAFSViewVerdictKey, ownerOk ? @YES : @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gVerbose) {
            NSLog(@"[AwemeFullScreen] pattern %s ownerVC=%s ownerIsVideo=%d",
                  class_getName(object_getClass(v)),
                  owner ? class_getName(object_getClass(owner)) : "(nil)", ownerOk);
        }
    }

    BOOL ok = ownerOk || AFS_onVideoPageNow();
    if (!ok) return;

    if (!v.hidden) {
        v.hidden = YES;
        if (!gLoggedFirstHit) {
            gLoggedFirstHit = YES;
            NSLog(@"[AwemeFullScreen] v2.1.0 first hit: hid %s (ownerIsVideo=%d)",
                  class_getName(object_getClass(v)), ownerOk);
        }
    }
}

#pragma mark - 辅助：-[UIViewController viewDidLayoutSubviews]（撑满 + 缓存清单）

static void (*o_afs_viewDidLayoutSubviews)(id, SEL);

static void afs_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (o_afs_viewDidLayoutSubviews) o_afs_viewDidLayoutSubviews(self, _cmd);
    if (!gActive) return;
    if (!AFS_isVideoVC(self)) return;

    UIViewController *vc = (UIViewController *)self;
    UIView *root = vc.view;
    if (!root) return;

    gScreenBounds = [UIScreen mainScreen].bounds;
    AFS_watchAdd(root);

    NSArray *list = objc_getAssociatedObject(root, kAFSHideListKey);
    if (!list) {
        list = AFS_resolveHideList(vc, root);
        objc_setAssociatedObject(root, kAFSHideListKey, list,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gVerbose) {
            NSLog(@"[AwemeFullScreen] %s hide-list = %lu view(s)",
                  class_getName(object_getClass(vc)), (unsigned long)list.count);
        }
    }
    AFS_applyList(root, list);

    // 二次确认：每个 root view 只排一次
    if (!objc_getAssociatedObject(root, kAFSSecondPassKey)) {
        objc_setAssociatedObject(root, kAFSSecondPassKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *wr = root;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *r = wr;
            if (!gActive || !r) return;
            NSArray *l = objc_getAssociatedObject(r, kAFSHideListKey);
            if (l) AFS_applyList(r, l);
        });
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

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, AFS_notifyCb, (__bridge CFStringRef)kAFSNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        AFS_swizzle([UIView class], @selector(layoutSubviews),
                    (IMP)afs_layoutSubviews, (IMP *)&o_afs_layoutSubviews);
        AFS_swizzle([UIViewController class], @selector(viewDidLayoutSubviews),
                    (IMP)afs_viewDidLayoutSubviews, (IMP *)&o_afs_viewDidLayoutSubviews);

        NSLog(@"[AwemeFullScreen] v2.1.0 installed in %@ active=%d "
              @"(layoutSubviews=%s viewDidLayoutSubviews=%s, pure runtime, no text)",
              [[NSBundle mainBundle] bundleIdentifier], gActive,
              o_afs_layoutSubviews ? "ok" : "FAILED",
              o_afs_viewDidLayoutSubviews ? "ok" : "FAILED");
    } @catch (NSException *e) {
        NSLog(@"[AwemeFullScreen] install failed (app unaffected): %@", e);
    }
}
