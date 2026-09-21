// FUBackground v2.0.0 Max — TrollStore 真后台保活 dylib（纯 ObjC runtime，无 substrate）
//
// ═══════════════════════════════════════════════════════════════════════════
// v2.0 双引擎架构（融合 ImmortalizerJailed 的场景伪装 + FUBackground 的音频断言）
//
// 【引擎一：场景伪装 SceneFake】（核心，移植自 ImmortalizerJailed 的思路并重写）
//   iOS 让 App"进入后台"的方式，是由 FrontBoard 经进程内的 FBSWorkspaceScenesClient
//   下发 scene settings diff（foreground = No、deactivationReasons、快照动作）。
//   hook 该方法：对"后台化/快照"diff 直接吞掉不转发 —— App 的场景层永远停留在
//   前台状态，计时器不降速、UI/动画不停、业务逻辑照常跑。
//   配套：
//     - hook UIApplication.applicationState：物理在后台时返回 Active；但用 dladdr
//       识别调用者，UserNotifications/PushKit 来问时如实返回 Background，保证推送
//       通道注册与接收正常。
//     - hook UNUserNotificationCenter setDelegate:，改写 delegate 的 willPresent：
//       物理在后台时强制弹横幅（App 自以为在前台，系统默认不弹）。
//   该引擎成立时【不需要】Info.plist 的 UIBackgroundModes=audio 声明。
//
// 【引擎二：音频断言 AudioKeep】（兜底防挂起）
//   即便场景层留在前台，系统仍可能在物理切走后挂起进程。播放 volume=0 的内嵌
//   白噪声（真实微能量波形，比数字全零更不易被音频管线跳过），CategoryPlayback +
//   MixWithOthers（不打断用户音乐），借音频断言让 RunLoop 持续运转。
//   1.5 秒自愈轮询（停了才重建，不做无谓重建）；来电/闹钟中断后自动恢复；
//   beginBackgroundTask 提供启动桥接宽限。
//   该引擎单独使用时仍需要 UIBackgroundModes=audio；与引擎一同开则非必需。
//
// 【悬浮球 FloatingBall】注入的每个 App 内显示可拖拽悬浮球，点击对"本 App"
//   即时开/关保活（独立于全局配置），5 秒不用自动收成屏幕边缘小把手。
//
// 场景拦截 / applicationState 伪装 / 通知横幅三段逻辑基于 Serge Alagon 的
// ImmortalizerJailed（https://github.com/sergealagon/ImmortalizerJailed，
// Copyright (C) 2025 Serge Alagon，GPLv3）修改而来；本文件作为衍生整体同样
// 适用 GPLv3。白噪声数据亦取自该项目。其余部分为 FUBackground 原创。
// ═══════════════════════════════════════════════════════════════════════════
//
// 全局配置：/var/Managed Preferences/mobile/com.local.fubg.plist
//   Enabled      总开关（默认 YES）
//   SceneFake    场景伪装引擎（默认 YES）
//   AudioKeep    音频断言兜底（默认 YES）
//   FloatingBall 注入 App 内悬浮球（默认 YES）
//   ExcludeApps  排除名单，bundle id 前缀匹配（默认空）
// 本 App 开关：NSUserDefaults 键 fubg_local_off（悬浮球切换）
// Darwin 通知 com.local.fubg.settingschanged 热重载。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import "FUBGNoiseData.h"

static NSString *const kFBGPrefPath = @"/var/Managed Preferences/mobile/com.local.fubg.plist";
static NSString *const kFBGNotify   = @"com.local.fubg.settingschanged";
static NSString *const kFBGLocalOff = @"fubg_local_off";

// ---- 全局状态 ----
static BOOL    gEnabled    = YES;
static BOOL    gSceneFake  = YES;
static BOOL    gAudioKeep  = YES;
static BOOL    gShowBall   = YES;
static NSArray *gExclude   = nil;
static BOOL    gLocalOff   = NO;

static BOOL    gActive    = NO;   // 本 App 最终是否参与保活（总开关∧名单∧本地开关）
static BOOL    gUseScene  = NO;   // 本 App 是否启用场景伪装
static BOOL    gUseAudio  = NO;   // 本 App 是否启用音频断言
static BOOL    gPhysBg    = NO;   // 物理上是否处于后台（由真实生命周期通知维护）
static BOOL    gHasAudioMode = NO;

