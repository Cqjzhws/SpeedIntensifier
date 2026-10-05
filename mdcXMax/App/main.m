// mdcX Max v2.1.0 — TrollStore 增强版
// 基于 speedyfriend433/mdcX (MIT) 的文件零页技术全新 ObjC 重写：
//   · 引擎A：VM_BEHAVIOR_ZERO_WIRED_PAGES 零页漏洞（SSV 文件生效，重启自动还原）
//   · 引擎B：TrollStore 根权限（persona-mgmt 根 respring + 无沙盒全文件访问）
//   · 应用后真实验证（重读文件首页确认已清零）
//
// v2.1.0 增强与美化：
//   · 引擎A 开机自检：临时文件实测零页是否生效（v2.0.0 永远显示"就绪"，iOS 16.2+ 已修复该漏洞时是假状态）
//   · 启动 / 下拉自动扫描全部目标文件的当前零页状态（生效中 / 部分 / 未生效）
//   · 状态存储改串行队列 + 内存缓存（修 v2.0.0 批量应用时 17 个任务并发全量写 plist 互相覆盖）
//   · 批量应用改串行执行 + 真实进度条（原为固定 3s 假等待，与实际完成脱节）
//   · cell 渲染不再逐行读磁盘；日志时间戳复用静态 formatter；清理死代码
//   · 全新前端：渐变头卡 + 引擎状态圆点 / 分类 SF Symbols / 状态胶囊 / 卡片式日志
//   · 触觉反馈；日志复制 / 清空；操作菜单（重扫 / 清状态记录 / 根 Respring）
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
#define kVersion   @"2.1.0"

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

// v2.0.0 每次全量读改写 plist，批量应用时并发互踩丢状态；现在写入走串行队列、读取走内存缓存。
static void MdxStoreWrite(NSDictionary *snapshot) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("mdcx.store", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{ [snapshot writeToFile:kStatePath atomically:YES]; });
}

#pragma mark - 渐变头卡
// 用 drawRect: + CGGradient 实现，不依赖 QuartzCore.framework
//（v2.0.0 官方 IPA 只链接 UIKit/Foundation/CoreFoundation，本地 Theos 构建环境同样没有 QuartzCore）

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
    // systemPurple -> systemBlue 对角渐变
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
@end

#pragma mark - VC

@interface MdxVC : UITableViewController
@end

