// FUClean v1.0 — TrollStore 系统清理（一键清系统日志，App 日志受保护）
//
// 架构：本 App 带 no-sandbox + platform-application + persona-mgmt 权限（TrollStore 保留
// 任意 entitlements）。真正删除 root 所属的系统日志（/var/db/diagnostics 等）由 bundle
// 内 Helpers/fuclean-helper 完成：App 通过 posix_spawn 的 root persona 启动它，以 uid 0
// 运行，stdout 返回 JSON 结果。
//
// "保 App 日志"由 helper 强制执行，与界面开关无关：
//   数据容器 / App Group 容器的 Library/Logs 与所有 *.log 永远不会被删除，
//   扫描时单独统计并在界面绿色分区展示。
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

// root persona 私有接口（符号由 libSystem 导出，TrollStore 环境可用）
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict attr,
                                          uid_t persona, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict attr, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict attr, gid_t gid);
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern char **environ;

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.fuclean.plist";

#pragma mark ==================== root helper 调用 ====================

// 以 root persona 启动 helper，同步返回 stdout 字符串
static NSString *FCRunHelper(NSArray<NSString *> *args, int *exitCode) {
    NSString *hp = [[NSBundle mainBundle].bundlePath
                    stringByAppendingPathComponent:@"Helpers/fuclean-helper"];
    chmod(hp.fileSystemRepresentation, 0755);
    if (![[NSFileManager defaultManager] fileExistsAtPath:hp]) {
        return @"{\"ok\":0,\"error\":\"helper missing\"}";
    }

    int outfds[2];
    if (pipe(outfds) != 0) return @"{\"ok\":0,\"error\":\"pipe\"}";

    posix_spawn_file_actions_t acts;
    posix_spawn_file_actions_init(&acts);
    posix_spawn_file_actions_addclose(&acts, outfds[0]);
    posix_spawn_file_actions_adddup2(&acts, outfds[1], 1);
    posix_spawn_file_actions_addclose(&acts, outfds[1]);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    NSUInteger argc = args.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    argv[0] = (char *)hp.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = (char *)args[i].UTF8String;
    argv[argc] = NULL;

    pid_t pid = -1;
    int rs = posix_spawn(&pid, hp.fileSystemRepresentation, &acts, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&acts);
    posix_spawnattr_destroy(&attr);
    free(argv);
    close(outfds[1]);

    if (rs != 0) {
        close(outfds[0]);
        if (exitCode) *exitCode = -1;
        return [NSString stringWithFormat:@"{\"ok\":0,\"error\":\"spawn %d\"}", rs];
    }

    NSMutableData *out = [NSMutableData data];
    char buf[8192];
    ssize_t n;
    while ((n = read(outfds[0], buf, sizeof(buf))) > 0) [out appendBytes:buf length:n];
    close(outfds[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (exitCode) *exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"{\"ok\":0}";
}

#pragma mark ==================== 注销 ====================
static int FCKillProcessNamed(const char *name) {
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

#pragma mark ==================== 工具 ====================
static NSString *FCFormatBytes(unsigned long long b) {
    double v = (double)b;
    NSArray *u = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    int i = 0;
    while (v >= 1024.0 && i < u.count - 1) { v /= 1024.0; i++; }
    if (i == 0) return [NSString stringWithFormat:@"%llu %@", b, u[i]];
    return [NSString stringWithFormat:@"%.2f %@", v, u[i]];
}

static NSString *FCReadExclude(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    NSArray *ex = d[@"ExcludeApps"];
    return [ex isKindOfClass:[NSArray class]] ? [ex componentsJoinedByString:@"\n"] : @"";
}
static void FCWriteExclude(NSString *text) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [arr addObject:t];
    }
    [@{ @"ExcludeApps": arr } writeToFile:kPrefPath atomically:YES];
}

#pragma mark ==================== 界面 ====================
@interface FCRootVC : UIViewController
@end

@implementation FCRootVC {
    UILabel *_totalLabel;
    UILabel *_protectedLabel;
    UILabel *_status;
    UIButton *_scanBtn;
    UIButton *_cleanBtn;
    UIActivityIndicatorView *_spinner;
    UIStackView *_catStack;
    UITextView *_exclude;
    UITextView *_historyView;

    NSDictionary *_scan;                 // helper scan 结果
    NSMutableDictionary<NSString *, NSNumber *> *_catOn;
    NSArray<NSDictionary *> *_history;
}

- (UILabel *)_label:(NSString *)text color:(UIColor *)color size:(CGFloat)size
              bold:(BOOL)bold lines:(NSInteger)lines {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = color;
    l.numberOfLines = lines;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"FUClean";

    _catOn = [NSMutableDictionary dictionaryWithDictionary:@{
        @"unified": @YES, @"crash": @YES, @"syslogs": @YES, @"syscaches": @YES,
        @"tmp": @YES, @"safari": @YES, @"appcache": @YES,
    }];
    _history = @[];

    UILabel *title = [self _label:@"系统清理" color:[UIColor labelColor] size:28 bold:YES lines:1];
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [self _label:@"FUClean v1.0 · 一键清系统日志 · App 日志保护"
                          color:[UIColor secondaryLabelColor] size:13 bold:NO lines:0];
    sub.textAlignment = NSTextAlignmentCenter;

    UIView *banner = [[UIView alloc] init];
    banner.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:0.30 alpha:0.14];
    banner.layer.cornerRadius = 10;
    UILabel *bt = [self _label:@"🛡️ App 日志保护始终生效"
                         color:[UIColor colorWithRed:0.12 green:0.45 blue:0.22 alpha:1]
                          size:15 bold:YES lines:1];
    UILabel *bs = [self _label:@"各 App 的 Library/Logs 与 .log 文件不会被清理（含微信等重要日志库）"
                         color:[UIColor colorWithRed:0.15 green:0.40 blue:0.20 alpha:1]
                          size:12 bold:NO lines:0];
    UIStackView *bb = [[UIStackView alloc] initWithArrangedSubviews:@[bt, bs]];
    bb.axis = UILayoutConstraintAxisVertical;
    bb.spacing = 3;
    bb.translatesAutoresizingMaskIntoConstraints = NO;
    [banner addSubview:bb];
    [NSLayoutConstraint activateConstraints:@[
        [bb.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10],
        [bb.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14],
        [bb.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-14],
        [bb.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10],
    ]];

    _totalLabel = [self _label:@"尚未扫描" color:[UIColor labelColor] size:16 bold:YES lines:1];
    _protectedLabel = [self _label:@"受保护的 App 日志：—"
                             color:[UIColor colorWithRed:0.12 green:0.45 blue:0.22 alpha:1]
                              size:13 bold:NO lines:0];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];

    _scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_scanBtn setTitle:@"扫描系统垃圾" forState:UIControlStateNormal];
    _scanBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    _scanBtn.backgroundColor = [UIColor systemBlueColor];
    [_scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _scanBtn.layer.cornerRadius = 10;
    [_scanBtn addTarget:self action:@selector(onScan) forControlEvents:UIControlEventTouchUpInside];
    [_scanBtn.heightAnchor constraintEqualToConstant:48].active = YES;

    _catStack = [[UIStackView alloc] init];
    _catStack.axis = UILayoutConstraintAxisVertical;
    _catStack.spacing = 0;
    _catStack.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _catStack.layer.cornerRadius = 12;
    UILabel *ph = [self _label:@"扫描后这里列出可清理项目，可逐项开关。"
                         color:[UIColor secondaryLabelColor] size:13 bold:NO lines:1];
    ph.textAlignment = NSTextAlignmentCenter;
    [_catStack addArrangedSubview:ph];
    [ph.heightAnchor constraintEqualToConstant:48].active = YES;

    _cleanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cleanBtn setTitle:@"一键清理" forState:UIControlStateNormal];
    _cleanBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _cleanBtn.backgroundColor = [UIColor systemRedColor];
    [_cleanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _cleanBtn.layer.cornerRadius = 12;
    [_cleanBtn addTarget:self action:@selector(onClean) forControlEvents:UIControlEventTouchUpInside];
    [_cleanBtn.heightAnchor constraintEqualToConstant:52].active = YES;
    _cleanBtn.enabled = NO;
    _cleanBtn.alpha = 0.5;

    _status = [self _label:@"" color:[UIColor secondaryLabelColor] size:12 bold:NO lines:0];
    _status.textAlignment = NSTextAlignmentCenter;

    UILabel *wl = [self _label:@"清理白名单（每行一个 Bundle ID 前缀，命中的 App 不清缓存）"
                         color:[UIColor secondaryLabelColor] size:13 bold:NO lines:0];
    _exclude = [[UITextView alloc] init];
    _exclude.font = [UIFont systemFontOfSize:13];
    _exclude.text = FCReadExclude();
    _exclude.layer.cornerRadius = 8;
    [_exclude.heightAnchor constraintEqualToConstant:70].active = YES;
    UIButton *saveWl = [UIButton buttonWithType:UIButtonTypeSystem];
    [saveWl setTitle:@"保存白名单" forState:UIControlStateNormal];
    [saveWl addTarget:self action:@selector(onSaveWhitelist) forControlEvents:UIControlEventTouchUpInside];

    UIButton *respring = [UIButton buttonWithType:UIButtonTypeSystem];
    [respring setTitle:@"注销 iPhone（清理后刷新系统缓存建议）" forState:UIControlStateNormal];
    respring.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [respring addTarget:self action:@selector(onRespring) forControlEvents:UIControlEventTouchUpInside];

    _historyView = [[UITextView alloc] init];
    _historyView.font = [UIFont systemFontOfSize:12];
    _historyView.editable = NO;
    _historyView.layer.cornerRadius = 8;
    [_historyView.heightAnchor constraintEqualToConstant:130].active = YES;
    [self reloadHistory];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub, banner,
        _totalLabel, _protectedLabel,
        _scanBtn, _catStack, _cleanBtn, _status,
        wl, _exclude, saveWl,
        respring,
        [self _label:@"清理历史" color:[UIColor secondaryLabelColor] size:13 bold:NO lines:1],
        _historyView,
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

#pragma mark 类别名
+ (NSDictionary *)catNames {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"unified":   @"系统统一日志（logd 诊断库）",
            @"crash":     @"崩溃与诊断报告",
            @"syslogs":   @"其他系统日志",
            @"syscaches": @"系统组件缓存",
            @"tmp":       @"系统临时文件",
            @"safari":    @"Safari 缓存（不含 Cookie/历史）",
            @"appcache":  @"第三方 App 缓存（白名单生效，日志受保护）",
        };
    });
    return m;
}

