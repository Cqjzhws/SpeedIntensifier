// mdcX Max v2.2.0 — TrollStore 增强版
// 基于 speedyfriend433/mdcX (MIT) 的文件零页技术全新 ObjC 重写：
//   · 引擎A：VM_BEHAVIOR_ZERO_WIRED_PAGES 零页漏洞（SSV 文件生效，重启自动还原）
//   · 引擎B：TrollStore 根权限（persona-mgmt 根 respring / reboot + 无沙盒全文件访问）
//   · 应用后真实验证（重读文件首页确认已清零）
//
// v2.2.0 增强与美化：
//   · 修复致命编译错误：systemLayoutSizeFitting:（Swift 名，ObjC 不存在）
//     → systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:
//     （v2.1.0 两次 CI 构建均因此失败，IPA 实际从未出包）
//   · 搜索：导航栏实时搜索（名称 / 描述 / 分类 / 文件名），空结果占位
//   · 头卡新增实时统计胶囊：已生效 X/17 项 · Y/36 文件
//   · 批量应用自动跳过已生效项（幂等、更快、减少 mlock 压力），结束弹注销/重启引导
//   · 新增“重启还原全部”：零页效果只存于内存，/sbin/reboot 一键还原（根权限）
//   · 长按任意条目查看目标文件清单（大小 + 完整路径），可一键复制
//   · 分类配色体系：Dock 紫 / Spotlight 青 / 界面元素 靛蓝 / 通知 粉 / 锁屏 蓝 / 声音 橙
//   · section 标题右侧分类计数；触觉按成功/警告区分；关于页
//
// v2.1.0 已有能力：引擎A 临时文件自检 / 启动下拉扫描 / 串行状态存储 /
//   串行批量+真实进度条 / 渐变头卡 / 状态胶囊 / 卡片日志 / 触觉反馈
//
// 编译兼容：仅使用 UIKit/Foundation/CoreGraphics（渐变用 drawRect + CGGradient，
// 菜单用 UIAlertController actionSheet），GitHub Actions clang 与本地旧 Theos 均可编。
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <unistd.h>
#import <string.h>
#import <mach/mach.h>
#import "exploit.h"

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

#define kStatePath @"/var/mobile/Library/Preferences/com.local.mdcxmax.plist"
#define kVersion   @"2.2.0"

#pragma mark - Tweak 目录（17 项 / 36 文件）

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

static int MdxTotalFiles(void) {
    int n = 0;
    for (int i = 0; i < gTweakCount; i++) n += gTweaks[i].npaths;
    return n;
}

// 分类 SF Symbols 图标（iOS 14 可用；缺失时回落 paintpalette）
static NSString *MdxCategoryIcon(NSString *cat) {
    if ([cat isEqualToString:@"Dock"])       return @"dock.rectangle";
    if ([cat isEqualToString:@"Spotlight"])  return @"magnifyingglass";
    if ([cat isEqualToString:@"通知"])        return @"bell.fill";
    if ([cat isEqualToString:@"锁屏"])        return @"lock.fill";
    if ([cat isEqualToString:@"声音"])        return @"speaker.wave.2.fill";
    return @"square.on.square"; // 界面元素
}

// v2.2.0 分类配色
static UIColor *MdxCategoryColor(NSString *cat) {
    if ([cat isEqualToString:@"Dock"])       return [UIColor systemPurpleColor];
    if ([cat isEqualToString:@"Spotlight"])  return [UIColor systemTealColor];
    if ([cat isEqualToString:@"通知"])        return [UIColor systemPinkColor];
    if ([cat isEqualToString:@"锁屏"])        return [UIColor systemBlueColor];
    if ([cat isEqualToString:@"声音"])        return [UIColor systemOrangeColor];
    return [UIColor systemIndigoColor]; // 界面元素
}

static NSString *MdxFormatSize(long long bytes) {
    if (bytes < 0) return @"不可读";
    if (bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.2f MB", bytes / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
}

static UIImage *MdxSymbol(NSString *name, CGFloat pt) {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightMedium];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!img) img = [UIImage systemImageNamed:@"paintpalette" withConfiguration:cfg];
    return img;
}

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

// 零页效果仅存于内存页缓存，SSV 磁盘镜像不动；重启即由磁盘完整还原。
static void RebootDevice(void) {
    SpawnRoot(@"/sbin/reboot", @[]);
}

#pragma mark - 引擎A 自检

// 临时文件实测零页：写入一整页已知字节 → 跑零页 → 重读校验。
// iOS 16.2+ 已修复 VM_BEHAVIOR_ZERO_WIRED_PAGES 滥用，此时返回 NO。
static BOOL EngineASelfTest(void) {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mdcx_selftest.bin"];
    size_t sz = (size_t)vm_page_size;
    char *buf = malloc(sz);
    if (!buf) return NO;
    memset(buf, 0x41, sz);
    FILE *fp = fopen(p.fileSystemRepresentation, "wb");
    if (!fp) { free(buf); return NO; }
    fwrite(buf, 1, sz, fp);
    fclose(fp);
    free(buf);
    int pages = 0;
    int rc = mdcx_zero_file(p.fileSystemRepresentation, 0, &pages);
    int z = mdcx_check_zeroed(p.fileSystemRepresentation);
    unlink(p.fileSystemRepresentation);
    return (rc == 0 && pages > 0 && z == 1);
}

