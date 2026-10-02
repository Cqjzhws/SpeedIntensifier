// AwemeFullScreen — 抖音(Aweme) 全屏插件 v2.0.0
// ============================================================================
// 为什么重写（而不是改原来那个 dylib）：
//   用户手上的 AwemeFullScreen.dylib 经拆包确认是一个 **越狱 rootless 构建**：
//     · LOAD_DYLIB @rpath/CydiaSubstrate.framework/CydiaSubstrate（用 MSHookMessageEx）
//     · rpath 里带 /var/jb/Library/Frameworks、@loader_path/.jbroot/usr/lib
//     · 没有任何字符串表（__cstring 仅 6 字节、无 __cfstring）
//     · 导入的 ObjC 类只有 UIView / UIColor / UIScreen
//   在**纯 TrollStore（无越狱）**环境下 CydiaSubstrate 不存在 → 该 dylib 直接加载失败。
//   本文件是纯 ObjC runtime 实现（无 Substrate），巨魔与越狱两种环境都能用。
//
// 本版相对旧版的三处改动（对应用户诉求）：
//   1. 【启动速度】旧版把重活放在超热路径上，是拖慢启动的主因：
//        · -[UIView layoutSubviews] 里对**每一个视图**都调用
//          [self valueForKey:@"viewController"]（KVC + @try），
//        · -[UIViewController viewDidLayoutSubviews] 里每次都做
//          class_getInstanceVariable / respondsToSelector / strstr 探测，
//          匹配后还做一次全量子视图递归（旧版每个节点都 [subviews copy] 分配数组），
//        · 每次布局都 dispatch_after(0.05s) 排一个二次确认块（滚动时堆上千个块）。
//      本版：
//        · layoutSubviews 热路径只做「一个 BOOL + 至多 8 次指针比较」，**零 objc 调用、
//          零字符串、零 KVC、零分配**；
//        · 视频VC判定按 **Class 缓存一次**（关联对象），之后只读缓存；
//        · 隐藏清单按 root view **只解析一次**并缓存，之后只重设 hidden；
//        · 子视图扫描不再 copy 数组，且有深度/节点预算；
//        · 二次确认改为**每个 root view 一次**，不再是每次布局一次。
//   2. 【去掉文字提示】本实现**不显示任何屏幕文字**，也**从不调用**
//      showText:withCenterPoint:（旧 dylib 引用了该 selector，用于借用抖音自己的
//      文字绘制 API 弹提示）。源码内不存在任何 UI 文本。
//   3. 【增强】隐藏项补齐：awe_tabBar / awe_blurView / progressSliderUnderView /
//      类名含 tabBar|blur 的视图 / tabBarController.tabBar；
//      视频VC识别补齐 ivar、selector 与类名模式，并用 isFromChat 对**弱匹配**做否决。
//
// 兼容与安全（沿用本项目红线）：
//   · 纯 runtime，method_setImplementation 保存原 IMP；原 IMP 调用前判空；
//   · swizzle 有重复安装保护；constructor 全程 @try，异常只丢功能不影响 App 启动；
//   · 只 hook 两个方法，且均有 O(1) 早退；
//   · 仅在 com.ss.iphone.aweme（含 lite 子包）激活。
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
static BOOL gIsAweme    = NO;
static BOOL gActive     = NO;      // gEnabled && gFullScreen && gIsAweme，热路径只读它
static CGRect gScreenBounds;       // 缓存屏幕 bounds，避免热路径调 [UIScreen mainScreen]

// 关联对象键
static const void *kAFSClassVerdictKey = &kAFSClassVerdictKey;  // NSNumber，挂在 Class 上
static const void *kAFSHideListKey     = &kAFSHideListKey;      // NSArray<UIView*>，挂在 root view 上
static const void *kAFSSecondPassKey   = &kAFSSecondPassKey;    // NSNumber，挂在 root view 上

// 被监视的 root view（视频VC的根视图）。
// 只存裸指针、不 retain：地址复用最坏只是多做一次关联对象查询（取不到清单就自动移出），
// 换来的收益是 layoutSubviews 热路径完全不需要任何 objc 调用。
#define kAFSWatchMax 8
static void *gWatch[kAFSWatchMax];
static int   gWatchCount = 0;

#pragma mark - 配置

static void AFS_recalc(void) {
    gActive = (gEnabled && gFullScreen && gIsAweme);
}

static void AFS_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kAFSPrefPath];
    if (d) {
        if (d[@"Enabled"])    gEnabled    = [d[@"Enabled"] boolValue];
        if (d[@"FullScreen"]) gFullScreen = [d[@"FullScreen"] boolValue];
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
    if ([bid isEqualToString:kAFSBundleID]) return YES;
    if ([bid hasPrefix:kAFSBundleID]) return YES;         // 含 .lite 等子包
    // 极少数注入方式下 bundle id 取不到，用可执行文件名兜底
    NSString *exe = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if ([exe isEqualToString:@"Aweme"]) return YES;
    return NO;
}