static AVAudioPlayer *gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = 0;   // 0 = 无桥接任务（UIBackgroundTaskInvalid 非文件级编译期常量）
static NSTimer *gWatchdog = nil;

#pragma mark - 配置

static BOOL _fbg_isExcluded(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gExclude) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) return YES;
    }
    return NO;
}

static void _fbg_recalc(void) {
    gActive   = gEnabled && !gLocalOff && !_fbg_isExcluded();
    gUseScene = gActive && gSceneFake;
    gUseAudio = gActive && gAudioKeep;
}

static void _fbg_loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kFBGPrefPath];
        if (d) {
            if (d[@"Enabled"])      gEnabled   = [d[@"Enabled"] boolValue];
            if (d[@"SceneFake"])    gSceneFake = [d[@"SceneFake"] boolValue];
            if (d[@"AudioKeep"])    gAudioKeep = [d[@"AudioKeep"] boolValue];
            if (d[@"FloatingBall"]) gShowBall  = [d[@"FloatingBall"] boolValue];
            id ex = d[@"ExcludeApps"];
            if ([ex isKindOfClass:[NSArray class]]) gExclude = ex;
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];
    gLocalOff = [[NSUserDefaults standardUserDefaults] boolForKey:kFBGLocalOff];

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];

    _fbg_recalc();
}

#pragma mark - 引擎一：场景伪装
// 移植/修改自 ImmortalizerJailed main.m（GPLv3, Serge Alagon），致谢 @khanhduytran0

static void (*gOrigSceneUpdate)(id, SEL, id, id, id, id);

// 由后台化 diff 的描述特征判断这是否是一条"让 App 退到后台"的场景更新
static BOOL _fbg_isBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;
    if ([desc containsString:@"foreground = NotSet"] ||
        [desc containsString:@"foreground = No"] ||
        [desc containsString:@"foreground = BSSettingFlagNo"] ||
        [desc containsString:@"foreground = NO"]) {
        return YES;
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露/状态推进
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void _fbg_sceneUpdate(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (gUseScene) {
        @try {
            if (_fbg_isBackgroundingDiff([arg2 description])) {
                NSLog(@"[FUBG] swallowed backgrounding scene diff");
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gOrigSceneUpdate(self, _cmd, arg1, arg2, arg3, arg4);
}

// ---- applicationState 伪装 ----
static UIApplicationState (*gOrigAppState)(id, SEL);

static UIApplicationState _fbg_appState(id self, SEL _cmd) {
    if (gUseScene && gPhysBg) {
        // 推送/通知框架需要真实答案：前台态时它们不会建立后台接收通道
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        Dl_info info;
        if (dladdr(ret, &info) && info.dli_fname) {
            NSString *image = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
            if ([image containsString:@"UserNotifications"] ||
                [image containsString:@"PushKit"]) {
                return UIApplicationStateBackground;
            }
        }
        return UIApplicationStateActive;
    }
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// ---- 通知横幅伪装 ----
static void (*gOrigWillPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                                void (^)(UNNotificationPresentationOptions));

static void _fbg_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center,
                             UNNotification *note,
                             void (^handler)(UNNotificationPresentationOptions)) {
    if (gUseScene && gPhysBg) {
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
    } else if (gOrigWillPresent) {
        gOrigWillPresent(self, _cmd, center, note, handler);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

static void _fbg_unSetDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    if (delegate) {
        Class dc = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(dc, sel);
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)_fbg_willPresent) {
                gOrigWillPresent = (void *)cur;
                method_setImplementation(m, (IMP)_fbg_willPresent);
            }
        }
    }
}

static void _fbg_installSceneHooks(void) {
    Class wsClass = objc_getClass("FBSWorkspaceScenesClient");
    Method sceneM = wsClass ? class_getInstanceMethod(
        wsClass, @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:)) : NULL;
    if (sceneM) {
        gOrigSceneUpdate = (void (*)(id, SEL, id, id, id, id))method_getImplementation(sceneM);
        method_setImplementation(sceneM, (IMP)_fbg_sceneUpdate);
        NSLog(@"[FUBG] scene hook installed");
    } else {
        NSLog(@"[FUBG] FBSWorkspaceScenesClient method not found, scene engine disabled");
    }

    Method stateM = class_getInstanceMethod([UIApplication class], @selector(applicationState));
    if (stateM) {
        gOrigAppState = (UIApplicationState (*)(id, SEL))method_getImplementation(stateM);
        method_setImplementation(stateM, (IMP)_fbg_appState);
    }

    Class unClass = [UNUserNotificationCenter class];
    Method delM = class_getInstanceMethod(unClass, @selector(setDelegate:));
    if (delM) {
        gOrigUNSetDelegate = (void (*)(id, SEL, id))method_getImplementation(delM);
        method_setImplementation(delM, (IMP)_fbg_unSetDelegate);
    }
}

#pragma mark - 引擎二：音频断言

static BOOL _fbg_activateSession(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback
            withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e] || e) {
        NSLog(@"[FUBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e] || e) {
        NSLog(@"[FUBG] setActive failed: %@", e); return NO;
    }
    return YES;
}

