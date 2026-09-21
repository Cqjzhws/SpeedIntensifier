// mdcX Max v2.0.0 — TrollStore 增强版
// 基于 speedyfriend433/mdcX (MIT) 的文件零页技术全新 ObjC 重写：
//   · 引擎A：VM_BEHAVIOR_ZERO_WIRED_PAGES 零页漏洞（原版同款，SSV 文件生效）
//   · 引擎B：TrollStore 根权限（persona-mgmt 根 respring + 无沙盒全文件访问）
//   · 应用后真实验证（重读文件首页确认已清零，原版无此功能）
//   · 结果持久化 / 分类批量应用 / 状态徽章 / 活动日志 / 新图标
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <unistd.h>
#import <string.h>
#import "exploit.h"

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

#define kStatePath @"/var/mobile/Library/Preferences/com.local.mdcxmax.plist"

#pragma mark - Tweak 目录（16 项 / 34 文件，与原版 mdcX 1.4.0 对齐）

typedef struct { const char *cat; const char *name; const char *desc; int npaths; const char *const *paths; } MdxTweak;

static const char *P_dockDark[]   = {"/System/Library/PrivateFrameworks/CoreMaterial.framework/dockDark.materialrecipe",
                                     "/System/Library/PrivateFrameworks/CoreMaterial.framework/dockLight.materialrecipe"};
static const char *P_shelf[]      = {"/System/Library/PrivateFrameworks/SpringBoard.framework/shelfBackground.materialrecipe"};
static const char *P_spotBlurB[]  = {"/System/Library/PrivateFrameworks/SpotlightUIInternal.framework/bottomBlur.materialrecipe"};
static const char *P_transUI[]    = {"/System/Library/PrivateFrameworks/CoreMaterial.framework/platterStrokeLight.visualstyleset",
                                     "/System/Library/PrivateFrameworks/CoreMaterial.framework/platterStrokeDark.visualstyleset",
                                     "/System/Library/PrivateFrameworks/CoreMaterial.framework/plattersDark.materialrecipe",
                                     "/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderLight.materialrecipe",
                                     "/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderDark.materialrecipe",
                                     "/System/Library/PrivateFrameworks/CoreMaterial.framework/platters.materialrecipe"};
static const char *P_avatar[]     = {"/System/Library/PrivateFrameworks/UserNotificationsUIKit.framework/avatarBackground.materialrecipe",
                                     "/System/Library/PrivateFrameworks/UserNotificationsUIKit.framework/avatarBackgroundDark.materialrecipe"};
static const char *P_folder[]     = {"/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderDark.materialrecipe",
                                     "/System/Library/PrivateFrameworks/SpringBoardHome.framework/folderLight.materialrecipe"};
static const char *P_overlay[]    = {"/System/Library/PrivateFrameworks/SpringBoardHome.framework/homeScreenOverlay.materialrecipe"};
static const char *P_switcher[]   = {"/System/Library/PrivateFrameworks/SpringBoard.framework/homeScreenBackdrop-switcher.materialrecipe"};
static const char *P_appBg[]      = {"/System/Library/PrivateFrameworks/SpringBoard.framework/homeScreenBackdrop-application.materialrecipe"};
static const char *P_spotBlur[]   = {"/System/Library/PrivateFrameworks/SpringBoard.framework/spotlightBlurBackground.materialrecipe",
                                     "/System/Library/PrivateFrameworks/SpringBoard.framework/spotlightLumSatBackground.materialrecipe"};
static const char *P_homeBar[]    = {"/System/Library/PrivateFrameworks/MaterialKit.framework/Assets.car"};
static const char *P_lockShort[]  = {"/System/Library/PrivateFrameworks/CoverSheet.framework/Assets.car"};
static const char *P_charge[]     = {"/System/Library/Audio/UISounds/connect_power.caf"};
static const char *P_lockSnd[]    = {"/System/Library/Audio/UISounds/lock.caf"};
static const char *P_record[]     = {"/System/Library/Audio/UISounds/begin_record.caf",
                                     "/System/Library/Audio/UISounds/end_record.caf"};
