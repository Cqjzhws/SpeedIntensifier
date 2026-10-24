// SIOriginal-BG v3.0.2-BG — 真后台保活配置 App（TrollStore 安装用）
//
// SIOriginal v2.4.1 精简版配套配置器：只写保活相关的键，动画加速等键已随功能整体移除。
// 写 plist + 发 Darwin 通知（dylib 热重载）；提供已装 App audio 后台模式扫描、注销。
//
// 配置文件：/var/Managed Preferences/mobile/com.local.sioriginalbg.plist
//   Enabled / SceneFake / AudioKeep / CallAware   四个开关
//   BgRefresh / BgRefreshInterval                 后台定时刷新（v3.0.2）
//   Blacklist                                     排除名单（数组；条目结尾 * 表示前缀匹配）
//   AppOverrides                                  App 级覆盖 { "bundle id" = { ... }; }

#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

static NSString *const kPrefPath = @"/var/Managed Preferences/mobile/com.local.sioriginalbg.plist";
static NSString *const kNotify   = @"com.local.sioriginalbg.settingschanged";
static NSString *const kVersion  = @"SIOriginal-BG v3.0.2-BG";

// 只有这些键会被写进 plist（新增键必须登记，否则是死配置）
static NSArray *BGConfigKeys(void) {
    return @[ @"Enabled", @"SceneFake", @"AudioKeep", @"CallAware",
              @"BgRefresh", @"BgRefreshInterval", @"Blacklist", @"AppOverrides" ];
}

#pragma mark ==================== 注销 ====================
static int BGKillProcessNamed(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    len += 32 * sizeof(struct kinfo_proc);
    struct kinfo_proc *list = (struct kinfo_proc *)malloc(len);
    if (!list) return -1;
    int killed = 0;
    if (sysctl(mib, 4, list, &len, NULL, 0) == 0) {
        int count = (int)(len / sizeof(struct kinfo_proc));
        for (int i = 0; i < count; i++) {
            if (strncmp(list[i].kp_proc.p_comm, name, sizeof(list[i].kp_proc.p_comm)) == 0) {
                if (kill(list[i].kp_proc.p_pid, SIGKILL) == 0) killed++;
            }
        }
    }
    free(list);
    return killed;
}

static void BGRespring(void) {
    (void)BGKillProcessNamed("SpringBoard");
    BGKillProcessNamed("backboardd");
}

#pragma mark ==================== 配置读写 ====================

static NSMutableDictionary *BGReadConfig(void) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:kPrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    // 缺键默认值必须与 dylib 静态初值 / SIOBG_resetDefaults() 一致（缺键 = 开）
    if (!d[@"Enabled"])      d[@"Enabled"]      = @YES;
    if (!d[@"SceneFake"])    d[@"SceneFake"]    = @YES;
    if (!d[@"AudioKeep"])    d[@"AudioKeep"]    = @YES;
    if (!d[@"CallAware"])    d[@"CallAware"]    = @YES;   // v3.0.1 通话感知避让
    if (!d[@"BgRefresh"])    d[@"BgRefresh"]    = @YES;   // v3.0.2 后台定时刷新
    if (!d[@"BgRefreshInterval"]) d[@"BgRefreshInterval"] = @30.0;
    if (!d[@"Blacklist"])    d[@"Blacklist"]    = @[];
    if (!d[@"AppOverrides"]) d[@"AppOverrides"] = @{};
    return d;
}

static BOOL BGWriteConfig(NSDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:kPrefPath] mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    for (NSString *k in BGConfigKeys()) {
        if (cfg[k]) merged[k] = cfg[k];
    }
    BOOL ok = [merged writeToFile:kPrefPath atomically:YES];
    if (ok) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)kNotify, NULL, NULL, YES);
    }
    NSLog(@"[SIOBG-App] write pref -> %d", ok);
    return ok;
}

// 每行一个 Bundle ID；条目结尾写 * 表示前缀匹配（如 com.tencent.*）
static NSArray *BGParseList(NSString *text) {
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [arr addObject:t];
    }
    return arr;
}

