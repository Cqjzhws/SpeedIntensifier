// FUBackground v2.0 — 真后台保活配置 App（TrollStore 安装用）
// 写 plist + 发 Darwin 通知（dylib 热重载）；提供已装 App audio 后台模式扫描、注销。
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.fubg.plist";
static NSString *const kNotify   = @"com.local.fubg.settingschanged";

#pragma mark ==================== 注销 ====================
static int FBKillProcessNamed(const char *name) {
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
static void FBRespring(void) {
    (void)FBKillProcessNamed("SpringBoard");
    FBKillProcessNamed("backboardd");
}

#pragma mark ==================== 配置读写 ====================
static void FBWriteConfig(BOOL enabled, BOOL sceneFake, BOOL audioKeep, BOOL ball,
                          NSArray *exclude) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSDictionary *d = @{ @"Enabled": @(enabled),
                         @"SceneFake": @(sceneFake),
                         @"AudioKeep": @(audioKeep),
                         @"FloatingBall": @(ball),
                         @"ExcludeApps": exclude ?: @[] };
    BOOL ok = [d writeToFile:kPrefPath atomically:YES];
    NSLog(@"[FUBApp] write pref -> %d", ok);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kNotify, NULL, NULL, YES);
}
static NSDictionary *FBReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) d = @{ @"Enabled": @YES, @"SceneFake": @YES,
                   @"AudioKeep": @YES, @"FloatingBall": @YES,
                   @"ExcludeApps": @[] };
    return d;
}

#pragma mark ==================== 已装 App 扫描 ====================
// TrollStore/数据卷 App 路径：/var/containers/Bundle/Application/<UUID>/<App>.app
// 需要 no-sandbox entitlement（本 App 已带）。
static NSString *FBScanInstalledApps(void) {
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *yesLines = [NSMutableArray array];
    NSMutableArray<NSString *> *noLines  = [NSMutableArray array];
    int total = 0;

    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *uuid in uuids) {
        NSString *uuidPath = [root stringByAppendingPathComponent:uuid];
        NSArray *subs = [fm contentsOfDirectoryAtPath:uuidPath error:nil];
        for (NSString *sub in subs) {
            if (![sub hasSuffix:@".app"]) continue;
            NSString *plistPath = [uuidPath stringByAppendingPathComponent:
                                   [sub stringByAppendingPathComponent:@"Info.plist"]];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (!info) continue;
            NSString *bid = info[@"CFBundleIdentifier"];
            if (!bid || ![bid isKindOfClass:[NSString class]]) continue;
            if ([bid hasPrefix:@"com.apple."]) continue;
            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: sub;
            NSArray *modes = info[@"UIBackgroundModes"];
            BOOL hasAudio = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];
            total++;
            if (hasAudio) {
                [yesLines addObject:[NSString stringWithFormat:@"✅ %@\n    %@", name, bid]];
            } else {
                [noLines addObject:[NSString stringWithFormat:@"▪️ %@\n    %@", name, bid]];
            }
        }
    }

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"扫描到 %d 个用户 App\n", total];
    [out appendString:@"v2.0 默认开启【场景伪装】：无论是否有 audio 声明，注入 dylib 即可保活；下方分组仅反映“音频兜底”引擎的前提条件。\n\n"];
    [out appendFormat:@"【✅ 自带 audio 声明 — 双引擎完整】%d 个\n%@\n\n",
     (int)yesLines.count,
     yesLines.count ? [yesLines componentsJoinedByString:@"\n"] : @"(无)"];
    [out appendFormat:@"【▪️ 无 audio 声明 — 场景伪装仍可保活；仅关场景伪装时才需改包】%d 个\n%@\n",
     (int)noLines.count,
     noLines.count ? [noLines componentsJoinedByString:@"\n"] : @"(无)"];
    return out;
}

#pragma mark ==================== UI ====================
@interface FBRootVC : UIViewController
@end

@implementation FBRootVC {
    UISwitch *_enableSwitch;
    UISwitch *_sceneSwitch;
    UISwitch *_audioSwitch;
    UISwitch *_ballSwitch;
    UITextView *_exclude;
    UITextView *_scanResult;
    UILabel *_status;
}

