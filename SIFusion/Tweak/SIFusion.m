// SIFusion v2.0.0 Max — 终极融合版（SIClassic × SpeedsterTS × SpeedIntensifier 三方并集）
// 纯 ObjC runtime，无 substrate。TrollStore / TrollFools 注入任意数据卷 App 即可生效。
//
// 三方 hook 并集（去重后 ~68 hooks）：
//   · SpeedsterTS v1.1.1 独立模式 15 hooks（UIView block×4 / CAAnimation / CALayer addAnimation /
//     CATransaction / Nav push·pop×3 / present·dismiss）——微信实测不闪退
//   · SIClassic v1.0.2 独有 CASpringAnimation 弹簧物理四件套（stiffness/damping/mass/velocity）
//   · SpeedIntensifier v1.6.1 额外 45+ hooks：UIPA 全族 / UIWindow / 交互式转场 /
//     上下文菜单 / Tab 直选 / PageVC 翻页 / UISV 缩放 / 三类栏 setItems / 控件 /
//     CALayer actionForKey 隐式动画瞬时化 / CAPropertyAnimation 二级链 /
//     TV/CV 列表变异（selectRow/deselect/reloadSections/setEditing/moveRow 等）
//
// 关键安全设计：
//   · TV/CV 列表类 hook（微信闪退根因族）全部独立由 ListAccel 开关控制，默认 OFF。
//     微信用户保持关闭即可；其他 App 用户开启后获得完整列表动画加速。
//   · 其余 49 个 hook 均为非列表类，跟随 Enabled 开关，微信安全。
//   · CAAnimation 只 hook 基类 setDuration:；addAnimation 用 associated-object 标记防二次缩放。
//   · 共存检测：进程内已加载其他加速器时只装弹簧层（互补）。
//   · v1.1.0 高级模式（Speedy 式独立倍率）+ v1.2.0 层时钟叠加 保留。
//
// 配置：/var/Managed Preferences/mobile/com.local.sifusion.plist
//   Enabled / Preset(0-4) / Spring / Blacklist
//   Advanced / DurMult / VelMult / StiffMult / DampMult / MassMult / LayerSpeed
//   ListAccel（列表类 hook 开关，默认关）
// Darwin 通知 com.local.sifusion.settingschanged 热重载。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

static NSString *const kFUPrefPath = @"/var/Managed Preferences/mobile/com.local.sifusion.plist";
static NSString *const kFUNotify   = @"com.local.sifusion.settingschanged";

static BOOL    gEnabled = YES;
static int     gPreset = 2;            // 0微快 1快 2很快(默认) 3极快 4瞬切
static BOOL    gSpring = YES;          // 弹簧物理平滑
static BOOL    gBlacklisted = NO;
static NSArray *gBlacklist = nil;
static BOOL    gCompanion = NO;        // 检测到其他加速器，互补模式
static BOOL    gFSTxInternal = NO;     // 自家 CATransaction 调用标记

// 高级模式（Speedy 式独立倍率）：开启后覆盖档位表与弹簧物理公式
static BOOL    gAdvanced = NO;
static double  gDurMult   = 0.15;      // 持续时间倍数
static double  gVelMult   = 1.0;       // 初始速率倍数（setVelocity:）
static double  gStiffMult = 1.0;       // 刚性倍数
static double  gDampMult  = 1.0;       // 阻尼倍数
static double  gMassMult  = 1.0;       // 质量倍数
static BOOL    gLayerSpeed = NO;       // 层时钟叠加（实验，默认关）
static BOOL    gListAccel = NO;        // 列表类 hook（TV/CV 变异，默认关，微信安全）

// 档位 → 时长乘数（SpeedsterTS 实测数值）
static const double kDurFactors[5] = { 0.50, 0.30, 0.15, 0.05, 0.001 };

static inline double _factor(void) {
    if (gAdvanced) {
        double f = gDurMult;
        return (f < 0.001) ? 0.001 : (f > 1.0 ? 1.0 : f);
    }
    return kDurFactors[MAX(0, MIN(4, gPreset))];
}
static inline double _mult(void) {
    double f = _factor();
    return f > 0.0 ? 1.0 / f : 10000.0;
}
static inline BOOL _on(void) { return gEnabled && !gBlacklisted && !gCompanion; }
// 列表类 hook（TV/CV 选择/刷新/移动/编辑）：微信闪退根因族，独立开关默认关
static inline BOOL _listOn(void) { return _on() && gListAccel; }

static inline NSTimeInterval _scale(NSTimeInterval t) {
    if (t <= 0) return t;
    NSTimeInterval s = t * _factor();
    return (s < 0.016 && s > 0) ? 0.016 : s;
}
static inline NSTimeInterval _scaleMin(NSTimeInterval t, double minMs) {
    if (t <= 0) return t;
    NSTimeInterval s = t * _factor();
    NSTimeInterval mn = minMs / 1000.0;
    return s < mn ? mn : s;
}

static inline BOOL _isBlurKey(NSString *k) {
    static NSArray *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[ @"backdrop", @"visualeffect", @"blur", @"gaussian", @"snapshot" ];
    });
    NSString *low = k.lowercaseString;
    for (NSString *b in bad) if ([low containsString:b]) return YES;
    return NO;
}

