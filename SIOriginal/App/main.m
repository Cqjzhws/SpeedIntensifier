// SIOriginal — 配置 App（TrollStore 安装）
// 重制版配套配置器：写 Managed Preferences plist + 发 Darwin 通知热重载。
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

// unistd.h 已声明 reboot()，补 RB_AUTOBOOT
#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT 0
#endif
extern int reboot(int);

static NSString * const PrefPath  = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";
static NSString * const NotifyKey = @"com.local.sioriginal.settingschanged";

static void SpawnRoot(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // 99 = PERSONA_SYSTEM（root），TrollStore root spawn 的标准值
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    char *argv[args.count + 2];
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++)
        argv[i + 1] = (char *)[args[i] UTF8String];
    argv[args.count + 1] = NULL;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc == 0 && pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

// 不等待：reboot 成功时系统立即复位、永不返回，等待反而可能阻塞 UI
static void SpawnRootNowait(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid = -1;
    char *argv[args.count + 2];
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++)
        argv[i + 1] = (char *)[args[i] UTF8String];
    argv[args.count + 1] = NULL;
    posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
}

// 硬重启（移植自 SIFusion 已验证方案）：
// ① root persona 拉起自身 --sio-reboot-helper，子进程进 UIKit 前直调 reboot()（最可靠）
// ② /usr/sbin/reboot（iOS 15+ 路径）③ /sbin/reboot（旧路径）
// ④ killall launchd ⑤ killall backboardd
static NSString *SIOReboot(void) {
    pid_t pid;

    NSString *selfPath = [[NSBundle mainBundle] executablePath];
    if (selfPath.length) {
        posix_spawnattr_t attr0;
        posix_spawnattr_init(&attr0);
        posix_spawnattr_set_persona_np(&attr0, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attr0, 0);
        posix_spawnattr_set_persona_gid_np(&attr0, 0);
        char *a0[] = { (char *)[selfPath UTF8String], "--sio-reboot-helper", NULL };
        int s0 = posix_spawn(&pid, [selfPath UTF8String], NULL, &attr0, a0, environ);
        posix_spawnattr_destroy(&attr0);
        if (s0 == 0) return @"root 助手 reboot()";
    }

    const char *paths[] = { "/usr/sbin/reboot", "/sbin/reboot" };
    for (int i = 0; i < 2; i++) {
        posix_spawnattr_t a;
        posix_spawnattr_init(&a);
        posix_spawnattr_set_persona_np(&a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&a, 0);
        posix_spawnattr_set_persona_gid_np(&a, 0);
        char *av[] = { (char *)paths[i], NULL };
        int s = posix_spawn(&pid, paths[i], NULL, &a, av, environ);
        posix_spawnattr_destroy(&a);
        if (s == 0) return [NSString stringWithFormat:@"%s", paths[i]];
    }

    const char *kills[][3] = { {"/usr/bin/killall","-9","launchd"},
                               {"/usr/bin/killall","-9","backboardd"} };
    for (int i = 0; i < 2; i++) {
        posix_spawnattr_t a;
        posix_spawnattr_init(&a);
        posix_spawnattr_set_persona_np(&a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&a, 0);
        posix_spawnattr_set_persona_gid_np(&a, 0);
        char *av[] = { (char *)kills[i][0], (char *)kills[i][1], (char *)kills[i][2], NULL };
        int s = posix_spawn(&pid, kills[i][0], NULL, &a, av, environ);
        posix_spawnattr_destroy(&a);
        if (s == 0) return [NSString stringWithFormat:@"%s %s", kills[i][1], kills[i][2]];
    }
    return @"全部失败";
}

static void Respring(void) {
    // 先用 sysctl 直接杀，失败再走 root persona killall
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) == 0) {
        len += 16 * sizeof(struct kinfo_proc);
        struct kinfo_proc *list = malloc(len);
        if (list && sysctl(mib, 4, list, &len, NULL, 0) == 0) {
            int n = (int)(len / sizeof(struct kinfo_proc));
            for (int i = 0; i < n; i++)
                if (strncmp(list[i].kp_proc.p_comm, "SpringBoard", sizeof(list[i].kp_proc.p_comm)) == 0)
                    kill(list[i].kp_proc.p_pid, SIGKILL);
        }
        free(list);
    }
    SpawnRoot(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]);
}

