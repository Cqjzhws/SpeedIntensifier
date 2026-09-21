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

static NSString * const PrefPath  = @"/var/Managed Preferences/mobile/com.local.sioriginal.plist";
static NSString * const NotifyKey = @"com.local.sioriginal.settingschanged";

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
    posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
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
    if (!d[@"Mode"])       d[@"Mode"]       = @0;
    if (!d[@"Speed"])      d[@"Speed"]      = @5.0;
    if (!d[@"SlowFactor"]) d[@"SlowFactor"] = @2.0;
    if (!d[@"Spring"])     d[@"Spring"]     = @YES;
    if (!d[@"Extra"])      d[@"Extra"]      = @YES;
    if (!d[@"Blacklist"])  d[@"Blacklist"]  = @[ @"com.tencent.wework" ];
    return d;
}

static void WriteConfig(NSMutableDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [cfg writeToFile:PrefPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NotifyKey, NULL, NULL, YES);
}

static NSString *ModeText(int m) {
    return m == 1 ? @"慢放" : (m == 2 ? @"瞬切" : @"加速");
}

@interface SIOVC : UIViewController
@end

@implementation SIOVC {
    UISwitch *_swEnabled, *_swSpring, *_swExtra;
    UISegmentedControl *_segMode;
    UISlider *_slider;
    UILabel *_sliderLabel;
    UITextView *_blacklist;
    UILabel *_status;
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

    UILabel *title = [self label:@"SI Original · 原版重制" size:24 dim:NO];
    title.font = [UIFont boldSystemFontOfSize:24];
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [self label:@"v1.0.0 · 17 Hooks · pw5a29 原版机制 iOS16 重制" size:13 dim:YES];
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

    UILabel *hint = [self label:@"dylib 用 TrollFools 注入目标 App；保存后 Darwin 通知热重载，目标 App 内立即生效。慢放 = 原版 slowDownFactor 功能，可观察动画细节。瞬切 = 动画零时长直达。" size:12 dim:YES];
    hint.textAlignment = NSTextAlignmentCenter;
    _status = [self label:@"" size:13 dim:YES];
    _status.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub,
        [self row:[self label:@"启用" size:17 dim:NO] ctrl:_swEnabled],
        lblMode, _segMode,
        _sliderLabel, _slider,
        [self row:lblSpring ctrl:_swSpring],
        [self row:lblExtra ctrl:_swExtra],
        lblBL, _blacklist, save, rs, hint, _status
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

- (void)onSave {
    NSMutableDictionary *cfg = ReadConfig();
    cfg[@"Enabled"] = @(_swEnabled.on);
    cfg[@"Mode"] = @((int)_segMode.selectedSegmentIndex);
    cfg[@"Speed"] = @((double)_slider.value);
    cfg[@"Spring"] = @(_swSpring.on);
    cfg[@"Extra"] = @(_swExtra.on);
    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }
    cfg[@"Blacklist"] = bl;
    WriteConfig(cfg);
    _status.text = [NSString stringWithFormat:@"已保存：%@ · %@ · 弹簧%@ · 转场%@",
                    _swEnabled.on ? @"开" : @"关",
                    ModeText((int)_segMode.selectedSegmentIndex),
                    _swSpring.on ? @"开" : @"关",
                    _swExtra.on ? @"开" : @"关"];
}

- (void)onRespring {
    [self onSave];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
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
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIOAppDelegate class]));
    }
}