static void _fbg_buildAndPlay(void) {
    @try {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:data error:nil];
        if (!p) return;
        p.numberOfLoops = -1;
        p.volume = 0.0f;
        [p prepareToPlay];
        [p play];
        gPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void _fbg_startAudio(void) {
    if (!gUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == 0) {
            gTask = [app beginBackgroundTaskWithName:@"fubg-bridge" expirationHandler:^{
                NSLog(@"[FUBG] bridge task expired");
                if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
            }];
        }
        if (_fbg_activateSession() && (!gPlayer || !gPlayer.isPlaying)) {
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
        NSLog(@"[FUBG] audio keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void _fbg_stopAudio(BOOL releaseSession) {
    @try {
        if (gPlayer.isPlaying) [gPlayer pause];
        // 经验（Immortalizer 作者）：mix 模式下保持 session 激活、不主动 setActive:NO，
        // 可避免与目标 App 自身音频会话打架造成的卡顿；仅彻底关闭时通知他人恢复。
        if (releaseSession) {
            [[AVAudioSession sharedInstance] setActive:NO
                                          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                                error:nil];
        }
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
    } @catch (__unused NSException *e) {}
}

// 自愈轮询：仅在停摆时重建，兼顾可靠与耗电
static void _fbg_watchdogFire(__unused NSTimer *t) {
    if (!gUseAudio || !gPhysBg) return;
    @try {
        if (!gPlayer || !gPlayer.isPlaying) {
            NSLog(@"[FUBG] watchdog: player stopped, rebuilding");
            _fbg_activateSession();
            if (gPlayer) { [gPlayer play]; }
            else { _fbg_buildAndPlay(); }
        }
    } @catch (__unused NSException *e) {}
}

static void _fbg_onInterruption(NSNotification *note) {
    if (!gUseAudio) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
    if (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gUseAudio && gPhysBg) {
                _fbg_activateSession();
                if (gPlayer) { [gPlayer play]; } else { _fbg_buildAndPlay(); }
            }
        });
    }
}

#pragma mark - 悬浮球

@interface FBGToastView : UIView
+ (void)showIn:(UIView *)container title:(NSString *)title subtitle:(NSString *)subtitle
      iconName:(NSString *)iconName;
@end

@implementation FBGToastView
+ (void)showIn:(UIView *)container title:(NSString *)title subtitle:(NSString *)subtitle
      iconName:(NSString *)iconName {
    FBGToastView *blur = [[self alloc] initWithFrame:CGRectMake(0, -90, container.bounds.size.width, 80)];
    blur.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    blur.layer.cornerRadius = 18;
    blur.layer.masksToBounds = YES;

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName]];
    iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *t = [[UILabel alloc] init];
    t.text = title;
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:15];
    UILabel *s = [[UILabel alloc] init];
    s.text = subtitle;
    s.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    s.font = [UIFont systemFontOfSize:12];
    UIStackView *txt = [[UIStackView alloc] initWithArrangedSubviews:@[t, s]];
    txt.axis = UILayoutConstraintAxisVertical;
    txt.spacing = 2;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iv, txt]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [blur addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [iv.widthAnchor constraintEqualToConstant:28], [iv.heightAnchor constraintEqualToConstant:28],
        [row.leadingAnchor constraintEqualToAnchor:blur.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:blur.trailingAnchor constant:-16],
        [row.centerYAnchor constraintEqualToAnchor:blur.centerYAnchor],
    ]];
    [container addSubview:blur];

    [UIView animateWithDuration:0.3 animations:^{
        blur.transform = CGAffineTransformMakeTranslation(0, 110);
    } completion:^(__unused BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                blur.alpha = 0;
                blur.transform = CGAffineTransformMakeTranslation(0, 40);
            } completion:^(__unused BOOL f2) { [blur removeFromSuperview]; }];
        });
    }];
}
@end