// 每行一个 App 覆盖，格式：<bundle id> [enabled=0/1] [scene=0/1] [audio=0/1] [call=0/1] [bgrefresh=0/1] [interval=秒]
// 例：com.tencent.xin scene=0 audio=1   （微信只关场景伪装，保留音频断言）
// 例：com.tencent.xin bgrefresh=0       （微信不补刷新）
// 例：com.tencent.xin interval=60       （微信 60s 一刷）
static NSDictionary *BGParseOverrides(NSString *text) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (!t.length) continue;
        NSArray *toks = [t componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
        NSString *bid = [toks.firstObject stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
        if (!bid.length) continue;
        NSMutableDictionary *ovr = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < toks.count; i++) {
            NSArray *kv = [toks[i] componentsSeparatedByString:@"="];
            if (kv.count != 2) continue;
            NSString *k = [kv[0] lowercaseString];
            NSString *v = [kv[1] lowercaseString];
            BOOL on = [v isEqualToString:@"1"] || [v isEqualToString:@"yes"] || [v isEqualToString:@"on"];
            if      ([k isEqualToString:@"enabled"])   ovr[@"Enabled"]   = @(on);
            else if ([k isEqualToString:@"scene"])     ovr[@"SceneFake"] = @(on);
            else if ([k isEqualToString:@"audio"])     ovr[@"AudioKeep"] = @(on);
            else if ([k isEqualToString:@"call"])      ovr[@"CallAware"] = @(on);
            else if ([k isEqualToString:@"bgrefresh"]) ovr[@"BgRefresh"] = @(on);
            else if ([k isEqualToString:@"interval"]) {
                double sec = v.doubleValue;
                if (sec > 0) ovr[@"BgRefreshInterval"] = @(sec);
            }
        }
        if (ovr.count) out[bid] = ovr;
    }
    return out;
}

