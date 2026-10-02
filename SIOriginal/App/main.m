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

// v1.8.14：列表 hook 硬保护名单 —— 必须与 dylib 内 SIO_listHardBlocked() 保持一致。
// 名单内 App 的列表加速恒为关闭，配置界面直接置灰，避免用户以为"打开了但没生效"。
static NSArray *HardGuardBundles(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[ @"com.sfic.knight" ]; });
    return a;
}

static void SpawnRoot(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
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
    if (!d[@"Mode"])       d[@"Mode"]       = @2;
    if (!d[@"Speed"])      d[@"Speed"]      = @5.0;
    if (!d[@"SlowFactor"]) d[@"SlowFactor"] = @2.0;
    if (!d[@"Spring"])     d[@"Spring"]     = @YES;
    if (!d[@"Extra"])      d[@"Extra"]      = @YES;
    if (!d[@"ListAccel"])  d[@"ListAccel"]  = @NO;
    // v1.8.15：缩放动画加速，默认关闭（同一族在微信上出过「预览页卡死」）
    if (!d[@"ZoomAccel"])  d[@"ZoomAccel"]  = @NO;
    if (!d[@"Blacklist"])  d[@"Blacklist"]  = @[ @"com.tencent.wework" ];
    if (!d[@"FUBGEnabled"])      d[@"FUBGEnabled"]      = @YES;
    if (!d[@"FUBGSceneFake"])    d[@"FUBGSceneFake"]    = @YES;
    if (!d[@"FUBGAudioKeep"])    d[@"FUBGAudioKeep"]    = @YES;
    if (!d[@"FUBGFloatingBall"]) d[@"FUBGFloatingBall"] = @NO;
    if (!d[@"AppOverrides"])     d[@"AppOverrides"]     = @{};
    return d;
}

static BOOL WriteConfig(NSMutableDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    NSArray *sioKeys = @[ @"Enabled", @"Mode", @"Speed", @"SlowFactor",
                          @"Spring", @"Extra", @"ListAccel", @"Blacklist", @"ZoomAccel",
                          @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                          @"FUBGFloatingBall", @"FUBGExcludeApps", @"AppOverrides" ];
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
        d[@"UIAnimationDragCoefficient"] = @0.0001;
    } else {
        [d removeObjectForKey:@"UIAnimationDragCoefficient"];
    }
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [d writeToFile:UIKitPath atomically:YES];
}

@interface SIOVC : UIViewController
@end