static void _loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kFUPrefPath];
        if (d) {
            if (d[@"Enabled"])  gEnabled = [d[@"Enabled"] boolValue];
            if (d[@"Preset"])   gPreset = MAX(0, MIN(4, [d[@"Preset"] intValue]));
            if (d[@"Spring"])   gSpring = [d[@"Spring"] boolValue];
            if (d[@"Advanced"]) gAdvanced = [d[@"Advanced"] boolValue];
            double dv;
            if ((dv = [d[@"DurMult"] doubleValue])   > 0) gDurMult   = dv;
            if ((dv = [d[@"VelMult"] doubleValue])   > 0) gVelMult   = dv;
            if ((dv = [d[@"StiffMult"] doubleValue]) > 0) gStiffMult = dv;
            if ((dv = [d[@"DampMult"] doubleValue])  > 0) gDampMult  = dv;
            if ((dv = [d[@"MassMult"] doubleValue])  > 0) gMassMult  = dv;
            if (d[@"LayerSpeed"]) gLayerSpeed = [d[@"LayerSpeed"] boolValue];
            if (d[@"ListAccel"])  gListAccel  = [d[@"ListAccel"] boolValue];
            gBlacklist = d[@"Blacklist"];
        }
    } @catch (__unused NSException *e) {}
    if (!gBlacklist) gBlacklist = @[ @"com.tencent.wework" ];

    gBlacklisted = NO;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gBlacklist) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) {
            gBlacklisted = YES; break;
        }
    }
}

// ================================ Swizzle 桥接 ================================
static BOOL _swiz(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getInstanceMethod(cls, orig);
    Method rm = class_getInstanceMethod(objc_getClass("SIFusionHooks"), repl);
    if (!om || !rm) return NO;
    if (!class_addMethod(cls, repl, method_getImplementation(rm), method_getTypeEncoding(rm))) {
        Method e = class_getInstanceMethod(cls, repl);
        if (!e) return NO;
        method_exchangeImplementations(om, e);
        return YES;
    }
    method_exchangeImplementations(om, class_getInstanceMethod(cls, repl));
    return YES;
}
static BOOL _swizClass(Class cls, SEL orig, SEL repl) {
    if (!cls) return NO;
    Method om = class_getClassMethod(cls, orig);
    Method rm = class_getClassMethod(objc_getClass("SIFusionHooks"), repl);
    if (!om || !rm) return NO;
    Class meta = object_getClass(cls);
    if (!class_addMethod(meta, repl, method_getImplementation(rm), method_getTypeEncoding(rm))) {
        Method e = class_getClassMethod(cls, repl);
        if (!e) return NO;
        method_exchangeImplementations(om, e);
        return YES;
    }
    method_exchangeImplementations(om, class_getClassMethod(cls, repl));
    return YES;
}

static char kFUInternalDurKey;

@interface SIFusionHooks : NSObject
@end

@implementation SIFusionHooks

#pragma mark ---------- UIView 动画 block ×4 ----------
+ (void)fu_animate:(NSTimeInterval)d animations:(void (^)(void))a {
    [self fu_animate:_on() ? _scale(d) : d animations:a];
}
+ (void)fu_animate:(NSTimeInterval)d animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    [self fu_animate:_on() ? _scale(d) : d animations:a completion:c];
}
+ (void)fu_animate:(NSTimeInterval)d delay:(NSTimeInterval)dl options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_on()) {
        [self fu_animate:_scale(d) delay:dl * _factor() options:o animations:a completion:c];
    } else {
        [self fu_animate:d delay:dl options:o animations:a completion:c];
    }
}
+ (void)fu_animate:(NSTimeInterval)d delay:(NSTimeInterval)dl usingSpringWithDamping:(CGFloat)dr
 initialSpringVelocity:(CGFloat)v options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_on()) {
        [self fu_animate:_scale(d) delay:dl * _factor() usingSpringWithDamping:dr
       initialSpringVelocity:v options:o animations:a completion:c];
    } else {
        [self fu_animate:d delay:dl usingSpringWithDamping:dr initialSpringVelocity:v options:o
              animations:a completion:c];
    }
}

#pragma mark ---------- CAAnimation / CALayer / CATransaction ----------
- (void)fu_setDuration:(NSTimeInterval)t {
    if (_on()) {
        NSNumber *internal = objc_getAssociatedObject(self, &kFUInternalDurKey);
        if (internal.boolValue) { [self fu_setDuration:t]; return; }
        [self fu_setDuration:_scaleMin(t, 8.0)];
    } else {
        [self fu_setDuration:t];
    }
}
- (void)fu_addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (_on() && anim && !_isBlurKey(key ?: @"")) {
        // 层时钟叠加（实验）：按档位倍数加速本层的动画时钟，兜底覆盖
        // 未被时长 hook 触达的私有动画路径；与档位叠乘，上限 20 倍
        if (gLayerSpeed) {
            CGFloat sp = (CGFloat)(1.0 / _factor());
            if (sp > 20.0f) sp = 20.0f;
            if (sp > 1.0f) ((CALayer *)self).speed = sp;
        }
        NSTimeInterval d = anim.duration;
        if (d > 0 && d <= 0.26) {
            objc_setAssociatedObject(anim, &kFUInternalDurKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            anim.duration = _scaleMin(d, 8.0);
        }
    }
    [self fu_addAnimation:anim forKey:key];
}
+ (void)fu_setAnimationDuration:(NSTimeInterval)t {
    if (gFSTxInternal || !_on()) {
        [self fu_setAnimationDuration:t];
    } else {
        [self fu_setAnimationDuration:_scale(t)];
    }
}