- (UIView *)_rowWith:(UIView *)left ctrl:(UIView *)ctrl {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ left, ctrl ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [ctrl setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [ctrl setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [left setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [left setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return row;
}

- (UILabel *)_label:(NSString *)text color:(UIColor *)color size:(CGFloat)size {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

- (NSArray *)_collectExclude {
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *line in [_exclude.text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [arr addObject:t];
    }
    return arr;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"真后台";

    NSDictionary *cfg = FBReadConfig();
    BOOL cfgEnabled = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    BOOL cfgScene   = cfg[@"SceneFake"] ? [cfg[@"SceneFake"] boolValue] : YES;
    BOOL cfgAudio   = cfg[@"AudioKeep"] ? [cfg[@"AudioKeep"] boolValue] : YES;
    BOOL cfgBall    = cfg[@"FloatingBall"] ? [cfg[@"FloatingBall"] boolValue] : YES;
    NSArray *cfgEx = cfg[@"ExcludeApps"] ?: @[];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"真后台保活";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"FUBackground v2.0 Max · 场景伪装 + 音频断言双引擎";
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 0;

    // —— 开关组 ——
    _enableSwitch = [[UISwitch alloc] init]; _enableSwitch.on = cfgEnabled;
    _sceneSwitch  = [[UISwitch alloc] init]; _sceneSwitch.on  = cfgScene;
    _audioSwitch  = [[UISwitch alloc] init]; _audioSwitch.on  = cfgAudio;
    _ballSwitch   = [[UISwitch alloc] init]; _ballSwitch.on   = cfgBall;

    UIView *row1 = [self _rowWith:[self _label:@"总开关（注入 dylib 的 App 全部生效）"
                                         color:[UIColor labelColor] size:15] ctrl:_enableSwitch];
    UIView *row2 = [self _rowWith:[self _label:@"场景伪装（核心：拦截后台化指令，App 始终以为自己在前台；不依赖 audio 声明）"
                                         color:[UIColor labelColor] size:15] ctrl:_sceneSwitch];
    UIView *row3 = [self _rowWith:[self _label:@"音频断言兜底（无声白噪声防挂起，不打断音乐；与场景伪装双保险）"
                                         color:[UIColor secondaryLabelColor] size:13] ctrl:_audioSwitch];
    UIView *row4 = [self _rowWith:[self _label:@"悬浮球（App 内可拖动的开关，点击对该 App 单独暂停/恢复）"
                                         color:[UIColor secondaryLabelColor] size:13] ctrl:_ballSwitch];

    UILabel *lbl2 = [self _label:@"排除名单（每行一个 Bundle ID 前缀，命中不保活）"
                           color:[UIColor secondaryLabelColor] size:15];
    _exclude = [[UITextView alloc] init];
    _exclude.font = [UIFont systemFontOfSize:14];
    _exclude.text = [cfgEx componentsJoinedByString:@"\n"];
    _exclude.layer.cornerRadius = 8;
    [_exclude.heightAnchor constraintEqualToConstant:80].active = YES;

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [scanBtn setTitle:@"扫描已安装 App 的后台支持情况" forState:UIControlStateNormal];
    scanBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [scanBtn addTarget:self action:@selector(onScan) forControlEvents:UIControlEventTouchUpInside];

    _scanResult = [[UITextView alloc] init];
    _scanResult.font = [UIFont systemFontOfSize:12];
    _scanResult.editable = NO;
    _scanResult.text = @"点上方按钮扫描。\nv2.0 开启场景伪装后，所有 App 注入 FUBackground.dylib 即可保活（无需改包）；audio 声明只影响音频兜底引擎。";
    _scanResult.layer.cornerRadius = 8;
    [_scanResult.heightAnchor constraintEqualToConstant:220].active = YES;

    UILabel *hint = [self _label:
        @"用法：TrollFools 把 FUBackground.dylib 注入目标 App；App 内出现沙漏悬浮球即生效，点球可单独开关。场景伪装拦截系统下发的后台化指令，音频断言防止进程被挂起，看门狗自愈、来电中断自动恢复。配置即时生效，无需注销。"
                           color:[UIColor secondaryLabelColor] size:12];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    [apply setTitle:@"保存配置（即时生效）" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    apply.backgroundColor = [UIColor systemBlueColor];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.layer.cornerRadius = 10;
    [apply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];
    [apply.heightAnchor constraintEqualToConstant:46].active = YES;

    UIButton *respring = [UIButton buttonWithType:UIButtonTypeSystem];
    [respring setTitle:@"注销 iPhone" forState:UIControlStateNormal];
    respring.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [respring addTarget:self action:@selector(onRespring) forControlEvents:UIControlEventTouchUpInside];

    _status = [[UILabel alloc] init];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub, row1, row2, row3, row4,
        lbl2, _exclude,
        scanBtn, _scanResult,
        hint,
        apply, respring, _status
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];
}

- (void)onScan {
    _scanResult.text = @"扫描中…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = FBScanInstalledApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            _scanResult.text = result;
        });
    });
}

- (void)onApply {
    FBWriteConfig(_enableSwitch.on, _sceneSwitch.on, _audioSwitch.on, _ballSwitch.on,
                  [self _collectExclude]);
    _status.text = _enableSwitch.on
        ? @"已保存：保活配置已更新，即时生效。"
        : @"已保存：保活已关闭。";
}

- (void)onRespring {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"注销 iPhone"
                                                                message:@"保存配置并立即注销？"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        FBWriteConfig(_enableSwitch.on, _sceneSwitch.on, _audioSwitch.on, _ballSwitch.on,
                      [self _collectExclude]);
        FBRespring();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

@interface FBAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation FBAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)lo {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[FBRootVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FBAppDelegate class]));
    }
}
