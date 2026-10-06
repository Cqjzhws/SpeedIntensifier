// SIOriginal — 配置 App v2.0.0 Max（TrollStore 安装）
// 重制版配套配置器：写 Managed Preferences plist + 发 Darwin 通知热重载。
// v2.0.0：Tab 卡片式 UI、一键预设、配置导入/导出、注入环境自检、新引擎参数。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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
static NSString * const kAppliedNote = @"SIOModelDidApply";
static NSString * const SIO_VERSION = @"v2.0.6 Max";

// v1.8.14：列表 hook 硬保护名单 —— 必须与 dylib 内 SIO_listHardBlocked() 保持一致。
static NSArray *HardGuardBundles(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[ @"com.sfic.knight" ]; });
    return a;
}

#pragma mark - root 执行工具

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

#pragma mark - 配置读写（v2.0.0 全量键）

static NSMutableDictionary *ReadConfig(void) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (!d[@"Enabled"])    d[@"Enabled"]    = @YES;
    if (!d[@"Mode"])       d[@"Mode"]       = @2;
    if (!d[@"Speed"])      d[@"Speed"]      = @5.0;
    if (!d[@"SlowFactor"]) d[@"SlowFactor"] = @2.0;
    if (!d[@"Spring"])     d[@"Spring"]     = @YES;
    if (!d[@"Extra"])      d[@"Extra"]      = @NO;  // v2.0.4：默认关闭导航 hook
    if (!d[@"ListAccel"])  d[@"ListAccel"]  = @NO;
    if (!d[@"ZoomAccel"])  d[@"ZoomAccel"]  = @NO;
    if (!d[@"FastScroll"]) d[@"FastScroll"] = @NO;   // v2.0.6：回退默认关闭
    if (!d[@"FastTap"])    d[@"FastTap"]    = @NO;   // v2.0.6：回退默认关闭
    if (!d[@"LayerBoost"]) d[@"LayerBoost"] = @1.0;
    // v2.0.0 Max 新引擎参数缺省值（必须与 dylib SIO_reload 的缺省一致）
    if (!d[@"FloorDuration"])    d[@"FloorDuration"]    = @0.01;
    if (!d[@"TransitionBoost"])  d[@"TransitionBoost"]  = @1.0;
    if (!d[@"FastLongPress"])    d[@"FastLongPress"]    = @NO;
    if (!d[@"LongPressDuration"])d[@"LongPressDuration"]= @0.30;
    if (!d[@"InAppNotify"])      d[@"InAppNotify"]      = @YES;
    if (!d[@"Blacklist"])  d[@"Blacklist"]  = @[ @"com.tencent.wework" ];
    if (!d[@"FUBGEnabled"])      d[@"FUBGEnabled"]      = @NO;
    if (!d[@"FUBGSceneFake"])    d[@"FUBGSceneFake"]    = @NO;
    if (!d[@"FUBGAudioKeep"])    d[@"FUBGAudioKeep"]    = @NO;
    if (!d[@"FUBGFloatingBall"]) d[@"FUBGFloatingBall"] = @NO;
    if (!d[@"AppOverrides"])     d[@"AppOverrides"]     = @{};
    return d;
}

// 白名单：只有这里的键会被写入 plist（新增引擎键必须同步登记）
static NSArray *SIOConfigKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"Enabled", @"Mode", @"Speed", @"SlowFactor",
                  @"Spring", @"Extra", @"ListAccel", @"Blacklist", @"ZoomAccel",
                  @"FastScroll", @"FastTap", @"LayerBoost",
                  @"FloorDuration", @"TransitionBoost",
                  @"FastLongPress", @"LongPressDuration", @"InAppNotify",
                  @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                  @"FUBGFloatingBall", @"FUBGExcludeApps", @"AppOverrides" ];
    });
    return keys;
}

static BOOL WriteConfig(NSMutableDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    for (NSString *k in SIOConfigKeys()) {
        if (cfg[k]) merged[k] = cfg[k];
    }
    BOOL ok = [merged writeToFile:PrefPath atomically:YES];
    if (ok) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)NotifyKey, NULL, NULL, YES);
    }
    return ok;
}

#pragma mark - 辅助功能 / UIKit 全局系数

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

static double ReadUIKitDrag(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PrefPath];
    NSNumber *v = d[@"UIAnimationDragCoefficient"];
    return v ? v.doubleValue : 0.0;
}
static void WriteUIKitDrag(double coeff) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (coeff > 0.0) {
        d[@"UIAnimationDragCoefficient"] = @(coeff);
    } else {
        [d removeObjectForKey:@"UIAnimationDragCoefficient"];
    }
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [d writeToFile:PrefPath atomically:YES];
}
// 分档索引 → 系数：0=关闭 1=×5(0.2) 2=×10(0.1) 3=×20(0.05) 4=极端(0.0001)
static double DragCoeffForIndex(int i) {
    switch (i) {
        case 1:  return 0.2;
        case 2:  return 0.1;
        case 3:  return 0.05;
        case 4:  return 0.0001;
        default: return 0.0;
    }
}
static int DragIndexForCoeff(double c) {
    if (c > 0.04 && c < 0.06)  return 3;
    if (c > 0.08 && c < 0.12)  return 2;
    if (c > 0.15 && c < 0.25)  return 1;
    if (c > 0.0 && c < 0.04)   return 4;
    return 0;
}
static int DragMultiplierForCoeff(double c) {
    if (c > 0.04 && c < 0.06)  return 20;
    if (c > 0.08 && c < 0.12)  return 10;
    if (c > 0.15 && c < 0.25)  return 5;
    return 0;
}

#pragma mark - 档位映射（与 dylib 接受范围严格一致）

// 显式动画额外倍率：×1 / ×2 / ×3 / ×5 / ×10
static double LayerBoostForIndex(int i) {
    switch (i) {
        case 1:  return 2.0;
        case 2:  return 3.0;
        case 3:  return 5.0;
        case 4:  return 10.0;
        default: return 1.0;
    }
}
static int LayerIndexForBoost(double b) {
    if (b > 1.5 && b < 2.5)  return 1;
    if (b > 2.5 && b < 4.0)  return 2;
    if (b > 4.0 && b < 7.0)  return 3;
    if (b >= 7.0)            return 4;
    return 0;
}
// 慢放倍率：×2 / ×3 / ×5 / ×10
static double SlowFactorForIndex(int i) {
    switch (i) {
        case 1:  return 3.0;
        case 2:  return 5.0;
        case 3:  return 10.0;
        default: return 2.0;
    }
}
static int SlowIndexForFactor(double f) {
    if (f > 2.5 && f < 4.0)  return 1;
    if (f > 4.0 && f < 7.0)  return 2;
    if (f >= 7.0)            return 3;
    return 0;
}
// 时长安全下限：0.005 / 0.01 / 0.02 / 0.05
static double FloorForIndex(int i) {
    switch (i) {
        case 1:  return 0.01;
        case 2:  return 0.02;
        case 3:  return 0.05;
        default: return 0.005;
    }
}
static int FloorIndexFor(double f) {
    if (f > 0.0075 && f < 0.015) return 1;
    if (f > 0.015  && f < 0.035) return 2;
    if (f >= 0.035)              return 3;
    return 0;
}
// 转场独立倍率：×1 / ×1.5 / ×2 / ×3
static double TransForIndex(int i) {
    switch (i) {
        case 1:  return 1.5;
        case 2:  return 2.0;
        case 3:  return 3.0;
        default: return 1.0;
    }
}
static int TransIndexFor(double t) {
    if (t > 1.25 && t < 1.75) return 1;
    if (t >= 1.75 && t < 2.5) return 2;
    if (t >= 2.5)             return 3;
    return 0;
}
// 长按时长：0.20 / 0.30 / 0.40
static double LPDurForIndex(int i) {
    switch (i) {
        case 1:  return 0.30;
        case 2:  return 0.40;
        default: return 0.20;
    }
}
static int LPIndexForDur(double d) {
    if (d > 0.25 && d < 0.35) return 1;
    if (d >= 0.35)            return 2;
    return 0;
}

