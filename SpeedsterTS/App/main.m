// SpeedsterTS — TrollStore 配置 App
// 写入 com.hoangdus.speedsterprefs.plist（键名与 Speedster 原版一致），
// 并发出 com.hoangdus.speedsterprefs-updated Darwin 通知让已注入进程即时重读。
// 说明：TrollStore 下仅 App 内弹簧动画可生效；桌面/文件夹等 SpringBoard 功能需越狱。
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <stdlib.h>
#import <sys/sysctl.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

static NSString *const kPrefStd = @"/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist";
static NSString *const kPrefJB  = @"/var/jb/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist";

static void ApplyPersona(posix_spawnattr_t *attr) {
    posix_spawnattr_init(attr);
    posix_spawnattr_set_persona_np(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(attr, 0);
    posix_spawnattr_set_persona_gid_np(attr, 0);
}

static int KillProcessNamed(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    len += 32 * sizeof(struct kinfo_proc);
    struct kinfo_proc *list = (struct kinfo_proc *)malloc(len);
    if (!list) return -1;
    if (sysctl(mib, 4, list, &len, NULL, 0) != 0) { free(list); return -1; }
    int count = (int)(len / sizeof(struct kinfo_proc));
    int killed = 0;
    for (int i = 0; i < count; i++) {
        if (strncmp(list[i].kp_proc.p_comm, name, sizeof(list[i].kp_proc.p_comm)) == 0) {
            if (kill(list[i].kp_proc.p_pid, SIGKILL) == 0) killed++;
        }
    }
    free(list);
    return killed;
}

static void Respring(void) {
    if (KillProcessNamed("SpringBoard") > 0) return;
    posix_spawnattr_t attr;
    char *a[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    ApplyPersona(&attr);
    pid_t pid;
    posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a, environ);
    posix_spawnattr_destroy(&attr);
    KillProcessNamed("backboardd");
}

@interface STRootVC : UIViewController
@end

@implementation STRootVC {
    UISwitch *_inAppSwitch;
    UISwitch *_bounceSwitch;
    UISegmentedControl *_speedSeg;
    UISegmentedControl *_bounceSeg;
    UILabel *_status;
}

// 档位 → 原版键值（质量/阻尼削减量，越大越快/越弹）
static const double kMassVals[5]  = { 0.40, 0.55, 0.70, 0.85, 0.93 };
static const double kDampVals[5]  = { 0.10, 0.25, 0.40, 0.60, 0.80 };

- (UILabel *)makeLabel:(NSString *)t font:(UIFont *)f color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.text = t; l.font = f; l.textColor = c; l.numberOfLines = 0;
    return l;
}

