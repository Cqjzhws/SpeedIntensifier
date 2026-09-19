// SpeedIntensifier — 配置 App（TrollStore 安装用）
// 作用：写入加速档位配置 + 全局 UIAnimationDragCoefficient，并提供注销/重启按钮。
// 真正的动画加速由注入的 SpeedIntensifier.dylib 完成（TrollFools 注入到目标 App）。
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

// iPhoneOS SDK 无 <sys/reboot.h>，但 unistd.h 已声明 int reboot(int)；
// 仅补 RB_AUTOBOOT 常量（BSD 标准值）
#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT 0x01234567
#endif

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.speedintensifier.plist";
static NSString *const kUIKitPath = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";
// v1.5.9：SpringBoard/UIKit 读偏好的标准路径（桌面文件夹动画吃这里面的拖动系数）
static NSString *const kUIKitPathStd = @"/var/mobile/Library/Preferences/com.apple.UIKit.plist";
static NSString *const kPrefDir = @"/var/Managed Preferences/mobile";

static void SIApplyAttr(posix_spawnattr_t *attr);

static void SIApplyAttr(posix_spawnattr_t *attr) {
    posix_spawnattr_init(attr);
    posix_spawnattr_set_persona_np(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(attr, 0);
    posix_spawnattr_set_persona_gid_np(attr, 0);
}

// v1.5.2：原生直接 kill——sysctl 枚举进程表找到目标 pid 后 kill(pid, SIGKILL)。
// 不依赖外部 killall 二进制与 root persona；App 为 mobile uid，SpringBoard 同为 mobile uid，
// no-sandbox entitlement 下同 uid 信号必达。外部二进制被拦截/路径不符也能注销。
static int SIKillProcessNamed(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    len += 32 * sizeof(struct kinfo_proc);   // 留余量，避免两次枚举间进程增长
    struct kinfo_proc *list = (struct kinfo_proc *)malloc(len);
    if (!list) return -1;
    if (sysctl(mib, 4, list, &len, NULL, 0) != 0) { free(list); return -1; }
    int count = (int)(len / sizeof(struct kinfo_proc));
    int killed = 0;
    for (int i = 0; i < count; i++) {
        if (strncmp(list[i].kp_proc.p_comm, name, sizeof(list[i].kp_proc.p_comm)) == 0) {
            pid_t p = list[i].kp_proc.p_pid;
            if (kill(p, SIGKILL) == 0) killed++;
            NSLog(@"[SIApp] native kill %@(%d) -> %s", @(name), p, strerror(errno));
        }
    }
    free(list);
    return killed;
}

// iOS 16.6.1 上 `/sbin/reboot` 经常被 sandbox 拦截静默失败，
// v1.5.1 重启方案（按可靠性排序）：
// ① 以 root persona 重新拉起自身 --si-reboot-helper 子进程，由子进程直调 reboot() 系统调用（最可靠）；
// ② /usr/sbin/reboot（iOS 15+ 常见路径）；
// ③ /sbin/reboot（旧路径）；
// ④ killall launchd（pid1 受内核保护时无效）；
// ⑤ killall backboardd（强制重载主进程）。
// 返回最终触发方案名（用于界面反馈），全部失败返回 "all failed"。
static NSString *SIReboot(void) {
    pid_t pid;

    // ① root 助手：以 persona uid 0 拉起自身，子进程 main() 检测到参数后直调 reboot()
    NSString *selfPath = [[NSBundle mainBundle] executablePath];
    if (selfPath.length) {
        posix_spawnattr_t attr0;
        SIApplyAttr(&attr0);
        char *a0[] = { (char *)[selfPath UTF8String], "--si-reboot-helper", NULL };
        int s0 = posix_spawn(&pid, [selfPath UTF8String], NULL, &attr0, a0, environ);
        posix_spawnattr_destroy(&attr0);
        NSLog(@"[SIApp] self helper(reboot syscall) spawn status=%d pid=%d errno=%d", s0, pid, errno);
        if (s0 == 0) return @"root 助手 reboot() 系统调用";
    }

    // ② /usr/sbin/reboot
    posix_spawnattr_t attr1;
    char *a1[] = { "/usr/sbin/reboot", NULL };
    SIApplyAttr(&attr1);
    int s1 = posix_spawn(&pid, "/usr/sbin/reboot", NULL, &attr1, a1, environ);
    posix_spawnattr_destroy(&attr1);
    NSLog(@"[SIApp] /usr/sbin/reboot spawn status=%d pid=%d errno=%d", s1, pid, errno);
    if (s1 == 0) return @"/usr/sbin/reboot";

    // ③ /sbin/reboot
    posix_spawnattr_t attr2;
    char *a2[] = { "/sbin/reboot", NULL };
    SIApplyAttr(&attr2);
    int s2 = posix_spawn(&pid, "/sbin/reboot", NULL, &attr2, a2, environ);
    posix_spawnattr_destroy(&attr2);
    NSLog(@"[SIApp] /sbin/reboot spawn status=%d pid=%d errno=%d", s2, pid, errno);
    if (s2 == 0) return @"/sbin/reboot";

    // ④ killall launchd（部分系统 pid1 受保护，仅作回退）
    posix_spawnattr_t attr3;
    char *a3[] = { "/usr/bin/killall", "-9", "launchd", NULL };
    SIApplyAttr(&attr3);
    int s3 = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr3, a3, environ);
    posix_spawnattr_destroy(&attr3);
    NSLog(@"[SIApp] killall launchd spawn status=%d pid=%d errno=%d", s3, pid, errno);
    if (s3 == 0) return @"killall launchd";

    // ⑤ killall backboardd（强制重载主进程，等价类重启）
    posix_spawnattr_t attr4;
    char *a4[] = { "/usr/bin/killall", "-9", "backboardd", NULL };
    SIApplyAttr(&attr4);
    int s4 = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr4, a4, environ);
    posix_spawnattr_destroy(&attr4);
    NSLog(@"[SIApp] killall backboardd spawn status=%d pid=%d errno=%d", s4, pid, errno);
    return @"all failed";
}