#pragma mark 扫描/清理
- (void)setBusy:(BOOL)busy text:(NSString *)text {
    if (busy) {
        [_spinner startAnimating];
        _scanBtn.enabled = NO; _cleanBtn.enabled = NO;
        _scanBtn.alpha = 0.6; _cleanBtn.alpha = 0.5;
    } else {
        [_spinner stopAnimating];
        _scanBtn.enabled = YES;
        _scanBtn.alpha = 1.0;
    }
    _status.text = text;
}

- (void)onScan {
    [self.view endEditing:YES];
    FCWriteExclude(_exclude.text);
    [self setBusy:YES text:@"root 助手扫描中（首次可能需要十几秒）…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int code = 0;
        NSString *out = FCRunHelper(@[@"scan"], &code);
        NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
        NSError *e = nil;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO text:@""];
            if (![j[@"ok"] intValue] || e) {
                _status.text = [NSString stringWithFormat:@"扫描失败（code=%d）：%@", code,
                                j[@"error"] ?: e.localizedDescription ?: out];
                return;
            }
            _scan = j;
            [self renderScan];
        });
    });
}

- (void)renderScan {
    for (UIView *v in _catStack.arrangedSubviews) [v removeFromSuperview];

    unsigned long long totalSel = 0;
    NSDictionary *nameMap = [FCRootVC catNames];
    for (NSDictionary *c in _scan[@"categories"]) {
        NSString *key = c[@"key"];
        unsigned long long bytes = [c[@"bytes"] unsignedLongLongValue];
        long files = [c[@"files"] longValue];
        if ([_catOn[key] boolValue]) totalSel += bytes;

        UIView *row = [[UIView alloc] init];
        UILabel *name = [self _label:nameMap[key] ?: key
                               color:[UIColor labelColor] size:14 bold:NO lines:2];
        UILabel *size = [self _label:[NSString stringWithFormat:@"%@ · %ld 个文件",
                                      FCFormatBytes(bytes), files]
                               color:[UIColor secondaryLabelColor] size:12 bold:NO lines:1];
        UIStackView *txt = [[UIStackView alloc] initWithArrangedSubviews:@[name, size]];
        txt.axis = UILayoutConstraintAxisVertical;
        txt.spacing = 2;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [_catOn[key] boolValue];
        [sw addTarget:self action:@selector(onCatSwitch:) forControlEvents:UIControlEventValueChanged];
        sw.accessibilityLabel = key;

        UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[txt, sw]];
        r.axis = UILayoutConstraintAxisHorizontal;
        r.alignment = UIStackViewAlignmentCenter;
        r.spacing = 10;
        r.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:r];
        [NSLayoutConstraint activateConstraints:@[
            [r.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
            [r.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
            [r.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
            [r.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        ]];
        [_catStack addArrangedSubview:row];
    }

    unsigned long long prot = [_scan[@"protected_bytes"] unsignedLongLongValue];
    long protFiles = [_scan[@"protected_files"] longValue];
    NSMutableString *ps = [NSMutableString stringWithFormat:
        @"🛡️ 受保护的 App 日志：%@ · %ld 个文件（不会清理）", FCFormatBytes(prot), protFiles];
    NSArray *apps = _scan[@"protected_apps"];
    for (NSDictionary *a in apps) {
        if ([a[@"bytes"] unsignedLongLongValue] == 0) continue;
        [ps appendFormat:@"\n   · %@：%@", a[@"id"], FCFormatBytes([a[@"bytes"] unsignedLongLongValue])];
        if (ps.length > 500) { [ps appendString:@"\n   …"]; break; }
    }
    _protectedLabel.text = ps;

    _totalLabel.text = [NSString stringWithFormat:@"可清理（选中）：%@", FCFormatBytes(totalSel)];
    _cleanBtn.enabled = totalSel > 0;
    _cleanBtn.alpha = totalSel > 0 ? 1.0 : 0.5;
    [_cleanBtn setTitle:[NSString stringWithFormat:@"一键清理（约 %@）", FCFormatBytes(totalSel)]
              forState:UIControlStateNormal];
}

- (void)onCatSwitch:(UISwitch *)sw {
    NSString *key = sw.accessibilityLabel;
    _catOn[key] = @(sw.on);
    unsigned long long totalSel = 0;
    for (NSDictionary *c in _scan[@"categories"]) {
        if ([_catOn[c[@"key"]] boolValue])
            totalSel += [c[@"bytes"] unsignedLongLongValue];
    }
    _totalLabel.text = [NSString stringWithFormat:@"可清理（选中）：%@", FCFormatBytes(totalSel)];
    _cleanBtn.enabled = totalSel > 0;
    _cleanBtn.alpha = totalSel > 0 ? 1.0 : 0.5;
    [_cleanBtn setTitle:[NSString stringWithFormat:@"一键清理（约 %@）", FCFormatBytes(totalSel)]
              forState:UIControlStateNormal];
}

- (void)onClean {
    NSMutableArray *keys = [NSMutableArray array];
    unsigned long long expect = 0;
    for (NSDictionary *c in _scan[@"categories"]) {
        NSString *k = c[@"key"];
        if ([_catOn[k] boolValue]) {
            [keys addObject:k];
            expect += [c[@"bytes"] unsignedLongLongValue];
        }
    }
    if (!keys.count) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"确认清理"
        message:[NSString stringWithFormat:
            @"将清理 %lu 个项目，约释放 %@。\n\n受保护的 App 日志（%@）不会被动。\n"
            "正在使用的日志文件会跳过，系统服务会自动重建所需文件。",
            (unsigned long)keys.count, FCFormatBytes(expect),
            FCFormatBytes([_scan[@"protected_bytes"] unsignedLongLongValue])]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"开始清理" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *a) {
        [self setBusy:YES text:@"root 助手清理中，请勿退出…"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int code = 0;
            NSString *out = FCRunHelper(@[@"clean", [keys componentsJoinedByString:@","]], &code);
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:
                [out dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setBusy:NO text:@""];
                if (![j[@"ok"] intValue]) {
                    _status.text = [NSString stringWithFormat:@"清理失败（code=%d）%@", code, j[@"error"] ?: @""];
                    return;
                }
                unsigned long long freed = [j[@"total_bytes"] unsignedLongLongValue];
                long deleted = [j[@"deleted"] longValue];
                long failed = [j[@"failed"] longValue];
                long skipped = [j[@"skipped"] longValue];
                [self appendHistory:freed deleted:deleted failed:failed keys:keys];
                [self reloadHistory];
                UIAlertController *r = [UIAlertController alertControllerWithTitle:@"清理完成"
                    message:[NSString stringWithFormat:
                        @"释放空间：%@\n删除项：%ld（失败 %ld，跳过占用中 %ld）\n\n建议注销一次以刷新系统缓存。",
                        FCFormatBytes(freed), deleted, failed, skipped]
                    preferredStyle:UIAlertControllerStyleAlert];
                [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *x) { [self onScan]; }]];
                [r addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive
                    handler:^(__unused UIAlertAction *x) { FCKillProcessNamed("SpringBoard"); }]];
                [self presentViewController:r animated:YES completion:nil];
            });
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark 历史
- (NSString *)historyPath {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:@"fuclean_history.json"];
}
- (void)appendHistory:(unsigned long long)bytes deleted:(long)deleted
               failed:(long)failed keys:(NSArray *)keys {
    NSMutableArray *h = [NSMutableArray arrayWithArray:_history];
    [h insertObject:@{
        @"time": [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                dateStyle:NSDateFormatterShortStyle
                                                timeStyle:NSDateFormatterShortStyle],
        @"bytes": @(bytes), @"deleted": @(deleted), @"failed": @(failed),
        @"keys": [keys componentsJoinedByString:@","],
    } atIndex:0];
    if (h.count > 20) [h removeObjectsInRange:NSMakeRange(20, h.count - 20)];
    _history = h;
    [h writeToFile:[self historyPath] atomically:YES];
}
- (void)reloadHistory {
    NSArray *h = [NSArray arrayWithContentsOfFile:[self historyPath]];
    if ([h isKindOfClass:[NSArray class]]) _history = h; else _history = @[];
    NSMutableString *s = [NSMutableString string];
    if (!_history.count) [s appendString:@"暂无清理记录"];
    for (NSDictionary *r in _history) {
        [s appendFormat:@"%@  释放 %@  删除 %ld 项%@\n",
            r[@"time"], FCFormatBytes([r[@"bytes"] unsignedLongLongValue]),
            [r[@"deleted"] longValue],
            [r[@"failed"] longValue] ? [NSString stringWithFormat:@"  失败%@", r[@"failed"]] : @""];
    }
    _historyView.text = s;
}

- (void)onSaveWhitelist {
    [self.view endEditing:YES];
    FCWriteExclude(_exclude.text);
    _status.text = @"白名单已保存（下次扫描生效）";
}

- (void)onRespring {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"注销 iPhone"
        message:@"立即注销？" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *a) {
        FCKillProcessNamed("SpringBoard");
        FCKillProcessNamed("backboardd");
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

@interface FCAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation FCAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)lo {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[FCRootVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FCAppDelegate class]));
    }
}
