//
//  HighFPSMax.m — 纯 runtime swizzle 实现的高刷新率强制（无 CydiaSubstrate 依赖）
//  基于 CAHighFPS (com.ps.coreanimationhighfps) 机制增强重制
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

#define kPrefPath  @"/var/Managed Preferences/mobile/com.local.highfpsmax.plist"
#define kNotifyKey @"com.local.highfpsmax.reload"

#pragma mark - 配置
static BOOL       gEnabled = YES;
static NSInteger  gRefreshRate = 120;
static BOOL       gMetalTripleBuffer = YES;
static NSArray   *gBlacklist = nil;
static NSString  *gSelfBundle = nil;

static NSDictionary *ReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (d) return d;
    return @{ @"enabled": @YES, @"refreshRate": @(120), @"metalTriple": @YES, @"blacklist": @[] };
}

static void LoadConfig(void) {
    NSDictionary *d = ReadConfig();
    gEnabled = [d[@"enabled"] boolValue];
    gRefreshRate = [d[@"refreshRate"] integerValue];
    if (gRefreshRate <= 0) gRefreshRate = 120;
    gMetalTripleBuffer = [d[@"metalTriple"] boolValue];
    NSArray *bl = d[@"blacklist"];
    gBlacklist = [bl isKindOfClass:[NSArray class]] ? bl : @[];
}

static BOOL IsBlocked(void) {
    if (!gSelfBundle) return NO;
    for (NSString *b in gBlacklist) {
        if ([b isKindOfClass:[NSString class]] && [gSelfBundle isEqualToString:b]) return YES;
    }
    return NO;
}

#pragma mark - Swizzle 辅助
static void HF_Swizzle(Class cls, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - UIScreen maximumFramesPerSecond
static NSInteger (*orig_maxFPS)(id, SEL) = NULL;
static NSInteger hf_maxFPS(id self, SEL _cmd) {
    if (!gEnabled || IsBlocked()) return orig_maxFPS(self, _cmd);
    return gRefreshRate;
}

#pragma mark - CADisplayLink setFrameInterval:
static void (*orig_setFrameInterval)(id, SEL, NSInteger) = NULL;
static void hf_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    if (!gEnabled || IsBlocked()) { orig_setFrameInterval(self, _cmd, interval); return; }
    orig_setFrameInterval(self, _cmd, 1);
}

#pragma mark - CADisplayLink setPreferredFramesPerSecond:
static void (*orig_setPreferredFPS)(id, SEL, NSInteger) = NULL;
static void hf_setPreferredFPS(id self, SEL _cmd, NSInteger fps) {
    if (!gEnabled || IsBlocked()) { orig_setPreferredFPS(self, _cmd, fps); return; }
    orig_setPreferredFPS(self, _cmd, gRefreshRate);
}

#pragma mark - CADisplayLink setPreferredFrameRateRange: (iOS 15+)
// preferredFrameRateRange 是 CAFrameRateRange 结构体：minimum/maximum/preferred
typedef struct { float minimum; float maximum; float preferred; } HFFrameRateRange;
static void (*orig_setPreferredRange)(id, SEL, HFFrameRateRange) = NULL;
static void hf_setPreferredRange(id self, SEL _cmd, HFFrameRateRange range) {
    if (!gEnabled || IsBlocked()) { orig_setPreferredRange(self, _cmd, range); return; }
    HFFrameRateRange r;
    r.minimum = 60;
    r.maximum = gRefreshRate;
    r.preferred = gRefreshRate;
    orig_setPreferredRange(self, _cmd, r);
}

#pragma mark - CAMetalLayer setMaximumDrawableCount:
static void (*orig_setMaxDrawable)(id, SEL, NSUInteger) = NULL;
static void hf_setMaxDrawable(id self, SEL _cmd, NSUInteger count) {
    if (!gEnabled || !gMetalTripleBuffer || IsBlocked()) { orig_setMaxDrawable(self, _cmd, count); return; }
    orig_setMaxDrawable(self, _cmd, 3);
}

#pragma mark - Darwin 通知热重载
static void HFReloadCallback(CFNotificationCenterRef c, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    LoadConfig();
}

__attribute__((constructor))
static void HighFPSMaxInit(void) {
    @autoreleasepool {
        gSelfBundle = [[NSBundle mainBundle] bundleIdentifier];
        // 排除 appex（不处理 extension）
        if ([gSelfBundle containsString:@"appex"]) return;
        // 排除 SpringBoard 本身
        if ([gSelfBundle isEqualToString:@"com.apple.springboard"]) return;

        LoadConfig();

        // UIScreen maximumFramesPerSecond
        Class screenCls = [UIScreen class];
        SEL maxSel = @selector(maximumFramesPerSecond);
        Method m = class_getInstanceMethod(screenCls, maxSel);
        if (m) {
            orig_maxFPS = (typeof(orig_maxFPS))method_getImplementation(m);
            class_replaceMethod(screenCls, maxSel, (IMP)hf_maxFPS, method_getTypeEncoding(m));
        }

        // CADisplayLink hooks
        Class dlCls = NSClassFromString(@"CADisplayLink");
        if (dlCls) {
            SEL s1 = @selector(setFrameInterval:);
            Method m1 = class_getInstanceMethod(dlCls, s1);
            if (m1) {
                orig_setFrameInterval = (typeof(orig_setFrameInterval))method_getImplementation(m1);
                class_replaceMethod(dlCls, s1, (IMP)hf_setFrameInterval, method_getTypeEncoding(m1));
            }
            SEL s2 = @selector(setPreferredFramesPerSecond:);
            Method m2 = class_getInstanceMethod(dlCls, s2);
            if (m2) {
                orig_setPreferredFPS = (typeof(orig_setPreferredFPS))method_getImplementation(m2);
                class_replaceMethod(dlCls, s2, (IMP)hf_setPreferredFPS, method_getTypeEncoding(m2));
            }
            // iOS 15+ setPreferredFrameRateRange:
            SEL s3 = NSSelectorFromString(@"setPreferredFrameRateRange:");
            Method m3 = class_getInstanceMethod(dlCls, s3);
            if (m3) {
                orig_setPreferredRange = (typeof(orig_setPreferredRange))method_getImplementation(m3);
                class_replaceMethod(dlCls, s3, (IMP)hf_setPreferredRange, method_getTypeEncoding(m3));
            }
        }

        // CAMetalLayer 三缓冲
        Class mlCls = NSClassFromString(@"CAMetalLayer");
        if (mlCls) {
            SEL s4 = @selector(setMaximumDrawableCount:);
            Method m4 = class_getInstanceMethod(mlCls, s4);
            if (m4) {
                orig_setMaxDrawable = (typeof(orig_setMaxDrawable))method_getImplementation(m4);
                class_replaceMethod(mlCls, s4, (IMP)hf_setMaxDrawable, method_getTypeEncoding(m4));
            }
        }

        // Darwin 通知热重载
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, HFReloadCallback, (__bridge CFStringRef)kNotifyKey, NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    }
}