#pragma mark - UI 小部件构造

static UILabel *SIOLabel(NSString *t, CGFloat size, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:size];
    l.textColor = color ?: [UIColor labelColor];
    l.numberOfLines = 0;
    return l;
}

static UIView *SIORow(NSString *title, UIView *ctrl, UIColor *titleColor) {
    UILabel *l = SIOLabel(title, 16, titleColor);
    [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[ l, ctrl ]];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.alignment = UIStackViewAlignmentCenter;
    h.spacing = 12;
    return h;
}

static UIView *SIOCard(NSArray<UIView *> *items, CGFloat spacing) {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:items];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = spacing;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [st.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [st.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [st.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
    ]];
    return card;
}

static UIButton *SIOPill(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.layer.masksToBounds = YES;
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    return b;
}

static UILabel *SIOSectionTitle(NSString *t) {
    UILabel *l = SIOLabel(t, 13, [UIColor secondaryLabelColor]);
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    return l;
}

// 渐变头部（CAGradientLayer 子层；QuartzCore 在 App 链接框架内，避免裸 CoreGraphics 符号）
@interface SIOGradientHeader : UIView {
    CAGradientLayer *_grad;
}
@end
@implementation SIOGradientHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 20;
        self.layer.masksToBounds = YES;
        _grad = [CAGradientLayer layer];
        _grad.colors = @[
            (id)[UIColor colorWithRed:0.10 green:0.45 blue:0.32 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.03 green:0.07 blue:0.16 alpha:1.0].CGColor,
        ];
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(0, 1);
        [self.layer insertSublayer:_grad atIndex:0];
        UILabel *t = SIOLabel(@"隔壁老王 · 王灿专用", 24, [UIColor whiteColor]);
        t.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        UILabel *s = SIOLabel([NSString stringWithFormat:@"SIOriginal %@ · 动画加速超强版", SIO_VERSION],
                              13, [UIColor colorWithWhite:1 alpha:0.78]);
        t.translatesAutoresizingMaskIntoConstraints = NO;
        s.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:t];
        [self addSubview:s];
        [NSLayoutConstraint activateConstraints:@[
            [t.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [t.bottomAnchor constraintEqualToAnchor:s.topAnchor constant:-4],
            [s.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
            [s.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _grad.frame = self.bounds;
}
@end

#pragma mark - 配置模型（持有全部控件，跨 4 个 Tab 统一保存）

@class SIOModel;

@interface SIOModel : NSObject
// 引擎页
@property (strong) UISwitch *swEnabled;
@property (strong) UISegmentedControl *segMode;
@property (strong) UISlider *slSpeed;
@property (strong) UILabel *lblSpeed;
@property (strong) UISegmentedControl *segSlow;
@property (strong) UIView *slowWrap;
@property (strong) UISegmentedControl *segFloor;
@property (strong) UILabel *lblFloor;
@property (strong) UISegmentedControl *segLayer;
@property (strong) UILabel *lblLayer;
@property (strong) UISegmentedControl *segTrans;
@property (strong) UILabel *lblTrans;
@property (strong) UISwitch *swSpring, *swExtra;
// 手感页
@property (strong) UISwitch *swList, *swZoom, *swFastScroll, *swFastTap;
@property (strong) UISwitch *swLongPress;
@property (strong) UISegmentedControl *segLPDur;
@property (strong) UISwitch *swNotify;
// 系统页
@property (strong) UISwitch *swRM, *swCF, *swRT;
@property (strong) UISegmentedControl *segDrag;
@property (strong) UILabel *lblDrag;
@property (strong) UISwitch *swFUBG, *swFUBGScene, *swFUBGAudio, *swFUBGBall;
// 高级页：专属覆盖
@property (strong) UITextField *ovBundle;
@property (strong) UISwitch *ovOn, *ovSpring, *ovExtra, *ovList, *ovZoom;
@property (strong) UISwitch *ovFastScroll, *ovFastTap, *ovLongPress;
@property (strong) UISlider *ovSpeed;
@property (strong) UILabel *ovSpeedLabel, *ovGuard;
@property (strong) UISegmentedControl *ovMode, *ovLayer, *ovFloor, *ovTrans, *ovLPDur;
// 高级页：黑名单
@property (strong) UITextView *blacklist;

- (void)loadControlValues;
- (BOOL)save;
- (NSString *)summary;
- (void)applyPreset:(NSInteger)i;
- (NSString *)exportConfig;                 // nil = 失败
- (NSString *)importConfig:(NSString *)json; // nil=成功，否则错误描述
- (NSString *)checkReport;
- (void)refreshOverrides;
@end

@implementation SIOModel

- (void)loadControlValues {
    NSMutableDictionary *c = ReadConfig();
    self.swEnabled.on = [c[@"Enabled"] boolValue];
    int mode = [c[@"Mode"] intValue];
    self.segMode.selectedSegmentIndex = (mode >= 0 && mode <= 2) ? mode : 0;
    double speed = [c[@"Speed"] doubleValue];
    if (speed < 1.0 || speed > 50.0) speed = 5.0;
    self.slSpeed.value = (float)speed;
    self.segSlow.selectedSegmentIndex = SlowIndexForFactor([c[@"SlowFactor"] doubleValue]);
    self.segFloor.selectedSegmentIndex = FloorIndexFor([c[@"FloorDuration"] doubleValue]);
    self.segLayer.selectedSegmentIndex = LayerIndexForBoost([c[@"LayerBoost"] doubleValue]);
    self.segTrans.selectedSegmentIndex = TransIndexFor([c[@"TransitionBoost"] doubleValue]);
    self.swSpring.on = [c[@"Spring"] boolValue];
    self.swExtra.on = [c[@"Extra"] boolValue];

    self.swList.on = [c[@"ListAccel"] boolValue];
    self.swZoom.on = [c[@"ZoomAccel"] boolValue];
    self.swFastScroll.on = [c[@"FastScroll"] boolValue];
    self.swFastTap.on = [c[@"FastTap"] boolValue];
    self.swLongPress.on = [c[@"FastLongPress"] boolValue];
    self.segLPDur.selectedSegmentIndex = LPIndexForDur([c[@"LongPressDuration"] doubleValue]);
    self.swNotify.on = [c[@"InAppNotify"] boolValue];
    self.blacklist.text = [c[@"Blacklist"] componentsJoinedByString:@"\n"];

    self.swRM.on = ReadAx(@"ReduceMotionEnabled");
    self.swCF.on = ReadAx(@"PreferCrossFadeTransitions");
    self.swRT.on = ReadAx(@"ReduceTransparencyEnabled");
    self.segDrag.selectedSegmentIndex = DragIndexForCoeff(ReadUIKitDrag());

    self.swFUBG.on = [c[@"FUBGEnabled"] boolValue];
    self.swFUBGScene.on = [c[@"FUBGSceneFake"] boolValue];
    self.swFUBGAudio.on = [c[@"FUBGAudioKeep"] boolValue];
    self.swFUBGBall.on = [c[@"FUBGFloatingBall"] boolValue];

    // 专属覆盖默认 bundle
    NSDictionary *ovAll = [c[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                          ? c[@"AppOverrides"] : @{};
    NSString *first = ovAll[@"com.sfic.knight"] ? @"com.sfic.knight"
                    : ([ovAll.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject
                       ?: @"com.sfic.knight");
    self.ovBundle.text = first;
    [self refreshOverrides];
    [self refreshDynamicLabels];
}

- (void)refreshDynamicLabels {
    int mode = (int)self.segMode.selectedSegmentIndex;
    self.slSpeed.hidden = (mode != 0);
    self.lblSpeed.hidden = (mode != 0);
    self.slowWrap.hidden = (mode != 1);
    self.lblSpeed.text = [NSString stringWithFormat:@"加速倍率（当前 ×%.1f，上限 ×50）", self.slSpeed.value];

    double fl = FloorForIndex((int)self.segFloor.selectedSegmentIndex);
    self.lblFloor.text = [NSString stringWithFormat:
        @"所有动画的时长下限：%@。追求极致选 0.005s（风险自担）；遇到卡顿/回调异常请调回 0.01s 或更高。瞬切模式也使用该下限。",
        fl < 0.009 ? [NSString stringWithFormat:@"%.3fs", fl]
                   : [NSString stringWithFormat:@"%.2fs", fl]];

    double lb = LayerBoostForIndex((int)self.segLayer.selectedSegmentIndex);
    self.lblLayer.text = lb <= 1.0001
        ? @"×1 = 不额外加速。转圈/进度/旋转/地图相机按全局倍率缩放。"
        : [NSString stringWithFormat:@"转圈/进度/旋转/地图相机等显式动画在全局倍率上再 ÷%.0f。不影响 UIView 块动画与转场；慢放不叠加；受下限保护。", lb];

    double tb = TransForIndex((int)self.segTrans.selectedSegmentIndex);
    self.lblTrans.text = tb <= 1.0001
        ? @"×1 = 不额外加速。push/pop/模态弹窗按全局倍率缩放。"
        : [NSString stringWithFormat:@"导航/模态/Tab 转场在全局倍率上再 ÷%.1f，块动画不受影响；慢放不叠加。", tb];

    self.segLPDur.enabled = self.swLongPress.on;
}

- (void)refreshOverrides {
    NSString *bid = [self.ovBundle.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    if (!bid.length) bid = @"com.sfic.knight";
    id allRaw = [NSDictionary dictionaryWithContentsOfFile:PrefPath][@"AppOverrides"];
    NSDictionary *all = [allRaw isKindOfClass:[NSDictionary class]] ? allRaw : @{};
    id mineRaw = all[bid];
    NSDictionary *mine = [mineRaw isKindOfClass:[NSDictionary class]] ? mineRaw : nil;

    self.ovOn.on = (mine != nil);
    double sp = mine[@"Speed"] ? [mine[@"Speed"] doubleValue] : 5.0;
    if (sp < 1.0 || sp > 50.0) sp = 5.0;
    self.ovSpeed.value = (float)sp;
    self.ovSpeedLabel.text = [NSString stringWithFormat:@"专属倍率（当前 ×%.1f）", sp];
    int m = mine[@"Mode"] ? [mine[@"Mode"] intValue] : 0;
    self.ovMode.selectedSegmentIndex = (m >= 0 && m <= 2) ? m : 0;
    self.ovSpring.on = mine[@"Spring"] ? [mine[@"Spring"] boolValue] : YES;
    self.ovExtra.on  = mine[@"Extra"]  ? [mine[@"Extra"] boolValue]  : YES;
    self.ovList.on   = mine[@"ListAccel"] ? [mine[@"ListAccel"] boolValue] : NO;
    self.ovZoom.on   = mine[@"ZoomAccel"] ? [mine[@"ZoomAccel"] boolValue] : NO;
    self.ovFastScroll.on = mine[@"FastScroll"] ? [mine[@"FastScroll"] boolValue] : NO;
    self.ovFastTap.on    = mine[@"FastTap"]    ? [mine[@"FastTap"] boolValue]    : NO;
    self.ovLongPress.on  = mine[@"FastLongPress"] ? [mine[@"FastLongPress"] boolValue] : NO;
    self.ovLPDur.selectedSegmentIndex = LPIndexForDur(mine[@"LongPressDuration"] ? [mine[@"LongPressDuration"] doubleValue] : 0.30);
    self.ovLPDur.enabled = self.ovLongPress.on;
    self.ovLayer.selectedSegmentIndex = LayerIndexForBoost(mine[@"LayerBoost"] ? [mine[@"LayerBoost"] doubleValue] : 1.0);
    self.ovFloor.selectedSegmentIndex = FloorIndexFor(mine[@"FloorDuration"] ? [mine[@"FloorDuration"] doubleValue] : 0.01);
    self.ovTrans.selectedSegmentIndex = TransIndexFor(mine[@"TransitionBoost"] ? [mine[@"TransitionBoost"] doubleValue] : 1.0);

    BOOL guarded = [HardGuardBundles() containsObject:bid];
    self.ovList.enabled = !guarded;
    if (guarded) {
        self.ovList.on = NO;
        self.ovGuard.text = [NSString stringWithFormat:
            @"⚠️ %@ 在列表 hook 硬保护名单：列表加速恒关，无法打开（dylib 启动日志 listGuard=1）。其余 hook 正常加速。", bid];
        self.ovGuard.textColor = [UIColor systemOrangeColor];
    } else if (mine) {
        self.ovGuard.text = [NSString stringWithFormat:@"已存在 %@ 的专属配置，改完点右上角「保存」生效。", bid];
        self.ovGuard.textColor = [UIColor secondaryLabelColor];
    } else {
        self.ovGuard.text = [NSString stringWithFormat:@"%@ 暂无专属配置；打开开关并保存即可创建。", bid];
        self.ovGuard.textColor = [UIColor secondaryLabelColor];
    }
}

- (NSArray *)blacklistFromView {
    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [self.blacklist.text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }
    return bl;
}

- (BOOL)save {
    NSMutableDictionary *cfg = ReadConfig();
    cfg[@"Enabled"] = @(self.swEnabled.on);
    cfg[@"Mode"] = @((int)self.segMode.selectedSegmentIndex);
    cfg[@"Speed"] = @((double)self.slSpeed.value);
    cfg[@"SlowFactor"] = @(SlowFactorForIndex((int)self.segSlow.selectedSegmentIndex));
    cfg[@"Spring"] = @(self.swSpring.on);
    cfg[@"Extra"] = @(self.swExtra.on);
    cfg[@"ListAccel"] = @(self.swList.on);
    cfg[@"ZoomAccel"] = @(self.swZoom.on);
    cfg[@"FastScroll"] = @(self.swFastScroll.on);
    cfg[@"FastTap"] = @(self.swFastTap.on);
    cfg[@"LayerBoost"] = @(LayerBoostForIndex((int)self.segLayer.selectedSegmentIndex));
    cfg[@"FloorDuration"] = @(FloorForIndex((int)self.segFloor.selectedSegmentIndex));
    cfg[@"TransitionBoost"] = @(TransForIndex((int)self.segTrans.selectedSegmentIndex));
    cfg[@"FastLongPress"] = @(self.swLongPress.on);
    cfg[@"LongPressDuration"] = @(LPDurForIndex((int)self.segLPDur.selectedSegmentIndex));
    cfg[@"InAppNotify"] = @(self.swNotify.on);
    cfg[@"Blacklist"] = [self blacklistFromView];

    cfg[@"FUBGEnabled"] = @(self.swFUBG.on);
    cfg[@"FUBGSceneFake"] = @(self.swFUBGScene.on);
    cfg[@"FUBGAudioKeep"] = @(self.swFUBGAudio.on);
    cfg[@"FUBGFloatingBall"] = @(self.swFUBGBall.on);

    // App 专属覆盖（保留其它 bundle 的既有条目）
    NSString *ovBid = [self.ovBundle.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
    id ovAllRaw = [NSDictionary dictionaryWithContentsOfFile:PrefPath][@"AppOverrides"];
    NSMutableDictionary *ovOut = [ovAllRaw isKindOfClass:[NSDictionary class]]
                                 ? [ovAllRaw mutableCopy] : [NSMutableDictionary dictionary];
    if (ovBid.length) {
        if (self.ovOn.on) {
            BOOL guarded = [HardGuardBundles() containsObject:ovBid];
            ovOut[ovBid] = @{
                @"Enabled":   @YES,
                @"Mode":      @((int)self.ovMode.selectedSegmentIndex),
                @"Speed":     @((double)self.ovSpeed.value),
                @"Spring":    @(self.ovSpring.on),
                @"Extra":     @(self.ovExtra.on),
                @"ListAccel": @(guarded ? NO : self.ovList.on),
                @"ZoomAccel": @(self.ovZoom.on),
                @"FastScroll": @(self.ovFastScroll.on),
                @"FastTap":    @(self.ovFastTap.on),
                @"LayerBoost": @(LayerBoostForIndex((int)self.ovLayer.selectedSegmentIndex)),
                @"FloorDuration":   @(FloorForIndex((int)self.ovFloor.selectedSegmentIndex)),
                @"TransitionBoost": @(TransForIndex((int)self.ovTrans.selectedSegmentIndex)),
                @"FastLongPress":   @(self.ovLongPress.on),
                @"LongPressDuration": @(LPDurForIndex((int)self.ovLPDur.selectedSegmentIndex)),
            };
        } else {
            [ovOut removeObjectForKey:ovBid];
        }
    }
    cfg[@"AppOverrides"] = ovOut;

    BOOL ok = WriteConfig(cfg);
    WriteAx(@"ReduceMotionEnabled", self.swRM.on);
    WriteAx(@"PreferCrossFadeTransitions", self.swCF.on);
    WriteAx(@"ReduceTransparencyEnabled", self.swRT.on);
    WriteUIKitDrag(DragCoeffForIndex((int)self.segDrag.selectedSegmentIndex));
    return ok;
}

- (NSString *)summary {
    int mode = (int)self.segMode.selectedSegmentIndex;
    NSString *detail;
    if (mode == 0) detail = [NSString stringWithFormat:@"加速 ×%.1f", self.slSpeed.value];
    else if (mode == 1) detail = [NSString stringWithFormat:@"慢放 ×%.0f",
                                  SlowFactorForIndex((int)self.segSlow.selectedSegmentIndex)];
    else detail = [NSString stringWithFormat:@"瞬切（下限 %@）",
                   FloorForIndex((int)self.segFloor.selectedSegmentIndex) < 0.009
                     ? [NSString stringWithFormat:@"%.3fs", FloorForIndex((int)self.segFloor.selectedSegmentIndex)]
                     : [NSString stringWithFormat:@"%.2fs", FloorForIndex((int)self.segFloor.selectedSegmentIndex)]];
    return [NSString stringWithFormat:@"%@ · %@ · 显式×%.0f · 转场×%.1f · 弹簧%@ · 滑行%@ · 点按%@ · 长按%@",
            self.swEnabled.on ? @"已启用" : @"已暂停", detail,
            LayerBoostForIndex((int)self.segLayer.selectedSegmentIndex),
            TransForIndex((int)self.segTrans.selectedSegmentIndex),
            self.swSpring.on ? @"开" : @"关",
            self.swFastScroll.on ? @"开" : @"关",
            self.swFastTap.on ? @"开" : @"关",
            self.swLongPress.on ? @"开" : @"关"];
}

// 一键预设：改控件 → 发通知让页面刷新 → 由调用方负责 save
- (void)applyPreset:(NSInteger)i {
    self.swEnabled.on = YES;
    self.segMode.selectedSegmentIndex = 0;
    self.segFloor.selectedSegmentIndex = 1;   // 0.01
    self.segLayer.selectedSegmentIndex = 0;  // ×1
    self.segTrans.selectedSegmentIndex = 0;  // ×1
    self.swSpring.on = YES;
    self.swExtra.on = YES;
    self.swList.on = NO;
    self.swZoom.on = NO;
    self.swFastScroll.on = NO;
    self.swFastTap.on = NO;
    self.swLongPress.on = NO;
    self.segLPDur.selectedSegmentIndex = 1;  // 0.30
    self.segSlow.selectedSegmentIndex = 0;
    self.slSpeed.value = 5.0f;
    self.swNotify.on = YES;
    // v2.0.1：预设统一关闭保活引擎，避免注入后目标 App 闪退
    self.swFUBG.on = NO;
    self.swFUBGScene.on = NO;
    self.swFUBGAudio.on = NO;

    switch (i) {
        case 0: // 极速
            self.slSpeed.value = 15.0f;
            self.segFloor.selectedSegmentIndex = 0;  // 0.005
            self.segLayer.selectedSegmentIndex = 2;  // ×3
            self.segTrans.selectedSegmentIndex = 2;  // ×2
            self.swFastScroll.on = YES;
            self.swFastTap.on = YES;
            self.swLongPress.on = YES;
            self.segLPDur.selectedSegmentIndex = 0;  // 0.20
            break;
        case 1: // 均衡
            self.slSpeed.value = 5.0f;
            self.swFastScroll.on = YES;
            self.swFastTap.on = YES;
            self.swLongPress.on = YES;
            break;
        case 2: // 保守
            self.slSpeed.value = 2.0f;
            self.segFloor.selectedSegmentIndex = 2;  // 0.02
            break;
        case 3: // 瞬切
            self.segMode.selectedSegmentIndex = 2;
            self.segFloor.selectedSegmentIndex = 1;
            self.segLayer.selectedSegmentIndex = 1;  // ×2
            self.segTrans.selectedSegmentIndex = 2;  // ×2
            self.swFastScroll.on = YES;
            self.swFastTap.on = YES;
            self.swLongPress.on = YES;
            break;
    }
    [self refreshDynamicLabels];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAppliedNote object:nil];
}

- (NSString *)exportConfig {
    NSMutableDictionary *d = [ReadConfig() mutableCopy];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"_format"] = @"SIOriginalConfig";
    out[@"_version"] = SIO_VERSION;
    for (NSString *k in SIOConfigKeys()) {
        if (d[k]) out[k] = d[k];
    }
    out[@"UIAnimationDragCoefficient"] = @(ReadUIKitDrag());
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (err || !data) return nil;
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"sioriginal-config-v2.json"];
    [data writeToFile:path atomically:YES];
    [UIPasteboard generalPasteboard].string = str;
    return path;
}

- (NSString *)importConfig:(NSString *)json {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![obj isKindOfClass:[NSDictionary class]])
        return @"剪贴板内容不是有效的 JSON 配置";
    NSDictionary *d = obj;

    // 布尔键
    NSArray *boolKeys = @[ @"Enabled", @"Spring", @"Extra", @"ListAccel", @"ZoomAccel",
                           @"FastScroll", @"FastTap", @"FastLongPress", @"InAppNotify",
                           @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                           @"FUBGFloatingBall" ];
    for (NSString *k in boolKeys) {
        if (d[k]) {
            UISwitch *sw = [self switchForKey:k];
            if (sw && [d[k] isKindOfClass:[NSNumber class]]) sw.on = [d[k] boolValue];
        }
    }
    if ([d[@"Mode"] isKindOfClass:[NSNumber class]]) {
        int m = [d[@"Mode"] intValue];
        if (m >= 0 && m <= 2) self.segMode.selectedSegmentIndex = m;
    }
    if ([d[@"Speed"] isKindOfClass:[NSNumber class]]) {
        double v = [d[@"Speed"] doubleValue];
        if (v >= 1.0 && v <= 50.0) self.slSpeed.value = (float)v;
    }
    if ([d[@"SlowFactor"] isKindOfClass:[NSNumber class]])
        self.segSlow.selectedSegmentIndex = SlowIndexForFactor([d[@"SlowFactor"] doubleValue]);
    if ([d[@"FloorDuration"] isKindOfClass:[NSNumber class]])
        self.segFloor.selectedSegmentIndex = FloorIndexFor([d[@"FloorDuration"] doubleValue]);
    if ([d[@"LayerBoost"] isKindOfClass:[NSNumber class]])
        self.segLayer.selectedSegmentIndex = LayerIndexForBoost([d[@"LayerBoost"] doubleValue]);
    if ([d[@"TransitionBoost"] isKindOfClass:[NSNumber class]])
        self.segTrans.selectedSegmentIndex = TransIndexFor([d[@"TransitionBoost"] doubleValue]);
    if ([d[@"LongPressDuration"] isKindOfClass:[NSNumber class]])
        self.segLPDur.selectedSegmentIndex = LPIndexForDur([d[@"LongPressDuration"] doubleValue]);
    if ([d[@"Blacklist"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *lines = [NSMutableArray array];
        for (id x in d[@"Blacklist"])
            if ([x isKindOfClass:[NSString class]]) [lines addObject:x];
        self.blacklist.text = [lines componentsJoinedByString:@"\n"];
    }
    if ([d[@"UIAnimationDragCoefficient"] isKindOfClass:[NSNumber class]])
        self.segDrag.selectedSegmentIndex = DragIndexForCoeff([d[@"UIAnimationDragCoefficient"] doubleValue]);

    [self refreshDynamicLabels];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAppliedNote object:nil];
    return nil;
}

- (UISwitch *)switchForKey:(NSString *)k {
    if ([k isEqualToString:@"Enabled"]) return self.swEnabled;
    if ([k isEqualToString:@"Spring"]) return self.swSpring;
    if ([k isEqualToString:@"Extra"]) return self.swExtra;
    if ([k isEqualToString:@"ListAccel"]) return self.swList;
    if ([k isEqualToString:@"ZoomAccel"]) return self.swZoom;
    if ([k isEqualToString:@"FastScroll"]) return self.swFastScroll;
    if ([k isEqualToString:@"FastTap"]) return self.swFastTap;
    if ([k isEqualToString:@"FastLongPress"]) return self.swLongPress;
    if ([k isEqualToString:@"InAppNotify"]) return self.swNotify;
    if ([k isEqualToString:@"FUBGEnabled"]) return self.swFUBG;
    if ([k isEqualToString:@"FUBGSceneFake"]) return self.swFUBGScene;
    if ([k isEqualToString:@"FUBGAudioKeep"]) return self.swFUBGAudio;
    if ([k isEqualToString:@"FUBGFloatingBall"]) return self.swFUBGBall;
    return nil;
}

- (NSString *)checkReport {
    NSMutableString *r = [NSMutableString string];
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    [r appendFormat:@"SIOriginal 配置器 %@（build %@）\n",
        info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    [r appendFormat:@"Bundle ID：%@\n\n", info[@"CFBundleIdentifier"] ?: @"?"];

    [r appendString:@"【权限 / 路径自检】\n"];
    const char *dir = "/var/Managed Preferences/mobile";
    [r appendFormat:@"%s 配置目录可写：%@\n", dir, access(dir, W_OK) == 0 ? @"✅" : @"❌"];
    BOOL plistExists = [[NSFileManager defaultManager] fileExistsAtPath:PrefPath];
    [r appendFormat:@"UIKit.plist 存在：%@\n", plistExists ? @"✅" : @"➖ 尚未保存过"];
    BOOL axWritable = access("/var/mobile/Library/Preferences", W_OK) == 0;
    [r appendFormat:@"辅助功能目录可写：%@\n\n", axWritable ? @"✅" : @"❌"];

    [r appendString:@"【当前引擎配置】\n"];
    [r appendFormat:@"%@\n\n", [self summary]];

    [r appendString:@"【注入方式提醒】\n"];
    [r appendString:@"本 App 只负责写配置并发 Darwin 热重载通知；动画引擎 SIOriginal.dylib 需用 TrollFools 注入目标 App。保存配置后，前台目标 App 顶部会出现 1.5 秒生效提示（可在「手感」页关闭）。\n\n"];

    [r appendString:@"【硬保护】\n"];
    [r appendFormat:@"列表 hook 恒关名单：%@、com.apple.springboard（防止黑屏/白苹果）。\n",
        [HardGuardBundles() componentsJoinedByString:@"、"]];
    return r;
}

@end

#pragma mark - 页面基类

@interface SIOPageVC : UIViewController
@property (weak) SIOModel *model;
@property (strong) UIStackView *stack;
- (void)buildContent;      // 子类重写
- (void)uiApplied;         // 子类重写（预设/导入后刷新）
- (void)saveTapped;
@end

@implementation SIOPageVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.delaysContentTouches = NO;
    scroll.canCancelContentTouches = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(saveTapped)];

    [self buildContent];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(noteApplied)
                                                 name:kAppliedNote object:nil];
}

- (void)noteApplied { [self uiApplied]; }
- (void)buildContent {}
- (void)uiApplied {}

- (void)saveTapped {
    BOOL ok = [self.model save];
    UINotificationFeedbackGenerator *fg = [[UINotificationFeedbackGenerator alloc] init];
    [fg prepare];
    if (ok) {
        [fg notificationOccurred:UINotificationFeedbackTypeSuccess];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"✅ 配置已保存并热重载"
            message:[self.model summary] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [fg notificationOccurred:UINotificationFeedbackTypeError];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"❌ 保存失败"
            message:@"无法写入 com.apple.UIKit.plist，请确认 TrollStore 权限正常。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

#pragma mark - ① 引擎页

@interface SIOEngineVC : SIOPageVC
@end
@implementation SIOEngineVC

- (void)buildContent {
    SIOModel *m = self.model;

    SIOGradientHeader *header = [[SIOGradientHeader alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header.heightAnchor constraintEqualToConstant:108].active = YES;
    [self.stack addArrangedSubview:header];

    // 一键预设
    UIButton *p1 = SIOPill(@"🚀 极速", [UIColor systemGreenColor], [UIColor whiteColor]);
    UIButton *p2 = SIOPill(@"⚖️ 均衡", [UIColor systemBlueColor], [UIColor whiteColor]);
    UIButton *p3 = SIOPill(@"🛡 保守", [UIColor systemGrayColor], [UIColor whiteColor]);
    UIButton *p4 = SIOPill(@"⚡ 瞬切", [UIColor systemOrangeColor], [UIColor whiteColor]);
    p1.tag = 0; p2.tag = 1; p3.tag = 2; p4.tag = 3;
    for (UIButton *b in @[p1,p2,p3,p4])
        [b addTarget:self action:@selector(preset:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *presetRow = [[UIStackView alloc] initWithArrangedSubviews:@[p1,p2,p3,p4]];
    presetRow.axis = UILayoutConstraintAxisHorizontal;
    presetRow.distribution = UIStackViewDistributionFillEqually;
    presetRow.spacing = 8;
    [self.stack addArrangedSubview:SIOSectionTitle(@"一键预设（点击立即套用并保存）")];
    [self.stack addArrangedSubview:presetRow];

    // 总开关 + 模式
    m.swEnabled = [[UISwitch alloc] init];
    m.segMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    [m.segMode addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"启用动画引擎", m.swEnabled, nil),
        SIOLabel(@"模式", 16, [UIColor labelColor]),
        m.segMode,
    ], 10)];

    // 倍率组
    m.lblSpeed = SIOLabel(@"", 16, [UIColor labelColor]);
    m.slSpeed = [[UISlider alloc] init];
    m.slSpeed.minimumValue = 1.0f;
    m.slSpeed.maximumValue = 50.0f;
    [m.slSpeed addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.segSlow = [[UISegmentedControl alloc] initWithItems:@[ @"×2", @"×3", @"×5", @"×10" ]];
    [m.segSlow addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    UIStackView *slowStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        SIOLabel(@"慢放倍率", 16, [UIColor labelColor]), m.segSlow ]];
    slowStack.axis = UILayoutConstraintAxisVertical;
    slowStack.spacing = 8;
    m.slowWrap = slowStack;
    [self.stack addArrangedSubview:SIOCard(@[
        m.lblSpeed, m.slSpeed,
        m.slowWrap,
    ], 10)];

    // v2.0.0 新引擎组
    UILabel *ft = SIOLabel(@"动画时长下限", 16, [UIColor labelColor]);
    m.segFloor = [[UISegmentedControl alloc] initWithItems:@[ @"0.005", @"0.01", @"0.02", @"0.05" ]];
    [m.segFloor addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.lblFloor = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);

    UILabel *lt = SIOLabel(@"显式动画额外倍率", 16, [UIColor labelColor]);
    m.segLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    [m.segLayer addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.lblLayer = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);

    UILabel *tt = SIOLabel(@"转场独立额外倍率", 16, [UIColor labelColor]);
    m.segTrans = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×1.5", @"×2", @"×3" ]];
    [m.segTrans addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.lblTrans = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:SIOCard(@[
        ft, m.segFloor, m.lblFloor,
        lt, m.segLayer, m.lblLayer,
        tt, m.segTrans, m.lblTrans,
    ], 10)];

    // 弹簧 / 转场开关
    m.swSpring = [[UISwitch alloc] init];
    m.swExtra = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"弹簧参数缩放（保持物理一致性）", m.swSpring, nil),
        SIORow(@"进阶转场（导航栈 / 模态 / Tab）", m.swExtra, nil),
    ], 12)];

    UILabel *hint = SIOLabel(
        @"提示：高倍率 + 0.005 下限属于极限组合，个别 App 可能出现动画完成回调异常，调回 0.01s 即可。慢放模式下额外倍率均不叠加。",
        12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:hint];
}

- (void)changed { [self.model refreshDynamicLabels]; }
- (void)uiApplied { [self.model refreshDynamicLabels]; }

- (void)preset:(UIButton *)b {
    NSString *name = [b titleForState:UIControlStateNormal];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"套用预设 %@？", name]
        message:@"预设会覆盖当前引擎/手感参数（黑名单与 App 专属覆盖不受影响），并立即保存热重载。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"套用并保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        [self.model applyPreset:b.tag];
        BOOL ok = [self.model save];
        UIAlertController *r = [UIAlertController
            alertControllerWithTitle:ok ? [NSString stringWithFormat:@"✅ %@ 已生效", name] : @"❌ 保存失败"
            message:ok ? [self.model summary] : @"请确认 TrollStore 写权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:r animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - ② 手感页

@interface SIOFeelVC : SIOPageVC
@end
@implementation SIOFeelVC

- (void)buildContent {
    SIOModel *m = self.model;
    self.title = @"手感 · 列表";

    m.swFastScroll = [[UISwitch alloc] init];
    m.swFastTap = [[UISwitch alloc] init];
    m.swLongPress = [[UISwitch alloc] init];
    [m.swLongPress addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.segLPDur = [[UISegmentedControl alloc] initWithItems:@[ @"0.20s", @"0.30s", @"0.40s" ]];
    [m.segLPDur addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.swNotify = [[UISwitch alloc] init];

    [self.stack addArrangedSubview:SIOSectionTitle(@"交互跟手")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"滑行惯性加急（setter 强黏，防 App 改回）", m.swFastScroll, nil),
        SIORow(@"点击零延迟（delaysContentTouches 强黏）", m.swFastTap, nil),
        SIORow(@"长按手势加速（系统默认 0.5s 下压）", m.swLongPress, nil),
        SIOLabel(@"长按触发时长", 15, m.swLongPress.on ? [UIColor labelColor] : [UIColor tertiaryLabelColor]),
        m.segLPDur,
        SIORow(@"保存后在目标 App 顶部弹生效提示", m.swNotify, nil),
    ], 12)];

    m.swZoom = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOSectionTitle(@"滚动 / 缩放")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"缩放动画加速（实验，图片预览异常就关）", m.swZoom, nil),
    ], 12)];

    // 列表加速（高危组）
    m.swList = [[UISwitch alloc] init];
    m.swList.onTintColor = [UIColor systemRedColor];
    [self.stack addArrangedSubview:SIOSectionTitle(@"高危项")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"列表加速 TV/CV", m.swList, [UIColor systemRedColor]),
    ], 12)];

    UILabel *warn = SIOLabel(
        @"⚠️ 硬保护名单：顺丰同城骑士 com.sfic.knight、桌面进程 com.apple.springboard —— 列表加速恒为关闭，任何配置都打不开（SpringBoard 打开会黑屏/白苹果）。淘宝/京东等重列表 App 也建议保持关闭。",
        12, [UIColor systemOrangeColor]);
    [self.stack addArrangedSubview:warn];

    UILabel *blacklistTitle = SIOSectionTitle(@"黑名单（每行一个 Bundle ID，命中则完全不加速）");
    m.blacklist = [[UITextView alloc] init];
    m.blacklist.translatesAutoresizingMaskIntoConstraints = NO;
    m.blacklist.editable = YES;
    m.blacklist.selectable = YES;
    m.blacklist.scrollEnabled = YES;
    m.blacklist.font = [UIFont systemFontOfSize:14];
    m.blacklist.textColor = [UIColor labelColor];
    m.blacklist.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    m.blacklist.layer.borderColor = [UIColor separatorColor].CGColor;
    m.blacklist.layer.borderWidth = 0.5;
    m.blacklist.layer.cornerRadius = 10;
    m.blacklist.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    m.blacklist.autocapitalizationType = UITextAutocapitalizationTypeNone;
    m.blacklist.autocorrectionType = UITextAutocorrectionTypeNo;
    m.blacklist.spellCheckingType = UITextSpellCheckingTypeNo;
    m.blacklist.keyboardType = UIKeyboardTypeURL;
    [m.blacklist.heightAnchor constraintEqualToConstant:120].active = YES;
    [self.stack addArrangedSubview:blacklistTitle];
    [self.stack addArrangedSubview:m.blacklist];
}