static const char *P_shutter[]    = {"/System/Library/Audio/UISounds/photoShutter.caf",
                                     "/System/Library/Audio/UISounds/Modern/camera_shutter_burst.caf",
                                     "/System/Library/Audio/UISounds/Modern/camera_shutter_burst_begin.caf",
                                     "/System/Library/Audio/UISounds/Modern/camera_shutter_burst_end.caf",
                                     "/System/Library/Audio/UISounds/nano/CameraShutter_Haptic.caf"};
static const char *P_keyboard[]   = {"/System/Library/Audio/UISounds/key_press_click.caf",
                                     "/System/Library/Audio/UISounds/key_press_delete.caf",
                                     "/System/Library/Audio/UISounds/key_press_modifier.caf",
                                     "/System/Library/Audio/UISounds/keyboard_press_clear.caf",
                                     "/System/Library/Audio/UISounds/keyboard_press_delete.caf",
                                     "/System/Library/Audio/UISounds/keyboard_press_normal.caf"};

static const MdxTweak gTweaks[] = {
    {"Dock", "隐藏 Dock 背景", "Dock 底座透明化", 2, P_dockDark},
    {"Dock", "SpringBoard 架子背景", "改造 shelf 背景（影响 Dock/iPad 架子）", 1, P_shelf},
    {"Spotlight", "移除 Spotlight 底部模糊", "搜索界面底部模糊移除", 1, P_spotBlurB},
    {"界面元素", "透明 UI 元素", "通知/媒体播放器背景透明", 6, P_transUI},
    {"界面元素", "隐藏文件夹背景", "主屏文件夹背景透明", 2, P_folder},
    {"界面元素", "移除主屏编辑遮罩", "抖动模式变暗遮罩移除", 1, P_overlay},
    {"界面元素", "移除多任务模糊", "App 切换器背景模糊移除", 1, P_switcher},
    {"界面元素", "App 背景透明", "App 切换器内应用卡片背景透明", 1, P_appBg},
    {"界面元素", "移除 Spotlight 模糊", "主屏搜索背景模糊移除", 2, P_spotBlur},
    {"界面元素", "隐藏 Home 条", "隐藏底部指示条", 1, P_homeBar},
    {"通知", "透明通知头像", "通知内 App 图标背景透明", 2, P_avatar},
    {"锁屏", "隐藏锁屏快捷键", "隐藏手电筒/相机按钮", 1, P_lockShort},
    {"声音", "静音充电提示音", "连接电源音清零", 1, P_charge},
    {"声音", "静音锁定音", "锁屏音清零", 1, P_lockSnd},
    {"声音", "静音录像提示音", "开始/结束录像音清零", 2, P_record},
    {"声音", "静音快门音", "拍照/连拍快门音清零", 5, P_shutter},
    {"声音", "静音键盘音", "键盘敲击音清零", 6, P_keyboard},
};
static const int gTweakCount = sizeof(gTweaks) / sizeof(gTweaks[0]);

#pragma mark - 根权限（TrollStore）

static void SpawnRoot(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    char *argv[args.count + 2];
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = (char *)[args[i] UTF8String];
    argv[args.count + 1] = NULL;
    posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
}

static BOOL RootAvailable(void) {
    // 探测：以根 persona 执行 true，等待返回
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    char *argv[] = { "/usr/bin/true", NULL };
    int rc = posix_spawn(&pid, "/usr/bin/true", NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) return NO;
    int st = 0;
    return (waitpid(pid, &st, 0) == pid) ? YES : NO;
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

#pragma mark - 持久化

static NSString *StateKeyForTweak(NSString *name) { return name; }
static void SaveTweakState(NSString *name, NSString *state) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:kStatePath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    d[name] = state;
    [d writeToFile:kStatePath atomically:YES];
}

#pragma mark - VC

@interface MdxVC : UITableViewController
@end

@implementation MdxVC {
    NSMutableArray<NSString *> *_log;
    NSMutableArray<NSString *> *_status;   // 每 tweak 状态文本
    NSMutableSet<NSNumber *> *_busy;
    BOOL _allBusy;
    BOOL _rootOK;
    UITextView *_logView;
    UILabel *_engineLabel;
    UIBarButtonItem *_applyAllBtn;
    NSArray<NSString *> *_cats;
}

