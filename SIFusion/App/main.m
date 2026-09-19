// SIFusion — 配置 App（TrollStore 安装用）
// SIClassic × SpeedsterTS 融合增强版配套配置器。
// 写 plist + 发 Darwin 通知（dylib 热重载），并提供注销按钮。
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

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.sifusion.plist";
static NSString *const kNotify   = @"com.local.sifusion.settingschanged";

static dispatch_time_t fu_dwell(double sec);

static void FUApplyAttr(posix_spawnattr_t *attr) {
    posix_spawnattr_init(attr);
    posix_spawnattr_set_persona_np(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(attr, 0);
    posix_spawnattr_set_persona_gid_np(attr, 0);
}

static int FUKillProcessNamed(const char *name) {
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
            pid_t p = list[i].kp_proc.p_pid;
            if (kill(p, SIGKILL) == 0) killed++;
        }
    }
    free(list);
    return killed;
}

static void FURespring(void) {
    int k1 = FUKillProcessNamed("SpringBoard");
    if (k1 > 0) return;
    posix_spawnattr_t attr;
    char *a1[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    FUApplyAttr(&attr);
    pid_t pid;
    posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a1, environ);
    posix_spawnattr_destroy(&attr);
}

static void FUWriteConfig(BOOL enabled, int preset, BOOL spring, NSArray *blacklist) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSDictionary *d = @{ @"Enabled": @(enabled),
                         @"Preset": @(preset),
                         @"Spring": @(spring),
                         @"Blacklist": blacklist ?: @[ @"com.tencent.wework" ] };
    BOOL ok = [d writeToFile:kPrefPath atomically:YES];
    NSLog(@"[SIFApp] write pref -> %d", ok);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kNotify, NULL, NULL, YES);
}

static NSDictionary *FUReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) d = @{ @"Enabled": @YES,
                   @"Preset": @2,
                   @"Spring": @YES,
                   @"Blacklist": @[ @"com.tencent.wework" ] };
    return d;
}

@interface FURootVC : UIViewController
@end

@implementation FURootVC {
    UISwitch *_enableSwitch;
    UISwitch *_springSwitch;
    UISegmentedControl *_speedSeg;
    UITextView *_blacklist;
    UILabel *_status;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSDictionary *cfg = FUReadConfig();
    BOOL cfgEnabled = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    BOOL cfgSpring  = cfg[@"Spring"] ? [cfg[@"Spring"] boolValue] : YES;
    int cfgPreset   = cfg[@"Preset"] ? [cfg[@"Preset"] intValue] : 2;
    if (cfgPreset < 0 || cfgPreset > 4) cfgPreset = 2;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"SI Fusion";
    title.font = [UIFont boldSystemFontOfSize:26];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"v1.0.0 · 16 Hooks · SIClassic × SpeedsterTS 融合增强";
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 0;

    UILabel *lbl1 = [[UILabel alloc] init];
    lbl1.text = @"启用加速";
    lbl1.font = [UIFont systemFontOfSize:17];
    _enableSwitch = [[UISwitch alloc] init];
    _enableSwitch.on = cfgEnabled;

    UILabel *lbl2 = [[UILabel alloc] init];
    lbl2.text = @"速度档位";
    lbl2.font = [UIFont systemFontOfSize:17];
    _speedSeg = [[UISegmentedControl alloc] initWithItems:@[ @"微快", @"快", @"很快", @"极快", @"瞬切" ]];
    _speedSeg.selectedSegmentIndex = cfgPreset;

    UILabel *lbl3 = [[UILabel alloc] init];
    lbl3.text = @"弹簧物理平滑（stiffness×m²·damping×m，高倍率不生硬）";
    lbl3.font = [UIFont systemFontOfSize:15];
    lbl3.numberOfLines = 0;
    _springSwitch = [[UISwitch alloc] init];
    _springSwitch.on = cfgSpring;

    UILabel *lbl4 = [[UILabel alloc] init];
    lbl4.text = @"黑名单（每行一个 Bundle ID，命中则不加速）";
    lbl4.font = [UIFont systemFontOfSize:15];
    lbl4.textColor = [UIColor secondaryLabelColor];
    lbl4.numberOfLines = 0;
    _blacklist = [[UITextView alloc] init];
    _blacklist.font = [UIFont systemFontOfSize:14];
    _blacklist.layer.borderColor = [UIColor separatorColor].CGColor;
    _blacklist.layer.borderWidth = 0.5;
    _blacklist.layer.cornerRadius = 8;
    _blacklist.text = [(cfg[@"Blacklist"] ?: @[]) componentsJoinedByString:@"\n"];
    [_blacklist.heightAnchor constraintEqualToConstant:90].active = YES;

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    [apply setTitle:@"保存并注销 iPhone18pro" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    apply.backgroundColor = [UIColor systemBlueColor];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.layer.cornerRadius = 12;
    [apply.heightAnchor constraintEqualToConstant:50].active = YES;
    [apply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"说明：dylib 用 TrollFools 注入目标 App。改档位保存后杀掉 App 重开即生效，无需重新注入。与其他加速器同时注入时自动只启用独家弹簧 stiffness hook，不双重缩放。不含列表选择类 hook，微信可用。";
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;

    _status = [[UILabel alloc] init];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub,
        [self _rowWith:lbl1 ctrl:_enableSwitch],
        lbl2, _speedSeg,
        [self _rowWith:lbl3 ctrl:_springSwitch],
        lbl4, _blacklist, apply, hint, _status
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *box = [[UIView alloc] init];
    [box addSubview:stack];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:box];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:box.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [box.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [box.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [box.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [box.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [box.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
}

- (UIView *)_rowWith:(UIView *)left ctrl:(UIView *)ctrl {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ left, ctrl ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    [left setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return row;
}

- (void)onApply {
    int preset = _speedSeg.selectedSegmentIndex < 0 ? 2 : (int)_speedSeg.selectedSegmentIndex;
    NSArray *names = @[ @"微快", @"快", @"很快", @"极快", @"瞬切" ];

    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }

    FUWriteConfig(_enableSwitch.on, preset, _springSwitch.on, bl);
    _status.text = [NSString stringWithFormat:@"已保存：%@ · %@ · 弹簧%@。正在注销…",
                    _enableSwitch.on ? @"开" : @"关",
                    names[preset],
                    _springSwitch.on ? @"开" : @"关"];
    dispatch_after(fu_dwell(0.6), dispatch_get_main_queue(), ^{
        FURespring();
    });
}

static dispatch_time_t fu_dwell(double sec) {
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC));
}

@end

@interface FUAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation FUAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[FURootVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FUAppDelegate class]));
    }
}