#pragma mark - 状态存储（串行队列写入 + 内存缓存）

static void MdxStoreWrite(NSDictionary *snapshot) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("mdcx.store", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{ [snapshot writeToFile:kStatePath atomically:YES]; });
}

#pragma mark - 渐变头卡（drawRect + CGGradient，不依赖 QuartzCore.framework）

@interface MdxGradientView : UIView
@end

@implementation MdxGradientView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 16;
        self.layer.masksToBounds = YES;
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    UIColor *c1 = [UIColor systemPurpleColor];
    UIColor *c2 = [UIColor systemBlueColor];
    CGFloat r1=0,g1=0,b1=0,a1=0,r2=0,g2=0,b2=0,a2=0;
    [c1 getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [c2 getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    CGFloat comps[8] = { (CGFloat)r1,(CGFloat)g1,(CGFloat)b1,1.0, (CGFloat)r2,(CGFloat)g2,(CGFloat)b2,1.0 };
    CGFloat locs[2] = { 0.0, 1.0 };
    CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0,0), CGPointMake(rect.size.width, rect.size.height), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(space);
}
@end

#pragma mark - 自定义 cell

@interface MdxCell : UITableViewCell
@property (nonatomic, strong) UIView *iconWrap;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIButton *actionBtn;
@property (nonatomic, copy) void (^onLongPress)(void);
@end

@implementation MdxCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    if (!self) return nil;

    _iconWrap = [UIView new];
    _iconWrap.layer.cornerRadius = 10;
    _iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_iconWrap];

    _iconView = [UIImageView new];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [_iconWrap addSubview:_iconView];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_titleLabel];

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    _statusLabel.layer.cornerRadius = 4;
    _statusLabel.layer.masksToBounds = YES;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_statusLabel];

    _descLabel = [UILabel new];
    _descLabel.font = [UIFont systemFontOfSize:11];
    _descLabel.textColor = [UIColor secondaryLabelColor];
    _descLabel.numberOfLines = 2;
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_descLabel];

    _actionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionBtn.layer.cornerRadius = 15;
    _actionBtn.layer.masksToBounds = YES;
    _actionBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_actionBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_actionBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateDisabled];
    _actionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_actionBtn];

    // 长按查看文件清单
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    lp.minimumPressDuration = 0.45;
    [self.contentView addGestureRecognizer:lp];

    [NSLayoutConstraint activateConstraints:@[
        [_iconWrap.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconWrap.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconWrap.widthAnchor constraintEqualToConstant:40],
        [_iconWrap.heightAnchor constraintEqualToConstant:40],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconWrap.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconWrap.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:22],
        [_iconView.heightAnchor constraintEqualToConstant:22],

        [_actionBtn.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_actionBtn.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_actionBtn.widthAnchor constraintEqualToConstant:68],
        [_actionBtn.heightAnchor constraintEqualToConstant:30],

        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconWrap.trailingAnchor constant:10],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_actionBtn.leadingAnchor constant:-10],

        [_statusLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],

        [_descLabel.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:3],
        [_descLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_descLabel.trailingAnchor constraintEqualToAnchor:_actionBtn.leadingAnchor constant:-10],
        [_descLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
    ]];
    return self;
}

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && _onLongPress) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        _onLongPress();
    }
}
@end

#pragma mark - VC

@interface MdxVC : UITableViewController <UISearchResultsUpdating>
@end

@implementation MdxVC {
    NSMutableArray<NSString *> *_log;
    NSMutableArray *_applyResult;      // NSNull 或本次会话的应用结果字符串
    NSArray<NSNumber *> *_scanState;   // 0 未生效 1 部分生效 2 生效中 3 无法检测（nil=未扫描）
    NSMutableDictionary *_stateCache;
    NSMutableSet<NSNumber *> *_busy;
    BOOL _batchActive;
    BOOL _scanning;
    BOOL _rootOK, _engineA, _engineChecked;
    dispatch_queue_t _workQ;

    // 搜索
    UISearchController *_search;
    NSString *_filterText;
    NSArray<NSNumber *> *_filtered;

    // 头卡
    UIView *_headerView;
    MdxGradientView *_headerCard;
    UILabel *_engineALabel, *_engineBLabel, *_sysLabel, *_statLabel;
    UIView *_dotA, *_dotB, *_statPill;
    UIView *_progressRow;
    UIProgressView *_progressView;
    UILabel *_progressLabel;
    NSLayoutConstraint *_progressRowH;

    // 空结果占位
    UILabel *_emptyLabel;

    // 日志卡
    UITextView *_logView;

    UIBarButtonItem *_applyAllBtn;
    NSArray<NSString *> *_cats;
}