static NSString *BGOverridesText(NSDictionary *ovr) {
    if (![ovr isKindOfClass:[NSDictionary class]] || !ovr.count) return @"";
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *keys = [ovr.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *bid in keys) {
        NSDictionary *d = ovr[bid];
        NSMutableArray *parts = [NSMutableArray arrayWithObject:bid];
        if (d[@"Enabled"])   [parts addObject:[NSString stringWithFormat:@"enabled=%d", [d[@"Enabled"] boolValue]]];
        if (d[@"SceneFake"]) [parts addObject:[NSString stringWithFormat:@"scene=%d",   [d[@"SceneFake"] boolValue]]];
        if (d[@"AudioKeep"]) [parts addObject:[NSString stringWithFormat:@"audio=%d",   [d[@"AudioKeep"] boolValue]]];
        if (d[@"CallAware"]) [parts addObject:[NSString stringWithFormat:@"call=%d",    [d[@"CallAware"] boolValue]]];
        if (d[@"BgRefresh"]) [parts addObject:[NSString stringWithFormat:@"bgrefresh=%d", [d[@"BgRefresh"] boolValue]]];
        if (d[@"BgRefreshInterval"])
            [parts addObject:[NSString stringWithFormat:@"interval=%@", d[@"BgRefreshInterval"]]];
        [lines addObject:[parts componentsJoinedByString:@" "]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark ==================== 已装 App 扫描 ====================
// TrollStore App 路径：/var/containers/Bundle/Application/<UUID>/<App>.app
// 需要 no-sandbox entitlement（本 App 已带）。
static NSString *BGScanInstalledApps(void) {
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
    [out appendString:@"默认开启【场景伪装】：无论是否有 audio 声明，注入 dylib 即可保活；\n"];
    [out appendString:@"下方分组只反映「音频兜底」引擎的前提条件。\n\n"];
    [out appendFormat:@"【✅ 自带 audio 声明 — 双引擎完整】%d 个\n%@\n\n",
     (int)yesLines.count,
     yesLines.count ? [yesLines componentsJoinedByString:@"\n"] : @"(无)"];
    [out appendFormat:@"【▪️ 无 audio 声明 — 场景伪装仍可保活；仅关场景伪装时才需改包】%d 个\n%@\n",
     (int)noLines.count,
     noLines.count ? [noLines componentsJoinedByString:@"\n"] : @"(无)"];
    return out;
}

#pragma mark ==================== UI ====================
@interface BGRootVC : UIViewController
@end

@implementation BGRootVC {
    UISwitch *_enableSwitch;
    UISwitch *_sceneSwitch;
    UISwitch *_audioSwitch;
    UISwitch *_callSwitch;
    UISwitch *_refreshSwitch;
    UITextField *_intervalField;
    UITextView *_blacklist;
    UITextView *_overrides;
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"真后台";

    NSDictionary *cfg = BGReadConfig();

    UILabel *title = [[UILabel alloc] init];
    title.text = @"真后台保活";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = [NSString stringWithFormat:@"%@ · 场景伪装 + 音频断言双引擎\n（动画加速等已删除，仅保留保活）", kVersion];
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 0;

    // —— 开关组 ——
    _enableSwitch = [[UISwitch alloc] init];
    _enableSwitch.on = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    _sceneSwitch  = [[UISwitch alloc] init];
    _sceneSwitch.on  = cfg[@"SceneFake"] ? [cfg[@"SceneFake"] boolValue] : YES;
    _audioSwitch  = [[UISwitch alloc] init];
    _audioSwitch.on  = cfg[@"AudioKeep"] ? [cfg[@"AudioKeep"] boolValue] : YES;
    _callSwitch   = [[UISwitch alloc] init];
    _callSwitch.on   = cfg[@"CallAware"] ? [cfg[@"CallAware"] boolValue] : YES;
    _refreshSwitch = [[UISwitch alloc] init];
    _refreshSwitch.on = cfg[@"BgRefresh"] ? [cfg[@"BgRefresh"] boolValue] : YES;

    _intervalField = [[UITextField alloc] init];
    _intervalField.keyboardType = UIKeyboardTypeNumberPad;
    _intervalField.borderStyle = UITextBorderStyleRoundedRect;
    _intervalField.placeholder = @"30";
    _intervalField.textAlignment = NSTextAlignmentCenter;
    _intervalField.font = [UIFont systemFontOfSize:15];
    id iv = cfg[@"BgRefreshInterval"];
    _intervalField.text = iv ? [iv stringValue] : @"30";
    [_intervalField.widthAnchor constraintEqualToConstant:72].active = YES;

    UIView *row1 = [self _rowWith:[self _label:@"总开关（注入 dylib 的 App 全部生效）"
                                         color:[UIColor labelColor] size:15] ctrl:_enableSwitch];
    UIView *row2 = [self _rowWith:[self _label:@"场景伪装（核心：拦截后台化指令，App 始终以为自己在前台；不依赖 audio 声明）"
                                         color:[UIColor labelColor] size:15] ctrl:_sceneSwitch];
    UIView *row3 = [self _rowWith:[self _label:@"音频断言兜底（无声白噪声防挂起，不打断音乐；与场景伪装双保险）"
                                         color:[UIColor secondaryLabelColor] size:13] ctrl:_audioSwitch];
    UIView *row4 = [self _rowWith:[self _label:@"通话避让（来电/录音时让出音频会话，配合忙线拒接等插件；v3.0.1 新增）"
                                         color:[UIColor secondaryLabelColor] size:13] ctrl:_callSwitch];
    UIView *row5 = [self _rowWith:[self _label:@"后台定时刷新（真后台期间周期性触发 App 自己的同步分支；v3.0.2 新增）"
                                         color:[UIColor secondaryLabelColor] size:13] ctrl:_refreshSwitch];
    UIView *row6 = [self _rowWith:[self _label:@"刷新周期（秒，10–600；填 0 = 关闭刷新）"
                                         color:[UIColor secondaryLabelColor] size:13] ctrl:_intervalField];

    UILabel *lblBl = [self _label:@"排除名单（每行一个 Bundle ID，命中不保活；结尾 * 表示前缀匹配）"
                            color:[UIColor secondaryLabelColor] size:15];
    _blacklist = [[UITextView alloc] init];
    _blacklist.font = [UIFont systemFontOfSize:14];
    _blacklist.text = [cfg[@"Blacklist"] isKindOfClass:[NSArray class]]
        ? [cfg[@"Blacklist"] componentsJoinedByString:@"\n"] : @"";
    _blacklist.layer.cornerRadius = 8;
    [_blacklist.heightAnchor constraintEqualToConstant:80].active = YES;

    UILabel *lblOvr = [self _label:@"App 专属覆盖（每行一个，格式：Bundle ID [enabled=0/1] [scene=0/1] [audio=0/1]）"
                             color:[UIColor secondaryLabelColor] size:15];
    _overrides = [[UITextView alloc] init];
    _overrides.font = [UIFont systemFontOfSize:14];
    _overrides.text = BGOverridesText(cfg[@"AppOverrides"]);
    _overrides.layer.cornerRadius = 8;
    [_overrides.heightAnchor constraintEqualToConstant:80].active = YES;

    UILabel *hintOvr = [self _label:@"例：com.tencent.xin scene=0 audio=1（微信只关场景伪装、保留音频断言）\n例：com.tencent.xin bgrefresh=0（微信不补刷新）；interval=60 单独调周期"
                              color:[UIColor tertiaryLabelColor] size:12];

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [scanBtn setTitle:@"扫描已安装 App 的后台支持情况" forState:UIControlStateNormal];
    scanBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [scanBtn addTarget:self action:@selector(onScan) forControlEvents:UIControlEventTouchUpInside];

    _scanResult = [[UITextView alloc] init];
    _scanResult.font = [UIFont systemFontOfSize:12];
    _scanResult.editable = NO;
    _scanResult.text = @"点上方按钮扫描。";
    _scanResult.layer.cornerRadius = 8;
    [_scanResult.heightAnchor constraintEqualToConstant:220].active = YES;

    UILabel *hint = [self _label:
        @"用法：TrollFools 把 SIOriginalBG.dylib 注入目标 App。场景伪装拦截系统下发的后台化指令，音频断言防止进程被挂起，看门狗自愈、来电中断自动恢复。v3.0.1 起默认开启「通话避让」：检测到微信自身通话/录音占用音频会话时立刻让出，修掉与忙线拒接等插件的冲突和来电通知延迟。v3.0.2 起默认开启「后台定时刷新」：场景伪装吞掉转场后 App 收不到「回前台」通知，解锁会秒开不刷新（消息要杀进程才有）；该功能在真后台期间每 30s 补投一次刷新通知触发 App 自己的同步分支。控制台日志前缀 [SIOBG]。"
                           color:[UIColor secondaryLabelColor] size:12];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    [apply setTitle:@"保存配置（即时生效）" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    apply.backgroundColor = [UIColor systemBlueColor];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.layer.cornerRadius = 10;
    [apply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];
    [apply.heightAnchor constraintEqualToConstant:46].active = YES;

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:@"恢复出厂默认" forState:UIControlStateNormal];
    reset.titleLabel.font = [UIFont systemFontOfSize:16];
    [reset addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];

    UIButton *respring = [UIButton buttonWithType:UIButtonTypeSystem];
    [respring setTitle:@"注销 iPhone" forState:UIControlStateNormal];
    respring.titleLabel.font = [UIFont systemFontOfSize:16];
    [respring addTarget:self action:@selector(onRespring) forControlEvents:UIControlEventTouchUpInside];

    _status = [[UILabel alloc] init];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, sub, row1, row2, row3, row4, row5, row6,
        lblBl, _blacklist,
        lblOvr, _overrides, hintOvr,
        scanBtn, _scanResult,
        hint,
        apply, reset, respring, _status
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

- (NSDictionary *)_collectConfig {
    // 周期：非数字/空 → 0（关闭）；数字原样交给 dylib 钳制到 10–600
    double interval = [_intervalField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]].doubleValue;
    return @{ @"Enabled":      @(_enableSwitch.on),
              @"SceneFake":    @(_sceneSwitch.on),
              @"AudioKeep":    @(_audioSwitch.on),
              @"CallAware":    @(_callSwitch.on),
              @"BgRefresh":    @(_refreshSwitch.on),
              @"BgRefreshInterval": @(interval),
              @"Blacklist":    BGParseList(_blacklist.text),
              @"AppOverrides": BGParseOverrides(_overrides.text) };
}

- (void)onScan {
    _scanResult.text = @"扫描中…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = BGScanInstalledApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            _scanResult.text = result;
        });
    });
}