// v1.5.2 注销方案（按可靠性排序）：
// ① 原生 sysctl 枚举 + 直接 kill SpringBoard（无需 root/persona，最可靠）；
// ② root persona killall SpringBoard；
// ③ 原生 kill backboardd（同 mobile uid 不可达则跳过，连带重启 SpringBoard）；
// ④ root persona killall backboardd（强制重载主进程，等价类注销）。
// 返回最终触发方案名（用于界面反馈）。
static NSString *SIRespring(void) {
    // ① 原生直接 kill SpringBoard
    int k1 = SIKillProcessNamed("SpringBoard");
    if (k1 > 0) return @"原生 kill iPhone18";

    // ② root persona killall
    posix_spawnattr_t attr;
    char *a1[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    SIApplyAttr(&attr);
    pid_t pid;
    int s1 = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a1, environ);
    posix_spawnattr_destroy(&attr);
    NSLog(@"[SIApp] killall SpringBoard spawn status=%d pid=%d errno=%d", s1, pid, errno);

    // ③ 原生 kill backboardd（mobile uid 通常无权限，仅尝试）
    int k3 = SIKillProcessNamed("backboardd");
    if (k3 > 0) return @"原生 kill backboardd";

    // ④ persona killall backboardd
    posix_spawnattr_t attr2;
    char *a2[] = { "/usr/bin/killall", "-9", "backboardd", NULL };
    SIApplyAttr(&attr2);
    int s2 = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr2, a2, environ);
    posix_spawnattr_destroy(&attr2);
    NSLog(@"[SIApp] killall backboardd spawn status=%d pid=%d errno=%d", s2, pid, errno);
    return (s1 == 0 || s2 == 0) ? @"persona killall" : @"all failed";
}

static void SIWriteConfig(double factor, BOOL enabled, BOOL extra, BOOL instant, BOOL folder) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    // v1.5.8 修复：不再把 com.tencent.xin 写回黑名单（微信与其他 App 同等加速），仅保留企业微信
    NSDictionary *d = @{ @"SpeedFactor": @(factor),
                         @"Enabled": @(enabled),
                         @"ExtraAcceleration": @(extra),
                         @"InstantMode": @(instant),
                         @"FolderAccel": @(folder),
                         @"Blacklist": @[ @"com.tencent.wework" ] };
    BOOL ok = [d writeToFile:kPrefPath atomically:YES];
    NSLog(@"[SIApp] write pref %@ -> %d", kPrefPath, ok);

    // 全局拖动系数（未注入 dylib 时也能有基础加速）。
    // v1.5.9：双路径写入——Managed Preferences（管理偏好优先级高）+ 标准偏好路径（SpringBoard 必读）。
    // 桌面图标文件夹的打开/收起动画由 SpringBoard 的 UIKit 拖动系数控制，保存注销后生效。
    double coeff = enabled ? (instant ? 0.0001 : (factor <= 0 ? 0.001 : factor)) : 1.0;
    for (NSString *p in @[ kUIKitPath, kUIKitPathStd ]) {
        NSMutableDictionary *u = [NSMutableDictionary dictionaryWithContentsOfFile:p] ?: [NSMutableDictionary dictionary];
        u[@"UIAnimationDragCoefficient"] = @(coeff);
        BOOL ok2 = [u writeToFile:p atomically:YES];
        NSLog(@"[SIApp] write UIKit coeff %@ -> %d", p, ok2);
    }
}