#pragma mark 构建 UI

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"mdcX Max";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationController.navigationBar.prefersLargeTitles = NO;

    _log = [NSMutableArray array];
    _busy = [NSMutableSet set];
    _filterText = @"";
    _workQ = dispatch_queue_create("mdcx.work", DISPATCH_QUEUE_SERIAL);

    NSMutableArray *ar = [NSMutableArray array];
    for (int i = 0; i < gTweakCount; i++) [ar addObject:[NSNull null]];
    _applyResult = ar;

    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    _stateCache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];

    NSMutableArray *cats = [NSMutableArray array];
    for (int i = 0; i < gTweakCount; i++) {
        NSString *c = [NSString stringWithUTF8String:gTweaks[i].cat];
        if (![cats containsObject:c]) [cats addObject:c];
    }
    _cats = cats;
    _filtered = [self allIndices];

    [self.tableView registerClass:[MdxCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 66;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 66, 0, 0);

    UIRefreshControl *rc = [UIRefreshControl new];
    rc.tintColor = [UIColor systemPurpleColor];
    [rc addTarget:self action:@selector(rescan) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    // 搜索
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.hidesNavigationBarDuringPresentation = NO;
    _search.searchResultsUpdater = self;
    _search.searchBar.placeholder = [NSString stringWithFormat:@"搜索 %d 项美化", gTweakCount];
    _search.searchBar.tintColor = [UIColor systemPurpleColor];
    self.navigationItem.searchController = _search;
    self.definesPresentationContext = YES;

    [self buildHeader];
    [self buildLogCard];

    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 152, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;

    _applyAllBtn = [[UIBarButtonItem alloc] initWithTitle:@"全部应用" style:UIBarButtonItemStyleDone
                                                   target:self action:@selector(applyAll)];
    self.navigationItem.rightBarButtonItem = _applyAllBtn;

    // 兼容旧 Theos SDK：不用 iOS 14 的 initWithTitle:image:primaryAction:menu:
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(showMenu:)];

    [self log:[NSString stringWithFormat:@"mdcX Max v%@ 启动，引擎自检中…", kVersion]];

    dispatch_async(_workQ, ^{
        BOOL root = RootAvailable();
        BOOL eng = EngineASelfTest();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_rootOK = root;
            self->_engineA = eng;
            self->_engineChecked = YES;
            [self updateHeader];
            [self updateApplyButton];
            [self log:[NSString stringWithFormat:@"引擎自检：零页 %@ · 根权限 %@",
                       eng ? @"可用" : @"不可用", root ? @"可用" : @"不可用"]];
            if (!eng) [self log:@"提示：当前系统可能已修复零页漏洞（iOS 16.2+），应用将无效"];
            [self rescan];
        });
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutTableHeader];
}

// v2.1.0 致命 bug 修复：Swift 名 systemLayoutSizeFitting: 在 ObjC 头文件中不存在
- (void)layoutTableHeader {
    UIView *h = self.tableView.tableHeaderView;
    if (!h) return;
    CGFloat w = self.tableView.bounds.size.width;
    CGSize s = [h systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height)
                withHorizontalFittingPriority:UILayoutPriorityRequired
                      verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(s.height - h.frame.size.height) > 0.5) {
        h.frame = CGRectMake(0, 0, w, s.height);
        self.tableView.tableHeaderView = h;
    }
}

#pragma mark 搜索

- (NSArray<NSNumber *> *)allIndices {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:gTweakCount];
    for (int i = 0; i < gTweakCount; i++) [a addObject:@(i)];
    return a;
}

- (BOOL)isFiltering {
    return _search.active && _filterText.length > 0;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    _filterText = sc.searchBar.text.lowercaseString ?: @"";
    if ([self isFiltering]) {
        NSMutableArray *hit = [NSMutableArray array];
        for (int i = 0; i < gTweakCount; i++) {
            const MdxTweak *t = &gTweaks[i];
            NSMutableString *hay = [NSMutableString stringWithFormat:@"%s %s %s", t->cat, t->name, t->desc];
            for (int p = 0; p < t->npaths; p++) {
                const char *slash = strrchr(t->paths[p], '/');
                [hay appendFormat:@" %s", slash ? slash + 1 : t->paths[p]];
            }
            if ([[hay lowercaseString] containsString:_filterText]) [hit addObject:@(i)];
        }
        _filtered = hit;
    } else {
        _filtered = [self allIndices];
    }
    [self updateEmptyState];
    [self.tableView reloadData];
}

- (void)updateEmptyState {
    if ([self isFiltering] && _filtered.count == 0) {
        if (!_emptyLabel) {
            UIView *wrap = [[UIView alloc] initWithFrame:self.tableView.bounds];
            wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            UILabel *l = [UILabel new];
            l.text = @"未找到匹配的项目";
            l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            l.textColor = [UIColor secondaryLabelColor];
            l.textAlignment = NSTextAlignmentCenter;
            l.translatesAutoresizingMaskIntoConstraints = NO;
            [wrap addSubview:l];
            [NSLayoutConstraint activateConstraints:@[
                [l.centerXAnchor constraintEqualToAnchor:wrap.centerXAnchor],
                [l.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:140],
                [l.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:24],
                [l.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-24],
            ]];
            _emptyLabel = l;
            self.tableView.backgroundView = wrap;
        }
        self.tableView.backgroundView.hidden = NO;
    } else {
        self.tableView.backgroundView.hidden = YES;
    }
}

#pragma mark 头卡 / 日志卡

- (UILabel *)headerLabel:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *l = [UILabel new];
    l.font = font;
    l.textColor = color;
    l.numberOfLines = lines;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (UIView *)headerDot {
    UIView *d = [UIView new];
    d.layer.cornerRadius = 4;
    d.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5];
    d.translatesAutoresizingMaskIntoConstraints = NO;
    [d.widthAnchor constraintEqualToConstant:8].active = YES;
    [d.heightAnchor constraintEqualToConstant:8].active = YES;
    return d;
}