#pragma mark - 监视表（热路径专用，全是纯指针操作）

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

#pragma mark - 视频VC识别（每类只跑一次）

// 从二进制里抄出来的识别依据：
//   ivar:  awe_tabBar / awe_blurView / progressSliderUnderView
//   sel:   isFromGeneralSearchOrVideoSearch（正向）、isFromChat（仅用于否决弱匹配）
//   类名:  awemeBase*，或 Video* + Detail/Feed/Player/Base
static BOOL AFS_probeVideoVC(id vc) {
    Class c = object_getClass(vc);
    if (!c) return NO;

    // 1) 强匹配：抖音视频VC特有的 ivar
    if (class_getInstanceVariable(c, "awe_tabBar"))              return YES;
    if (class_getInstanceVariable(c, "awe_blurView"))            return YES;
    if (class_getInstanceVariable(c, "progressSliderUnderView")) return YES;

    // 2) 弱匹配：专属 selector 或类名模式，可能被 isFromChat 否决
    BOOL weak = NO;
    if ([vc respondsToSelector:@selector(isFromGeneralSearchOrVideoSearch)]) weak = YES;
    if (!weak) {
        const char *cn = class_getName(c);
        if (cn) {
            if (strstr(cn, "awemeBase") || strstr(cn, "AwemeBase")) {
                weak = YES;
            } else if ((strstr(cn, "Video") || strstr(cn, "video")) &&
                       (strstr(cn, "Detail") || strstr(cn, "Feed") ||
                        strstr(cn, "Player") || strstr(cn, "Base"))) {
                weak = YES;
            }
        }
    }
    if (!weak) return NO;

    // 聊天内嵌的视频页不处理（仅否决弱匹配，强匹配不受影响）
    // 用 method_getImplementation 直调，避免在 ARC 下强转 objc_msgSend
    Method m = class_getInstanceMethod(object_getClass(vc), @selector(isFromChat));
    if (m) {
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(m);
        @try {
            if (fn(vc, @selector(isFromChat))) return NO;
        } @catch (__unused NSException *e) {}
    }
    return YES;
}

#pragma mark - 隐藏清单解析（每个 root view 只做一次）

static void AFS_addIvarView(NSMutableArray *out, id obj, const char *iname) {
    Class c = object_getClass(obj);
    if (!c) return;
    Ivar iv = class_getInstanceVariable(c, iname);
    if (!iv) return;
    // 只读对象类型 ivar，避免对非对象 ivar 调 object_getIvar 拿到野指针
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return;
    id raw = nil;
    @try { raw = object_getIvar(obj, iv); } @catch (__unused NSException *e) { return; }
    if ([raw isKindOfClass:[UIView class]] && ![out containsObject:raw]) [out addObject:raw];
}

// 受限的子视图扫描：深度 <= 6、节点预算 <= 200。
// 刻意不用 [v.subviews copy]——旧版在每个节点都分配一个数组，是启动期的主要开销之一。
static void AFS_scanPattern(UIView *v, NSMutableArray *out, int depth, int *budget) {
    if (!v || depth > 6 || *budget <= 0) return;
    (*budget)--;
    const char *cn = class_getName(object_getClass(v));
    if (cn) {
        if (strstr(cn, "tabBar") || strstr(cn, "TabBar") ||
            strstr(cn, "blur")   || strstr(cn, "Blur")   ||
            strstr(cn, "progressSliderUnder")) {
            if (![out containsObject:v]) [out addObject:v];
        }
    }
    for (UIView *s in v.subviews) AFS_scanPattern(s, out, depth + 1, budget);
}

static NSArray *AFS_resolveHideList(UIViewController *vc, UIView *root) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:6];

    // 1) ivar 直读（最快，不触发 KVC）
    AFS_addIvarView(out, vc, "awe_tabBar");
    AFS_addIvarView(out, vc, "awe_blurView");
    AFS_addIvarView(out, vc, "progressSliderUnderView");

    // 2) 类名模式扫描兜底（有预算上限）
    int budget = 200;
    AFS_scanPattern(root, out, 0, &budget);

    // 3) tabBarController 的 tabBar
    UITabBarController *tbc = vc.tabBarController;
    if ([tbc isKindOfClass:[UITabBarController class]]) {
        UIView *tb = tbc.tabBar;
        if (tb && ![out containsObject:tb]) [out addObject:tb];
    }
    return out;
}

// 施加：隐藏清单 + 撑满 + 清背景
static void AFS_applyList(UIView *root, NSArray *list) {
    for (NSUInteger i = 0; i < list.count; i++) {
        UIView *v = list[i];
        if (!v.hidden) v.hidden = YES;
    }
    CGRect sf = gScreenBounds;
    if (!CGRectEqualToRect(root.frame, sf)) root.frame = sf;
    root.backgroundColor = [UIColor clearColor];
}