- (void)onApply {
    BOOL ok = BGWriteConfig([self _collectConfig]);
    _status.text = ok
        ? (_enableSwitch.on ? @"已保存：保活配置已更新，即时生效。" : @"已保存：保活已关闭。")
        : @"保存失败（plist 写不进去，检查权限/磁盘）。";
}

- (void)onReset {
    BOOL ok = BGWriteConfig(@{ @"Enabled": @YES, @"SceneFake": @YES, @"AudioKeep": @YES,
                               @"CallAware": @YES, @"BgRefresh": @YES,
                               @"BgRefreshInterval": @30.0,
                               @"Blacklist": @[], @"AppOverrides": @{} });
    if (ok) {
        NSDictionary *cfg = BGReadConfig();
        _enableSwitch.on = YES;
        _sceneSwitch.on   = YES;
        _audioSwitch.on   = YES;
        _callSwitch.on    = YES;
        _refreshSwitch.on = YES;
        _intervalField.text = @"30";
        _blacklist.text   = @"";
        _overrides.text   = BGOverridesText(cfg[@"AppOverrides"]);
        _status.text = @"已恢复出厂默认（五项全开、周期 30s、名单清空）。";
    } else {
        _status.text = @"恢复失败（plist 写不进去）。";
    }
}

- (void)onRespring {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"注销 iPhone"
                                                                message:@"保存配置并立即注销？"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        BGWriteConfig([self _collectConfig]);
        BGRespring();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

@interface BGAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation BGAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)lo {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[BGRootVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([BGAppDelegate class]));
    }
}