- (void)buildHeader {
    _headerView = [UIView new];
    _headerView.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 240);

    _headerCard = [[MdxGradientView alloc] init];
    _headerCard.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerView addSubview:_headerCard];

    UIColor *white = [UIColor whiteColor];
    UIColor *whiteDim = [UIColor colorWithWhite:1 alpha:0.85];

    UILabel *title = [self headerLabel:[UIFont systemFontOfSize:22 weight:UIFontWeightHeavy]
                                 color:white lines:1];
    title.text = @"mdcX Max";

    UILabel *badge = [self headerLabel:[UIFont systemFontOfSize:10 weight:UIFontWeightBold]
                                 color:white lines:1];
    badge.text = [NSString stringWithFormat:@" v%@ ", kVersion];
    badge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    badge.layer.cornerRadius = 6;
    badge.layer.masksToBounds = YES;

    UILabel *subtitle = [self headerLabel:[UIFont systemFontOfSize:12 weight:UIFontWeightRegular]
                                    color:whiteDim lines:1];
    subtitle.text = @"VM 零页 · SSV 系统美化 · 重启自动还原";

    _dotA = [self headerDot];
    _dotB = [self headerDot];
    _engineALabel = [self headerLabel:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium]
                                color:white lines:2];
    _engineBLabel = [self headerLabel:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium]
                                color:white lines:2];
    _engineALabel.text = @"引擎A 零页漏洞：检测中…";
    _engineBLabel.text = @"引擎B TrollStore 根权限：检测中…";

    _sysLabel = [self headerLabel:[UIFont systemFontOfSize:11 weight:UIFontWeightRegular]
                            color:[UIColor colorWithWhite:1 alpha:0.75] lines:1];
    _sysLabel.text = [NSString stringWithFormat:@"iOS %@ · %d 项 / %d 文件 · 页 %dKB",
                      [UIDevice currentDevice].systemVersion, gTweakCount, MdxTotalFiles(),
                      (int)(vm_page_size / 1024)];

    // 统计胶囊
    _statPill = [UIView new];
    _statPill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    _statPill.layer.cornerRadius = 11;
    _statPill.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerCard addSubview:_statPill];

    _statLabel = [self headerLabel:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold]
                             color:white lines:1];
    _statLabel.textAlignment = NSTextAlignmentCenter;
    _statLabel.text = @"生效状态：等待扫描";
    [_statPill addSubview:_statLabel];

    _progressRow = [UIView new];
    _progressRow.translatesAutoresizingMaskIntoConstraints = NO;
    _progressRow.clipsToBounds = YES;
    _progressRow.alpha = 0;

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progressTintColor = white;
    _progressView.trackTintColor = [UIColor colorWithWhite:1 alpha:0.3];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressRow addSubview:_progressView];

    _progressLabel = [self headerLabel:[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold]
                                 color:white lines:1];
    _progressLabel.textAlignment = NSTextAlignmentRight;
    [_progressRow addSubview:_progressLabel];

    [_headerCard addSubview:title];
    [_headerCard addSubview:badge];
    [_headerCard addSubview:subtitle];
    [_headerCard addSubview:_dotA];
    [_headerCard addSubview:_engineALabel];
    [_headerCard addSubview:_dotB];
    [_headerCard addSubview:_engineBLabel];
    [_headerCard addSubview:_sysLabel];
    [_headerCard addSubview:_progressRow];

    _progressRowH = [_progressRow.heightAnchor constraintEqualToConstant:0];
    _progressRowH.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [_headerCard.topAnchor constraintEqualToAnchor:_headerView.topAnchor constant:12],
        [_headerCard.leadingAnchor constraintEqualToAnchor:_headerView.leadingAnchor constant:16],
        [_headerCard.trailingAnchor constraintEqualToAnchor:_headerView.trailingAnchor constant:-16],
        [_headerCard.bottomAnchor constraintEqualToAnchor:_headerView.bottomAnchor constant:-8],

        [title.topAnchor constraintEqualToAnchor:_headerCard.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:_headerCard.leadingAnchor constant:16],
        [badge.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [badge.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:_headerCard.trailingAnchor constant:-16],

        [_dotA.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_dotA.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:14],
        [_engineALabel.leadingAnchor constraintEqualToAnchor:_dotA.trailingAnchor constant:6],
        [_engineALabel.centerYAnchor constraintEqualToAnchor:_dotA.centerYAnchor],
        [_engineALabel.trailingAnchor constraintEqualToAnchor:_headerCard.trailingAnchor constant:-16],

        [_dotB.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_dotB.topAnchor constraintEqualToAnchor:_dotA.bottomAnchor constant:10],
        [_engineBLabel.leadingAnchor constraintEqualToAnchor:_dotB.trailingAnchor constant:6],
        [_engineBLabel.centerYAnchor constraintEqualToAnchor:_dotB.centerYAnchor],
        [_engineBLabel.trailingAnchor constraintEqualToAnchor:_headerCard.trailingAnchor constant:-16],

        [_sysLabel.topAnchor constraintEqualToAnchor:_dotB.bottomAnchor constant:12],
        [_sysLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_sysLabel.trailingAnchor constraintEqualToAnchor:_headerCard.trailingAnchor constant:-16],

        [_statPill.topAnchor constraintEqualToAnchor:_sysLabel.bottomAnchor constant:10],
        [_statPill.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_statPill.trailingAnchor constraintEqualToAnchor:_headerCard.trailingAnchor constant:-16],
        [_statPill.heightAnchor constraintEqualToConstant:24],

        [_statLabel.topAnchor constraintEqualToAnchor:_statPill.topAnchor constant:3],
        [_statLabel.bottomAnchor constraintEqualToAnchor:_statPill.bottomAnchor constant:-3],
        [_statLabel.leadingAnchor constraintEqualToAnchor:_statPill.leadingAnchor constant:12],
        [_statLabel.trailingAnchor constraintEqualToAnchor:_statPill.trailingAnchor constant:-12],
        [_statLabel.centerYAnchor constraintEqualToAnchor:_statPill.centerYAnchor],

        [_progressRow.topAnchor constraintEqualToAnchor:_statPill.bottomAnchor constant:10],
        [_progressRow.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_progressRow.trailingAnchor constraintEqualToAnchor:_headerCard.trailingAnchor constant:-16],
        [_progressRow.bottomAnchor constraintEqualToAnchor:_headerCard.bottomAnchor constant:-14],

        [_progressView.leadingAnchor constraintEqualToAnchor:_progressRow.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:_progressLabel.leadingAnchor constant:-8],
        [_progressView.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
        [_progressLabel.trailingAnchor constraintEqualToAnchor:_progressRow.trailingAnchor],
        [_progressLabel.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
        [_progressLabel.widthAnchor constraintEqualToConstant:44],
    ]];

    self.tableView.tableHeaderView = _headerView;
}