static NSMutableDictionary *ReadConfig(void) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (!d[@"Enabled"])    d[@"Enabled"]    = @YES;
    if (!d[@"Mode"])       d[@"Mode"]       = @2;          // 瞬切 0.01s
    if (!d[@"Speed"])      d[@"Speed"]      = @5.0;
    if (!d[@"SlowFactor"]) d[@"SlowFactor"] = @2.0;
    if (!d[@"Spring"])     d[@"Spring"]     = @YES;
    if (!d[@"Extra"])      d[@"Extra"]      = @YES;
    if (!d[@"ListAccel"])  d[@"ListAccel"]  = @YES;        // 默认全开（微信已在 dylib 内硬保护）
    if (!d[@"Blacklist"])  d[@"Blacklist"]  = @[ @"com.tencent.wework" ];
    // 注入 App 内实时帧率 HUD（被动显示），默认开启
    if (!d[@"FPSEnabled"])        d[@"FPSEnabled"]        = @YES;
    // 真后台保活：默认全开
    if (!d[@"FUBGEnabled"])      d[@"FUBGEnabled"]      = @YES;
    if (!d[@"FUBGSceneFake"])    d[@"FUBGSceneFake"]    = @YES;
    if (!d[@"FUBGAudioKeep"])    d[@"FUBGAudioKeep"]    = @YES;
    if (!d[@"FUBGFloatingBall"]) d[@"FUBGFloatingBall"] = @YES;
    return d;
}

static BOOL WriteConfig(NSMutableDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    // 合并写入：保留 com.apple.UIKit.plist 原有系统键（如 UIAnimationDragCoefficient）
    NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    NSArray *sioKeys = @[ @"Enabled", @"Mode", @"Speed", @"SlowFactor",
                          @"Spring", @"Extra", @"ListAccel", @"Blacklist",
                          @"FPSEnabled",
                          @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                          @"FUBGFloatingBall", @"FUBGExcludeApps" ];
    for (NSString *k in sioKeys) {
        if (cfg[k]) merged[k] = cfg[k];
    }
    BOOL ok = [merged writeToFile:PrefPath atomically:YES];
    if (ok) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)NotifyKey, NULL, NULL, YES);
    }
    return ok;
}

static NSString *ModeText(int m) {
    return m == 1 ? @"慢放" : (m == 2 ? @"瞬切 0.01s" : @"加速");
}

// ---- 系统动态效果（辅助功能，需注销生效） ----
static NSString * const AxPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
static BOOL ReadAx(NSString *key) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AxPath];
    return d[key] ? [d[key] boolValue] : NO;
}
static void WriteAx(NSString *key, BOOL val) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:AxPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    d[key] = @(val);
    [d writeToFile:AxPath atomically:YES];
}

// ---- UIKit 全局动画系数（UIAnimationDragCoefficient，需重启目标 App / 注销） ----
static NSString * const UIKitPath = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";
static BOOL ReadUIKitDrag(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:UIKitPath];
    NSNumber *v = d[@"UIAnimationDragCoefficient"];
    return v != nil;
}
static void WriteUIKitDrag(BOOL enabled) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:UIKitPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (enabled) {
        d[@"UIAnimationDragCoefficient"] = @0.0001;  // 全局 UIKit 动画近乎瞬切
    } else {
        [d removeObjectForKey:@"UIAnimationDragCoefficient"];
    }
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [d writeToFile:UIKitPath atomically:YES];
}

#pragma mark - 全局高刷 PiP 引擎
// 移植自 Yoroin/GlobalRefresh-PiP（原 CaiWanFeng/PiP）的 VideoCall 路线：
// 透明画中画 VC 内挂 CADisplayLink 强请求 120Hz，PiP 存活期间拉起系统合成器全局高刷。
// 不注入、不 hook，对所有前台 App 生效；悬浮窗可缩到 0.1pt 视觉隐藏并吸附侧边。
@interface SIOPiPRefresh : NSObject <AVPictureInPictureControllerDelegate>
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, strong) AVPictureInPictureVideoCallViewController *contentVC;
@property (nonatomic, strong) UIView *sourceView;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) CGFloat pipHeight;
@property (nonatomic, assign) NSInteger retryToken;
@property (nonatomic, copy) void (^onStatus)(NSString *);
+ (instancetype)shared;
- (BOOL)supported;
- (void)startInHost:(UIView *)host height:(CGFloat)h;
- (void)updateHeight:(CGFloat)h;
- (void)stop;
@end