@interface FBGFloatingWindow : UIWindow
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, assign) BOOL docked;
@property (nonatomic, strong) NSTimer *dockTimer;
+ (instancetype)shared;
- (void)attachWhenSceneReady;
- (void)refreshState;
@end

@implementation FBGFloatingWindow

+ (instancetype)shared {
    static FBGFloatingWindow *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [[self alloc] initWithFrame:UIScreen.mainScreen.bounds]; });
    return one;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [UIViewController new];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        _ball = [UIButton buttonWithType:UIButtonTypeCustom];
        _ball.frame = CGRectMake(self.bounds.size.width - 70, 220, 52, 52);
        _ball.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
        _ball.layer.cornerRadius = 26;
        _ball.layer.masksToBounds = YES;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onPan:)];
        [_ball addGestureRecognizer:pan];
        [_ball addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [self.rootViewController.view addSubview:_ball];
        [self snap];

        _handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 46)];
        _handle.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
        _handle.layer.cornerRadius = 6;
        _handle.hidden = YES; _handle.alpha = 0;
        UIPanGestureRecognizer *hpan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(onHandlePan:)];
        UITapGestureRecognizer *htap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(undock)];
        [_handle addGestureRecognizer:hpan];
        [_handle addGestureRecognizer:htap];
        [self.rootViewController.view addSubview:_handle];

        [self refreshState];
    }
    return self;
}

- (void)makeKeyWindow {
    [super makeKeyWindow];
    // 不抢目标 App 的 keyWindow
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
            }
        }
        if (kw && kw != self) [kw makeKeyWindow];
    });
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_ball.hidden) {
        CGPoint p = [self convertPoint:point toView:_ball];
        if ([_ball pointInside:p withEvent:event]) return [super hitTest:point withEvent:event];
    }
    if (!_handle.hidden) {
        CGPoint p = [self convertPoint:point toView:_handle];
        if ([_handle pointInside:p withEvent:event]) return [super hitTest:point withEvent:event];
    }
    return nil;
}

- (void)attachWhenSceneReady {
    __block int tries = 0;
    __weak typeof(self) weakSelf = self;
    __block void (^attempt)(void);
    attempt = ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        UIWindowScene *target = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { target = (UIWindowScene *)sc; break; }
        }
        if (target) {
            me.windowScene = target;
            me.hidden = NO;
            [me makeKeyAndVisible];
            [me startDockClock];
            [me refreshState];
        } else if (++tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), attempt);
        }
    };
    dispatch_async(dispatch_get_main_queue(), attempt);
}

- (void)refreshState {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hidden = !gShowBall;
        if (!gShowBall) return;
        BOOL on = !gLocalOff && gEnabled;
        UIImage *icon = [UIImage systemImageNamed: on ? @"hourglass" : @"powersleep"];
        [self.ball setImage:icon forState:UIControlStateNormal];
        self.ball.tintColor = on ? [UIColor systemBlueColor] : [UIColor systemRedColor];
    });
}

- (void)snap {
    CGFloat w = self.bounds.size.width;
    CGPoint c = _ball.center;
    c.x = c.x < w / 2 ? 26 : w - 26;
    c.y = MAX(26, MIN(self.bounds.size.height - 26, c.y));
    [UIView animateWithDuration:0.25 animations:^{ _ball.center = c; }];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    [self resetDockClock];
    CGPoint tr = [g translationInView:self];
    g.view.center = CGPointMake(g.view.center.x + tr.x, g.view.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) { [self snap]; [self startDockClock]; }
}

- (void)onHandlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { [self undock]; return; }
    CGPoint tr = [g translationInView:self];
    _ball.center = CGPointMake(_ball.center.x + tr.x, _ball.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) { [self snap]; [self startDockClock]; }
}

- (void)startDockClock {
    [_dockTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _dockTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(__unused NSTimer *t) {
        [weakSelf dock];
    }];
}
- (void)resetDockClock {
    if (_docked) return;
    [_dockTimer invalidate];
    [self startDockClock];
}