@implementation MdxVC {
    NSMutableArray<NSString *> *_log;
    NSMutableArray *_applyResult;      // NSNull 或本次会话的应用结果字符串
    NSArray<NSNumber *> *_scanState;   // 0 未生效 1 部分生效 2 生效中 3 无法检测（nil=未扫描）
    NSMutableDictionary *_stateCache;  // tweak 名 → 持久化记录（磁盘 plist 的内存镜像）
    NSMutableSet<NSNumber *> *_busy;
    BOOL _batchActive;
    BOOL _scanning;
    BOOL _rootOK, _engineA, _engineChecked;
    dispatch_queue_t _workQ;

    // 头卡
    UIView *_headerView;
    MdxGradientView *_headerCard;
    UILabel *_engineALabel, *_engineBLabel, *_sysLabel;
    UIView *_dotA, *_dotB;
    UIView *_progressRow;
    UIProgressView *_progressView;
    UILabel *_progressLabel;
    NSLayoutConstraint *_progressRowH;

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

    [self.tableView registerClass:[MdxCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 66;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 66, 0, 0);

    UIRefreshControl *rc = [UIRefreshControl new];
    rc.tintColor = [UIColor systemPurpleColor];
    [rc addTarget:self action:@selector(rescan) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [self buildHeader];
    [self buildLogCard];

    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 152, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;

    _applyAllBtn = [[UIBarButtonItem alloc] initWithTitle:@"全部应用" style:UIBarButtonItemStyleDone
                                                   target:self action:@selector(applyAll)];
    self.navigationItem.rightBarButtonItem = _applyAllBtn;

    // 左上菜单：不用 iOS 14 SDK 的 initWithTitle:image:primaryAction:menu:（Theos 旧 SDK 编译不过），
    // 改为普通按钮 + UIAlertController actionSheet（iOS 8 起，任何 SDK 可编）
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(showMenu:)];

    [self log:@"mdcX Max 启动，引擎自检中…"];

    // 根探测 + 引擎自检放后台，完成后刷新头卡并触发首轮扫描（v2.0.0 在主线程同步 waitpid）
    dispatch_async(_workQ, ^{
        BOOL root = RootAvailable();
        BOOL eng = EngineASelfTest();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_rootOK = root;
            self->_engineA = eng;
            self->_engineChecked = YES;
            [self updateHeader];
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

- (void)layoutTableHeader {
    UIView *h = self.tableView.tableHeaderView;
    if (!h) return;
    CGFloat w = self.tableView.bounds.size.width;
    CGSize s = [h systemLayoutSizeFitting:CGSizeMake(w, UILayoutFittingCompressedSize.height)
            withHorizontalFittingPriority:UILayoutPriorityRequired
                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(s.height - h.frame.size.height) > 0.5) {
        h.frame = CGRectMake(0, 0, w, s.height);
        self.tableView.tableHeaderView = h;
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
    _headerView.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 210);

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
                            color:[UIColor colorWithWhite:1 alpha:0.75] lines:2];
    _sysLabel.text = [NSString stringWithFormat:@"iOS %@ · %d 项 / %d 文件 · 页 %dKB",
                      [UIDevice currentDevice].systemVersion, gTweakCount, MdxTotalFiles(),
                      (int)(vm_page_size / 1024)];

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

        [_progressRow.topAnchor constraintEqualToAnchor:_sysLabel.bottomAnchor constant:10],
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
        ? @"引擎B TrollStore 根权限：可用（根 Respring）"
        : @"引擎B TrollStore 根权限：不可用（Respring 无效）";
    [self layoutTableHeader];
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
    t.text = @"活动日志";
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

// 替代 iOS 14 UIMenu 的 action sheet
- (void)showMenu:(UIBarButtonItem *)sender {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新扫描状态" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self rescan]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *a) { [self copyLog]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空状态记录" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) { [self confirmClearStates]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"根 Respring" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) { [self onRespring]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // Info.plist 声明 UIDeviceFamily 含 iPad：actionSheet 在 iPad 上必须锚点，否则崩溃
    ac.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:ac animated:YES completion:nil];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _cats.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSString *c = _cats[s];
    int n = 0;
    for (int i = 0; i < gTweakCount; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) n++;
    return n;
}

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

- (NSIndexPath *)indexPathForGlobal:(int)gi {
    NSString *c = [NSString stringWithUTF8String:gTweaks[gi].cat];
    NSInteger sec = [_cats indexOfObject:c];
    int seen = -1;
    for (int i = 0; i <= gi; i++)
        if ([[NSString stringWithUTF8String:gTweaks[i].cat] isEqualToString:c]) seen++;
    return [NSIndexPath indexPathForRow:seen inSection:sec];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    UIView *v = [UIView new];
    UIImageView *iv = [[UIImageView alloc] initWithImage:MdxSymbol(MdxCategoryIcon(_cats[s]), 13)];
    iv.tintColor = [UIColor secondaryLabelColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:iv];
    UILabel *l = [UILabel new];
    l.text = _cats[s];
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = [UIColor secondaryLabelColor];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [iv.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:14],
        [iv.heightAnchor constraintEqualToConstant:14],
        [l.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
        [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
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

    cell.iconView.image = MdxSymbol(MdxCategoryIcon(cat), 17);
    cell.iconView.tintColor = [UIColor systemPurpleColor];
    cell.iconWrap.backgroundColor = [[UIColor systemPurpleColor] colorWithAlphaComponent:0.15];
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

    BOOL en = !_batchActive && ![_busy containsObject:@(gi)];
    cell.actionBtn.enabled = en;
    cell.actionBtn.tag = gi;
    [cell.actionBtn setTitle:en ? @"应用" : @"…" forState:UIControlStateNormal];
    cell.actionBtn.backgroundColor = en ? [UIColor systemPurpleColor] : [UIColor systemGray3Color];
    [cell.actionBtn addTarget:self action:@selector(applyTap:) forControlEvents:UIControlEventTouchUpInside];
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
    [self.tableView reloadRowsAtIndexPaths:@[[self indexPathForGlobal:gi]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark 应用逻辑（核心零页在 _workQ 串行执行）

// 同步应用一个 tweak（必须在 _workQ 上调用），返回状态字符串
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

    // 主线程更新内存缓存并取快照，写盘走串行队列（互不覆盖）
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
            [self log:[NSString stringWithFormat:@"完成：%@ → %@",
                       [NSString stringWithUTF8String:gTweaks[gi].name], status]];
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
    _batchActive = YES;
    _applyAllBtn.enabled = NO;
    _progressView.progress = 0;
    _progressLabel.text = [NSString stringWithFormat:@"0/%d", gTweakCount];
    [self setProgressVisible:YES];
    [self.tableView reloadData];
    [self log:@"批量应用开始…"];

    dispatch_async(_workQ, ^{
        for (int i = 0; i < gTweakCount; i++) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_busy addObject:@(i)];
                [self reloadRow:i];
            });
            NSString *status = [self applySync:i];
            int done = i + 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_applyResult[i] = status;
                [self->_busy removeObject:@(i)];
                [self reloadRow:i];
                self->_progressView.progress = (float)done / gTweakCount;
                self->_progressLabel.text = [NSString stringWithFormat:@"%d/%d", done, gTweakCount];
            });
            usleep(80 * 1000); // 间隔，避免同时大量 mlock
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_batchActive = NO;
            self->_applyAllBtn.enabled = YES;
            [self setProgressVisible:NO];
            [self log:@"批量应用结束。重启（不只是 respring）会还原 SSV 零页效果。"];
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            [self rescan];
        });
    });
}

#pragma mark 扫描

- (void)rescan {
    if (_scanning) {
        // 扫描进行中又触发下拉：收起转圈，避免 refreshControl 卡死
        [self.refreshControl endRefreshing];
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
            [self log:@"状态扫描完成"];
        });
    });
}

#pragma mark 菜单动作

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