#pragma mark ---------- 容器转场（v1.2.0：transitionWithView/FromView） ----------
+ (void)fu_transitionWithView:(UIView *)view duration:(NSTimeInterval)d options:(UIViewAnimationOptions)o
        animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    [self fu_transitionWithView:view duration:_on() ? _scale(d) : d
                        options:o animations:a completion:c];
}
+ (void)fu_transitionFromView:(UIView *)from toView:(UIView *)to duration:(NSTimeInterval)d
                      options:(UIViewAnimationOptions)o completion:(void (^)(BOOL))c {
    [self fu_transitionFromView:from toView:to duration:_on() ? _scale(d) : d
                        options:o completion:c];
}

#pragma mark ---------- 导航转场（侧滑返回松手完成段） ----------
- (void)fu_pushViewController:(UIViewController *)vc animated:(BOOL)flag {
    if (!_on() || !flag) { [self fu_pushViewController:vc animated:flag]; return; }
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        [self fu_pushViewController:vc animated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
}
- (UIViewController *)fu_popViewControllerAnimated:(BOOL)flag {
    if (!_on() || !flag) return [self fu_popViewControllerAnimated:flag];
    UIViewController *r;
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self fu_popViewControllerAnimated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
    return r;
}
- (NSArray<UIViewController *> *)fu_popToViewController:(UIViewController *)vc animated:(BOOL)flag {
    if (!_on() || !flag) return [self fu_popToViewController:vc animated:flag];
    NSArray *r;
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self fu_popToViewController:vc animated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
    return r;
}
- (NSArray<UIViewController *> *)fu_popToRootViewControllerAnimated:(BOOL)flag {
    if (!_on() || !flag) return [self fu_popToRootViewControllerAnimated:flag];
    NSArray *r;
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.35, 16.0)];
        r = [self fu_popToRootViewControllerAnimated:flag];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
    return r;
}
// v1.2.0：侧滑返回松手后的完成段走这里（私有时长 setter）；selector 缺失时
// _swiz 安全跳过。交互转场不走 push/pop hook，这是该段的唯一收窄点。
- (void)fu_setTransitionDuration:(NSTimeInterval)t {
    if (_on() && t > 0) {
        [self fu_setTransitionDuration:_scaleMin(t, 16.0)];
    } else {
        [self fu_setTransitionDuration:t];
    }
}

#pragma mark ---------- present / dismiss ----------
- (void)fu_presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))c {
    if (!_on() || !flag) { [self fu_presentViewController:vc animated:flag completion:c]; return; }
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.30, 30.0)];
        [self fu_presentViewController:vc animated:flag completion:c];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
}
- (void)fu_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))c {
    if (!_on() || !flag) { [self fu_dismissViewControllerAnimated:flag completion:c]; return; }
    @try {
        gFSTxInternal = YES;
        [CATransaction begin];
        [CATransaction setAnimationDuration:_scaleMin(0.25, 30.0)];
        [self fu_dismissViewControllerAnimated:flag completion:c];
        [CATransaction commit];
    } @finally { gFSTxInternal = NO; }
}

#pragma mark ---------- 弹簧物理层（SIClassic 推导 + 互补唯一 hook） ----------
// stiffness 独家生效条件（其他加速器都没 hook 它）：开着、未黑名单、弹簧平滑开。
// 互补模式下仍生效，但瞬切档互补时不动它，交给主加速器全权处理。
static inline BOOL _stiffnessOn(void) {
    return gEnabled && !gBlacklisted && gSpring &&
           (!gCompanion || gPreset != 4);
}
// damping/mass 在互补模式下完全不碰（SpeedsterTS 自己 hook 了这两个，
// 叠加会双重修改）；仅独立模式做物理缩放。
static inline BOOL _springPhysicsOn(void) {
    return gEnabled && !gBlacklisted && gSpring && !gCompanion;
}

// stiffness：高级模式按用户倍率直接缩放；普通模式用物理推导 × m²：
// ω=√(k/m)，k 乘 m² → ω 乘 m → settle 缩到 1/m，ζ 不变
- (void)fu_setStiffness:(CGFloat)v {
    if (_stiffnessOn() && v > 0.0f) {
        CGFloat k;
        if (gAdvanced) {
            k = v * (CGFloat)gStiffMult;
        } else {
            double m = _mult();
            k = v * (CGFloat)(m * m);
        }
        if (k > 1.0e5f) k = 1.0e5f;
        [self fu_setStiffness:k];
    } else {
        [self fu_setStiffness:v];
    }
}
// damping：高级模式按用户倍率；普通模式 × m 与 stiffness 配套保持阻尼比
// ζ = c/(2√(km)) 不变
- (void)fu_setDamping:(CGFloat)v {
    if (_springPhysicsOn() && v > 0.0f) {
        CGFloat c;
        if (gAdvanced) {
            c = v * (CGFloat)gDampMult;
        } else {
            double m = _mult();
            c = v * (CGFloat)m;
        }
        if (c > 1.0e5f) c = 1.0e5f;
        [self fu_setDamping:c];
    } else {
        [self fu_setDamping:v];
    }
}
// mass：高级模式按用户倍率；普通模式仅瞬切档压到极小（settle 趋近 0）
- (void)fu_setMass:(CGFloat)v {
    if (gAdvanced && _springPhysicsOn() && v > 0.0f) {
        CGFloat mv = v * (CGFloat)gMassMult;
        if (mv > 1.0e5f) mv = 1.0e5f;
        [self fu_setMass:mv];
    } else if (gEnabled && !gBlacklisted && gSpring && gPreset == 4 && v > 0.0f) {
        [self fu_setMass:0.0001f];
    } else {
        [self fu_setMass:v];
    }
}
// 初始速率：仅高级模式生效（Speedy 对标项）；velocity 可为负（方向），保号缩放
- (void)fu_setVelocity:(CGFloat)v {
    if (gAdvanced && _springPhysicsOn() && v != 0.0f) {
        CGFloat nv = v * (CGFloat)gVelMult;
        if (nv > 1.0e5f) nv = 1.0e5f;
        if (nv < -1.0e5f) nv = -1.0e5f;
        [self fu_setVelocity:nv];
    } else {
        [self fu_setVelocity:v];
    }
}