- (void)dock {
    if (_docked) return;
    _docked = YES;
    BOOL left = _ball.center.x < self.bounds.size.width / 2;
    _handle.frame = CGRectMake(left ? 0 : self.bounds.size.width - 14,
                               _ball.frame.origin.y + 3, 14, 46);
    [UIView animateWithDuration:0.25 animations:^{
        _ball.alpha = 0;
        _ball.transform = CGAffineTransformMakeScale(0.5, 0.5);
    } completion:^(__unused BOOL f) {
        _ball.hidden = YES;
        _handle.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ _handle.alpha = 1; }];
    }];
}

- (void)undock {
    if (!_docked) return;
    _docked = NO;
    _ball.hidden = NO;
    BOOL left = _handle.frame.origin.x < self.bounds.size.width / 2;
    _ball.center = CGPointMake(left ? 26 + 7 : self.bounds.size.width - 26 - 7, _handle.center.y);
    [UIView animateWithDuration:0.25 animations:^{
        _handle.alpha = 0;
        _ball.alpha = 1;
        _ball.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL f) {
        _handle.hidden = YES;
        [self startDockClock];
    }];
}

- (void)onTap {
    [self resetDockClock];
    BOOL newOff = !gLocalOff;
    [[NSUserDefaults standardUserDefaults] setBool:newOff forKey:kFBGLocalOff];
    gLocalOff = newOff;
    _fbg_recalc();
    notify_post([kFBGNotify UTF8String]);

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];

    [self refreshState];
    [UIView animateWithDuration:0.1 animations:^{
        _ball.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(__unused BOOL f) {
        [UIView animateWithDuration:0.1 animations:^{
            _ball.transform = CGAffineTransformIdentity;
        }];
    }];

    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"App";
    [FBGToastView showIn:self.rootViewController.view
                   title:appName
                subtitle:(newOff ? @"真后台 已暂停（本 App）" : @"真后台 已开启")
                iconName:(newOff ? @"powersleep" : @"hourglass")];

    if (newOff && gPhysBg) _fbg_stopAudio(YES);
}

@end

#pragma mark - 生命周期 / Darwin

static void _fbg_onEnterBackground(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    gPhysBg = YES;
    _fbg_startAudio();
}

static void _fbg_onEnterForeground(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    gPhysBg = NO;
    // 回前台只暂停播放、保留会话（mix 模式下不与 App 音频冲突）
    if (gPlayer.isPlaying) [gPlayer pause];
    if (gTask != 0) {
        [[UIApplication sharedApplication] endBackgroundTask:gTask];
        gTask = 0;
    }
}

static void _fbg_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    _fbg_loadPref();
    NSLog(@"[FUBG] prefs reloaded: active=%d scene=%d audio=%d ball=%d",
          gActive, gUseScene, gUseAudio, gShowBall);
    [[FBGFloatingWindow shared] refreshState];
    if (!gUseAudio && gPhysBg) _fbg_stopAudio(NO);
    if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) _fbg_startAudio();
}

#pragma mark - 入口

__attribute__((constructor))
static void _fbg_entry(void) {
    @autoreleasepool {
        _fbg_loadPref();

        // hook 一次性安装，内部按全局开关决定行为
        dispatch_async(dispatch_get_main_queue(), ^{
            _fbg_installSceneHooks();
        });

        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onEnterBackground,
            (__bridge CFStringRef)UIApplicationDidEnterBackgroundNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onEnterForeground,
            (__bridge CFStringRef)UIApplicationWillEnterForegroundNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onPrefReload,
            (__bridge CFStringRef)kFBGNotify, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ _fbg_onInterruption(n); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *n){
                if (gUseAudio && gPhysBg) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (gPlayer && !gPlayer.isPlaying) [gPlayer play];
                    });
                }
            }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gUseAudio) {
                gWatchdog = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                              block:^(NSTimer *t){ _fbg_watchdogFire(t); }];
                [[NSRunLoop mainRunLoop] addTimer:gWatchdog forMode:NSRunLoopCommonModes];
            }
            if (gShowBall) [[FBGFloatingWindow shared] attachWhenSceneReady];
        });

        NSLog(@"[FUBG] v2.0.0 loaded in %@: active=%d scene=%d audio=%d ball=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gActive, gUseScene, gUseAudio, gShowBall, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    }
}
