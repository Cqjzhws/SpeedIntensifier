//
//  main.m — HighFPS Max 配置 App
//
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);

#define kPrefPath  @"/var/Managed Preferences/mobile/com.local.highfpsmax.plist"
#define kNotifyKey @"com.local.highfpsmax.reload"

static void ApplyAttr(posix_spawnattr_t *a) {
    posix_spawnattr_init(a);
    posix_spawnattr_set_persona_np(a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(a, 0);
    posix_spawnattr_set_persona_gid_np(a, 0);
}

static int KillNamed(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    len += 32 * sizeof(struct kinfo_proc);
    struct kinfo_proc *list = malloc(len);
    if (!list) return -1;
    if (sysctl(mib, 4, list, &len, NULL, 0) != 0) { free(list); return -1; }
    int cnt = (int)(len / sizeof(struct kinfo_proc)), k = 0;
    for (int i = 0; i < cnt; i++) {
        if (strncmp(list[i].kp_proc.p_comm, name, sizeof(list[i].kp_proc.p_comm)) == 0) {
            if (kill(list[i].kp_proc.p_pid, SIGKILL) == 0) k++;
        }
    }
    free(list); return k;
}

static void Respring(void) {
    int k = KillNamed("SpringBoard");
    if (k > 0) return;
    posix_spawnattr_t a; ApplyAttr(&a);
    pid_t p; char *av[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    posix_spawn(&p, "/usr/bin/killall", NULL, &a, av, environ);
    posix_spawnattr_destroy(&a);
}

static NSDictionary *ReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (d) return d;
    return @{ @"enabled": @YES, @"refreshRate": @(120), @"metalTriple": @YES, @"blacklist": @[] };
}

static void WriteConfig(NSDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [cfg writeToFile:kPrefPath atomically:YES];
    notify_post(kNotifyKey.UTF8String);
}

@interface HFVC : UIViewController
@property (strong) UISwitch *swEnabled, *swMetal;
@property (strong) UISegmentedControl *segRate;
@property (strong) UITextField *txtRate, *txtBlacklist;
@property (strong) UILabel *lblRate;
@end

@implementation HFVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"HighFPS Max";

    NSDictionary *cfg = ReadConfig();

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"HighFPS Max · 高刷强制";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textAlignment = NSTextAlignmentCenter;

    self.swEnabled = [[UISwitch alloc] init];
    self.swEnabled.on = [cfg[@"enabled"] boolValue];

    NSArray *rates = @[@"60", @"90", @"120", @"自定义"];
    self.segRate = [[UISegmentedControl alloc] initWithItems:rates];
    NSInteger rr = [cfg[@"refreshRate"] integerValue];
    if (rr == 60) self.segRate.selectedSegmentIndex = 0;
    else if (rr == 90) self.segRate.selectedSegmentIndex = 1;
    else if (rr == 120) self.segRate.selectedSegmentIndex = 2;
    else self.segRate.selectedSegmentIndex = 3;
    [self.segRate addTarget:self action:@selector(rateChanged) forControlEvents:UIControlEventValueChanged];

    self.txtRate = [[UITextField alloc] init];
    self.txtRate.placeholder = @"如 120";
    self.txtRate.text = @(rr).stringValue;
    self.txtRate.keyboardType = UIKeyboardTypeNumberPad;
    self.txtRate.borderStyle = UITextBorderStyleRoundedRect;
    self.txtRate.hidden = (self.segRate.selectedSegmentIndex != 3);
    [self.txtRate addTarget:self action:@selector(rateChanged) forControlEvents:UIControlEventEditingChanged];

    self.lblRate = [[UILabel alloc] init];
    self.lblRate.font = [UIFont systemFontOfSize:13];
    self.lblRate.textColor = [UIColor secondaryLabelColor];
    [self rateChanged];

    self.swMetal = [[UISwitch alloc] init];
    self.swMetal.on = [cfg[@"metalTriple"] boolValue];

    self.txtBlacklist = [[UITextField alloc] init];
    self.txtBlacklist.placeholder = @"排除 App 的 bundle ID，逗号分隔";
    NSArray *bl = cfg[@"blacklist"];
    self.txtBlacklist.text = [bl componentsJoinedByString:@","];
    self.txtBlacklist.borderStyle = UITextBorderStyleRoundedRect;

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存并应用" forState:UIControlStateNormal];
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

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"强制 App 以指定刷新率运行。需要硬件支持 ProMotion（120Hz）。60Hz 屏幕设 120 无效。dylib 用 TrollFools 注入目标 App。";
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title,
        [self row:@"启用高刷" ctrl:self.swEnabled],
        [self label:@"目标刷新率" size:15],
        self.segRate, self.txtRate, self.lblRate,
        [self row:@"Metal 三缓冲" ctrl:self.swMetal],
        [self label:@"黑名单（bundle ID，逗号分隔）" size:15],
        self.txtBlacklist,
        save, rs, hint
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
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
}

- (UIView *)row:(UIView *)left ctrl:(UIView *)right {
    UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    sv.axis = UILayoutConstraintAxisHorizontal;
    sv.alignment = UIStackViewAlignmentCenter;
    sv.distribution = UIStackViewDistributionEqualSpacing;
    return sv;
}
- (UILabel *)label:(NSString *)t size:(CGFloat)s {
    UILabel *l = [[UILabel alloc] init]; l.text = t; l.font = [UIFont boldSystemFontOfSize:s]; return l;
}

- (void)rateChanged {
    NSInteger idx = self.segRate.selectedSegmentIndex;
    self.txtRate.hidden = (idx != 3);
    NSInteger r = 120;
    if (idx == 0) r = 60;
    else if (idx == 1) r = 90;
    else if (idx == 2) r = 120;
    else r = [self.txtRate.text integerValue];
    if (r < 30) r = 30;
    if (r > 240) r = 240;
    self.lblRate.text = [NSString stringWithFormat:@"当前：%ld Hz", (long)r];
}

- (void)onSave {
    NSInteger r = 120;
    NSInteger idx = self.segRate.selectedSegmentIndex;
    if (idx == 0) r = 60;
    else if (idx == 1) r = 90;
    else if (idx == 2) r = 120;
    else r = [self.txtRate.text integerValue];
    if (r < 30) r = 30;
    if (r > 240) r = 240;

    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *s in [self.txtBlacklist.text componentsSeparatedByString:@","]) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }

    NSDictionary *cfg = @{
        @"enabled": @(self.swEnabled.on),
        @"refreshRate": @(r),
        @"metalTriple": @(self.swMetal.on),
        @"blacklist": bl,
    };
    WriteConfig(cfg);

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"✅ 已保存"
        message:[NSString stringWithFormat:@"刷新率 %ld Hz，%@，三缓冲%@",
            (long)r, self.swEnabled.on ? @"已启用" : @"已关闭", self.swMetal.on ? @"开" : @"关"]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onRespring {
    [self onSave];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
}

@end

@interface HFAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end

@implementation HFAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[HFVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([HFAppDelegate class]));
    }
}