- (void)changed { [self.model refreshDynamicLabels]; }
- (void)uiApplied { [self.model refreshDynamicLabels]; }

@end

#pragma mark - ③ 系统页（保活 + 辅助功能 + UIKit 系数）

@interface SIOSystemVC : SIOPageVC
@end
@implementation SIOSystemVC

- (void)buildContent {
    SIOModel *m = self.model;
    self.title = @"保活 · 系统";

    m.swFUBG = [[UISwitch alloc] init];
    m.swFUBGScene = [[UISwitch alloc] init];
    m.swFUBGAudio = [[UISwitch alloc] init];
    m.swFUBGBall = [[UISwitch alloc] init];
    m.swFUBGBall.enabled = NO;
    [self.stack addArrangedSubview:SIOSectionTitle(@"真后台保活（FUBackground v2.0）")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"启用真后台保活", m.swFUBG, nil),
        SIORow(@"场景伪装引擎（推荐）", m.swFUBGScene, nil),
        SIORow(@"音频断言兜底（静音白噪）", m.swFUBGAudio, nil),
        SIORow(@"悬浮球（已全局禁用）", m.swFUBGBall, [UIColor tertiaryLabelColor]),
    ], 12)];

    m.swRM = [[UISwitch alloc] init];
    m.swCF = [[UISwitch alloc] init];
    m.swRT = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOSectionTitle(@"系统动态效果（写入辅助功能，需注销生效）")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORow(@"减弱动态效果（系统级）", m.swRM, nil),
        SIORow(@"首选交叉淡出过渡", m.swCF, nil),
        SIORow(@"减少透明度（关毛玻璃，降 GPU 负载）", m.swRT, nil),
    ], 12)];

    m.segDrag = [[UISegmentedControl alloc] initWithItems:@[ @"关闭", @"×5", @"×10", @"×20", @"极端" ]];
    [m.segDrag addTarget:self action:@selector(dragChanged) forControlEvents:UIControlEventValueChanged];
    m.lblDrag = SIOLabel(@"", 12, [UIColor systemOrangeColor]);
    [self.stack addArrangedSubview:SIOSectionTitle(@"UIKit 全局动画系数（需注销/重启目标 App）")];
    [self.stack addArrangedSubview:SIOCard(@[ m.segDrag, m.lblDrag ], 10)];
    [self dragChanged];
}

