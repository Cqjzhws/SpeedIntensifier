// SIClassic — 配置 App（TrollStore 安装用）
// Speed Intensifier (pw5a29) 的 iOS 16 TrollStore 移植版配套配置器。
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

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.siclassic.plist";
static NSString *const kNotify   = @"com.local.siclassic.settingschanged";

static dispatch_time_t dwell(double sec);

static void SIApplyAttr(posix_spawnattr_t *attr) {
    posix_spawnattr_init(attr);
    posix_spawnattr_set_persona_np(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(attr, 0);
    posix_spawnattr_set_persona_gid_np(attr, 0);
}

// 原生 sysctl 枚举 + kill SpringBoard（v1.5.2 起验证最可靠的注销方式）
static int SIKillProcessNamed(const char *name) {
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

static void SIRespring(void) {
    int k1 = SIKillProcessNamed("SpringBoard");
    if (k1 > 0) return;
    posix_spawnattr_t attr;
    char *a1[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    SIApplyAttr(&attr);
    pid_t pid;
    posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a1, environ);
    posix_spawnattr_destroy(&attr);
}

static void SIWriteConfig(BOOL enabled, double mult, BOOL instant, BOOL spring, NSArray *blacklist) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSDictionary *d = @{ @"Enabled": @(enabled),
                         @"Multiplier": @(mult),
                         @"Instant": @(instant),
                         @"Spring": @(spring),
                         @"Blacklist": blacklist ?: @[ @"com.tencent.wework" ] };
    BOOL ok = [d writeToFile:kPrefPath atomically:YES];
    NSLog(@"[SICApp] write pref -> %d", ok);
    // 通知所有已注入进程里的 dylib 热重载
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kNotify, NULL, NULL, YES);
}

static NSDictionary *SIReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) d = @{ @"Enabled": @YES,
                   @"Multiplier": @5.0,
                   @"Instant": @NO,
                   @"Spring": @YES,
                   @"Blacklist": @[ @"com.tencent.wework" ] };
    return d;
}

@interface SIRootVC : UIViewController <UITextViewDelegate>
@end

@implementation SIRootVC {
    UISwitch *_enableSwitch;
    UISwitch *_springSwitch;
    UISegmentedControl *_speedSeg;
    UITextView *_blacklist;
    UILabel *_status;
    NSArray<NSNumber *> *_mults;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _mults = @[@2.0, @5.0, @10.0, @0.0];   // 最后一档 = 瞬切

    NSDictionary *cfg = SIReadConfig();
    BOOL cfgEnabled = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    BOOL cfgSpring  = cfg[@"Spring"] ? [cfg[@"Spring"] boolValue] : YES;
    double cfgMult  = cfg[@"Multiplier"] ? [cfg[@"Multiplier"] doubleValue] : 5.0;
    BOOL cfgInstant = cfg[@"Instant"] ? [cfg[@"Instant"] boolValue] : NO;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"SpeedIntensifier Classic";
    title.font = [UIFont boldSystemFontOfSize:24];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"v1.0.0 · 4 Hooks · pw5a29 经典版 iOS16 移植";
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
    lbl2.text = @"速度倍率（动画时长 ÷ 倍率）";
    lbl2.font = [UIFont systemFontOfSize:17];
    _speedSeg = [[UISegmentedControl alloc] initWithItems:@[ @"×2", @"×5", @"×10", @"瞬切" ]];
    if (cfgInstant) {
        _speedSeg.selectedSegmentIndex = 3;
    } else {
        NSInteger idx = 1;
        for (NSUInteger i = 0; i < 3; i++) {
            if (fabs(_mults[i].doubleValue - cfgMult) < 0.01) { idx = (NSInteger)i; break; }
        }
        _speedSeg.selectedSegmentIndex = idx;
    }

    UILabel *lbl3 = [[UILabel alloc] init];
    lbl3.text = @"弹簧平滑（高倍率下防动画生硬）";
    lbl3.font = [UIFont systemFontOfSize:17];
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
    _blacklist.heightAnchor.constraint(equalToConstant:90).active = YES;

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    [apply setTitle:@"保存并注销 iPhone18pro" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    apply.backgroundColor = [UIColor systemBlueColor];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.layer.cornerRadius = 12;
    apply.heightAnchor.constraint(equalToConstant:50).active = YES;
    [apply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"说明：dylib 需用 TrollFools 注入目标 App。改配置保存后杀掉 App 重开即生效，无需重新注入。桌面/SpringBoard 动画在纯巨魔环境无法加速。";
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;

    _status = [[UILabel alloc] init];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.text = @"";

    UIView *box = [[UIView alloc] init];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub,
        [self _rowWith:lbl1 ctrl:_enableSwitch],
        lbl2, _speedSeg,
        [self _rowWith:lbl3 ctrl:_springSwitch],
        lbl4, _blacklist, apply, hint, _status
    ]];;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    [box addSubview:stack];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:box.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
    ]];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:box];
    [NSLayoutConstraint activateConstraints:@[
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
    NSInteger seg = _speedSeg.selectedSegmentIndex < 0 ? 1 : _speedSeg.selectedSegmentIndex;
    BOOL instant = (seg == 3);
    double mult = instant ? 100.0 : _mults[seg].doubleValue;

    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }

    SIWriteConfig(_enableSwitch.on, mult, instant, _springSwitch.on, bl);
    _status.text = [NSString stringWithFormat:@"已保存：%@ · 倍率%@ · 弹簧%@。正在注销…",
                    _enableSwitch.on ? @"开" : @"关",
                    instant ? @"瞬切" : [NSString stringWithFormat:@"×%.0f", mult],
                    _springSwitch.on ? @"开" : @"关"];
    dispatch_after(dwell(0.6), dispatch_get_main_queue(), ^{
        SIRespring();
    });
}

static dispatch_time_t dwell(double sec) {
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC));
}

@end

@interface SIAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SIAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    SIRootVC *vc = [[SIRootVC alloc] init];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIAppDelegate class]));
    }
}