// 读取当前已保存配置（文件不存在时返回默认值）
static NSDictionary *SIReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) {
        d = @{ @"SpeedFactor": @0.001,
               @"Enabled": @YES,
               @"ExtraAcceleration": @YES,
               @"InstantMode": @NO,
               @"FolderAccel": @YES };
    }
    return d;
}

@interface SIRootVC : UIViewController
@end

@implementation SIRootVC {
    UISwitch *_enableSwitch;
    UISwitch *_extraSwitch;
    UISwitch *_instantSwitch;
    UISwitch *_folderSwitch;
    UISegmentedControl *_speedSeg;
    UILabel *_status;
    NSArray<NSNumber *> *_factors;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _factors = @[@0.001, @0.01, @0.05, @0.1];

    // 回读当前配置
    NSDictionary *cfg = SIReadConfig();
    BOOL cfgEnabled = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    BOOL cfgExtra   = cfg[@"ExtraAcceleration"] ? [cfg[@"ExtraAcceleration"] boolValue] : YES;
    BOOL cfgInstant = cfg[@"InstantMode"] ? [cfg[@"InstantMode"] boolValue] : NO;
    BOOL cfgFolder  = cfg[@"FolderAccel"] ? [cfg[@"FolderAccel"] boolValue] : YES;
    double cfgFactor = cfg[@"SpeedFactor"] ? [cfg[@"SpeedFactor"] doubleValue] : 0.001;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"隔壁老王专用";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"动画加速 v1.5.9 · 65 Hooks · 桌面文件夹加速";
    sub.font = [UIFont systemFontOfSize:14];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;

    UILabel *lbl1 = [[UILabel alloc] init];
    lbl1.text = @"启用加速";
    lbl1.font = [UIFont systemFontOfSize:17];
    _enableSwitch = [[UISwitch alloc] init];
    _enableSwitch.on = cfgEnabled;

    UILabel *lbl1b = [[UILabel alloc] init];
    lbl1b.text = @"额外加速（关键帧/列表/弹窗/翻页）";
    lbl1b.font = [UIFont systemFontOfSize:17];
    lbl1b.adjustsFontSizeToFitWidth = YES;
    _extraSwitch = [[UISwitch alloc] init];
    _extraSwitch.on = cfgExtra;

    UILabel *lbl1c = [[UILabel alloc] init];
    lbl1c.text = @"瞬切模式（动画时长归零，最快）";
    lbl1c.font = [UIFont systemFontOfSize:17];
    lbl1c.adjustsFontSizeToFitWidth = YES;
    lbl1c.numberOfLines = 2;
    _instantSwitch = [[UISwitch alloc] init];
    _instantSwitch.on = cfgInstant;
    [_instantSwitch addTarget:self action:@selector(onInstantToggle) forControlEvents:UIControlEventValueChanged];

    UILabel *lbl1d = [[UILabel alloc] init];
    lbl1d.text = @"文件夹加速（文件App/文件夹浏览）";
    lbl1d.font = [UIFont systemFontOfSize:17];
    lbl1d.adjustsFontSizeToFitWidth = YES;
    _folderSwitch = [[UISwitch alloc] init];
    _folderSwitch.on = cfgFolder;

    UILabel *lbl2 = [[UILabel alloc] init];
    lbl2.text = @"速度档位（越小越快）";
    lbl2.font = [UIFont systemFontOfSize:17];

    _speedSeg = [[UISegmentedControl alloc] initWithItems:@[@"0.001", @"0.01", @"0.05", @"0.1"]];
    NSUInteger sel = 0;
    for (NSUInteger i = 0; i < _factors.count; i++) {
        if (fabs([_factors[i] doubleValue] - cfgFactor) < 0.0001) { sel = i; break; }
    }
    _speedSeg.selectedSegmentIndex = sel;

    UIButton *btnApply = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnApply setTitle:@"保存并注销 iPhone18" forState:UIControlStateNormal];
    btnApply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [btnApply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];

    UIButton *btnReboot = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnReboot setTitle:@"重启设备" forState:UIControlStateNormal];
    [btnReboot addTarget:self action:@selector(onReboot) forControlEvents:UIControlEventTouchUpInside];

    _status = [[UILabel alloc] init];
    _status.numberOfLines = 0;
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.text = @"提示：dylib 由 TrollFools 注入目标 App 后生效；本 App 负责写入配置并注销。\n桌面图标文件夹动画走全局拖动系数：保存注销即生效，无需注入。\n黑名单App（默认企业微信）只走基础加速。瞬切模式若出现异常请关闭。";

    NSArray *views = @[title, sub, lbl1, _enableSwitch, lbl1b, _extraSwitch, lbl1c, _instantSwitch, lbl1d, _folderSwitch, lbl2, _speedSeg, btnApply, btnReboot, _status];
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

        [lbl1b.topAnchor constraintEqualToAnchor:lbl1.bottomAnchor constant:24],
        [lbl1b.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [_extraSwitch.centerYAnchor constraintEqualToAnchor:lbl1b.centerYAnchor],
        [_extraSwitch.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],

        [lbl1c.topAnchor constraintEqualToAnchor:lbl1b.bottomAnchor constant:20],
        [lbl1c.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [lbl1c.trailingAnchor constraintLessThanOrEqualToAnchor:_instantSwitch.leadingAnchor constant:-12],
        [_instantSwitch.centerYAnchor constraintEqualToAnchor:lbl1c.centerYAnchor],
        [_instantSwitch.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],

        [lbl1d.topAnchor constraintEqualToAnchor:lbl1c.bottomAnchor constant:20],
        [lbl1d.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [_folderSwitch.centerYAnchor constraintEqualToAnchor:lbl1d.centerYAnchor],
        [_folderSwitch.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],

        [lbl2.topAnchor constraintEqualToAnchor:lbl1d.bottomAnchor constant:20],
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

- (void)onInstantToggle {
    if (_instantSwitch.isOn) {
        _status.text = @"瞬切模式：所有动画时长归零、页面瞬间切换。若目标 App 出现闪退请关闭后重新保存。";
    }
}

- (void)onApply {
    double factor = [_factors[_speedSeg.selectedSegmentIndex] doubleValue];
    SIWriteConfig(factor, _enableSwitch.isOn, _extraSwitch.isOn, _instantSwitch.isOn, _folderSwitch.isOn);
    _status.text = [NSString stringWithFormat:@"已保存 factor=%.3f 增强=%@ 瞬切=%@ 文件夹=%@，正在注销 iPhone18…",
                    factor, _extraSwitch.isOn ? @"开" : @"关", _instantSwitch.isOn ? @"开" : @"关",
                    _folderSwitch.isOn ? @"开" : @"关"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *how = SIRespring();
        _status.text = [NSString stringWithFormat:@"已保存，注销已触发（%@）。若屏幕未黑，请重开本 App 再点一次。", how];
    });
}

- (void)onReboot {
    SIWriteConfig([_factors[_speedSeg.selectedSegmentIndex] doubleValue],
                  _enableSwitch.isOn, _extraSwitch.isOn, _instantSwitch.isOn, _folderSwitch.isOn);
    _status.text = @"正在重启设备（请稍候）…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *r = SIReboot();
        _status.text = [NSString stringWithFormat:@"重启已触发：%@（如果几秒未重启说明 persona 被拦截，请长按电源键关机）", r];
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
    // root 助手模式：由 SIReboot() 以 persona uid 0 拉起，直调 reboot() 系统调用后立即重启
    if (argc > 1 && strcmp(argv[1], "--si-reboot-helper") == 0) {
        NSLog(@"[SIApp] helper mode: calling reboot(RB_AUTOBOOT) as uid=%d euid=%d", getuid(), geteuid());
        @autoreleasepool {
            reboot(RB_AUTOBOOT);   // 成功不会返回；失败则继续退出
            NSLog(@"[SIApp] reboot() failed errno=%d, fallback killall launchd", errno);
            posix_spawnattr_t attr;
            SIApplyAttr(&attr);
            char *args[] = { "/usr/bin/killall", "-9", "launchd", NULL };
            pid_t pid;
            posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, args, environ);
            posix_spawnattr_destroy(&attr);
        }
        return 0;
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIAppDelegate class]));
    }
}