- (UIView *)rowWith:(UIView *)left right:(UIView *)right {
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    r.axis = UILayoutConstraintAxisHorizontal;
    r.alignment = UIStackViewAlignmentCenter;
    r.spacing = 12;
    [left setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return r;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefStd]
                     ?: [NSDictionary dictionaryWithContentsOfFile:kPrefJB];
    BOOL cfgInApp = cfg[@"InAppAnimationEnabled"] ? [cfg[@"InAppAnimationEnabled"] boolValue] : YES;
    BOOL cfgBounce = cfg[@"isInAppBounceEnabled"] ? [cfg[@"isInAppBounceEnabled"] boolValue] : NO;
    double cfgMass = cfg[@"DurationMassValue"] ? [cfg[@"DurationMassValue"] doubleValue] : 0.70;
    double cfgDamp = cfg[@"DampingValue"] ? [cfg[@"DampingValue"] doubleValue] : 0.40;

    UILabel *title = [self makeLabel:@"Speedster TS" font:[UIFont boldSystemFontOfSize:28] color:[UIColor labelColor]];
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [self makeLabel:@"TrollStore 版 v1.1.0 · iOS16 全套加速\n基于 GPL Speedster (Hoangdus) 移植"
                              font:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    sub.textAlignment = NSTextAlignmentCenter;

    _inAppSwitch = [[UISwitch alloc] init];
    _inAppSwitch.on = cfgInApp;
    UIView *r1 = [self rowWith:[self makeLabel:@"App 内弹簧动画加速" font:[UIFont systemFontOfSize:17] color:[UIColor labelColor]]
                        right:_inAppSwitch];

    _speedSeg = [[UISegmentedControl alloc] initWithItems:@[@"微快", @"快", @"很快", @"极快", @"秒开"]];
    int si = 2;
    for (int i = 0; i < 5; i++) { if (fabs(cfgMass - kMassVals[i]) < 0.01) { si = i; break; } }
    _speedSeg.selectedSegmentIndex = si;

    _bounceSwitch = [[UISwitch alloc] init];
    _bounceSwitch.on = cfgBounce;
    UIView *r2 = [self rowWith:[self makeLabel:@"弹跳阻尼（更 Q 弹）" font:[UIFont systemFontOfSize:17] color:[UIColor labelColor]]
                        right:_bounceSwitch];

    _bounceSeg = [[UISegmentedControl alloc] initWithItems:@[@"微弹", @"轻弹", @"标准", @"很弹", @"超弹"]];
    int bi = 2;
    for (int i = 0; i < 5; i++) { if (fabs(cfgDamp - kDampVals[i]) < 0.01) { bi = i; break; } }
    _bounceSeg.selectedSegmentIndex = bi;

    UILabel *notice = [self makeLabel:
        @"v1.1.0：侧滑返回/push·pop/弹窗/转场/显式动画全套收窄（独立模式 15 hooks）。\n若同时注入 SpeedIntensifier，自动切换为只补弹簧动画的互补模式，不双重加速。\n以下需越狱（注入 SpringBoard）巨魔不可用：桌面文件夹 · App 开合 · 开关机 · 切换器 · 锁屏飞入 · 图标抖动"
                                font:[UIFont systemFontOfSize:12] color:[UIColor tertiaryLabelColor]];
    notice.textAlignment = NSTextAlignmentCenter;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"保存并注销" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    btn.backgroundColor = [UIColor systemBlueColor];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.layer.cornerRadius = 12;
    [btn addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [btn.heightAnchor constraintEqualToConstant:50].active = YES;

    UILabel *tip = [self makeLabel:
        @"用法：本 App 保存设置后，用 TrollFools 把 SpeedsterTS.dylib 注入目标 App；改档位无需重注入，注销或重启 App 即生效。"
                             font:[UIFont systemFontOfSize:12] color:[UIColor secondaryLabelColor]];

    _status = [self makeLabel:@"" font:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    _status.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[title, sub, r1, _speedSeg, r2, _bounceSeg, notice, btn, tip, _status]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *sv = [[UIScrollView alloc] init];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];
    [sv addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:sv.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:sv.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-40],
        [stack.centerXAnchor constraintEqualToAnchor:sv.centerXAnchor],
    ]];
}

- (void)onSave {
    double mass = kMassVals[_speedSeg.selectedSegmentIndex];
    double damp = kDampVals[_bounceSeg.selectedSegmentIndex];
    // 完整键集：App 内按 UI 写入；SpringBoard 项全部显式关闭，行为确定
    NSDictionary *d = @{
        @"InAppAnimationEnabled": @(_inAppSwitch.on),
        @"STSSpeedPreset": @(_speedSeg.selectedSegmentIndex),
        @"DurationMassValue": @(mass),
        @"isInAppBounceEnabled": @(_bounceSwitch.on),
        @"STSBouncePreset": @(_bounceSeg.selectedSegmentIndex),
        @"DampingValue": @(damp),
        @"isSpeedEnable": @NO, @"Speedvalue": @3,
        @"isBounceEnable": @NO, @"Bouncevalue": @3,
        @"isFineTuneSpeedEnable": @NO, @"FineTuneSpeedValue": @0,
        @"isFineTuneBounceEnable": @NO, @"FineTuneBounceValue": @0,
        @"isFolderAnimationEnabled": @NO, @"isFolderBounceEnabled": @NO,
        @"FolderDampingValue": @0, @"FolderMassValue": @0, @"InstantFolder": @NO,
        @"isScreenwakeEnable": @NO, @"isScreensleepEnable": @NO,
        @"Screenwakevalue": @2, @"Screensleepvalue": @0.01,
        @"nofly": @NO, @"nozoom": @NO, @"noWPzoom": @NO, @"noshaking": @NO,
    };
    mkdir("/var/mobile/Library/Preferences", 0755);
    BOOL ok1 = [d writeToFile:kPrefStd atomically:YES];
    @try { mkdir("/var/jb/var/mobile/Library/Preferences", 0755); [d writeToFile:kPrefJB atomically:YES]; } @catch (__unused id e) {}
    // 通知所有已注入进程即时重读（无需重注入）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.hoangdus.speedsterprefs-updated"),
                                         NULL, NULL, TRUE);
    NSLog(@"[SpeedsterTSApp] pref write std=%d mass=%.2f", ok1, mass);

    _status.text = [NSString stringWithFormat:@"已保存 加速=%@ 档%@ 弹跳=%@，正在注销…",
                    _inAppSwitch.on ? @"开" : @"关",
                    _speedSeg.selectedSegmentIndex >= 0 ? @(_speedSeg.selectedSegmentIndex + 1) : @1,
                    _bounceSwitch.on ? @"开" : @"关"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[STRootVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