@implementation SIOPiPRefresh

+ (instancetype)shared {
    static SIOPiPRefresh *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [SIOPiPRefresh new]; });
    return s;
}

- (BOOL)supported {
    if (@available(iOS 15.0, *)) {
        return [AVPictureInPictureController isPictureInPictureSupported]
            && NSClassFromString(@"AVPictureInPictureVideoCallViewController") != nil
            && NSClassFromString(@"AVPictureInPictureControllerContentSource") != nil;
    }
    return NO;
}

- (void)post:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onStatus) self.onStatus(s);
    });
}

- (void)startInHost:(UIView *)host height:(CGFloat)h {
    if (self.running) { [self updateHeight:h]; return; }
    if (@available(iOS 15.0, *)) {
        if (![self supported]) { [self post:@"系统不支持（画中画高刷需 iOS 15+）"]; return; }
        self.pipHeight = h > 0 ? h : 0.1;

        UIView *src = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        src.backgroundColor = [UIColor clearColor];
        src.userInteractionEnabled = NO;
        [host addSubview:src];
        self.sourceView = src;

        AVPictureInPictureVideoCallViewController *vc =
            [[AVPictureInPictureVideoCallViewController alloc] init];
        vc.preferredContentSize = CGSizeMake(300, self.pipHeight);
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.opaque = NO;
        self.contentVC = vc;

        AVPictureInPictureControllerContentSource *cs =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithActiveVideoCallSourceView:src contentViewController:vc];
        AVPictureInPictureController *p = [[AVPictureInPictureController alloc] initWithContentSource:cs];
        p.delegate = self;
        self.pip = p;

        // 120Hz 强请求：minimum=maximum=preferred=120（与 GlobalRefresh 强拉一致）
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) {
            CAFrameRateRange r; r.minimum = 120; r.maximum = 120; r.preferred = 120;
            l.preferredFrameRateRange = r;
        }
        if ([l respondsToSelector:@selector(setPreferredFramesPerSecond:)])
            l.preferredFramesPerSecond = 120;
        [l addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.link = l;

        [self post:@"正在开启高刷悬浮窗…"];
        self.retryToken++;
        [self attemptStart:0 token:self.retryToken];
    }
}

- (void)attemptStart:(NSInteger)n token:(NSInteger)token {
    if (@available(iOS 15.0, *)) {
        if (!self.pip || token != self.retryToken) return;
        if (self.pip.pictureInPicturePossible) {
            [self.pip startPictureInPicture];
            return;
        }
        if (n < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self attemptStart:n+1 token:token]; });
        } else {
            [self post:@"开启超时：PiP 未就绪，请重试"];
            [self teardown];
        }
    }
}

- (void)tick:(CADisplayLink *)link { /* 仅维持 120Hz 帧请求 */ }

- (void)updateHeight:(CGFloat)h {
    self.pipHeight = h > 0 ? h : 0.1;
    if (@available(iOS 15.0, *))
        self.contentVC.preferredContentSize = CGSizeMake(300, self.pipHeight);
}

- (void)stop {
    self.retryToken++;
    if (self.pip) { @try { [self.pip stopPictureInPicture]; } @catch (__unused NSException *e) {} }
    [self teardown];
    [self post:@"已停止高刷悬浮窗"];
}