- (void)updateHeader {
    if (!_engineChecked) return;
    _dotA.backgroundColor = _engineA ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    _engineALabel.text = _engineA
        ? @"引擎A 零页漏洞：可用（临时文件实测通过）"
        : @"引擎A 零页漏洞：不可用（当前 iOS 已修复该漏洞）";
    _dotB.backgroundColor = _rootOK ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    _engineBLabel.text = _rootOK
        ? @"引擎B TrollStore 根权限：可用（根 Respring / 重启）"
        : @"引擎B TrollStore 根权限：不可用（Respring 无效）";
    [self layoutTableHeader];
}

- (void)updateApplyButton {
    BOOL dead = _engineChecked && !_engineA;
    _applyAllBtn.enabled = !dead;
}

// 综合本次会话结果与扫描结果，统计头卡胶囊
- (void)updateStats {
    if (!_scanState) { _statLabel.text = @"生效状态：等待扫描"; return; }
    int full = 0, filesOk = 0, filesTotal = 0;
    for (int i = 0; i < gTweakCount; i++) {
        int s = [_scanState[i] intValue];
        id r = _applyResult[i];
        if (r != [NSNull null]) s = [r hasPrefix:@"✅"] ? 2 : 1;
        if (s == 2) full++;
        // 文件级统计直接复用扫描值（应用结果不重算文件数，避免误差）
        if ([_scanState[i] intValue] == 2) filesOk += gTweaks[i].npaths;
        filesTotal += gTweaks[i].npaths;
    }
    _statLabel.text = [NSString stringWithFormat:@"已生效 %d/%d 项 · 文件 %d/%d",
                       full, gTweakCount, filesOk, filesTotal];
}

- (void)setProgressVisible:(BOOL)v {
    _progressRowH.constant = v ? 18 : 0;
    _progressRow.alpha = v ? 1 : 0;
    [_headerCard layoutIfNeeded];
    [self layoutTableHeader];
}

- (UIButton *)logCardButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)buildLogCard {
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *t = [UILabel new];
    t.text = @"活动日志（长按条目可查看文件）";
    t.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    t.textColor = [UIColor secondaryLabelColor];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:t];

    UIButton *copy = [self logCardButton:@"复制" action:@selector(copyLog)];
    UIButton *clear = [self logCardButton:@"清空" action:@selector(clearLog)];
    [card addSubview:copy];
    [card addSubview:clear];

    _logView = [UITextView new];
    _logView.editable = NO;
    _logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logView.textColor = [UIColor secondaryLabelColor];
    _logView.backgroundColor = [UIColor clearColor];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_logView];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [card.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [card.heightAnchor constraintEqualToConstant:140],

        [t.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [t.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],

        [copy.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        [copy.centerYAnchor constraintEqualToAnchor:t.centerYAnchor],
        [clear.trailingAnchor constraintEqualToAnchor:copy.leadingAnchor constant:-14],
        [clear.centerYAnchor constraintEqualToAnchor:t.centerYAnchor],

        [_logView.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:4],
        [_logView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
        [_logView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [_logView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-6],
    ]];
}

#pragma mark 日志

- (void)log:(NSString *)s {
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [f stringFromDate:[NSDate date]], s];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_log addObject:line];
        if (self->_log.count > 300) [self->_log removeObjectAtIndex:0];
        self->_logView.text = [self->_log componentsJoinedByString:@"\n"];
        if (self->_logView.text.length)
            [self->_logView scrollRangeToVisible:NSMakeRange(self->_logView.text.length, 0)];
    });
}

- (void)copyLog {
    if (!_log.count) return;
    [UIPasteboard generalPasteboard].string = [_log componentsJoinedByString:@"\n"];
    [self log:@"日志已复制到剪贴板"];
}

- (void)clearLog {
    [_log removeAllObjects];
    _logView.text = @"";
}