- (NSString *)state:(int)idx {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    return d[[NSString stringWithUTF8String:gTweaks[idx].name]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"mdcX Max";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _log = [NSMutableArray array];
    _busy = [NSMutableSet set];
    NSMutableArray *st = [NSMutableArray array];
    for (int i = 0; i < gTweakCount; i++) [st addObject:@"未应用"];
    _status = st;

    // 分类去重
    NSMutableArray *cats = [NSMutableArray array];
    for (int i = 0; i < gTweakCount; i++) {
        NSString *c = [NSString stringWithUTF8String:gTweaks[i].cat];
        if (![cats containsObject:c]) [cats addObject:c];
    }
    _cats = cats;

    _rootOK = RootAvailable();

    // 引擎状态头（Auto Layout，避免 viewDidLoad 时 bounds 未就绪导致错位）
    NSMutableString *e = [NSMutableString string];
    [e appendFormat:@"引擎A 零页漏洞：就绪（页大小 %dKB）\n", (int)(vm_page_size / 1024)];
    [e appendFormat:@"引擎B TrollStore 根权限：%@（无沙盒读写 + 根 respring）\n", _rootOK ? @"✅ 可用" : @"❌ 不可用"];
    [e appendFormat:@"系统版本：%@ · 共 %d 项 / 34 文件 · SSV 零页重启后还原", [UIDevice currentDevice].systemVersion, gTweakCount];

    CGFloat availW = [UIScreen mainScreen].bounds.size.width - 32;
    _engineLabel = [[UILabel alloc] init];
    _engineLabel.numberOfLines = 0;
    _engineLabel.font = [UIFont systemFontOfSize:13];
    _engineLabel.textColor = [UIColor secondaryLabelColor];
    _engineLabel.text = e;
    CGSize sz = [_engineLabel sizeThatFits:CGSizeMake(availW, CGFLOAT_MAX)];
    CGFloat headH = ceil(sz.height) + 20;
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, headH)];
    _engineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:_engineLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_engineLabel.topAnchor constraintEqualToAnchor:head.topAnchor constant:10],
        [_engineLabel.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:16],
        [_engineLabel.trailingAnchor constraintEqualToAnchor:head.trailingAnchor constant:-16],
        [_engineLabel.bottomAnchor constraintLessThanOrEqualToAnchor:head.bottomAnchor constant:-10],
    ]];
    self.tableView.tableHeaderView = head;

    // 底部日志
    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.scrollEnabled = YES;
    _logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logView.textColor = [UIColor secondaryLabelColor];
    _logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _logView.layer.cornerRadius = 8;
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_logView];
    [NSLayoutConstraint activateConstraints:@[
        [_logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_logView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6],
        [_logView.heightAnchor constraintEqualToConstant:84],
    ]];
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 100, 0);

    _applyAllBtn = [[UIBarButtonItem alloc] initWithTitle:@"全部应用" style:UIBarButtonItemStyleDone
                                                    target:self action:@selector(applyAll)];
    self.navigationItem.rightBarButtonItem = _applyAllBtn;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"根 Respring" style:UIBarButtonItemStyleDone
                                         target:self action:@selector(onRespring)];

    [self log:[NSString stringWithFormat:@"mdcX Max 启动 · 根权限 %@", _rootOK ? @"可用" : @"不可用"]];
}

- (void)log:(NSString *)s {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [f stringFromDate:[NSDate date]], s];
    [_log addObject:line];
    if (_log.count > 200) [_log removeObjectAtIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        _logView.text = [_log componentsJoinedByString:@"\n"];
        NSRange b = {(long)_logView.text.length, 0};
        [_logView scrollRangeToVisible:b];
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _cats.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _cats[s]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSString *c = _cats[s];
    int n = 0;
    for (int i = 0; i < gTweakCount; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) n++;
    return n;
}
// 全局索引映射
- (int)globalIndex:(NSInteger)s row:(NSInteger)r {
    NSString *c = _cats[s];
    int seen = -1;
    for (int i = 0; i < gTweakCount; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) {
            seen++;
            if (seen == r) return i;
        }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"cell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(0, 0, 76, 32);
        btn.layer.cornerRadius = 8;
        btn.layer.borderWidth = 1;
        [btn setTitleColor:[UIColor systemPurpleColor] forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(applyTap:) forControlEvents:UIControlEventTouchUpInside];
        btn.tag = 999;
        c.accessoryView = btn;
        c.detailTextLabel.numberOfLines = 2;
        c.detailTextLabel.font = [UIFont systemFontOfSize:11];
        c.textLabel.font = [UIFont boldSystemFontOfSize:15];
    }
    int gi = [self globalIndex:ip.section row:ip.row];
    const MdxTweak *t = &gTweaks[gi];
    NSString *name = [NSString stringWithUTF8String:t->name];
    c.textLabel.text = name;

    NSString *stTxt = _status[gi];
    if ([stTxt hasPrefix:@"✅"] || [stTxt hasPrefix:@"⚠️"]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
        NSString *saved = d[name];
        if (saved) stTxt = [NSString stringWithFormat:@"%@ · %@", stTxt, saved];
    }
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@ · %d 文件", stTxt,
                              [NSString stringWithUTF8String:t->desc], t->npaths];

    UIButton *btn = (UIButton *)c.accessoryView;
    btn.tag = gi;
    btn.enabled = ![_busy containsObject:@(gi)] && !_allBusy;
    [btn setTitle:btn.enabled ? @"应用" : @"…" forState:UIControlStateNormal];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self applyIndex:[self globalIndex:ip.section row:ip.row]];
}

