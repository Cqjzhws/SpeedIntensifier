// SIClassic — Speed Intensifier (pw5a29) 的 iOS 16 TrollStore 移植版
// 原版：Speed Intensifier 10.1-1 by pw5a29 (BigBoss/ModMyi, 免费包)
// 逆向结论：原版全局加速的核心只有 CAAnimation -setDuration: 一个 hook
//   （UIView/系统动画底层几乎都生成 CAAnimation），外加 CASpringAnimation 的
//   弹簧参数 hook（mass/damping/stiffness）实现 "Spring/Fusion" 平滑模式；
//   其余 SBIcon/SBAppSwitcher/SBControlCenter/SBHUD 等全部是 SpringBoard
//   私有类 hook —— TrollStore 环境无法注入 SpringBoard，这些类在普通 App
//   进程里不存在，按类存在性安装时会自动跳过。
//
// 本移植版相对原版的更改：
//   · 去 CydiaSubstrate/MSHookMessageEx，改纯 ObjC runtime method swizzling
//   · arm64 only，clang 直编，TrollFools 可直接注入
//   · 配置改到 /var/Managed Preferences（注入任意 App 均可读），保留原版
//     Darwin 通知热重载机制（改配置杀 App 重开即生效，不用重新注入）
//   · 倍率档语义沿用原版 duration 系数：newDuration = orig / multiplier
//   · 弹簧平滑（原版 Spring/Fusion 思想）自动推导：物理上要把弹簧动画
//     缩短 m 倍且保持阻尼比不变，需 stiffness *= m²、damping *= m、mass 不变
//   · 增强 1 个 CATransaction +setAnimationDuration:（覆盖 duration=0 走
//     事务默认时长的隐式动画，SpeedIntensifier/SpeedsterTS 长期验证安全）
//   · 刻意不 hook 任何 UITableView/UICollectionView 选择/刷新/移动方法
//     （那类 hook 已证实会导致微信点链接闪退）
//
// 总 4 hooks。极简即极稳。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kSICPrefPath = @"/var/Managed Preferences/mobile/com.local.siclassic.plist";
static NSString *const kSICNotify   = @"com.local.siclassic.settingschanged";

static BOOL    gEnabled = YES;
static double  gMult = 5.0;          // 速度倍率：动画时长 / gMult
static BOOL    gInstant = NO;        // 瞬切（原版 unlimited）
static BOOL    gSpring = YES;        // 弹簧平滑（Spring/Fusion）
static BOOL    gBlacklisted = NO;
static NSArray *gBlacklist = nil;

static double _factor(void) {
    if (!gEnabled || gBlacklisted) return 1.0;
    if (gInstant) return 0.0001;
    if (gMult <= 0.0) return 1.0;
    return 1.0 / gMult;
}

static void _loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kSICPrefPath];
        if (d) {
            if (d[@"Enabled"])    gEnabled = [d[@"Enabled"] boolValue];
            if (d[@"Multiplier"]) gMult = [d[@"Multiplier"] doubleValue];
            if (d[@"Instant"])    gInstant = [d[@"Instant"] boolValue];
            if (d[@"Spring"])     gSpring = [d[@"Spring"] boolValue];
            gBlacklist = d[@"Blacklist"];
        }
    } @catch (__unused NSException *e) {}
    if (gMult < 1.0) gMult = 1.0;
    if (gMult > 100.0) gMult = 100.0;
    if (!gBlacklist) gBlacklist = @[ @"com.tencent.wework" ];

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gBlacklist) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) {
            gBlacklisted = YES; break;
        }
    }
}

// ---------------- swizzle 桥接（同 SpeedIntensifier 成熟模式） ----------------
static BOOL _swizzleInstance(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getInstanceMethod(cls, orig);
    Method rm = class_getInstanceMethod(objc_getClass("SIClassicTweak"), repl);
    if (!om || !rm) return NO;
    IMP ri = method_getImplementation(rm);
    const char *types = method_getTypeEncoding(rm);
    if (!class_addMethod(cls, repl, ri, types)) {
        Method ex = class_getInstanceMethod(cls, repl);
        if (ex) { method_exchangeImplementations(om, ex); return YES; }
        return NO;
    }
    Method r2 = class_getInstanceMethod(cls, repl);
    method_exchangeImplementations(om, r2);
    return YES;
}