#pragma mark ---------- v2.0.0 额外 hook（SpeedIntensifier v1.6.1 并集，非列表类） ----------

// UIView 关键帧动画
+ (void)fu_animateKeyframesWithDuration:(NSTimeInterval)d delay:(NSTimeInterval)dl
                                options:(UIViewKeyframeAnimationOptions)o
                             animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (_on()) {
        [self fu_animateKeyframesWithDuration:_scale(d) delay:dl * _factor()
                                      options:o animations:a completion:c];
    } else {
        [self fu_animateKeyframesWithDuration:d delay:dl options:o animations:a completion:c];
    }
}
// 老式 begin/commit 动画 API 时长
+ (void)fu_UIViewSetAnimationDuration:(NSTimeInterval)d {
    [self fu_UIViewSetAnimationDuration:_on() ? _scale(d) : d];
}
// 老式 beginAnimations 延迟
+ (void)fu_setAnimationDelay:(NSTimeInterval)d {
    if (_on()) {
        double f = _factor();
        [self fu_setAnimationDelay:(f >= 1.0 ? d : d * f)];
    } else {
        [self fu_setAnimationDelay:d];
    }
}
// UIView 系统动画（行删除等）
+ (void)fu_performSystemAnimation:(UISystemAnimation)sa onViews:(NSArray<UIView *> *)views
                          options:(UIViewAnimationOptions)opts
                       animations:(void (^)(void))a completion:(void (^)(BOOL))c {
    if (!_on()) {
        [self fu_performSystemAnimation:sa onViews:views options:opts animations:a completion:c];
        return;
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.30)];
    @try { [self fu_performSystemAnimation:sa onViews:views options:opts animations:a completion:c]; }
    @finally { [CATransaction commit]; }
}

// UIViewPropertyAnimator 全族
- (instancetype)fu_initWithDuration:(NSTimeInterval)d dampingRatio:(CGFloat)r animations:(void (^)(void))a {
    return [self fu_initWithDuration:_on() ? _scale(d) : d dampingRatio:r animations:a];
}
- (instancetype)fu_initWithDuration:(NSTimeInterval)d controlPoint1:(CGPoint)p1
                        controlPoint2:(CGPoint)p2 animations:(void (^)(void))a {
    return [self fu_initWithDuration:_on() ? _scale(d) : d controlPoint1:p1 controlPoint2:p2 animations:a];
}
- (void)fu_addAnimations:(void (^)(void))a delayFactor:(CGFloat)df {
    if (_on()) {
        double f = _factor();
        CGFloat nd = (f >= 1.0) ? df : (df * f);
        [self fu_addAnimations:a delayFactor:nd];
    } else {
        [self fu_addAnimations:a delayFactor:df];
    }
}
+ (instancetype)fu_runningPropertyAnimatorWithDuration:(NSTimeInterval)d delay:(NSTimeInterval)dl
                                                options:(UIViewAnimationOptions)o
                                             animations:(void (^)(void))a
                                             completion:(void (^)(UIViewAnimatingPosition))c {
    if (_on()) {
        double f = _factor();
        return [self fu_runningPropertyAnimatorWithDuration:_scale(d)
                                                     delay:(f >= 1.0 ? dl : dl * f)
                                                   options:o animations:a completion:c];
    }
    return [self fu_runningPropertyAnimatorWithDuration:d delay:dl options:o animations:a completion:c];
}
- (void)fu_startAnimationAfterDelay:(NSTimeInterval)d {
    if (_on()) {
        double f = _factor();
        [self fu_startAnimationAfterDelay:(f >= 1.0 ? d : d * f)];
    } else {
        [self fu_startAnimationAfterDelay:d];
    }
}

// UIWindow 动画时长
+ (void)fu_windowSetAnimationDuration:(NSTimeInterval)d {
    [self fu_windowSetAnimationDuration:_on() ? _scale(d) : d];
}

// CALayer 隐式动画：极速/瞬切档对常用隐式 key 返回 nil（瞬时到位）
- (id)fu_actionForKey:(NSString *)key {
    if (_on() && _factor() <= 0.01) {
        NSString *k = key.lowercaseString ?: @"";
        if ([k isEqualToString:@"position"] || [k isEqualToString:@"bounds"] ||
            [k isEqualToString:@"frame"] || [k isEqualToString:@"opacity"] ||
            [k isEqualToString:@"contents"] || [k isEqualToString:@"contentsrect"] ||
            [k isEqualToString:@"backgroundcolor"] || [k isEqualToString:@"cornerradius"] ||
            [k isEqualToString:@"hidden"] || [k isEqualToString:@"sublayers"]) {
            return nil;
        }
    }
    return [self fu_actionForKey:key];
}

// CAPropertyAnimation 二级链（仅当 setDuration: 与基类不同才安装，防重复链）
- (void)fu_propSetDuration:(CFTimeInterval)d {
    if (_on()) {
        [self fu_propSetDuration:_scaleMin(d, 8.0)];
    } else {
        [self fu_propSetDuration:d];
    }
}

