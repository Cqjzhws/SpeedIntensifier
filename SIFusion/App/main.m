// SIFusion — 配置 App（TrollStore 安装用）
// SIClassic × SpeedsterTS 融合增强版配套配置器。
// 写 plist + 发 Darwin 通知（dylib 热重载），提供注销 / 硬重启按钮。
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

// iPhoneOS SDK 无 <sys/reboot.h>，unistd.h 已声明 int reboot(int)；补 RB_AUTOBOOT
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

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.sifusion.plist";
static NSString *const kNotify   = @"com.local.sifusion.settingschanged";

static dispatch_time_t fu_dwell(double sec);
static void FUApplyAttr(posix_spawnattr_t *attr) {
    posix_spawnattr_init(attr);
    posix_spawnattr_set_persona_np(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(attr, 0);
    posix_spawnattr_set_persona_gid_np(attr, 0);
}

#pragma mark ==================== 注销 ====================
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

#pragma mark ==================== 硬重启（多级回退，SpeedIntensifier 已验证方案） ====================
// ① root persona 拉起自身 --fu-reboot-helper，子进程直调 reboot() 系统调用（最可靠）
// ② /usr/sbin/reboot（iOS 15+ 常见路径）
// ③ /sbin/reboot（旧路径）
// ④ killall launchd（pid1 受内核保护时无效，仅回退）
// ⑤ killall backboardd（强制重载主进程，等价类重启）
static NSString *FUReboot(void) {
    pid_t pid;

    NSString *selfPath = [[NSBundle mainBundle] executablePath];
    if (selfPath.length) {
        posix_spawnattr_t attr0;
        FUApplyAttr(&attr0);
        char *a0[] = { (char *)[selfPath UTF8String], "--fu-reboot-helper", NULL };
        int s0 = posix_spawn(&pid, [selfPath UTF8String], NULL, &attr0, a0, environ);
        posix_spawnattr_destroy(&attr0);
        NSLog(@"[SIFApp] self helper reboot() spawn status=%d pid=%d errno=%d", s0, pid, errno);
        if (s0 == 0) return @"root 助手 reboot() 系统调用";
    }

    posix_spawnattr_t attr1;
    char *a1[] = { "/usr/sbin/reboot", NULL };
    FUApplyAttr(&attr1);
    int s1 = posix_spawn(&pid, "/usr/sbin/reboot", NULL, &attr1, a1, environ);
    posix_spawnattr_destroy(&attr1);
    NSLog(@"[SIFApp] /usr/sbin/reboot status=%d errno=%d", s1, errno);
    if (s1 == 0) return @"/usr/sbin/reboot";

    posix_spawnattr_t attr2;
    char *a2[] = { "/sbin/reboot", NULL };
    FUApplyAttr(&attr2);
    int s2 = posix_spawn(&pid, "/sbin/reboot", NULL, &attr2, a2, environ);
    posix_spawnattr_destroy(&attr2);
    NSLog(@"[SIFApp] /sbin/reboot status=%d errno=%d", s2, errno);
    if (s2 == 0) return @"/sbin/reboot";

    posix_spawnattr_t attr3;
    char *a3[] = { "/usr/bin/killall", "-9", "launchd", NULL };
    FUApplyAttr(&attr3);
    int s3 = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr3, a3, environ);
    posix_spawnattr_destroy(&attr3);
    if (s3 == 0) return @"killall launchd";

    posix_spawnattr_t attr4;
    char *a4[] = { "/usr/bin/killall", "-9", "backboardd", NULL };
    FUApplyAttr(&attr4);
    int s4 = posix_spawn(&pid, "/usr/bin/killall", NULL, &attr4, a4, environ);
    posix_spawnattr_destroy(&attr4);
    return (s4 == 0) ? @"killall backboardd" : @"all failed";
}

