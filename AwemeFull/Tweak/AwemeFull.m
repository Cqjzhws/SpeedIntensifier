// AwemeFull — 抖音(Aweme) 全屏插件 v1.1.0
// 类名无关重制版：不依赖 awemeBaseViewController 具体类名。
//   · hook 基类 UIViewController 的 viewDidLayoutSubviews（catch 所有 VC）
//   · 运行时检测：ivar awe_tabBar/awe_blurView 存在 OR 响应
//     isFromGeneralSearchOrVideoSearch OR 类名匹配 Video/Feed/Detail 模式
//   · 多路隐藏 tabbar/blur：Ivar 直读 + KVC 兜底 + 子视图遍历（按类名模式）
//   · 撑满 self.view 到屏幕 bounds + 背景 clearColor
//   · dispatch_async 二次确认，防止抖音自身布局重置
//   · 纯 ObjC runtime swizzle (无 CydiaSubstrate)，仅 com.ss.iphone.aweme 激活
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <string.h>

#define kPrefPath    @"/var/Managed Preferences/mobile/com.local.awemefull.plist"
#define kNotifyName  @"com.local.awemefull.settingschanged"
#define kAwemeBundle @"com.ss.iphone.aweme"

static BOOL gEnabled    = YES;
static BOOL gFullScreen = YES;

static void AMF_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) return;
    gEnabled    = d[@"Enabled"]    ? [d[@"Enabled"] boolValue]    : YES;
    gFullScreen = d[@"FullScreen"] ? [d[@"FullScreen"] boolValue] : YES;
}

static void AMF_notifyCb(CFNotificationCenterRef c, void *o, CFNotificationName n,
                         const void *obj, CFDictionaryRef info) { AMF_reload(); }

static BOOL AMF_isAweme(void) {
    static NSString *bid = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bid = [[NSBundle mainBundle] bundleIdentifier] ?: @""; });
    if ([bid isEqualToString:kAwemeBundle]) return YES;
    if ([bid containsString:@"aweme"] || [bid hasPrefix:@"com.ss.iphone.aweme"]) return YES;
    return NO;
}

#pragma mark - 视频VC检测（类名无关）

static BOOL AMF_isVideoVC(id self) {
    Class c = object_getClass(self);
    if (!c) return NO;
    // 1) ivar 存在性（最快，抖音视频VC有 awe_tabBar/awe_blurView ivar）
    if (class_getInstanceVariable(c, "awe_tabBar"))    return YES;
    if (class_getInstanceVariable(c, "awe_blurView")) return YES;
    // 2) 抖音专属 selector 响应
    if ([self respondsToSelector:@selector(isFromGeneralSearchOrVideoSearch)]) return YES;
    // 3) 类名模式匹配（兼容改名后的视频VC）
    const char *cn = class_getName(c);
    if (cn) {
        if (strstr(cn, "awemeBase") || strstr(cn, "AwemeBase") || strstr(cn, "AWEBase")) return YES;
        if ((strstr(cn, "Video") || strstr(cn, "video")) &&
            (strstr(cn, "Detail") || strstr(cn, "Feed") || strstr(cn, "Base") ||
             strstr(cn, "Player") || strstr(cn, "Controller"))) return YES;
    }
    return NO;
}

#pragma mark - 隐藏 tabbar/blur（多路兜底）

// 递归遍历子视图，隐藏类名匹配 tabBar/blur 的视图
static void AMF_hideByPattern(UIView *v, int depth) {
    if (!v || depth > 6) return;
    const char *cn = class_getName(object_getClass(v));
    if (cn) {
        if (strstr(cn, "tabBar") || strstr(cn, "TabBar") || strstr(cn, "tabbar") ||
            strstr(cn, "blur")  || strstr(cn, "Blur")  || strstr(cn, "BlurView")) {
            if (!v.isHidden) v.hidden = YES;
        }
    }
    // 遍历子视图（拷贝防止并发修改）
    NSArray *subs = [v.subviews copy];
    for (UIView *s in subs) AMF_hideByPattern(s, depth + 1);
}

static UIView *AMF_getIvarView(id obj, const char *iname, NSString *kname) {
    if (!obj) return nil;
    UIView *v = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), iname);
    if (iv) {
        id raw = object_getIvar(obj, iv);
        if ([raw isKindOfClass:[UIView class]]) v = raw;
    }
    if (!v && kname) {
        @try { id raw = [obj valueForKey:kname];
               if ([raw isKindOfClass:[UIView class]]) v = raw; }
        @catch (NSException *e) { v = nil; }
    }
    return v;
}