- (void)dragChanged {
    SIOModel *m = self.model;
    int idx = (int)m.segDrag.selectedSegmentIndex;
    double c = DragCoeffForIndex(idx);
    if (idx == 4) {
        m.lblDrag.text = @"「极端」写 0.0001：全系统动画≈归零，绕过 dylib 安全下限，可能触发回调配对错乱；不要与 dylib 加速同时拉满。";
    } else if (c <= 0.0) {
        m.lblDrag.textColor = [UIColor secondaryLabelColor];
        m.lblDrag.text = @"未启用。选 ×5 / ×10 / ×20 可全系统加速，不建议与 dylib 加速同时拉满（两机制叠加）。";
    } else {
        m.lblDrag.textColor = [UIColor systemOrangeColor];
        m.lblDrag.text = [NSString stringWithFormat:@"已选 ×%d（写入 %.2f），全系统生效，需注销/重启目标 App。",
                          DragMultiplierForCoeff(c), c];
    }
}

- (void)uiApplied { [self dragChanged]; }

@end

#pragma mark - ④ 高级页（专属覆盖 / 导入导出 / 自检 / 电源）

@interface SIOAdvancedVC : SIOPageVC <UITextFieldDelegate>
@property (strong) UITextView *reportView;
@end
@implementation SIOAdvancedVC