#pragma mark ==================== 配置读写 ====================
static void FUWriteConfig(BOOL enabled, int preset, BOOL spring, NSArray *blacklist,
                          BOOL adv, double dur, double vel, double stiff, double damp, double mass) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSDictionary *d = @{ @"Enabled": @(enabled),
                         @"Preset": @(preset),
                         @"Spring": @(spring),
                         @"Blacklist": blacklist ?: @[ @"com.tencent.wework" ],
                         @"Advanced": @(adv),
                         @"DurMult": @(dur),
                         @"VelMult": @(vel),
                         @"StiffMult": @(stiff),
                         @"DampMult": @(damp),
                         @"MassMult": @(mass) };
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
                   @"Blacklist": @[ @"com.tencent.wework" ],
                   @"Advanced": @NO,
                   @"DurMult": @0.15,
                   @"VelMult": @1.0,
                   @"StiffMult": @1.0,
                   @"DampMult": @1.0,
                   @"MassMult": @1.0 };
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
    UISwitch *_advSwitch;
    UISlider *_durSlider, *_velSlider, *_stiffSlider, *_dampSlider, *_massSlider;
    UILabel *_durLbl, *_velLbl, *_stiffLbl, *_dampLbl, *_massLbl;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSDictionary *cfg = FUReadConfig();
    BOOL cfgEnabled = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    BOOL cfgSpring  = cfg[@"Spring"] ? [cfg[@"Spring"] boolValue] : YES;
    int cfgPreset   = cfg[@"Preset"] ? [cfg[@"Preset"] intValue] : 2;
    if (cfgPreset < 0 || cfgPreset > 4) cfgPreset = 2;
    BOOL cfgAdv     = cfg[@"Advanced"] ? [cfg[@"Advanced"] boolValue] : NO;
    double cfgDur   = cfg[@"DurMult"]   ? [cfg[@"DurMult"] doubleValue]   : 0.15;
    double cfgVel   = cfg[@"VelMult"]   ? [cfg[@"VelMult"] doubleValue]   : 1.0;
    double cfgStiff = cfg[@"StiffMult"] ? [cfg[@"StiffMult"] doubleValue] : 1.0;
    double cfgDamp  = cfg[@"DampMult"]  ? [cfg[@"DampMult"] doubleValue]  : 1.0;
    double cfgMass  = cfg[@"MassMult"]  ? [cfg[@"MassMult"] doubleValue]  : 1.0;
    if (cfgDur <= 0) cfgDur = 0.15;
    if (cfgVel <= 0) cfgVel = 1.0;
    if (cfgStiff <= 0) cfgStiff = 1.0;
    if (cfgDamp <= 0) cfgDamp = 1.0;
    if (cfgMass <= 0) cfgMass = 1.0;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"隔壁老王专用";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"v1.1.0 · 17 Hooks · 融合增强";
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

    // 高级设置：Speedy 式独立倍率（对标 Speedy「程序动画」页）
    UILabel *lblAdv = [[UILabel alloc] init];
    lblAdv.text = @"高级设置（独立倍率）";
    lblAdv.font = [UIFont systemFontOfSize:17];
    _advSwitch = [[UISwitch alloc] init];
    _advSwitch.on = cfgAdv;

    UILabel *advHint = [[UILabel alloc] init];
    advHint.text = @"开启后：持续时间倍数直接覆盖速度档位；刚性/阻尼/质量/初始速率按倍数缩放弹簧参数（1.00 = 不变）。保存后杀掉 App 重开生效。";
    advHint.font = [UIFont systemFontOfSize:12];
    advHint.textColor = [UIColor tertiaryLabelColor];
    advHint.numberOfLines = 0;

    UIView *durRow   = [self _sliderRow:@"持续时间倍数" value:cfgDur   min:0.01 max:1.0 tag:0];
    UIView *velRow   = [self _sliderRow:@"初始速率倍数" value:cfgVel   min:0.05 max:3.0 tag:1];
    UIView *stiffRow = [self _sliderRow:@"刚性倍数"     value:cfgStiff min:0.05 max:3.0 tag:2];
    UIView *dampRow  = [self _sliderRow:@"阻尼倍数"     value:cfgDamp  min:0.05 max:3.0 tag:3];
    UIView *massRow  = [self _sliderRow:@"质量倍数"     value:cfgMass  min:0.05 max:3.0 tag:4];

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

    // 硬重启：红色危险按钮，先保存配置再重启
    UIButton *reboot = [UIButton buttonWithType:UIButtonTypeSystem];
    [reboot setTitle:@"硬重启手机" forState:UIControlStateNormal];
    reboot.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    reboot.backgroundColor = [UIColor systemRedColor];
    [reboot setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reboot.layer.cornerRadius = 12;
    [reboot.heightAnchor constraintEqualToConstant:50].active = YES;
    [reboot addTarget:self action:@selector(onReboot) forControlEvents:UIControlEventTouchUpInside];

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
        [self _rowWith:lblAdv ctrl:_advSwitch],
        advHint,
        durRow, velRow, stiffRow, dampRow, massRow,
        lbl4, _blacklist,
        apply, reboot,
        hint, _status
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

// 行布局修复 v1.0.1：开关设最高抗压/拥抱优先级，长 label 被迫换行而不是把开关挤出屏幕
- (UIView *)_rowWith:(UIView *)left ctrl:(UIView *)ctrl {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ left, ctrl ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [ctrl setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
    [ctrl setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    [left setContentHuggingPriority:UILayoutPriorityDefaultLow
                             forAxis:UILayoutConstraintAxisHorizontal];
    [left setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                           forAxis:UILayoutConstraintAxisHorizontal];
    return row;
}

// 高级设置滑杆行：label（含实时数值）+ slider 纵排；按 tag 存进对应 ivar
- (UIView *)_sliderRow:(NSString *)title value:(double)v min:(double)mn max:(double)mx tag:(int)tag {
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = [NSString stringWithFormat:@"%@（%.2f）", title, v];
    lbl.font = [UIFont systemFontOfSize:15];
    lbl.numberOfLines = 0;
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = (float)mn;
    s.maximumValue = (float)mx;
    s.value = (float)v;
    s.tag = tag;
    [s addTarget:self action:@selector(onSlider:) forControlEvents:UIControlEventValueChanged];
    switch (tag) {
        case 0: _durLbl = lbl;   _durSlider = s;   break;
        case 1: _velLbl = lbl;   _velSlider = s;   break;
        case 2: _stiffLbl = lbl; _stiffSlider = s; break;
        case 3: _dampLbl = lbl;  _dampSlider = s;  break;
        case 4: _massLbl = lbl;  _massSlider = s;  break;
    }
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[ lbl, s ]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 4;
    return col;
}

- (void)onSlider:(UISlider *)s {
    static NSString *names[5] = { @"持续时间倍数", @"初始速率倍数", @"刚性倍数", @"阻尼倍数", @"质量倍数" };
    UILabel *labels[5] = { _durLbl, _velLbl, _stiffLbl, _dampLbl, _massLbl };
    if (s.tag < 0 || s.tag > 4 || !labels[s.tag]) return;
    labels[s.tag].text = [NSString stringWithFormat:@"%@（%.2f）", names[s.tag], s.value];
}

- (NSArray *)_collectBlacklist {
    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [_blacklist.text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }
    return bl;
}

- (void)onApply {
    int preset = _speedSeg.selectedSegmentIndex < 0 ? 2 : (int)_speedSeg.selectedSegmentIndex;
    NSArray *names = @[ @"微快", @"快", @"很快", @"极快", @"瞬切" ];
    FUWriteConfig(_enableSwitch.on, preset, _springSwitch.on, [self _collectBlacklist],
                  _advSwitch.on, _durSlider.value, _velSlider.value,
                  _stiffSlider.value, _dampSlider.value, _massSlider.value);
    _status.text = [NSString stringWithFormat:@"已保存：%@ · %@ · 弹簧%@ · 高级%@。正在注销…",
                    _enableSwitch.on ? @"开" : @"关",
                    names[preset],
                    _springSwitch.on ? @"开" : @"关",
                    _advSwitch.on ? @"开" : @"关"];
    dispatch_after(fu_dwell(0.6), dispatch_get_main_queue(), ^{
        FURespring();
    });
}

- (void)onReboot {
    // 二次确认，防误触（硬重启会中断一切）
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"硬重启手机"
                                                                message:@"将先保存当前配置，然后立即重启设备。确定继续？"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"硬重启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf _doReboot];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)_doReboot {
    int preset = _speedSeg.selectedSegmentIndex < 0 ? 2 : (int)_speedSeg.selectedSegmentIndex;
    FUWriteConfig(_enableSwitch.on, preset, _springSwitch.on, [self _collectBlacklist],
                  _advSwitch.on, _durSlider.value, _velSlider.value,
                  _stiffSlider.value, _dampSlider.value, _massSlider.value);
    NSString *way = FUReboot();
    _status.text = [NSString stringWithFormat:@"已保存，重启触发方式：%@", way];
    NSLog(@"[SIFApp] reboot via: %@", way);
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
        // 硬重启助手：以 root persona 被拉起，在进 UIKit 前直调 reboot()（最可靠路径）
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--fu-reboot-helper"]) {
            NSLog(@"[SIFApp] reboot helper: reboot(RB_AUTOBOOT)");
            reboot(RB_AUTOBOOT);
            // 不返回；万一返回，killall launchd 兜底
            pid_t pid;
            posix_spawnattr_t attr;
            FUApplyAttr(&attr);
            char *a[] = { "/usr/bin/killall", "-9", "launchd", NULL };
            posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a, environ);
            posix_spawnattr_destroy(&attr);
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FUAppDelegate class]));
    }
}