@implementation SIOVC {
    UISwitch *_swEnabled, *_swSpring, *_swExtra, *_swList, *_swZoom;
    UISegmentedControl *_segMode;
    UISlider *_slider;
    UILabel *_sliderLabel;
    UITextView *_blacklist;
    UILabel *_status;
    UISwitch *_swRM, *_swCF, *_swUIKit;
    UISwitch *_swFUBG, *_swFUBGScene, *_swFUBGAudio, *_swFUBGBall;
    // v1.8.14 App 专属覆盖
    UITextField *_ovBundle;
    UISwitch *_ovOn, *_ovSpring, *_ovExtra, *_ovList, *_ovZoom;
    UISlider *_ovSpeed;
    UILabel *_ovSpeedLabel, *_ovGuard;
    UISegmentedControl *_ovMode;
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
    UILabel *sub = [self label:@"v1.8.15 · 顺丰同城骑士针对性适配" size:13 dim:YES];
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
    // v1.8.15：上限 20 → 50。修正 CAAnimation 双重缩放后，高倍率重新有意义
    // （此前显式 CAAnimation 实际吃的是 speed²，×5 相当于 ×25）
    _slider.maximumValue = 50.0;
    _slider.continuous = YES;
    _slider.value = speed;
    [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];

    UILabel *lblSpring = [self label:@"弹簧参数缩放（保持物理一致性）" size:17 dim:NO];
    _swSpring = [[UISwitch alloc] init];
    _swSpring.on = [cfg[@"Spring"] boolValue];

    UILabel *lblExtra = [self label:@"进阶转场（导航栈 / 模态弹窗）" size:17 dim:NO];
    _swExtra = [[UISwitch alloc] init];
    _swExtra.on = [cfg[@"Extra"] boolValue];

    UILabel *lblList = [self label:@"列表加速 TV/CV（重列表 App 保持关闭）" size:17 dim:NO];
    lblList.textColor = [UIColor systemRedColor];
    _swList = [[UISwitch alloc] init];
    _swList.on = [cfg[@"ListAccel"] boolValue];
    _swList.onTintColor = [UIColor systemRedColor];

    // v1.8.15：UIScrollView 缩放动画（setZoomScale:animated: / zoomToRect:animated:）
    UILabel *lblZoom = [self label:@"缩放动画加速（实验，图片预览异常就关掉）" size:17 dim:NO];
    _swZoom = [[UISwitch alloc] init];
    _swZoom.on = [cfg[@"ZoomAccel"] boolValue];

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

    UILabel *lblFUBGBall = [self label:@"悬浮球（已全局禁用）" size:17 dim:YES];
    _swFUBGBall = [[UISwitch alloc] init];
    _swFUBGBall.on = [cfg[@"FUBGFloatingBall"] boolValue];
    _swFUBGBall.enabled = NO;

    // === v1.8.14 App 专属覆盖 ===
    // 配置文件是全局的：给某一个 App 调参数会连带影响所有注入的 App。
    // 这里为指定 Bundle ID 写一份独立配置，优先级高于全局值，互不干扰。
    UILabel *ovTitle = [self label:@"App 专属覆盖（只影响该 Bundle ID，不影响其他 App）" size:15 dim:YES];

    NSDictionary *ovAllCfg = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                             ? cfg[@"AppOverrides"] : @{};
    NSString *ovFirst = ovAllCfg[@"com.sfic.knight"] ? @"com.sfic.knight"
                      : ([ovAllCfg.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject
                         ?: @"com.sfic.knight");

    _ovBundle = [[UITextField alloc] init];
    _ovBundle.text = ovFirst;
    _ovBundle.placeholder = @"com.sfic.knight";
    _ovBundle.borderStyle = UITextBorderStyleRoundedRect;
    _ovBundle.font = [UIFont systemFontOfSize:14];
    _ovBundle.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _ovBundle.autocorrectionType = UITextAutocorrectionTypeNo;
    _ovBundle.spellCheckingType = UITextSpellCheckingTypeNo;
    _ovBundle.keyboardType = UIKeyboardTypeURL;
    _ovBundle.clearButtonMode = UITextFieldViewModeWhileEditing;
    _ovBundle.returnKeyType = UIReturnKeyDone;
    [_ovBundle addTarget:self action:@selector(ovBundleChanged)
        forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
    [_ovBundle.heightAnchor constraintEqualToConstant:36].active = YES;

    UILabel *lblOvOn = [self label:@"为该 App 启用专属配置" size:17 dim:NO];
    _ovOn = [[UISwitch alloc] init];
    // 只刷新提示文案，绝不回读 plist —— 否则开关会被立刻重置回当前已保存状态
    [_ovOn addTarget:self action:@selector(ovToggled) forControlEvents:UIControlEventValueChanged];

    _ovSpeedLabel = [self label:@"专属倍率（当前 ×5.0）" size:17 dim:NO];
    _ovSpeed = [[UISlider alloc] init];
    _ovSpeed.minimumValue = 1.0;
    _ovSpeed.maximumValue = 50.0;
    _ovSpeed.value = 5.0;
    _ovSpeed.continuous = YES;
    [_ovSpeed addTarget:self action:@selector(ovSliderChanged) forControlEvents:UIControlEventValueChanged];

    _ovMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放 ×2", @"瞬切" ]];
    _ovMode.selectedSegmentIndex = 0;

    UILabel *lblOvSpring = [self label:@"专属：弹簧参数缩放" size:17 dim:NO];
    _ovSpring = [[UISwitch alloc] init];
    _ovSpring.on = YES;
    UILabel *lblOvExtra = [self label:@"专属：进阶转场" size:17 dim:NO];
    _ovExtra = [[UISwitch alloc] init];
    _ovExtra.on = YES;
    UILabel *lblOvList = [self label:@"专属：列表加速（高危）" size:17 dim:NO];
    lblOvList.textColor = [UIColor systemRedColor];
    _ovList = [[UISwitch alloc] init];
    _ovList.on = NO;
    _ovList.onTintColor = [UIColor systemRedColor];
    UILabel *lblOvZoom = [self label:@"专属：缩放动画加速（实验）" size:17 dim:NO];
    _ovZoom = [[UISwitch alloc] init];
    _ovZoom.on = NO;
    _ovGuard = [self label:@"" size:12 dim:YES];
    _ovGuard.textColor = [UIColor systemOrangeColor];
    _ovGuard.numberOfLines = 0;

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

    UILabel *hint = [self label:@"dylib 用 TrollFools 注入目标 App；保存后 Darwin 通知热重载，目标 App 内立即生效。慢放 = 原版 slowDownFactor 功能，可观察动画细节。瞬切 = 0.01 秒直达。\n\n⚠️ v1.8.15（依据顺丰同城骑士 11.5.0 拆包证据）：① 修正 CAAnimation 残留双重缩放 —— 此前 App「先设时长再 addAnimation」会被连缩两次，实际倍率是 speed²（显示 ×5 其实 ÷25）并频繁撞 0.01s 下限，本 App 的高德地图相机动画（MAMapKeyFrameAnimation）正吃这个 bug；修正后若觉得变慢，把倍率从 5 提到 15–25 即可等价。② 新增缩放动画加速开关「ZoomAccel」（默认关，本 App 的 NXDesign 确实在用 setZoomScale:animated:，但这一族在微信上出过预览卡死，请先小范围试）。③ 倍率上限 20 → 50。\n\n本 App UI 是原生 UIKit + 数百个 nib，动画 hook 正常生效；老式 beginAnimations/setAnimationDuration: 与关键帧动画本 App 都在用。SVGA / Ugen 引擎动画为自驱，无法用改时长加速。" size:12 dim:YES];
    hint.textAlignment = NSTextAlignmentCenter;
    UILabel *listHint = [self label:@"列表加速含 24 个 TV/CV hook，默认关闭。⚠️ 顺丰同城骑士 com.sfic.knight 在硬保护名单内，列表加速恒为关闭，任何配置都打不开（该 App 只会走其余 34 个非列表 hook）。淘宝/京东等重列表 App 同样必须保持关闭，否则破坏列表状态机导致卡死。" size:12 dim:YES];
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
        [self row:lblZoom ctrl:_swZoom],
        axTitle,
        [self row:lblRM ctrl:_swRM],
        [self row:lblCF ctrl:_swCF],
        uiKitTitle,
        [self row:lblUIKit ctrl:_swUIKit],
        fubgTitle,
        [self row:lblFUBG ctrl:_swFUBG],
        [self row:lblFUBGScene ctrl:_swFUBGScene],
        [self row:lblFUBGAudio ctrl:_swFUBGAudio],
        [self row:lblFUBGBall ctrl:_swFUBGBall],
        ovTitle, _ovBundle,
        [self row:lblOvOn ctrl:_ovOn],
        _ovSpeedLabel, _ovSpeed, _ovMode,
        [self row:lblOvSpring ctrl:_ovSpring],
        [self row:lblOvExtra ctrl:_ovExtra],
        [self row:lblOvList ctrl:_ovList],
        [self row:lblOvZoom ctrl:_ovZoom],
        _ovGuard,
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
    [self ovBundleChanged];
}

// v1.8.14：切换 Bundle ID 时把该 App 已有的专属配置读进控件，并刷新硬保护提示
- (void)ovBundleChanged {
    NSString *bid = [_ovBundle.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    if (!bid.length) bid = @"com.sfic.knight";

    id allRaw = [NSDictionary dictionaryWithContentsOfFile:PrefPath][@"AppOverrides"];
    NSDictionary *all = [allRaw isKindOfClass:[NSDictionary class]] ? allRaw : @{};
    id mineRaw = all[bid];
    NSDictionary *mine = [mineRaw isKindOfClass:[NSDictionary class]] ? mineRaw : nil;

    _ovOn.on = (mine != nil);

    double sp = mine[@"Speed"] ? [mine[@"Speed"] doubleValue] : 5.0;
    if (sp < 1.0 || sp > 50.0) sp = 5.0;
    _ovSpeed.value = sp;
    _ovSpeedLabel.text = [NSString stringWithFormat:@"专属倍率（当前 ×%.1f）", sp];

    int m = mine[@"Mode"] ? [mine[@"Mode"] intValue] : 0;
    _ovMode.selectedSegmentIndex = (m >= 0 && m <= 2) ? m : 0;

    _ovSpring.on = mine[@"Spring"] ? [mine[@"Spring"] boolValue] : YES;
    _ovExtra.on  = mine[@"Extra"]  ? [mine[@"Extra"] boolValue]  : YES;
    _ovList.on   = mine[@"ListAccel"] ? [mine[@"ListAccel"] boolValue] : NO;
    _ovZoom.on   = mine[@"ZoomAccel"] ? [mine[@"ZoomAccel"] boolValue] : NO;

    BOOL guarded = [HardGuardBundles() containsObject:bid];
    _ovList.enabled = !guarded;
    if (guarded) {
        _ovList.on = NO;
        _ovGuard.text = [NSString stringWithFormat:
            @"⚠️ %@ 在列表 hook 硬保护名单内：列表加速恒为关闭，开关与配置都无法打开（dylib 启动日志会打印 listGuard=1）。该 App 的加速只走其余 34 个非列表 hook。", bid];
    } else if (mine) {
        _ovGuard.text = [NSString stringWithFormat:@"已存在 %@ 的专属配置，修改后点「保存配置」生效。", bid];
    } else {
        _ovGuard.text = [NSString stringWithFormat:@"%@ 暂无专属配置。打开「为该 App 启用专属配置」再保存即可创建。", bid];
    }
}

- (void)ovSliderChanged {
    _ovSpeedLabel.text = [NSString stringWithFormat:@"专属倍率（当前 ×%.1f）", _ovSpeed.value];
}

// 勾选/取消「启用专属配置」时只更新提示，不动控件值
- (void)ovToggled {
    NSString *bid = [_ovBundle.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    if (!bid.length) bid = @"com.sfic.knight";
    if ([HardGuardBundles() containsObject:bid]) {
        _ovGuard.text = [NSString stringWithFormat:
            @"⚠️ %@ 在列表 hook 硬保护名单内：列表加速恒为关闭，开关与配置都无法打开。该 App 的加速只走其余 34 个非列表 hook。", bid];
    } else if (_ovOn.on) {
        _ovGuard.text = [NSString stringWithFormat:@"保存后将为 %@ 创建专属配置（优先级高于全局值）。", bid];
    } else {
        _ovGuard.text = [NSString stringWithFormat:@"保存后将删除 %@ 的专属配置，该 App 回到全局配置。", bid];
    }
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

- (void)onSave {
    NSMutableDictionary *cfg = ReadConfig();
    cfg[@"Enabled"] = @(_swEnabled.on);
    cfg[@"Mode"] = @((int)_segMode.selectedSegmentIndex);
    cfg[@"Speed"] = @((double)_slider.value);
    cfg[@"Spring"] = @(_swSpring.on);
    cfg[@"Extra"] = @(_swExtra.on);
    cfg[@"ListAccel"] = @(_swList.on);
    cfg[@"ZoomAccel"] = @(_swZoom.on);
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

    // v1.8.14：写入 / 删除 App 专属覆盖
    NSString *ovBid = [_ovBundle.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
    id ovAllRaw = [NSDictionary dictionaryWithContentsOfFile:PrefPath][@"AppOverrides"];
    NSMutableDictionary *ovOut = [ovAllRaw isKindOfClass:[NSDictionary class]]
                                 ? [ovAllRaw mutableCopy] : [NSMutableDictionary dictionary];
    if (ovBid.length) {
        if (_ovOn.on) {
            BOOL guarded = [HardGuardBundles() containsObject:ovBid];
            ovOut[ovBid] = @{
                @"Enabled":   @YES,
                @"Mode":      @((int)_ovMode.selectedSegmentIndex),
                @"Speed":     @((double)_ovSpeed.value),
                @"Spring":    @(_ovSpring.on),
                @"Extra":     @(_ovExtra.on),
                // 硬保护名单内恒写 NO，避免配置文件里留下一个会被 dylib 忽略的 YES
                @"ListAccel": @(guarded ? NO : _ovList.on),
                @"ZoomAccel": @(_ovZoom.on),
            };
        } else {
            [ovOut removeObjectForKey:ovBid];
        }
    }
    cfg[@"AppOverrides"] = ovOut;

    BOOL ok = WriteConfig(cfg);
    WriteAx(@"ReduceMotionEnabled", _swRM.on);
    WriteAx(@"PreferCrossFadeTransitions", _swCF.on);
    WriteUIKitDrag(_swUIKit.on);

    UINotificationFeedbackGenerator *fg = [[UINotificationFeedbackGenerator alloc] init];
    [fg prepare];
    if (ok) {
        [fg notificationOccurred:UINotificationFeedbackTypeSuccess];
        NSString *msg = [NSString stringWithFormat:@"已保存：%@ · %@ · 弹簧%@ · 转场%@ · 列表%@ · 专属%@",
                        _swEnabled.on ? @"开" : @"关",
                        ModeText((int)_segMode.selectedSegmentIndex),
                        _swSpring.on ? @"开" : @"关",
                        _swExtra.on ? @"开" : @"关",
                        _swList.on ? @"开" : @"关",
                        (_ovOn.on && ovBid.length) ? ovBid : @"无"];
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
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--sio-reboot-helper"]) {
            reboot(RB_AUTOBOOT);
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