// 交互式转场（直接透传，不做延迟——这三个本就不是时长控制点）
- (void)fu_updateInteractiveTransition:(double)pct {
    [self fu_updateInteractiveTransition:pct];
}
- (void)fu_cancelInteractiveTransition {
    [self fu_cancelInteractiveTransition];
}
- (void)fu_finishInteractiveTransition {
    [self fu_finishInteractiveTransition];
}

// UIPresentationController 容器布局（透传占位，保持 hook 链完整）
- (void)fu_containerViewWillLayoutSubviews {
    [self fu_containerViewWillLayoutSubviews];
}

// UIContextMenuInteraction 弹出
- (void)fu_presentMenuAtLocation:(CGPoint)loc inView:(UIView *)vw {
    if (!_on()) { [self fu_presentMenuAtLocation:loc inView:vw]; return; }
    [self fu_presentMenuAtLocation:loc inView:vw];
}

// 导航整栈替换（激进：包在快速 UIView 动画块内调原 animated:NO）
- (void)fu_setViewControllers:(NSArray<UIViewController *> *)vcs animated:(BOOL)an {
    if (!an || !_on()) { [self fu_setViewControllers:vcs animated:an]; return; }
    [UIView animateWithDuration:_scaleMin(0.35, 16.0)
                          delay:0 options:UIViewAnimationOptionCurveEaseInOut
                       animations:^{ [self fu_setViewControllers:vcs animated:NO]; }
                       completion:nil];
}

// Tab 直选 index
- (void)fu_setSelectedIndex:(NSUInteger)idx {
    if (!_on()) { [self fu_setSelectedIndex:idx]; return; }
    [UIView animateWithDuration:_scaleMin(0.25, 16.0)
                          delay:0 options:UIViewAnimationOptionCurveEaseInOut
                       animations:^{ [self fu_setSelectedIndex:idx]; }
                       completion:nil];
}
// Tab 直选 VC
- (void)fu_setSelectedViewController:(UIViewController *)vc {
    if (!_on()) { [self fu_setSelectedViewController:vc]; return; }
    [UIView animateWithDuration:_scaleMin(0.25, 16.0)
                          delay:0 options:UIViewAnimationOptionCurveEaseInOut
                       animations:^{ [self fu_setSelectedViewController:vc]; }
                       completion:nil];
}

// PageVC 翻页
- (void)fu_setViewControllers:(NSArray<UIViewController *> *)vcs
                    direction:(UIPageViewControllerNavigationDirection)dir
                     animated:(BOOL)an completion:(void (^)(BOOL))c {
    if (!an || !_on()) { [self fu_setViewControllers:vcs direction:dir animated:an completion:c]; return; }
    [self fu_setViewControllers:vcs direction:dir animated:NO completion:c];
}

// UIScrollView 缩放
- (void)fu_setZoomScale:(CGFloat)zs animated:(BOOL)an {
    if (!an || !_on()) { [self fu_setZoomScale:zs animated:an]; return; }
    [UIView animateWithDuration:_scale(0.25) delay:0 options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self fu_setZoomScale:zs animated:NO]; } completion:nil];
}
- (void)fu_zoomToRect:(CGRect)r animated:(BOOL)an {
    if (!an || !_on()) { [self fu_zoomToRect:r animated:an]; return; }
    [UIView animateWithDuration:_scale(0.25) delay:0 options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self fu_zoomToRect:r animated:NO]; } completion:nil];
}

// 三类栏 setItems
- (void)fu_navBarSetItems:(NSArray<UINavigationItem *> *)items animated:(BOOL)an {
    if (!an || !_on()) { [self fu_navBarSetItems:items animated:an]; return; }
    [self fu_navBarSetItems:items animated:NO];
}
- (void)fu_tabBarSetItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)an {
    if (!an || !_on()) { [self fu_tabBarSetItems:items animated:an]; return; }
    [self fu_tabBarSetItems:items animated:NO];
}
- (void)fu_toolbarSetItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)an {
    if (!an || !_on()) { [self fu_toolbarSetItems:items animated:an]; return; }
    [self fu_toolbarSetItems:items animated:NO];
}

// 控件：进度 / 开关 / 滑杆
- (void)fu_setProgress:(float)p animated:(BOOL)an {
    if (!an || !_on()) { [self fu_setProgress:p animated:an]; return; }
    [self fu_setProgress:p animated:NO];
}
- (void)fu_setOn:(BOOL)on animated:(BOOL)an {
    if (!an || !_on()) { [self fu_setOn:on animated:an]; return; }
    [self fu_setOn:on animated:NO];
}
- (void)fu_setValue:(float)v animated:(BOOL)an {
    if (!an || !_on()) { [self fu_setValue:v animated:an]; return; }
    [self fu_setValue:v animated:NO];
}

#pragma mark ---------- v2.0.0 列表类 hook（_listOn 控制，默认关，微信安全） ----------