#pragma mark 表格数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return [self isFiltering] ? 1 : _cats.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if ([self isFiltering]) return _filtered.count;
    NSString *c = _cats[s];
    int n = 0;
    for (int i = 0; i < gTweakCount; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) n++;
    return n;
}

- (int)globalIndex:(NSInteger)s row:(NSInteger)r {
    if ([self isFiltering]) return [_filtered[r] intValue];
    NSString *c = _cats[s];
    int seen = -1;
    for (int i = 0; i < gTweakCount; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) {
            seen++;
            if (seen == r) return i;
        }
    return 0;
}

- (NSIndexPath *)indexPathForGlobal:(int)gi {
    if ([self isFiltering]) {
        NSUInteger r = [_filtered indexOfObject:@(gi)];
        if (r == NSNotFound) return nil;
        return [NSIndexPath indexPathForRow:r inSection:0];
    }
    NSString *c = [NSString stringWithUTF8String:gTweaks[gi].cat];
    NSInteger sec = [_cats indexOfObject:c];
    int seen = -1;
    for (int i = 0; i <= gi; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) seen++;
    return [NSIndexPath indexPathForRow:seen inSection:sec];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if ([self isFiltering]) {
        UIView *v = [UIView new];
        UILabel *l = [UILabel new];
        l.text = [NSString stringWithFormat:@"搜索结果（%lu）", (unsigned long)_filtered.count];
        l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        l.textColor = [UIColor secondaryLabelColor];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [v addSubview:l];
        [l.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20].active = YES;
        [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor].active = YES;
        return v;
    }
    NSString *cat = _cats[s];
    int cnt = 0;
    for (int i = 0; i < gTweakCount; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:cat]) cnt++;

    UIView *v = [UIView new];
    UIColor *cc = MdxCategoryColor(cat);
    UIImageView *iv = [[UIImageView alloc] initWithImage:MdxSymbol(MdxCategoryIcon(cat), 13)];
    iv.tintColor = cc;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:iv];
    UILabel *l = [UILabel new];
    l.text = cat;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = [UIColor secondaryLabelColor];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:l];
    UILabel *cntL = [UILabel new];
    cntL.text = [NSString stringWithFormat:@"%d 项", cnt];
    cntL.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    cntL.textColor = [UIColor tertiaryLabelColor];
    cntL.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:cntL];
    [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [iv.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:14],
        [iv.heightAnchor constraintEqualToConstant:14],
        [l.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
        [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [cntL.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:20],
        [cntL.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
    ]];
    return v;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 34; }

// 状态显示优先级：应用中 > 本次会话结果 > 启动扫描 > 待检测
- (void)statusFor:(int)gi text:(NSString **)text color:(UIColor **)color {
    if ([_busy containsObject:@(gi)]) {
        *text = @"应用中…"; *color = [UIColor systemBlueColor]; return;
    }
    id r = _applyResult[gi];
    if (r != [NSNull null]) {
        *text = r;
        *color = [r hasPrefix:@"✅"] ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        return;
    }
    if (_scanState) {
        switch ([_scanState[gi] intValue]) {
            case 2:  *text = @"生效中";   *color = [UIColor systemGreenColor];  return;
            case 1:  *text = @"部分生效"; *color = [UIColor systemOrangeColor]; return;
            case 3:  *text = @"无法检测"; *color = [UIColor secondaryLabelColor]; return;
            default: *text = @"未生效";   *color = [UIColor secondaryLabelColor]; return;
        }
    }
    *text = @"检测中…"; *color = [UIColor secondaryLabelColor];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    MdxCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
    int gi = [self globalIndex:ip.section row:ip.row];
    const MdxTweak *t = &gTweaks[gi];
    NSString *name = [NSString stringWithUTF8String:t->name];
    NSString *cat = [NSString stringWithUTF8String:t->cat];
    UIColor *cc = MdxCategoryColor(cat);

    cell.iconView.image = MdxSymbol(MdxCategoryIcon(cat), 17);
    cell.iconView.tintColor = cc;
    cell.iconWrap.backgroundColor = [cc colorWithAlphaComponent:0.14];
    cell.titleLabel.text = name;

    NSString *st; UIColor *sc;
    [self statusFor:gi text:&st color:&sc];
    cell.statusLabel.text = [NSString stringWithFormat:@" %@ ", st];
    cell.statusLabel.textColor = sc;
    cell.statusLabel.backgroundColor = [sc colorWithAlphaComponent:0.12];

    NSString *desc = [NSString stringWithFormat:@"%@ · %d 文件",
                      [NSString stringWithUTF8String:t->desc], t->npaths];
    NSString *saved = _stateCache[name];
    if (saved.length) desc = [desc stringByAppendingFormat:@" · 上次 %@", saved];
    cell.descLabel.text = desc;

    BOOL en = !_batchActive && ![_busy containsObject:@(gi)] && !(_engineChecked && !_engineA);
    cell.actionBtn.enabled = en;
    cell.actionBtn.tag = gi;
    [cell.actionBtn setTitle:en ? @"应用" : @"…" forState:UIControlStateNormal];
    cell.actionBtn.backgroundColor = en ? cc : [UIColor systemGray3Color];
    [cell.actionBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.actionBtn addTarget:self action:@selector(applyTap:) forControlEvents:UIControlEventTouchUpInside];

    __weak typeof(self) weakSelf = self;
    cell.onLongPress = ^{ [weakSelf showDetail:gi]; };
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self applyIndex:[self globalIndex:ip.section row:ip.row]];
}