- (void)applyTap:(UIButton *)sender { [self applyIndex:(int)sender.tag]; }

// 核心：应用一个 tweak（零页 + 校验 + 持久化）
- (void)applyIndex:(int)gi {
    if ([_busy containsObject:@(gi)]) return;
    const MdxTweak *t = &gTweaks[gi];
    NSString *name = [NSString stringWithUTF8String:t->name];
    [_busy addObject:@(gi)];
    _status[gi] = @"应用中…";
    [self.tableView reloadData];
    [self log:[NSString stringWithFormat:@"开始：%@", name]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int ok = 0, verified = 0;
        for (int p = 0; p < t->npaths; p++) {
            const char *path = t->paths[p];
            int pages = 0;
            int rc = mdcx_zero_file(path, 0, &pages);
            const char *base = strrchr(path, '/');
            base = base ? base + 1 : path;
            if (rc == 0) {
                ok++;
                int z = mdcx_check_zeroed(path);
                if (z == 1) verified++;
                [self log:[NSString stringWithFormat:@"  %s 零页成功（%d页）验证=%@", base, pages,
                           z == 1 ? @"已清零✅" : (z == 0 ? @"仍在❌" : @"无法读取")]];
            } else {
                [self log:[NSString stringWithFormat:@"  %s 失败 rc=%d", base, rc]];
            }
        }
        NSString *state = [NSString stringWithFormat:@"%d/%d✅", verified, t->npaths];
        NSString *status = [NSString stringWithFormat:@"✅ %d/%d", verified, t->npaths];
        if (ok < t->npaths) {
            state = [NSString stringWithFormat:@"%d/%d⚠️", ok, t->npaths];
            status = [NSString stringWithFormat:@"⚠️ %d/%d（零页 %d/%d）", verified, t->npaths, ok, t->npaths];
        }
        SaveTweakState(name, [NSString stringWithFormat:@"%@ %@", state,
                             [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                           dateStyle:NSDateFormatterShortStyle
                                                           timeStyle:NSDateFormatterShortStyle]]);
        dispatch_async(dispatch_get_main_queue(), ^{
            _status[gi] = status;
            [_busy removeObject:@(gi)];
            [self.tableView reloadData];
            [self log:[NSString stringWithFormat:@"完成：%@ → %@", name, status]];
        });
    });
}

- (void)applyAll {
    if (_allBusy || _busy.count) return;
    _allBusy = YES;
    _applyAllBtn.enabled = NO;
    [self log:@"批量应用开始…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < gTweakCount; i++) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![_busy containsObject:@(i)]) [self applyIndex:i];
            });
            usleep(120 * 1000); // 间隔，避免同时大量 mlock
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            _allBusy = NO;
            _applyAllBtn.enabled = YES;
            [self log:@"批量应用结束。重启（不只是 respring）会还原 SSV 零页效果。"];
            [self.tableView reloadData];
        });
    });
}

- (void)onRespring {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"确认 Respring"
                                message:@"将以根权限杀掉 SpringBoard 桌面进程以加载零页效果。" 
                                preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [self log:@"根 Respring 执行中…"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Respring();
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

@interface MdxAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MdxAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[MdxVC alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MdxAppDelegate class]));
    }
}
