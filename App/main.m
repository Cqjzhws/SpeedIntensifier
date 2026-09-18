// SpeedIntensifier — 配置 App（TrollStore 安装用）
// 作用：写入加速档位配置 + 全局 UIAnimationDragCoefficient，并提供注销/重启按钮。
// 真正的动画加速由注入的 SpeedIntensifier.dylib 完成（TrollFools 注入到目标 App）。
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <errno.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.speedintensifier.plist";
static NSString *const kUIKitPath = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";
static NSString *const kPrefDir = @"/var/Managed Preferences/mobile";

static void SIRespring(void) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    char *args[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    int status = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, args, environ);
    posix_spawnattr_destroy(&attr);
    NSLog(@"[SIApp] respring spawn status=%d pid=%d", status, pid);
}

static void SIReboot(void) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    char *args[] = { "/sbin/reboot", NULL };
    int status = posix_spawn(&pid, "/sbin/reboot", NULL, &attr, args, environ);
    posix_spawnattr_destroy(&attr);
    NSLog(@"[SIApp] reboot spawn status=%d pid=%d errno=%d", status, pid, errno);
}

static void SIWriteConfig(double factor, BOOL enabled) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSDictionary *d = @{ @"SpeedFactor": @(factor), @"Enabled": @(enabled) };
    BOOL ok = [d writeToFile:kPrefPath atomically:YES];
    NSLog(@"[SIApp] write pref %@ -> %d", kPrefPath, ok);

    // 全局拖动系数（未注入 dylib 时也能有基础加速）
    NSMutableDictionary *u = [NSMutableDictionary dictionaryWithContentsOfFile:kUIKitPath] ?: [NSMutableDictionary dictionary];
    u[@"UIAnimationDragCoefficient"] = @(enabled ? (factor <= 0 ? 0.001 : factor) : 1.0);
    [u writeToFile:kUIKitPath atomically:YES];
}

@interface SIRootVC : UIViewController
@end

@implementation SIRootVC {
    UISwitch *_enableSwitch;
    UISegmentedControl *_speedSeg;
    UILabel *_status;
    NSArray<NSNumber *> *_factors;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _factors = @[@0.001, @0.01, @0.05, @0.1];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Speed Intensifier";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"动画加速 · 默认最快 0.001";
    sub.font = [UIFont systemFontOfSize:14];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;

    UILabel *lbl1 = [[UILabel alloc] init];
    lbl1.text = @"启用加速";
    lbl1.font = [UIFont systemFontOfSize:17];
    _enableSwitch = [[UISwitch alloc] init];
    _enableSwitch.on = YES;

    UILabel *lbl2 = [[UILabel alloc] init];
    lbl2.text = @"速度档位（越小越快）";
    lbl2.font = [UIFont systemFontOfSize:17];

    _speedSeg = [[UISegmentedControl alloc] initWithItems:@[@"0.001", @"0.01", @"0.05", @"0.1"]];
    _speedSeg.selectedSegmentIndex = 0;

    UIButton *btnApply = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnApply setTitle:@"保存并注销 SpringBoard" forState:UIControlStateNormal];
    btnApply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [btnApply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];

    UIButton *btnReboot = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnReboot setTitle:@"重启设备" forState:UIControlStateNormal];
    [btnReboot addTarget:self action:@selector(onReboot) forControlEvents:UIControlEventTouchUpInside];

    _status = [[UILabel alloc] init];
    _status.numberOfLines = 0;
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.text = @"提示：dylib 由 TrollFools 注入目标 App 后生效；本 App 负责写入配置并注销。";

    NSArray *views = @[title, sub, lbl1, _enableSwitch, lbl2, _speedSeg, btnApply, btnReboot, _status];
    for (UIView *v in views) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:g.topAnchor constant:24],
        [title.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],

        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [sub.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],

        [lbl1.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:36],
        [lbl1.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [_enableSwitch.centerYAnchor constraintEqualToAnchor:lbl1.centerYAnchor],
        [_enableSwitch.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],

        [lbl2.topAnchor constraintEqualToAnchor:lbl1.bottomAnchor constant:36],
        [lbl2.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],

        [_speedSeg.topAnchor constraintEqualToAnchor:lbl2.bottomAnchor constant:12],
        [_speedSeg.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [_speedSeg.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],

        [btnApply.topAnchor constraintEqualToAnchor:_speedSeg.bottomAnchor constant:36],
        [btnApply.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],

        [btnReboot.topAnchor constraintEqualToAnchor:btnApply.bottomAnchor constant:16],
        [btnReboot.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],

        [_status.topAnchor constraintEqualToAnchor:btnReboot.bottomAnchor constant:28],
        [_status.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [_status.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
    ]];
}

- (void)onApply {
    double factor = [_factors[_speedSeg.selectedSegmentIndex] doubleValue];
    SIWriteConfig(factor, _enableSwitch.isOn);
    _status.text = [NSString stringWithFormat:@"已保存 factor=%.3f，正在注销 SpringBoard…", factor];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SIRespring();
    });
}

- (void)onReboot {
    SIWriteConfig([_factors[_speedSeg.selectedSegmentIndex] doubleValue], _enableSwitch.isOn);
    _status.text = @"正在重启设备…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SIReboot();
    });
}
@end

@interface SIAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SIAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    SIRootVC *vc = [[SIRootVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIAppDelegate class]));
    }
}
