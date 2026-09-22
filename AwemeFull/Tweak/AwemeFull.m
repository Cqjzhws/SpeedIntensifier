// AwemeFull — 抖音(Aweme) 全屏插件 v1.0.0
// 由 AwemeFullScreen.dylib 重制：纯 ObjC runtime swizzle (无 CydiaSubstrate，
// TrollFools 友好)，针对最新版抖音增强兼容性：
//   · 多候选类名查找 awemeBaseViewController (应对最新版改名)
//   · Ivar 直读 + KVC 兜底读取 awe_tabBar / awe_blurView
//   · swizzle viewDidLayoutSubviews + setFrame: 隐藏底部栏并撑满屏幕
//   · Darwin 通知热重载（可选 plist 开关；无配置 App 时默认全屏生效）
//   · 仅在 com.ss.iphone.aweme (及关联版本) 进程内激活
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#define kPrefPath    @"/var/Managed Preferences/mobile/com.local.awemefull.plist"
#define kNotifyName  @"com.local.awemefull.settingschanged"
#define kAwemeBundle @"com.ss.iphone.aweme"

// ---------- 配置 ----------
static BOOL gEnabled    = YES;  // 总开关（无配置文件时默认全屏生效）
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
    dispatch_once(&once, ^{
        bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    });
    if ([bid isEqualToString:kAwemeBundle]) return YES;
    if ([bid containsString:@"aweme"] || [bid hasPrefix:@"com.ss.iphone.aweme"]) return YES;
    return NO;
}

// ---------- swizzle 工具 ----------
static void AMF_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - 全屏模块

// 多候选类名：抖音各版本间 awemeBaseViewController 可能改名
static Class AMF_findBaseVCClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *names[] = {
            "awemeBaseViewController",
            "AwemeBaseViewController",
            "AWEBaseViewController",
            "AWEBaseVideoViewController",
            "AwemeVideoViewController",
            "AWEHomeVideoController",
            "awemeBaseVideoViewController",
            "AwemeFeedVideoViewController",
            0
        };
        for (int i = 0; names[i]; i++) {
            Class c = objc_getClass(names[i]);
            if (c) { cls = c; break; }
        }
    });
    return cls;
}

// Ivar 直读 + KVC 兜底
static UIView *AMF_getIvarView(id obj, const char *iname, NSString *kname) {
    if (!obj) return nil;
    UIView *v = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), iname);
    if (iv) {
        id raw = object_getIvar(obj, iv);
        if ([raw isKindOfClass:[UIView class]]) v = raw;
    }
    if (!v && kname) {
        @try {
            id raw = [obj valueForKey:kname];
            if ([raw isKindOfClass:[UIView class]]) v = raw;
        } @catch (NSException *e) { v = nil; }
    }
    return v;
}

static void (*o_AMF_viewDidLayoutSubviews)(id, SEL);
static void amf_viewDidLayoutSubviews(id self, SEL _cmd) {
    o_AMF_viewDidLayoutSubviews(self, _cmd);
    if (!gEnabled || !gFullScreen || !AMF_isAweme()) return;
    // 隐藏底部 tab + 毛玻璃，让视频铺满
    UIView *tb = AMF_getIvarView(self, "awe_tabBar", @"awe_tabBar");
    UIView *bv = AMF_getIvarView(self, "awe_blurView", @"awe_blurView");
    if (tb && !tb.isHidden) tb.hidden = YES;
    if (bv && !bv.isHidden) bv.hidden = YES;
    // 撑满屏幕
    @try {
        UIView *v = [self valueForKey:@"view"];
        if ([v isKindOfClass:[UIView class]]) {
            CGRect sf = [UIScreen mainScreen].bounds;
            if (!CGRectEqualToRect(v.frame, sf)) v.frame = sf;
        }
    } @catch (NSException *e) {}
}

static void (*o_AMF_setFrame)(id, SEL, CGRect);
static void amf_setFrame(id self, SEL _cmd, CGRect f) {
    if (gEnabled && gFullScreen && AMF_isAweme()) {
        f = [UIScreen mainScreen].bounds;
    }
    o_AMF_setFrame(self, _cmd, f);
}

static void AMF_installFullScreen(void) {
    Class c = AMF_findBaseVCClass();
    if (!c) {
        NSLog(@"[AwemeFull] awemeBaseViewController not found, fullscreen disabled");
        return;
    }
    AMF_swizzleInstance(c, @selector(viewDidLayoutSubviews),
                        (IMP)amf_viewDidLayoutSubviews, (IMP *)&o_AMF_viewDidLayoutSubviews);
    // setFrame: 仅当类实现该方法时 swizzle（某些版本有自定义 setFrame:）
    AMF_swizzleInstance(c, @selector(setFrame:),
                        (IMP)amf_setFrame, (IMP *)&o_AMF_setFrame);
    NSLog(@"[AwemeFull] fullscreen installed on %s", class_getName(c));
}

#pragma mark - 入口

static void __attribute__((constructor)) AMF_init(void) {
    if (!AMF_isAweme()) return;  // 仅抖音进程内激活
    AMF_reload();
    // Darwin 通知热重载（可选开关）
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, AMF_notifyCb, (__bridge CFStringRef)kNotifyName, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    AMF_installFullScreen();
    NSLog(@"[AwemeFull v1.0.0] init OK (bundle %@)",
          [[NSBundle mainBundle] bundleIdentifier]);
}