static void AMF_applyFullScreen(id self) {
    if (!gEnabled || !gFullScreen || !AMF_isAweme()) return;
    // 1) ivar + KVC 隐藏 tabbar/blur
    UIView *tb = AMF_getIvarView(self, "awe_tabBar", @"awe_tabBar");
    UIView *bv = AMF_getIvarView(self, "awe_blurView", @"awe_blurView");
    if (tb && !tb.isHidden) tb.hidden = YES;
    if (bv && !bv.isHidden) bv.hidden = YES;
    // 2) 子视图遍历兜底（按类名模式）
    UIView *v = nil;
    @try { v = [self valueForKey:@"view"]; } @catch (NSException *e) { v = nil; }
    if (![v isKindOfClass:[UIView class]]) return;
    AMF_hideByPattern(v, 0);
    // 3) 撑满屏幕 + 清背景
    CGRect sf = [UIScreen mainScreen].bounds;
    if (!CGRectEqualToRect(v.frame, sf)) v.frame = sf;
    @try { [v setBackgroundColor:[UIColor clearColor]]; } @catch (NSException *e) {}
    // 4) tabBarController 的 tabBar 也隐藏
    @try {
        id tbc = [self valueForKey:@"tabBarController"];
        if ([tbc isKindOfClass:[UIViewController class]]) {
            UIView *tb2 = [tbc performSelector:@selector(tabBar)];
            if ([tb2 isKindOfClass:[UIView class]] && !tb2.isHidden) tb2.hidden = YES;
        }
    } @catch (NSException *e) {}
}

#pragma mark - swizzle

static void (*o_AMF_viewDidLayoutSubviews)(id, SEL);
static void amf_viewDidLayoutSubviews(id self, SEL _cmd) {
    o_AMF_viewDidLayoutSubviews(self, _cmd);
    if (!gEnabled || !gFullScreen || !AMF_isAweme()) return;
    if (!AMF_isVideoVC(self)) return;  // 非视频VC跳过
    AMF_applyFullScreen(self);
    // 二次确认：防止抖音自身布局在之后重置
    __weak id ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id s = ws; if (s) AMF_applyFullScreen(s);
    });
}

// 额外 hook UIView layoutSubviews：当 self 是视频VC的view时撑满
// （原版也 hook layoutSubviews，覆盖抖音在 view 布局阶段重置 frame 的情况）
static void (*o_AMF_layoutSubviews)(id, SEL);
static void amf_layoutSubviews(id self, SEL _cmd) {
    o_AMF_layoutSubviews(self, _cmd);
    if (!gEnabled || !gFullScreen || !AMF_isAweme()) return;
    // 仅当此 view 的 viewController 是视频VC时处理
    @try {
        id vc = [self valueForKey:@"viewController"];  // 私有，抖音视图常有
        if (vc && AMF_isVideoVC(vc)) {
            CGRect sf = [UIScreen mainScreen].bounds;
            if (!CGRectEqualToRect(((UIView *)self).frame, sf))
                ((UIView *)self).frame = sf;
        }
    } @catch (NSException *e) {}
}

static void AMF_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

static void AMF_install(void) {
    // 基类 hook：UIViewController.viewDidLayoutSubviews（catch 所有视频VC，类名无关）
    AMF_swizzleInstance([UIViewController class], @selector(viewDidLayoutSubviews),
                        (IMP)amf_viewDidLayoutSubviews, (IMP *)&o_AMF_viewDidLayoutSubviews);
    // 基类 hook：UIView.layoutSubviews（覆盖抖音布局阶段重置）
    AMF_swizzleInstance([UIView class], @selector(layoutSubviews),
                        (IMP)amf_layoutSubviews, (IMP *)&o_AMF_layoutSubviews);
    NSLog(@"[AwemeFull v1.1.0] hooks installed (base-class, name-agnostic)");
}

#pragma mark - 入口

static void __attribute__((constructor)) AMF_init(void) {
    if (!AMF_isAweme()) return;
    AMF_reload();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, AMF_notifyCb, (__bridge CFStringRef)kNotifyName, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    AMF_install();
    NSLog(@"[AwemeFull v1.1.0] init OK (bundle %@)",
          [[NSBundle mainBundle] bundleIdentifier]);
}