- (void)buildContent {
    SIOModel *m = self.model;
    self.title = @"高级";

    // ---- App 专属覆盖 ----
    [self.stack addArrangedSubview:SIOSectionTitle(@"App 专属覆盖（只影响该 Bundle ID）")];
    m.ovBundle = [[UITextField alloc] init];
    m.ovBundle.translatesAutoresizingMaskIntoConstraints = NO;
    m.ovBundle.placeholder = @"com.sfic.knight";
    m.ovBundle.borderStyle = UITextBorderStyleRoundedRect;
    m.ovBundle.font = [UIFont systemFontOfSize:14];
    m.ovBundle.autocapitalizationType = UITextAutocapitalizationTypeNone;
    m.ovBundle.autocorrectionType = UITextAutocorrectionTypeNo;
    m.ovBundle.spellCheckingType = UITextSpellCheckingTypeNo;
    m.ovBundle.keyboardType = UIKeyboardTypeURL;
    m.ovBundle.clearButtonMode = UITextFieldViewModeWhileEditing;
    m.ovBundle.returnKeyType = UIReturnKeyDone;
    m.ovBundle.delegate = self;
    [m.ovBundle addTarget:self action:@selector(ovBundleEdited)
         forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
    [m.ovBundle.heightAnchor constraintEqualToConstant:38].active = YES;

    m.ovOn = [[UISwitch alloc] init];
    [m.ovOn addTarget:self action:@selector(ovToggled) forControlEvents:UIControlEventValueChanged];
    m.ovSpeedLabel = SIOLabel(@"专属倍率（当前 ×5.0）", 16, [UIColor labelColor]);
    m.ovSpeed = [[UISlider alloc] init];
    m.ovSpeed.minimumValue = 1.0f;
    m.ovSpeed.maximumValue = 50.0f;
    [m.ovSpeed addTarget:self action:@selector(ovSpeedChanged) forControlEvents:UIControlEventValueChanged];
    m.ovMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    m.ovLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    m.ovFloor = [[UISegmentedControl alloc] initWithItems:@[ @"0.005", @"0.01", @"0.02", @"0.05" ]];
    m.ovTrans = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×1.5", @"×2", @"×3" ]];
    m.ovSpring = [[UISwitch alloc] init];
    m.ovExtra = [[UISwitch alloc] init];
    m.ovList = [[UISwitch alloc] init];
    m.ovList.onTintColor = [UIColor systemRedColor];
    m.ovZoom = [[UISwitch alloc] init];
    m.ovFastScroll = [[UISwitch alloc] init];
    m.ovFastTap = [[UISwitch alloc] init];
    m.ovLongPress = [[UISwitch alloc] init];
    m.ovLPDur = [[UISegmentedControl alloc] initWithItems:@[ @"0.20s", @"0.30s", @"0.40s" ]];
    m.ovGuard = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);

    [self.stack addArrangedSubview:SIOCard(@[
        m.ovBundle,
        SIORow(@"为该 App 启用专属配置", m.ovOn, nil),
        m.ovSpeedLabel, m.ovSpeed,
        SIOLabel(@"专属模式", 15, [UIColor labelColor]), m.ovMode,
        SIOLabel(@"显式动画额外倍率", 15, [UIColor labelColor]), m.ovLayer,
        SIOLabel(@"时长下限", 15, [UIColor labelColor]), m.ovFloor,
        SIOLabel(@"转场额外倍率", 15, [UIColor labelColor]), m.ovTrans,
        SIORow(@"弹簧参数缩放", m.ovSpring, nil),
        SIORow(@"进阶转场", m.ovExtra, nil),
        SIORow(@"列表加速（高危）", m.ovList, [UIColor systemRedColor]),
        SIORow(@"缩放动画加速", m.ovZoom, nil),
        SIORow(@"滑行惯性加急", m.ovFastScroll, nil),
        SIORow(@"点击零延迟", m.ovFastTap, nil),
        SIORow(@"长按手势加速", m.ovLongPress, nil),
        SIOLabel(@"专属长按时长", 15, [UIColor labelColor]), m.ovLPDur,
        m.ovGuard,
    ], 10)];

    // ---- 导入 / 导出 ----
    [self.stack addArrangedSubview:SIOSectionTitle(@"配置导入 / 导出（JSON，经剪贴板）")];
    UIButton *exp = SIOPill(@"📤 导出配置到剪贴板", [UIColor systemBlueColor], [UIColor whiteColor]);
    UIButton *imp = SIOPill(@"📥 从剪贴板导入并保存", [UIColor systemTealColor], [UIColor whiteColor]);
    [exp addTarget:self action:@selector(doExport) forControlEvents:UIControlEventTouchUpInside];
    [imp addTarget:self action:@selector(doImport) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *ioRow = [[UIStackView alloc] initWithArrangedSubviews:@[exp, imp]];
    ioRow.axis = UILayoutConstraintAxisHorizontal;
    ioRow.distribution = UIStackViewDistributionFillEqually;
    ioRow.spacing = 8;
    [ioRow.heightAnchor constraintEqualToConstant:38].active = YES;
    [self.stack addArrangedSubview:ioRow];

    // ---- 自检 ----
    [self.stack addArrangedSubview:SIOSectionTitle(@"注入 / 环境自检")];
    UIButton *check = SIOPill(@"🔍 重新检测", [UIColor darkGrayColor], [UIColor whiteColor]);
    [check addTarget:self action:@selector(doCheck) forControlEvents:UIControlEventTouchUpInside];
    self.reportView = [[UITextView alloc] init];
    self.reportView.editable = NO;
    self.reportView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.reportView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.reportView.layer.cornerRadius = 12;
    self.reportView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.reportView.heightAnchor constraintEqualToConstant:260].active = YES;
    [self.stack addArrangedSubview:SIOCard(@[ check, self.reportView ], 10)];
    [self doCheck];

    // ---- 电源 ----
    [self.stack addArrangedSubview:SIOSectionTitle(@"电源操作（会先自动保存）")];
    UIButton *rs = SIOPill(@"🔄 注销 SpringBoard", [UIColor whiteColor], [UIColor systemBlueColor]);
    rs.layer.borderWidth = 1;
    rs.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [rs addTarget:self action:@selector(doRespring) forControlEvents:UIControlEventTouchUpInside];
    UIButton *rb = SIOPill(@"⏻ 硬重启设备", [UIColor whiteColor], [UIColor systemRedColor]);
    rb.layer.borderWidth = 1;
    rb.layer.borderColor = [UIColor systemRedColor].CGColor;
    [rb addTarget:self action:@selector(doReboot) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:SIOCard(@[ rs, rb ], 10)];

    UILabel *hint = SIOLabel(
        [NSString stringWithFormat:@"%@：新引擎支持可调时长下限、转场独立倍率、长按加速、setter 强黏手感与热重载生效提示。dylib 与配置器版本必须配套。", SIO_VERSION],
        12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:hint];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    [self.model refreshOverrides];
    return YES;
}
- (void)ovBundleEdited { [self.model refreshOverrides]; }
- (void)ovSpeedChanged {
    self.model.ovSpeedLabel.text =
        [NSString stringWithFormat:@"专属倍率（当前 ×%.1f）", self.model.ovSpeed.value];
}
- (void)ovToggled {
    SIOModel *m = self.model;
    NSString *bid = [m.ovBundle.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    if (!bid.length) bid = @"com.sfic.knight";
    if ([HardGuardBundles() containsObject:bid]) {
        m.ovGuard.text = [NSString stringWithFormat:@"⚠️ %@ 在列表硬保护名单：列表加速恒关。", bid];
        m.ovGuard.textColor = [UIColor systemOrangeColor];
    } else if (m.ovOn.on) {
        m.ovGuard.text = [NSString stringWithFormat:@"保存后将为 %@ 创建专属配置。", bid];
        m.ovGuard.textColor = [UIColor secondaryLabelColor];
    } else {
        m.ovGuard.text = [NSString stringWithFormat:@"保存后将删除 %@ 的专属配置，回到全局配置。", bid];
        m.ovGuard.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)doExport {
    NSString *path = [self.model exportConfig];
    UIAlertController *a;
    if (path) {
        a = [UIAlertController alertControllerWithTitle:@"✅ 已导出"
            message:[NSString stringWithFormat:@"JSON 已复制到剪贴板，并保存到：\n%@", path]
            preferredStyle:UIAlertControllerStyleAlert];
    } else {
        a = [UIAlertController alertControllerWithTitle:@"❌ 导出失败"
            message:@"JSON 序列化失败。" preferredStyle:UIAlertControllerStyleAlert];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doImport {
    NSString *json = [UIPasteboard generalPasteboard].string;
    if (!json.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板为空"
            message:@"请先复制一份 SIOriginal JSON 配置。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSString *err = [self.model importConfig:json];
    if (err) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"❌ 导入失败"
            message:err preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    BOOL ok = [self.model save];
    [self doCheck];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:ok ? @"✅ 导入成功并已保存" : @"⚠️ 已导入但保存失败"
        message:ok ? [self.model summary] : @"控件已更新，但 plist 写入失败，请检查权限。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doCheck {
    self.reportView.text = [self.model checkReport];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self doCheck];
}

- (void)doRespring {
    [self.model save];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
}

- (void)doReboot {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"确认硬重启"
        message:@"将以 root 权限直接重启设备（不是注销）。未保存数据可能丢失。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *x) {
            [self.model save];
            SIOReboot();
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)uiApplied { [self doCheck]; }

@end

#pragma mark - App Delegate

@interface SIOAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) SIOModel *model;
@end

@implementation SIOAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.model = [[SIOModel alloc] init];
    SIOModel *model = self.model;

    SIOEngineVC *e = [[SIOEngineVC alloc] init];
    e.model = model; e.title = @"引擎";
    SIOFeelVC *f = [[SIOFeelVC alloc] init];
    f.model = model; f.title = @"手感";
    SIOSystemVC *s = [[SIOSystemVC alloc] init];
    s.model = model; s.title = @"系统";
    SIOAdvancedVC *a = [[SIOAdvancedVC alloc] init];
    a.model = model; a.title = @"高级";

    // 立即加载所有页面，保证 model 的全部控件在任何 save/预设前已创建
    for (UIViewController *vc in @[e,f,s,a]) [vc loadViewIfNeeded];
    [model loadControlValues];

    UINavigationController *(^nav)(UIViewController *, NSString *, NSString *) =
        ^(UIViewController *vc, NSString *icon, NSString *title) {
        UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc];
        n.tabBarItem = [[UITabBarItem alloc] initWithTitle:title
                                                     image:[UIImage systemImageNamed:icon]
                                                       tag:0];
        n.navigationBar.prefersLargeTitles = NO;
        return n;
    };
    UITabBarController *tab = [[UITabBarController alloc] init];
    tab.viewControllers = @[ nav(e, @"bolt.fill", @"引擎"),
                             nav(f, @"hand.tap", @"手感"),
                             nav(s, @"gear", @"系统"),
                             nav(a, @"wrench.fill", @"高级") ];
    tab.tabBar.tintColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.45 alpha:1.0];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = tab;
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