static BOOL _swizzleClass(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getClassMethod(cls, orig);
    Method rm = class_getClassMethod(objc_getClass("SIClassicTweak"), repl);
    if (!om || !rm) return NO;
    IMP ri = method_getImplementation(rm);
    const char *types = method_getTypeEncoding(rm);
    Class meta = object_getClass(cls);
    if (!class_addMethod(meta, repl, ri, types)) {
        Method ex = class_getClassMethod(cls, repl);
        if (ex) { method_exchangeImplementations(om, ex); return YES; }
        return NO;
    }
    Method r2 = class_getClassMethod(cls, repl);
    method_exchangeImplementations(om, r2);
    return YES;
}

@interface SIClassicTweak : NSObject
@end

@implementation SIClassicTweak

// ① 原版核心：CAAnimation -setDuration:
- (void)sic_setDuration:(CFTimeInterval)d {
    double f = _factor();
    if (f == 1.0 || d <= 0.0) {
        [self sic_setDuration:d];
        return;
    }
    CFTimeInterval nd = d * f;
    if (gInstant && nd > 0.0) nd = 0.0001;   // 不给 0，避免动画被跳过致回调丢失
    [self sic_setDuration:nd];
}

// ② 弹簧平滑：stiffness *= m²（缩短 settle 时间到 1/m，阻尼比不变）
- (void)sic_setStiffness:(CGFloat)v {
    if (gEnabled && !gBlacklisted && gSpring && !gInstant && gMult > 1.0 && v > 0.0) {
        CGFloat k = v * (CGFloat)(gMult * gMult);
        // 单值钳制，防极端参数下弹簧数值爆炸（系统级动画 stiffness 通常 100~1000）
        if (k > 1.0e5f) k = 1.0e5f;
        [self sic_setStiffness:k];
    } else {
        [self sic_setStiffness:v];
    }
}

// ③ 弹簧平滑：damping *= m
- (void)sic_setDamping:(CGFloat)v {
    if (gEnabled && !gBlacklisted && gSpring && !gInstant && gMult > 1.0 && v > 0.0) {
        CGFloat c = v * (CGFloat)gMult;
        if (c > 1.0e5f) c = 1.0e5f;
        [self sic_setDamping:c];
    } else {
        [self sic_setDamping:v];
    }
}

// 瞬切档下弹簧也压到极短：直接把 mass 压小（仅 instant，开关式、无推导风险）
- (void)sic_setMass:(CGFloat)v {
    if (gEnabled && !gBlacklisted && gSpring && gInstant && v > 0.0) {
        [self sic_setMass:0.0001f];
    } else {
        [self sic_setMass:v];
    }
}

// ④ 增强：CATransaction 默认时长（覆盖 duration=0 的隐式动画）
+ (void)sic_setAnimationDuration:(CFTimeInterval)d {
    double f = _factor();
    if (f == 1.0 || d <= 0.0) {
        [self sic_setAnimationDuration:d];
        return;
    }
    CFTimeInterval nd = d * f;
    if (gInstant && nd > 0.0) nd = 0.0001;
    [self sic_setAnimationDuration:nd];
}

@end

static void _install(void) {
    int total = 0, ok = 0;
    Class ca = objc_getClass("CAAnimation");
    Class spring = objc_getClass("CASpringAnimation");
    Class tx = objc_getClass("CATransaction");

    total++; ok += _swizzleInstance(ca, @selector(setDuration:), @selector(sic_setDuration:));
    if (spring) {
        total++; ok += _swizzleInstance(spring, @selector(setStiffness:), @selector(sic_setStiffness:));
        total++; ok += _swizzleInstance(spring, @selector(setDamping:), @selector(sic_setDamping:));
        total++; ok += _swizzleInstance(spring, @selector(setMass:), @selector(sic_setMass:));
    }
    total++; ok += _swizzleClass(tx, @selector(setAnimationDuration:), @selector(sic_setAnimationDuration:));

    NSLog(@"[SIClassic] hooks %d/%d enabled=%d mult=%.1f instant=%d spring=%d blacklisted=%d",
          ok, total, gEnabled, gMult, gInstant, gSpring, gBlacklisted);
}

__attribute__((constructor))
static void _sic_entry(void) {
    _loadPref();
    _install();
    // 原版机制：Darwin 通知热重载配置
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)^(CFNotificationCenterRef c, void *observer, CFStringName name, const void *object, CFDictionaryRef info) {
            _loadPref();
            NSLog(@"[SIClassic] pref reloaded via darwin notify");
        },
        (__bridge CFStringRef)kSICNotify, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