#pragma mark - Hook 1：UIViewController.viewDidLayoutSubviews（非热路径，可做完整逻辑）

static void (*o_afs_viewDidLayoutSubviews)(id, SEL);

static void afs_viewDidLayoutSubviews(id self, SEL _cmd) {
    // 红线：原 IMP 判空，绝不对空指针发消息（放行原实现，宁可功能失效不可卡死 App）
    if (o_afs_viewDidLayoutSubviews) o_afs_viewDidLayoutSubviews(self, _cmd);
    if (!gActive) return;

    Class c = object_getClass(self);
    NSNumber *verdict = objc_getAssociatedObject(c, kAFSClassVerdictKey);
    if (!verdict) {
        // 每个 Class 只做一次探测（ivar/selector/字符串都在这里，不在热路径）
        BOOL isVideo = AFS_probeVideoVC(self);
        verdict = isVideo ? @YES : @NO;
        objc_setAssociatedObject(c, kAFSClassVerdictKey, verdict,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!isVideo) return;
    } else if (!verdict.boolValue) {
        return;
    }

    UIViewController *vc = (UIViewController *)self;
    UIView *root = vc.view;                 // 直接属性，不走 KVC
    if (!root) return;

    gScreenBounds = [UIScreen mainScreen].bounds;   // 顺手刷新缓存
    AFS_watchAdd(root);

    NSArray *list = objc_getAssociatedObject(root, kAFSHideListKey);
    if (!list) {
        list = AFS_resolveHideList(vc, root);
        objc_setAssociatedObject(root, kAFSHideListKey, list,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    AFS_applyList(root, list);

    // 二次确认：**每个 root view 只排一次**。
    // 旧版是在每次 viewDidLayoutSubviews 都排一个 0.05s 的块，滚动/旋转时主队列会堆积。
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

#pragma mark - Hook 2：UIView.layoutSubviews（全 App 最热的方法之一，必须 O(1) 早退）

static void (*o_afs_layoutSubviews)(id, SEL);

static void afs_layoutSubviews(id self, SEL _cmd) {
    if (o_afs_layoutSubviews) o_afs_layoutSubviews(self, _cmd);
    // ↓↓↓ 热路径：只有 1 次 BOOL 判断 + 至多 8 次指针比较。
    //     不做 objc 调用、不做 KVC、不做字符串比较、不做任何分配。
    if (!gActive || gWatchCount == 0) return;

    void *p = (__bridge void *)self;
    int found = -1;
    for (int i = 0; i < gWatchCount; i++) {
        if (gWatch[i] == p) { found = i; break; }
    }
    if (found < 0) return;

    UIView *v = (UIView *)self;
    NSArray *list = objc_getAssociatedObject(v, kAFSHideListKey);
    if (!list) {
        // 视图被重建 / 指针地址被复用：从监视表移除，后续不再进入这里
        AFS_watchRemoveAt(found);
        return;
    }
    for (NSUInteger i = 0; i < list.count; i++) {
        UIView *t = list[i];
        if (!t.hidden) t.hidden = YES;
    }
    CGRect sf = gScreenBounds;
    if (!CGRectIsEmpty(sf) && !CGRectEqualToRect(v.frame, sf)) v.frame = sf;
}

#pragma mark - 安装

static void AFS_swizzle(Class c, SEL sel, IMP newImp, IMP *orig) {
    if (!c || !sel || !newImp) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;              // 重复安装保护
    if (orig) *orig = cur;
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void AFS_init(void) {
    @try {
        gIsAweme = AFS_detectAweme();
        if (!gIsAweme) return;
        // 注意：此处刻意不碰 [UIScreen mainScreen]（构造期 UIApplication 可能未就绪），
        // gScreenBounds 会在第一次 viewDidLayoutSubviews 时填充。
        AFS_reload();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, AFS_notifyCb, (__bridge CFStringRef)kAFSNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        AFS_swizzle([UIViewController class], @selector(viewDidLayoutSubviews),
                    (IMP)afs_viewDidLayoutSubviews, (IMP *)&o_afs_viewDidLayoutSubviews);
        AFS_swizzle([UIView class], @selector(layoutSubviews),
                    (IMP)afs_layoutSubviews, (IMP *)&o_afs_layoutSubviews);

        NSLog(@"[AwemeFullScreen] v2.0.0 installed in %@ "
              @"(pure runtime / no Substrate / no on-screen text, active=%d)",
              [[NSBundle mainBundle] bundleIdentifier], gActive);
    } @catch (NSException *e) {
        NSLog(@"[AwemeFullScreen] install failed (app unaffected): %@", e);
    }
}