- (void)applyTap:(UIButton *)sender {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self applyIndex:(int)sender.tag];
}

- (void)reloadRow:(int)gi {
    NSIndexPath *ip = [self indexPathForGlobal:gi];
    if (ip) [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark 应用逻辑（核心零页在 _workQ 串行执行）

- (NSString *)applySync:(int)gi {
    const MdxTweak *t = &gTweaks[gi];
    NSString *name = [NSString stringWithUTF8String:t->name];
    [self log:[NSString stringWithFormat:@"开始：%@", name]];

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
    NSString *record = [NSString stringWithFormat:@"%@ %@", state,
                        [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                       dateStyle:NSDateFormatterShortStyle
                                                       timeStyle:NSDateFormatterShortStyle]];

    __block NSDictionary *snapshot;
    dispatch_sync(dispatch_get_main_queue(), ^{
        self->_stateCache[name] = record;
        snapshot = [self->_stateCache copy];
    });
    MdxStoreWrite(snapshot);
    return status;
}

- (void)applyIndex:(int)gi {
    if (_engineChecked && !_engineA) {
        [self showAlert:@"引擎A 不可用"
                    msg:@"当前系统已修复零页漏洞（iOS 16.2+），应用不会生效。"];
        return;
    }
    if (_batchActive || [_busy containsObject:@(gi)]) return;
    [_busy addObject:@(gi)];
    [self reloadRow:gi];

    dispatch_async(_workQ, ^{
        NSString *status = [self applySync:gi];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_applyResult[gi] = status;
            [self->_busy removeObject:@(gi)];
            [self reloadRow:gi];
            [self updateStats];
            [self log:[NSString stringWithFormat:@"完成：%@ → %@",
                       [NSString stringWithUTF8String:gTweaks[gi].name], status]];
            UINotificationFeedbackType ft =
                [status hasPrefix:@"✅"] ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning;
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:ft];
        });
    });
}

- (void)applyAll {
    if (_engineChecked && !_engineA) {
        [self showAlert:@"引擎A 不可用"
                    msg:@"当前系统已修复零页漏洞（iOS 16.2+），批量应用不会生效。"];
        return;
    }
    if (_batchActive || _busy.count) return;

    [self showConfirm:@"批量应用全部 17 项"
                message:@"将串行清零全部目标文件首页（约数秒）。已生效的项目会自动跳过。"
             confirmText:@"开始应用"
                  block:^{ [self runBatch]; }];
}

- (void)runBatch {
    _batchActive = YES;
    _applyAllBtn.enabled = NO;
    _progressView.progress = 0;
    _progressLabel.text = [NSString stringWithFormat:@"0/%d", gTweakCount];
    [self setProgressVisible:YES];
    [self.tableView reloadData];
    [self log:@"批量应用开始…"];

    // 在主线程取扫描快照，后台串行执行期间不再碰主线程状态指针
    NSArray<NSNumber *> *scanSnapshot = [_scanState copy];

    dispatch_async(_workQ, ^{
        int applied = 0, skipped = 0, failed = 0;
        for (int i = 0; i < gTweakCount; i++) {
            // v2.2.0：扫描确认已生效的项直接跳过，幂等且减少 mlock 压力
            BOOL already = scanSnapshot && [scanSnapshot[i] intValue] == 2;
            int done = i + 1;
            if (already) {
                skipped++;
                [self log:[NSString stringWithFormat:@"跳过：%@（生效中）",
                           [NSString stringWithUTF8String:gTweaks[i].name]]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_progressView.progress = (float)done / gTweakCount;
                    self->_progressLabel.text = [NSString stringWithFormat:@"%d/%d", done, gTweakCount];
                });
                continue;
            }
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_busy addObject:@(i)];
                [self reloadRow:i];
            });
            NSString *status = [self applySync:i];
            if (![status hasPrefix:@"✅"]) failed++;
            applied++;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_applyResult[i] = status;
                [self->_busy removeObject:@(i)];
                [self reloadRow:i];
                [self updateStats];
                self->_progressView.progress = (float)done / gTweakCount;
                self->_progressLabel.text = [NSString stringWithFormat:@"%d/%d", done, gTweakCount];
            });
            usleep(80 * 1000);
        }
        int fApplied = applied, fSkipped = skipped, fFailed = failed;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_batchActive = NO;
            [self updateApplyButton];
            [self setProgressVisible:NO];
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:
                fFailed ? UINotificationFeedbackTypeWarning : UINotificationFeedbackTypeSuccess];
            [self log:[NSString stringWithFormat:@"批量应用结束：应用 %d · 跳过 %d · 异常 %d",
                       fApplied, fSkipped, fFailed]];
            [self rescanWithCompletion:^{ [self batchDoneDialogApplied:fApplied skipped:fSkipped failed:fFailed]; }];
        });
    });
}