- (void)teardown {
    [self.link invalidate]; self.link = nil;
    [self.sourceView removeFromSuperview]; self.sourceView = nil;
    self.contentVC = nil;
    self.pip = nil;
    self.running = NO;
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pc {
    self.running = YES;
    [self post:@"运行中：拖到屏幕侧边吸附，再点“一键隐藏 0.1pt”"];
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pc {
    [self teardown];
    [self post:@"高刷悬浮窗已关闭"];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)pc
     failedToStartPictureInPictureWithError:(NSError *)error {
    [self post:[NSString stringWithFormat:@"开启失败：%@", error.localizedDescription ?: @"未知错误"]];
    [self teardown];
}

@end

@interface SIOVC : UIViewController
@end

@implementation SIOVC {
    UISwitch *_swEnabled, *_swSpring, *_swExtra, *_swList;
    UISegmentedControl *_segMode;
    UISlider *_slider;
    UILabel *_sliderLabel;
    UITextView *_blacklist;
    UILabel *_status;
    UISwitch *_swRM, *_swCF, *_swUIKit;
    UISwitch *_swFPS;
    UIButton *_pipStart, *_pipStop, *_pipHide;
    UISlider *_pipHeight;
    UILabel *_pipHeightLabel, *_pipStatus;
    UISwitch *_swFUBG, *_swFUBGScene, *_swFUBGAudio, *_swFUBGBall;
}

- (UIStackView *)row:(UIView *)l ctrl:(UIView *)c {
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[ l, c ]];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.alignment = UIStackViewAlignmentCenter;
    [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return h;
}

- (UILabel *)label:(NSString *)t size:(CGFloat)s dim:(BOOL)dim {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:s];
    l.textColor = dim ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    l.numberOfLines = 0;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    NSMutableDictionary *cfg = ReadConfig();
    int mode = [cfg[@"Mode"] intValue];
    double speed = [cfg[@"Speed"] doubleValue];

    UILabel *title = [self label:@"隔壁老王·王灿专用" size:24 dim:NO];
    title.font = [UIFont boldSystemFontOfSize:24];
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [self label:@"v1.7.0 · 高刷改为系统画中画全局 120Hz · 移除注入式强刷" size:13 dim:YES];
    sub.textAlignment = NSTextAlignmentCenter;

    _swEnabled = [[UISwitch alloc] init];
    _swEnabled.on = [cfg[@"Enabled"] boolValue];

    UILabel *lblMode = [self label:@"模式" size:17 dim:NO];
    _segMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放 ×2", @"瞬切" ]];
    _segMode.selectedSegmentIndex = (mode >= 0 && mode <= 2) ? mode : 0;
    [_segMode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];

    UILabel *lblSpeed = [self label:[NSString stringWithFormat:@"加速倍率（当前 ×%.1f）", speed] size:17 dim:NO];
    _sliderLabel = lblSpeed;
    _slider = [[UISlider alloc] init];
    _slider.minimumValue = 1.0;
    _slider.maximumValue = 20.0;
    _slider.continuous = YES;
    _slider.value = speed;
    [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];

    UILabel *lblSpring = [self label:@"弹簧参数缩放（保持物理一致性）" size:17 dim:NO];
    _swSpring = [[UISwitch alloc] init];
    _swSpring.on = [cfg[@"Spring"] boolValue];

    UILabel *lblExtra = [self label:@"进阶转场（导航栈 / 模态弹窗）" size:17 dim:NO];
    _swExtra = [[UISwitch alloc] init];
    _swExtra.on = [cfg[@"Extra"] boolValue];

    UILabel *lblList = [self label:@"列表加速 TV/CV（微信已硬保护）" size:17 dim:NO];
    lblList.textColor = [UIColor systemRedColor];
    _swList = [[UISwitch alloc] init];
    _swList.on = [cfg[@"ListAccel"] boolValue];
    _swList.onTintColor = [UIColor systemRedColor];

    UILabel *axTitle = [self label:@"系统动态效果（写入辅助功能，需注销生效）" size:15 dim:YES];
    UILabel *lblRM = [self label:@"减弱动态效果（系统级）" size:17 dim:NO];
    _swRM = [[UISwitch alloc] init];
    _swRM.on = ReadAx(@"ReduceMotionEnabled");
    UILabel *lblCF = [self label:@"首选交叉淡出过渡效果" size:17 dim:NO];
    _swCF = [[UISwitch alloc] init];
    _swCF.on = ReadAx(@"PreferCrossFadeTransitions");

    UILabel *uiKitTitle = [self label:@"UIKit 全局动画系数（写入 com.apple.UIKit，需注销/重启目标 App）" size:15 dim:YES];
    UILabel *lblUIKit = [self label:@"全局动画近乎瞬切（0.0001）" size:17 dim:NO];
    _swUIKit = [[UISwitch alloc] init];
    _swUIKit.on = ReadUIKitDrag();

    // === 实时帧率 HUD（注入 App 内被动显示） ===
    UILabel *hudTitle = [self label:@"实时帧率显示（注入 App 内）" size:15 dim:YES];
    UILabel *lblFPS = [self label:@"目标 App 显示实时帧率 HUD（可拖动）" size:17 dim:NO];
    _swFPS = [[UISwitch alloc] init];
    _swFPS.on = [cfg[@"FPSEnabled"] boolValue];

    // === 全局高刷 PiP 悬浮窗（系统合成层，全局 120Hz，无需注入） ===
    UILabel *pipTitle = [self label:@"全局高刷悬浮窗（画中画 · 全局 120Hz · 无需注入）" size:15 dim:YES];
    _pipStatus = [self label:@"未开启" size:13 dim:YES];
    _pipStatus.numberOfLines = 0;

    _pipStart = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pipStart setTitle:@"开启高刷悬浮窗" forState:UIControlStateNormal];
    _pipStart.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _pipStart.backgroundColor = [UIColor systemGreenColor];
    [_pipStart setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _pipStart.layer.cornerRadius = 10;
    [_pipStart.heightAnchor constraintEqualToConstant:42].active = YES;
    [_pipStart addTarget:self action:@selector(onPipStart) forControlEvents:UIControlEventTouchUpInside];

    _pipStop = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pipStop setTitle:@"停止悬浮窗" forState:UIControlStateNormal];
    _pipStop.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_pipStop setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    _pipStop.layer.cornerRadius = 10;
    _pipStop.layer.borderWidth = 1;
    _pipStop.layer.borderColor = [UIColor systemRedColor].CGColor;
    [_pipStop.heightAnchor constraintEqualToConstant:42].active = YES;
    [_pipStop addTarget:self action:@selector(onPipStop) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *pipBtns = [[UIStackView alloc] initWithArrangedSubviews:@[ _pipStart, _pipStop ]];
    pipBtns.axis = UILayoutConstraintAxisHorizontal;
    pipBtns.spacing = 10;
    pipBtns.distribution = UIStackViewDistributionFillEqually;

    _pipHeightLabel = [self label:@"悬浮窗高度：120 pt（吸附后再隐藏）" size:15 dim:NO];
    _pipHeight = [[UISlider alloc] init];
    _pipHeight.minimumValue = 0.1;
    _pipHeight.maximumValue = 120;
    _pipHeight.value = 120;
    [_pipHeight addTarget:self action:@selector(onPipHeight) forControlEvents:UIControlEventValueChanged];

    _pipHide = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pipHide setTitle:@"一键隐藏 0.1pt（吸附到侧边后点）" forState:UIControlStateNormal];
    _pipHide.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_pipHide setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    _pipHide.layer.cornerRadius = 10;
    _pipHide.layer.borderWidth = 1;
    _pipHide.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [_pipHide.heightAnchor constraintEqualToConstant:38].active = YES;
    [_pipHide addTarget:self action:@selector(onPipHide) forControlEvents:UIControlEventTouchUpInside];

    UILabel *pipHint = [self label:@"用法：开启→把悬浮窗拖到屏幕侧边吸附→点“一键隐藏”。此后所有前台 App 全局 120Hz，无需逐个注入。低电量模式会锁 60；个别自身硬锁 60 的游戏/弹幕可能出现帧率不同步顿挫。" size:12 dim:YES];
    pipHint.numberOfLines = 0;
    if (![SIOPiPRefresh shared].supported) {
        _pipStart.enabled = NO;
        _pipStatus.text = @"当前系统不支持画中画高刷（需 iOS 15+ / ProMotion 设备）";
    }
    [SIOPiPRefresh shared].onStatus = ^(NSString *s) { _pipStatus.text = s; };

    // === 真后台保活区块 ===
    UILabel *fubgTitle = [self label:@"真后台保活（FUBackground 引擎）" size:15 dim:YES];

    UILabel *lblFUBG = [self label:@"启用真后台保活" size:17 dim:NO];
    _swFUBG = [[UISwitch alloc] init];
    _swFUBG.on = [cfg[@"FUBGEnabled"] boolValue];

    UILabel *lblFUBGScene = [self label:@"场景伪装引擎（推荐）" size:17 dim:NO];
    _swFUBGScene = [[UISwitch alloc] init];
    _swFUBGScene.on = [cfg[@"FUBGSceneFake"] boolValue];

    UILabel *lblFUBGAudio = [self label:@"音频断言兜底（静音白噪）" size:17 dim:NO];
    _swFUBGAudio = [[UISwitch alloc] init];
    _swFUBGAudio.on = [cfg[@"FUBGAudioKeep"] boolValue];

    UILabel *lblFUBGBall = [self label:@"注入 App 悬浮球开关" size:17 dim:NO];
    _swFUBGBall = [[UISwitch alloc] init];
    _swFUBGBall.on = [cfg[@"FUBGFloatingBall"] boolValue];

    UILabel *lblBL = [self label:@"黑名单（每行一个 Bundle ID）" size:15 dim:YES];
    _blacklist = [[UITextView alloc] init];
    _blacklist.font = [UIFont systemFontOfSize:14];
    _blacklist.layer.borderColor = [UIColor separatorColor].CGColor;
    _blacklist.layer.borderWidth = 0.5;
    _blacklist.layer.cornerRadius = 8;
    _blacklist.text = [cfg[@"Blacklist"] componentsJoinedByString:@"\n"];
    [_blacklist.heightAnchor constraintEqualToConstant:88].active = YES;

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存配置（即时生效）" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    save.backgroundColor = [UIColor systemBlueColor];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.layer.cornerRadius = 12;
    [save.heightAnchor constraintEqualToConstant:48].active = YES;
    [save addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];

    UIButton *rs = [UIButton buttonWithType:UIButtonTypeSystem];
    [rs setTitle:@"注销 SpringBoard" forState:UIControlStateNormal];
    rs.layer.cornerRadius = 12;
    rs.layer.borderWidth = 1;
    rs.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [rs.heightAnchor constraintEqualToConstant:40].active = YES;
    [rs addTarget:self action:@selector(onRespring) forControlEvents:UIControlEventTouchUpInside];

    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    [rb setTitle:@"硬重启设备" forState:UIControlStateNormal];
    [rb setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    rb.layer.cornerRadius = 12;
    rb.layer.borderWidth = 1;
    rb.layer.borderColor = [UIColor systemRedColor].CGColor;
    [rb.heightAnchor constraintEqualToConstant:40].active = YES;
    [rb addTarget:self action:@selector(onReboot) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [self label:@"dylib 用 TrollFools 注入目标 App；保存后 Darwin 通知热重载，目标 App 内立即生效。慢放 = 原版 slowDownFactor 功能，可观察动画细节。瞬切 = 0.01 秒直达。" size:12 dim:YES];
    hint.textAlignment = NSTextAlignmentCenter;
    UILabel *listHint = [self label:@"列表加速含 24 个 TV/CV hook，企业微信/微信已双重保护（黑名单 + 硬编码）。其他重列表 App（淘宝/京东）若出现卡死请关闭此开关。" size:12 dim:YES];
    listHint.textColor = [UIColor systemOrangeColor];
    listHint.numberOfLines = 0;
    _status = [self label:@"" size:13 dim:YES];
    _status.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub,
        [self row:[self label:@"启用" size:17 dim:NO] ctrl:_swEnabled],
        lblMode, _segMode,
        _sliderLabel, _slider,
        [self row:lblSpring ctrl:_swSpring],
        [self row:lblExtra ctrl:_swExtra],
        [self row:lblList ctrl:_swList],
        axTitle,
        [self row:lblRM ctrl:_swRM],
        [self row:lblCF ctrl:_swCF],
        uiKitTitle,
        [self row:lblUIKit ctrl:_swUIKit],
        hudTitle,
        [self row:lblFPS ctrl:_swFPS],
        pipTitle,
        _pipStatus,
        pipBtns,
        _pipHeightLabel, _pipHeight,
        _pipHide,
        pipHint,
        fubgTitle,
        [self row:lblFUBG ctrl:_swFUBG],
        [self row:lblFUBGScene ctrl:_swFUBGScene],
        [self row:lblFUBGAudio ctrl:_swFUBGAudio],
        [self row:lblFUBGBall ctrl:_swFUBGBall],
        lblBL, _blacklist, save, rs, rb, listHint, hint, _status
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 13;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
    [self modeChanged];
}

- (void)modeChanged {
    int m = (int)_segMode.selectedSegmentIndex;
    _slider.hidden = (m != 0);
    _sliderLabel.hidden = (m != 0);
    _sliderLabel.text = [NSString stringWithFormat:@"加速倍率（当前 ×%.1f）", _slider.value];
}

- (void)sliderChanged {
    _sliderLabel.text = [NSString stringWithFormat:@"加速倍率（当前 ×%.1f）", _slider.value];
}

#pragma mark - 全局高刷 PiP
- (void)onPipStart {
    [[SIOPiPRefresh shared] startInHost:self.view height:_pipHeight.value];
}
- (void)onPipStop {
    [[SIOPiPRefresh shared] stop];
}
- (void)onPipHeight {
    CGFloat h = _pipHeight.value;
    _pipHeightLabel.text = [NSString stringWithFormat:@"悬浮窗高度：%.1f pt%@",
                            h, h <= 0.15 ? @"（已隐藏）" : (h >= 119 ? @"（吸附后再隐藏）" : @"")];
    if ([SIOPiPRefresh shared].running) [[SIOPiPRefresh shared] updateHeight:h];
}
- (void)onPipHide {
    _pipHeight.value = 0.1;
    [self onPipHeight];
}

- (void)onSave {
    NSMutableDictionary *cfg = ReadConfig();
    cfg[@"Enabled"] = @(_swEnabled.on);
    cfg[@"Mode"] = @((int)_segMode.selectedSegmentIndex);
    cfg[@"Speed"] = @((double)_slider.value);
    cfg[@"Spring"] = @(_swSpring.on);
    cfg[@"Extra"] = @(_swExtra.on);
    cfg[@"ListAccel"] = @(_swList.on);
    // 注入 App 实时帧率 HUD（被动显示）
    cfg[@"FPSEnabled"] = @(_swFPS.on);
    // 真后台保活
    cfg[@"FUBGEnabled"] = @(_swFUBG.on);
    cfg[@"FUBGSceneFake"] = @(_swFUBGScene.on);
    cfg[@"FUBGAudioKeep"] = @(_swFUBGAudio.on);
    cfg[@"FUBGFloatingBall"] = @(_swFUBGBall.on);
    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }
    cfg[@"Blacklist"] = bl;
    BOOL ok = WriteConfig(cfg);
    WriteAx(@"ReduceMotionEnabled", _swRM.on);
    WriteAx(@"PreferCrossFadeTransitions", _swCF.on);
    WriteUIKitDrag(_swUIKit.on);

    UINotificationFeedbackGenerator *fg = [[UINotificationFeedbackGenerator alloc] init];
    [fg prepare];
    if (ok) {
        [fg notificationOccurred:UINotificationFeedbackTypeSuccess];
        NSString *msg = [NSString stringWithFormat:@"已保存：%@ · %@ · 弹簧%@ · 转场%@ · 列表%@",
                        _swEnabled.on ? @"开" : @"关",
                        ModeText((int)_segMode.selectedSegmentIndex),
                        _swSpring.on ? @"开" : @"关",
                        _swExtra.on ? @"开" : @"关",
                        _swList.on ? @"开" : @"关"];
        _status.text = msg;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"✅ 配置已保存"
                            message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [fg notificationOccurred:UINotificationFeedbackTypeError];
        _status.text = @"❌ 保存失败，请检查权限";
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"❌ 保存失败"
                            message:@"无法写入 com.apple.UIKit.plist，请确认 TrollStore 权限正常。"
                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)onRespring {
    [self onSave];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
}

- (void)onReboot {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"确认硬重启"
                        message:@"将以 root 权限直接重启设备（不是注销）。所有未保存数据可能丢失。"
                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [self onSave];
        NSString *way = SIOReboot();
        _status.text = [NSString stringWithFormat:@"重启触发：%@", way];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

@interface SIOAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SIOAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[SIOVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 硬重启助手：以 root persona 被拉起，进 UIKit 前直调 reboot()（最可靠路径）
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--sio-reboot-helper"]) {
            reboot(RB_AUTOBOOT);
            // 不返回；万一返回，killall launchd 兜底
            pid_t pid;
            posix_spawnattr_t attr;
            posix_spawnattr_init(&attr);
            posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
            posix_spawnattr_set_persona_uid_np(&attr, 0);
            posix_spawnattr_set_persona_gid_np(&attr, 0);
            char *a[] = { "/usr/bin/killall", "-9", "launchd", NULL };
            posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a, environ);
            posix_spawnattr_destroy(&attr);
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIOAppDelegate class]));
    }
}