// UITableView
- (void)fu_TV_performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))c {
    if (!_listOn()) { [self fu_TV_performBatchUpdates:updates completion:c]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_TV_performBatchUpdates:updates completion:c]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_TV_insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)ip withRowAnimation:(UITableViewRowAnimation)an {
    if (!_listOn()) { [self fu_TV_insertRowsAtIndexPaths:ip withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_TV_insertRowsAtIndexPaths:ip withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_TV_deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)ip withRowAnimation:(UITableViewRowAnimation)an {
    if (!_listOn()) { [self fu_TV_deleteRowsAtIndexPaths:ip withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_TV_deleteRowsAtIndexPaths:ip withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_TV_reloadRowsAtIndexPaths:(NSArray<NSIndexPath *> *)ip withRowAnimation:(UITableViewRowAnimation)an {
    if (!_listOn()) { [self fu_TV_reloadRowsAtIndexPaths:ip withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_TV_reloadRowsAtIndexPaths:ip withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_TV_setEditing:(BOOL)ed animated:(BOOL)an {
    if (!an || !_listOn()) { [self fu_TV_setEditing:ed animated:an]; return; }
    [self fu_TV_setEditing:ed animated:NO];
}
- (void)fu_TV_reloadSections:(NSIndexSet *)sec withRowAnimation:(UITableViewRowAnimation)an {
    if (!_listOn()) { [self fu_TV_reloadSections:sec withRowAnimation:an]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_TV_reloadSections:sec withRowAnimation:an]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_TV_selectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)an
                    scrollPosition:(UITableViewScrollPosition)sp {
    if (!an || !_listOn()) { [self fu_TV_selectRowAtIndexPath:ip animated:an scrollPosition:sp]; return; }
    [self fu_TV_selectRowAtIndexPath:ip animated:NO scrollPosition:sp];
}
- (void)fu_TV_deselectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)an {
    if (!an || !_listOn()) { [self fu_TV_deselectRowAtIndexPath:ip animated:an]; return; }
    [self fu_TV_deselectRowAtIndexPath:ip animated:NO];
}
- (void)fu_TV_moveRowAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
    if (!_listOn()) { [self fu_TV_moveRowAtIndexPath:src toIndexPath:dst]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_TV_moveRowAtIndexPath:src toIndexPath:dst]; }
    @finally { [CATransaction commit]; }
}

// UICollectionView
- (void)fu_CV_performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))c {
    if (!_listOn()) { [self fu_CV_performBatchUpdates:updates completion:c]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_CV_performBatchUpdates:updates completion:c]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_CV_insertItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ip {
    if (!_listOn()) { [self fu_CV_insertItemsAtIndexPaths:ip]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_CV_insertItemsAtIndexPaths:ip]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_CV_deleteItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ip {
    if (!_listOn()) { [self fu_CV_deleteItemsAtIndexPaths:ip]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_CV_deleteItemsAtIndexPaths:ip]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_CV_reloadItemsAtIndexPaths:(NSArray<NSIndexPath *> *)ip {
    if (!_listOn()) { [self fu_CV_reloadItemsAtIndexPaths:ip]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_CV_reloadItemsAtIndexPaths:ip]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_CV_setLayout:(UICollectionViewLayout *)nl animated:(BOOL)an {
    if (!an || !_listOn()) { [self fu_CV_setLayout:nl animated:an]; return; }
    [self fu_CV_setLayout:nl animated:NO];
}
- (void)fu_CV_setLayout:(UICollectionViewLayout *)nl animated:(BOOL)an completion:(void (^)(BOOL))c {
    if (!an || !_listOn()) { [self fu_CV_setLayout:nl animated:an completion:c]; return; }
    [self fu_CV_setLayout:nl animated:NO completion:c];
}
- (void)fu_CV_moveItemAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
    if (!_listOn()) { [self fu_CV_moveItemAtIndexPath:src toIndexPath:dst]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_CV_moveItemAtIndexPath:src toIndexPath:dst]; }
    @finally { [CATransaction commit]; }
}
- (void)fu_CV_reloadSections:(NSIndexSet *)sec {
    if (!_listOn()) { [self fu_CV_reloadSections:sec]; return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:_scale(0.25)];
    @try { [self fu_CV_reloadSections:sec]; }
    @finally { [CATransaction commit]; }
}

@end

// ================================ 共存检测 ================================
static BOOL _otherAcceleratorLoaded(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img) continue;
        // 不含自身 SIFusion；命中任一其他加速器即进入互补模式
        if (strstr(img, "SIFusion")) continue;
        if (strstr(img, "SpeedIntensifier") ||
            strstr(img, "SpeedsterTS") ||
            strstr(img, "SIClassic")) return YES;
    }
    return NO;
}

static void _fu_notify_cb(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object,
                          CFDictionaryRef info) {
    _loadPref();
    NSLog(@"[SIFusion] pref reloaded (preset=%d spring=%d companion=%d)", gPreset, gSpring, gCompanion);
}

__attribute__((constructor))
static void _fu_entry(void) {
    @autoreleasepool {
        gCompanion = _otherAcceleratorLoaded();
        _loadPref();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, _fu_notify_cb,
            (__bridge CFStringRef)kFUNotify, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        int ok = 0, total = 0;
        Class spring = [CASpringAnimation class];

        // 弹簧物理层 4 个 hook 始终安装（stiffness/damping/mass/velocity；
        // mass/damping/velocity 与 SpeedsterTS 行为不同时仅在独立模式做物理缩放
        // ——见 _springPhysicsOn 内的 companion 守卫；stiffness 互补模式也生效）。
        // 注意：与 SpeedsterTS 同时注入时，SpeedsterTS 的 mass/damping hook 也在，
        // 但互补模式下本版 damping 走原速分支，不叠加；stiffness 独家。
        total += 4;
        ok += _swiz(spring, @selector(setStiffness:), @selector(fu_setStiffness:));
        ok += _swiz(spring, @selector(setDamping:),   @selector(fu_setDamping:));
        ok += _swiz(spring, @selector(setMass:),      @selector(fu_setMass:));
        ok += _swiz(spring, @selector(setVelocity:),  @selector(fu_setVelocity:));

        if (!gCompanion) {
            total += 4;
            ok += _swizClass([UIView class], @selector(animateWithDuration:animations:),
                             @selector(fu_animate:animations:));
            ok += _swizClass([UIView class], @selector(animateWithDuration:animations:completion:),
                             @selector(fu_animate:animations:completion:));
            ok += _swizClass([UIView class], @selector(animateWithDuration:delay:options:animations:completion:),
                             @selector(fu_animate:delay:options:animations:completion:));
            ok += _swizClass([UIView class],
                             @selector(animateWithDuration:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:),
                             @selector(fu_animate:delay:usingSpringWithDamping:initialSpringVelocity:options:animations:completion:));

            total += 3;
            ok += _swiz([CAAnimation class], @selector(setDuration:), @selector(fu_setDuration:));
            ok += _swiz([CALayer class], @selector(addAnimation:forKey:), @selector(fu_addAnimation:forKey:));
            ok += _swizClass([CATransaction class], @selector(setAnimationDuration:),
                             @selector(fu_setAnimationDuration:));

            // v1.2.0：容器转场 ×2
            total += 2;
            ok += _swizClass([UIView class], @selector(transitionWithView:duration:options:animations:completion:),
                             @selector(fu_transitionWithView:duration:options:animations:completion:));
            ok += _swizClass([UIView class], @selector(transitionFromView:toView:duration:options:completion:),
                             @selector(fu_transitionFromView:toView:duration:options:completion:));

            Class nav = [UINavigationController class];
            total += 5;
            ok += _swiz(nav, @selector(pushViewController:animated:),     @selector(fu_pushViewController:animated:));
            ok += _swiz(nav, @selector(popViewControllerAnimated:),       @selector(fu_popViewControllerAnimated:));
            ok += _swiz(nav, @selector(popToViewController:animated:),    @selector(fu_popToViewController:animated:));
            ok += _swiz(nav, @selector(popToRootViewControllerAnimated:), @selector(fu_popToRootViewControllerAnimated:));
            // 私有时长（侧滑完成段）；缺失时安全跳过
            ok += _swiz(nav, @selector(_setTransitionDuration:), @selector(fu_setTransitionDuration:));

            Class vc = [UIViewController class];
            total += 2;
            ok += _swiz(vc, @selector(presentViewController:animated:completion:),
                        @selector(fu_presentViewController:animated:completion:));
            ok += _swiz(vc, @selector(dismissViewControllerAnimated:completion:),
                        @selector(fu_dismissViewControllerAnimated:completion:));

            // ==================== v2.0.0 额外 hook（非列表类，跟随 Enabled） ====================
            Class uiv = [UIView class];
            total += 4;
            ok += _swizClass(uiv, @selector(animateKeyframesWithDuration:delay:options:animations:completion:),
                             @selector(fu_animateKeyframesWithDuration:delay:options:animations:completion:));
            ok += _swizClass(uiv, @selector(setAnimationDuration:),
                             @selector(fu_UIViewSetAnimationDuration:));
            ok += _swizClass(uiv, @selector(setAnimationDelay:),
                             @selector(fu_setAnimationDelay:));
            ok += _swizClass(uiv, @selector(performSystemAnimation:onViews:options:animations:completion:),
                             @selector(fu_performSystemAnimation:onViews:options:animations:completion:));

            Class uipa = [UIViewPropertyAnimator class];
            total += 5;
            ok += _swiz(uipa, @selector(initWithDuration:dampingRatio:animations:),
                        @selector(fu_initWithDuration:dampingRatio:animations:));
            ok += _swiz(uipa, @selector(initWithDuration:controlPoint1:controlPoint2:animations:),
                        @selector(fu_initWithDuration:controlPoint1:controlPoint2:animations:));
            ok += _swiz(uipa, @selector(addAnimations:delayFactor:),
                        @selector(fu_addAnimations:delayFactor:));
            ok += _swizClass(uipa, @selector(runningPropertyAnimatorWithDuration:delay:options:animations:completion:),
                             @selector(fu_runningPropertyAnimatorWithDuration:delay:options:animations:completion:));
            ok += _swiz(uipa, @selector(startAnimationAfterDelay:),
                        @selector(fu_startAnimationAfterDelay:));

            total += 1;
            ok += _swizClass([UIWindow class], @selector(setAnimationDuration:),
                             @selector(fu_windowSetAnimationDuration:));

            total += 1;
            ok += _swiz([CALayer class], @selector(actionForKey:),
                        @selector(fu_actionForKey:));

            // CAPropertyAnimation 二级链：仅当 setDuration: 与基类不同才装（防重复链）
            {
                Method baseM = class_getInstanceMethod([CAAnimation class], @selector(setDuration:));
                Method propM = class_getInstanceMethod([CAPropertyAnimation class], @selector(setDuration:));
                if (propM && baseM != propM) {
                    total += 1;
                    ok += _swiz([CAPropertyAnimation class], @selector(setDuration:),
                                @selector(fu_propSetDuration:));
                }
            }

            Class itt = [UIPercentDrivenInteractiveTransition class];
            total += 3;
            ok += _swiz(itt, @selector(updateInteractiveTransition:),
                        @selector(fu_updateInteractiveTransition:));
            ok += _swiz(itt, @selector(cancelInteractiveTransition),
                        @selector(fu_cancelInteractiveTransition));
            ok += _swiz(itt, @selector(finishInteractiveTransition),
                        @selector(fu_finishInteractiveTransition));

            total += 1;
            ok += _swiz([UIPresentationController class], @selector(containerViewWillLayoutSubviews),
                        @selector(fu_containerViewWillLayoutSubviews));

            total += 1;
            ok += _swiz([UIContextMenuInteraction class], @selector(presentMenuAtLocation:inView:),
                        @selector(fu_presentMenuAtLocation:inView:));

            // 导航整栈替换
            total += 1;
            ok += _swiz(nav, @selector(setViewControllers:animated:),
                        @selector(fu_setViewControllers:animated:));

            // Tab 直选
            Class tab = [UITabBarController class];
            total += 2;
            ok += _swiz(tab, @selector(setSelectedIndex:),
                        @selector(fu_setSelectedIndex:));
            ok += _swiz(tab, @selector(setSelectedViewController:),
                        @selector(fu_setSelectedViewController:));

            // PageVC 翻页
            Class pvc = [UIPageViewController class];
            total += 1;
            ok += _swiz(pvc, @selector(setViewControllers:direction:animated:completion:),
                        @selector(fu_setViewControllers:direction:animated:completion:));

            // UIScrollView 缩放
            Class uisv = [UIScrollView class];
            total += 2;
            ok += _swiz(uisv, @selector(setZoomScale:animated:),
                        @selector(fu_setZoomScale:animated:));
            ok += _swiz(uisv, @selector(zoomToRect:animated:),
                        @selector(fu_zoomToRect:animated:));

            // 三类栏 setItems
            total += 3;
            ok += _swiz([UINavigationBar class], @selector(setItems:animated:),
                        @selector(fu_navBarSetItems:animated:));
            ok += _swiz([UITabBar class], @selector(setItems:animated:),
                        @selector(fu_tabBarSetItems:animated:));
            ok += _swiz([UIToolbar class], @selector(setItems:animated:),
                        @selector(fu_toolbarSetItems:animated:));

            // 控件
            total += 3;
            ok += _swiz([UIProgressView class], @selector(setProgress:animated:),
                        @selector(fu_setProgress:animated:));
            ok += _swiz([UISwitch class], @selector(setOn:animated:),
                        @selector(fu_setOn:animated:));
            ok += _swiz([UISlider class], @selector(setValue:animated:),
                        @selector(fu_setValue:animated:));

            // ==================== v2.0.0 列表类 hook（ListAccel 开关，默认关） ====================
            if (_listOn()) {
                int lok = 0, ltotal = 0;
                Class tv = [UITableView class];
                ltotal += 9;
                lok += _swiz(tv, @selector(performBatchUpdates:completion:),
                             @selector(fu_TV_performBatchUpdates:completion:));
                lok += _swiz(tv, @selector(insertRowsAtIndexPaths:withRowAnimation:),
                             @selector(fu_TV_insertRowsAtIndexPaths:withRowAnimation:));
                lok += _swiz(tv, @selector(deleteRowsAtIndexPaths:withRowAnimation:),
                             @selector(fu_TV_deleteRowsAtIndexPaths:withRowAnimation:));
                lok += _swiz(tv, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                             @selector(fu_TV_reloadRowsAtIndexPaths:withRowAnimation:));
                lok += _swiz(tv, @selector(setEditing:animated:),
                             @selector(fu_TV_setEditing:animated:));
                lok += _swiz(tv, @selector(reloadSections:withRowAnimation:),
                             @selector(fu_TV_reloadSections:withRowAnimation:));
                lok += _swiz(tv, @selector(selectRowAtIndexPath:animated:scrollPosition:),
                             @selector(fu_TV_selectRowAtIndexPath:animated:scrollPosition:));
                lok += _swiz(tv, @selector(deselectRowAtIndexPath:animated:),
                             @selector(fu_TV_deselectRowAtIndexPath:animated:));
                lok += _swiz(tv, @selector(moveRowAtIndexPath:toIndexPath:),
                             @selector(fu_TV_moveRowAtIndexPath:toIndexPath:));

                Class cv = [UICollectionView class];
                ltotal += 8;
                lok += _swiz(cv, @selector(performBatchUpdates:completion:),
                             @selector(fu_CV_performBatchUpdates:completion:));
                lok += _swiz(cv, @selector(insertItemsAtIndexPaths:),
                             @selector(fu_CV_insertItemsAtIndexPaths:));
                lok += _swiz(cv, @selector(deleteItemsAtIndexPaths:),
                             @selector(fu_CV_deleteItemsAtIndexPaths:));
                lok += _swiz(cv, @selector(reloadItemsAtIndexPaths:),
                             @selector(fu_CV_reloadItemsAtIndexPaths:));
                lok += _swiz(cv, @selector(setCollectionViewLayout:animated:),
                             @selector(fu_CV_setLayout:animated:));
                lok += _swiz(cv, @selector(setCollectionViewLayout:animated:completion:),
                             @selector(fu_CV_setLayout:animated:completion:));
                lok += _swiz(cv, @selector(moveItemAtIndexPath:toIndexPath:),
                             @selector(fu_CV_moveItemAtIndexPath:toIndexPath:));
                lok += _swiz(cv, @selector(reloadSections:),
                             @selector(fu_CV_reloadSections:));

                total += ltotal;
                ok += lok;
                NSLog(@"[SIFusion] list hooks %d/%d (ListAccel=ON)", lok, ltotal);
            }
        }

        NSLog(@"[SIFusion] v2.0.0 Max loaded in %@: %@ mode, hooks %d/%d (preset=%d spring=%d adv=%d lspeed=%d list=%d blacklisted=%d)",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gCompanion ? @"COMPANION (spring-only)" : @"STANDALONE (full ~68)",
              ok, total, gPreset, gSpring, gAdvanced, gLayerSpeed, gListAccel, gBlacklisted);
    }
}