- (void)batchDoneDialogApplied:(int)applied skipped:(int)skipped failed:(int)failed {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"批量应用完成"
        message:[NSString stringWithFormat:@"新应用 %d 项 · 跳过已生效 %d 项 · 异常 %d 项。\n注销桌面后即可看到效果；重启设备将还原全部效果。",
                 applied, skipped, failed]
 preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"立即注销桌面" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        [self log:@"根 Respring 执行中…"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Respring();
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"重启还原全部" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [self confirmReboot];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark 扫描

- (void)rescan { [self rescanWithCompletion:nil]; }

- (void)rescanWithCompletion:(void (^)(void))completion {
    if (_scanning) {
        [self.refreshControl endRefreshing];
        if (completion) completion();
        return;
    }
    _scanning = YES;
    [self log:@"扫描目标文件当前状态…"];
    dispatch_async(_workQ, ^{
        NSMutableArray *scan = [NSMutableArray arrayWithCapacity:gTweakCount];
        for (int i = 0; i < gTweakCount; i++) {
            const MdxTweak *t = &gTweaks[i];
            int z = 0, unreadable = 0;
            for (int p = 0; p < t->npaths; p++) {
                int r = mdcx_check_zeroed(t->paths[p]);
                if (r == 1) z++;
                else if (r < 0) unreadable++;
            }
            int s;
            if (unreadable == t->npaths) s = 3;
            else if (z == t->npaths)  s = 2;
            else if (z > 0)           s = 1;
            else                      s = 0;
            [scan addObject:@(s)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_scanState = scan;
            self->_scanning = NO;
            [self.refreshControl endRefreshing];
            [self.tableView reloadData];
            [self updateStats];
            [self log:@"状态扫描完成"];
            if (completion) completion();
        });
    });
}

#pragma mark 菜单 / 详情 / 关于

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showConfirm:(NSString *)title message:(NSString *)msg confirmText:(NSString *)ct block:(void (^)(void))block {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:ct style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        if (block) block();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showMenu:(UIBarButtonItem *)sender {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新扫描状态" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self rescan]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self copyLog]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"立即注销桌面（Respring）" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self onRespring]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重启还原全部效果" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self confirmReboot]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关于 mdcX Max" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self showAbout]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空状态记录" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) { [self confirmClearStates]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // iPad：actionSheet 必须有锚点，否则崩溃
    ac.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showDetail:(int)gi {
    const MdxTweak *t = &gTweaks[gi];
    NSMutableString *msg = [NSMutableString stringWithFormat:@"%@（%d 个目标文件）\n",
                            [NSString stringWithUTF8String:t->desc], t->npaths];
    NSMutableString *all = [NSMutableString string];
    for (int p = 0; p < t->npaths; p++) {
        const char *path = t->paths[p];
        NSString *size = MdxFormatSize(mdcx_file_size(path));
        [msg appendFormat:@"\n%@\n%s", size, path];
        [all appendFormat:@"%s\n", path];
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:
        [NSString stringWithUTF8String:t->name] message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"复制全部路径" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *x) {
        [UIPasteboard generalPasteboard].string = all;
        [self log:@"目标文件路径已复制"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    // iPad 锚点：长按的 cell
    NSIndexPath *ip = [self indexPathForGlobal:gi];
    if (ip) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
        if (cell) {
            a.popoverPresentationController.sourceView = cell;
            a.popoverPresentationController.sourceRect = cell.bounds;
        }
    }
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showAbout {
    NSString *msg = [NSString stringWithFormat:
@"版本 %@\n基于 VM_BEHAVIOR_ZERO_WIRED_PAGES 文件零页技术（Google Project Zero 公开），对 SSV 系统卷素材文件的内存页清零，实现界面透明化与系统音静音。\n\n· 效果仅存于内存，重启设备自动还原，不修改磁盘系统文件\n· 需 TrollStore 安装（persona-mgmt 根权限）\n· 引擎A 在 iOS 16.2 及以上已被修复，届时功能不可用\n· 注销（Respring）加载效果，重启（Reboot）还原效果\n\n原项目：speedyfriend433/mdcX（MIT License）", kVersion];
    [self showAlert:@"mdcX Max" msg:msg];
}

- (void)confirmClearStates {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清空状态记录"
                                message:@"仅清除本 App 保存的应用记录与界面状态，已生效的零页效果需重启还原。"
                                preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [self->_stateCache removeAllObjects];
        for (int i = 0; i < gTweakCount; i++) self->_applyResult[i] = [NSNull null];
        MdxStoreWrite(@{});
        [self.tableView reloadData];
        [self updateStats];
        [self log:@"状态记录已清空"];
        [self rescan];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onRespring {
    if (_engineChecked && !_rootOK) {
        [self showAlert:@"根权限不可用" msg:@"未检测到 TrollStore 根权限，无法执行 Respring。"];
        return;
    }
    [self showConfirm:@"确认注销桌面"
                message:@"将以根权限杀掉 SpringBoard 进程以加载零页效果（约 10 秒回到锁屏）。"
             confirmText:@"注销"
                  block:^{
        [self log:@"根 Respring 执行中…"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Respring();
        });
    }];
}

- (void)confirmReboot {
    if (_engineChecked && !_rootOK) {
        [self showAlert:@"根权限不可用" msg:@"未检测到 TrollStore 根权限，无法执行重启，请手动重启设备。"];
        return;
    }
    [self showConfirm:@"确认重启设备"
                message:@"重启后 SSV 磁盘镜像会重新加载，所有零页效果（透明化 / 静音）将全部还原。设备将立即重启。"
             confirmText:@"重启"
                  block:^{
        [self log:@"根重启执行中…"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RebootDevice();
        });
    }];
}

@end

#pragma mark - AppDelegate

@interface MdxAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MdxAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:
            [[MdxVC alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.navigationBar.tintColor = [UIColor systemPurpleColor];
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
