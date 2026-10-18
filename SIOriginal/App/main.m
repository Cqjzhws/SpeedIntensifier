// SIOriginal — 配置 App v2.0.0 Max（TrollStore 安装）
// 重制版配套配置器：写 Managed Preferences plist + 发 Darwin 通知热重载。
// v2.0.0：Tab 卡片式 UI、一键预设、配置导入/导出、注入环境自检、新引擎参数。
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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

// unistd.h 已声明 reboot()，补 RB_AUTOBOOT
#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT 0
#endif
extern int reboot(int);

static NSString * const PrefPath  = @"/var/Managed Preferences/mobile/com.apple.UIKit.plist";
static NSString * const NotifyKey = @"com.local.sioriginal.settingschanged";
static NSString * const kAppliedNote = @"SIOModelDidApply";
static NSString * const SIO_VERSION = @"v2.1.10";

// v1.8.14：列表 hook 硬保护名单 —— 必须与 dylib 内 SIO_listHardBlocked() 保持一致。
static NSArray *HardGuardBundles(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[ @"com.sfic.knight" ]; });
    return a;
}

#pragma mark - root 执行工具

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
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc == 0 && pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

static void SpawnRootNowait(NSString *path, NSArray *args) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid = -1;
    char *argv[args.count + 2];
    argv[0] = (char *)path.fileSystemRepresentation;
    for (NSUInteger i = 0; i < args.count; i++)
        argv[i + 1] = (char *)[args[i] UTF8String];
    argv[args.count + 1] = NULL;
    posix_spawn(&pid, path.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
}

static NSString *SIOReboot(void) {
    pid_t pid;

    NSString *selfPath = [[NSBundle mainBundle] executablePath];
    if (selfPath.length) {
        posix_spawnattr_t attr0;
        posix_spawnattr_init(&attr0);
        posix_spawnattr_set_persona_np(&attr0, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attr0, 0);
        posix_spawnattr_set_persona_gid_np(&attr0, 0);
        char *a0[] = { (char *)[selfPath UTF8String], "--sio-reboot-helper", NULL };
        int s0 = posix_spawn(&pid, [selfPath UTF8String], NULL, &attr0, a0, environ);
        posix_spawnattr_destroy(&attr0);
        if (s0 == 0) return @"root 助手 reboot()";
    }

    const char *paths[] = { "/usr/sbin/reboot", "/sbin/reboot" };
    for (int i = 0; i < 2; i++) {
        posix_spawnattr_t a;
        posix_spawnattr_init(&a);
        posix_spawnattr_set_persona_np(&a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&a, 0);
        posix_spawnattr_set_persona_gid_np(&a, 0);
        char *av[] = { (char *)paths[i], NULL };
        int s = posix_spawn(&pid, paths[i], NULL, &a, av, environ);
        posix_spawnattr_destroy(&a);
        if (s == 0) return [NSString stringWithFormat:@"%s", paths[i]];
    }

    const char *kills[][3] = { {"/usr/bin/killall","-9","launchd"},
                               {"/usr/bin/killall","-9","backboardd"} };
    for (int i = 0; i < 2; i++) {
        posix_spawnattr_t a;
        posix_spawnattr_init(&a);
        posix_spawnattr_set_persona_np(&a, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&a, 0);
        posix_spawnattr_set_persona_gid_np(&a, 0);
        char *av[] = { (char *)kills[i][0], (char *)kills[i][1], (char *)kills[i][2], NULL };
        int s = posix_spawn(&pid, kills[i][0], NULL, &a, av, environ);
        posix_spawnattr_destroy(&a);
        if (s == 0) return [NSString stringWithFormat:@"%s %s", kills[i][1], kills[i][2]];
    }
    return @"全部失败";
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

#pragma mark - 配置读写（v2.0.0 全量键）

static NSMutableDictionary *ReadConfig(void) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    // v2.1.1：缺省值与 dylib SIO_reload 严格保持一致。
    // 【重要】FastScroll / FastTap / FastLongPress 必须默认关 —— 仓库 v2.0.5 把它们
    // 默认开启时曾出现「全部 APP 闪退」，v2.0.6 回退关闭后消失。v2.1.0 踩回这个坑。
    if (!d[@"Enabled"])    d[@"Enabled"]    = @YES;
    if (!d[@"Mode"])       d[@"Mode"]       = @0;      // 0=加速
    if (!d[@"Speed"])      d[@"Speed"]      = @15.0;   // 极速倍率（纯时长缩放，无闪退记录）
    if (!d[@"SlowFactor"]) d[@"SlowFactor"] = @2.0;
    if (!d[@"Spring"])     d[@"Spring"]     = @YES;
    if (!d[@"Extra"])      d[@"Extra"]      = @YES;
    if (!d[@"ListAccel"])  d[@"ListAccel"]  = @YES;    // v2.1.2 默认开（硬保护名单仍恒关）
    if (!d[@"ZoomAccel"])  d[@"ZoomAccel"]  = @YES;    // v2.1.2 默认开
    if (!d[@"FastScroll"]) d[@"FastScroll"] = @YES;    // v2.1.2 默认开（hook 按需安装）
    if (!d[@"FastTap"])    d[@"FastTap"]    = @YES;    // v2.1.2 默认开
    if (!d[@"LayerBoost"]) d[@"LayerBoost"] = @3.0;    // 显式动画再 ×3
    if (!d[@"FloorDuration"])    d[@"FloorDuration"]    = @0.01;  // 0.005 属极限值，回 0.01
    if (!d[@"TransitionBoost"])  d[@"TransitionBoost"]  = @2.0;   // 转场再 ×2
    // v2.1.2：FastLongPress / LongPressDuration 已随长按 hook 一并移除
    if (!d[@"InAppNotify"])      d[@"InAppNotify"]      = @YES;
    // v2.1.9：瞬时打开三件套 —— 与 dylib 侧默认值保持一致（缺键 = 开）
    if (!d[@"InstantTransition"]) d[@"InstantTransition"] = @YES;
    if (!d[@"HUDFast"])           d[@"HUDFast"]           = @YES;
    if (!d[@"WKFastShow"])        d[@"WKFastShow"]        = @YES;
    if (!d[@"Blacklist"])  d[@"Blacklist"]  = @[ @"com.tencent.wework" ];
    if (!d[@"FUBGEnabled"])      d[@"FUBGEnabled"]      = @YES;
    if (!d[@"FUBGSceneFake"])    d[@"FUBGSceneFake"]    = @YES;
    if (!d[@"FUBGAudioKeep"])    d[@"FUBGAudioKeep"]    = @YES;
    // v2.1.0：已删除 FUBGFloatingBall（假开关，dylib 侧无消费方）与
    // FUBGExcludeApps（无编辑入口、恒为空表的死配置），不再写入 plist。
    if (!d[@"AppOverrides"])     d[@"AppOverrides"]     = @{};
    return d;
}

// 白名单：只有这里的键会被写入 plist（新增引擎键必须同步登记）
static NSArray *SIOConfigKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"Enabled", @"Mode", @"Speed", @"SlowFactor",
                  @"Spring", @"Extra", @"ListAccel", @"Blacklist", @"ZoomAccel",
                  @"FastScroll", @"FastTap", @"LayerBoost",
                  @"FloorDuration", @"TransitionBoost",
                  @"InAppNotify",
                  // v2.1.9：瞬时打开三件套（新键登记白名单才能被写入 plist）
                  @"InstantTransition", @"HUDFast", @"WKFastShow",
                  @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep",
                  @"AppOverrides" ];
    });
    return keys;
}

static BOOL WriteConfig(NSMutableDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    for (NSString *k in SIOConfigKeys()) {
        if (cfg[k]) merged[k] = cfg[k];
    }
    BOOL ok = [merged writeToFile:PrefPath atomically:YES];
    if (ok) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)NotifyKey, NULL, NULL, YES);
    }
    return ok;
}

// v2.1.2 一次性迁移：清掉旧版遗留的「长按手势加速」两个键。
// 该功能连同其 hook 已整体移除（hook init 族方法必崩，见 dylib 头部注释），
// 配置 App 也不再展示这两项，所以这里直接从 plist 删除，避免留下幽灵配置。
// gMigratedDirty 置位时调用方会弹提示。
static BOOL gMigratedDirty = NO;
static void SIO_MigrateV211(void) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"sio_migrated_v2_1_2"]) return;
    @try {
        NSMutableDictionary *cur =
            [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
        if (!cur) {
            // 没有配置文件：直接标记完成，避免每次启动都跑
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"sio_migrated_v2_1_2"];
            return;
        }
        BOOL dirty = NO;
        NSMutableArray *fixed = [NSMutableArray array];
        // v2.1.2：长按加速的两个键已失效，直接从 plist 移除
        for (NSString *k in @[ @"FastLongPress", @"LongPressDuration" ]) {
            if (cur[k]) { [cur removeObjectForKey:k]; dirty = YES; [fixed addObject:k]; }
        }
        if (cur[@"FloorDuration"] && [cur[@"FloorDuration"] doubleValue] < 0.009) {
            cur[@"FloorDuration"] = @0.01;   // 0.005 属极限值，一并回安全值
            dirty = YES;
        }
        if (dirty) {
            mkdir("/var/Managed Preferences", 0755);
            mkdir("/var/Managed Preferences/mobile", 0755);
            if ([cur writeToFile:PrefPath atomically:YES]) {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    (__bridge CFStringRef)NotifyKey, NULL, NULL, YES);
                gMigratedDirty = YES;
            }
        }
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"sio_migrated_v2_1_2"];
    } @catch (__unused NSException *e) {}
}

#pragma mark - 辅助功能 / UIKit 全局系数

static NSString * const AxPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
static BOOL ReadAx(NSString *key) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AxPath];
    return d[key] ? [d[key] boolValue] : NO;
}
static void WriteAx(NSString *key, BOOL val) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:AxPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    d[key] = @(val);
    [d writeToFile:AxPath atomically:YES];
}

static double ReadUIKitDrag(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PrefPath];
    NSNumber *v = d[@"UIAnimationDragCoefficient"];
    return v ? v.doubleValue : 0.0;
}
static void WriteUIKitDrag(double coeff) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:PrefPath] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (coeff > 0.0) {
        d[@"UIAnimationDragCoefficient"] = @(coeff);
    } else {
        [d removeObjectForKey:@"UIAnimationDragCoefficient"];
    }
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [d writeToFile:PrefPath atomically:YES];
}
// 分档索引 → 系数：0=关闭 1=×5(0.2) 2=×10(0.1) 3=×20(0.05) 4=极端(0.0001)
static double DragCoeffForIndex(int i) {
    switch (i) {
        case 1:  return 0.2;
        case 2:  return 0.1;
        case 3:  return 0.05;
        case 4:  return 0.0001;
        default: return 0.0;
    }
}
static int DragIndexForCoeff(double c) {
    if (c > 0.04 && c < 0.06)  return 3;
    if (c > 0.08 && c < 0.12)  return 2;
    if (c > 0.15 && c < 0.25)  return 1;
    if (c > 0.0 && c < 0.04)   return 4;
    return 0;
}
static int DragMultiplierForCoeff(double c) {
    if (c > 0.04 && c < 0.06)  return 20;
    if (c > 0.08 && c < 0.12)  return 10;
    if (c > 0.15 && c < 0.25)  return 5;
    return 0;
}

#pragma mark - 档位映射（与 dylib 接受范围严格一致）

// 显式动画额外倍率：×1 / ×2 / ×3 / ×5 / ×10
static double LayerBoostForIndex(int i) {
    switch (i) {
        case 1:  return 2.0;
        case 2:  return 3.0;
        case 3:  return 5.0;
        case 4:  return 10.0;
        default: return 1.0;
    }
}
static int LayerIndexForBoost(double b) {
    if (b > 1.5 && b < 2.5)  return 1;
    if (b > 2.5 && b < 4.0)  return 2;
    if (b > 4.0 && b < 7.0)  return 3;
    if (b >= 7.0)            return 4;
    return 0;
}
// 慢放倍率：×2 / ×3 / ×5 / ×10
static double SlowFactorForIndex(int i) {
    switch (i) {
        case 1:  return 3.0;
        case 2:  return 5.0;
        case 3:  return 10.0;
        default: return 2.0;
    }
}
static int SlowIndexForFactor(double f) {
    if (f > 2.5 && f < 4.0)  return 1;
    if (f > 4.0 && f < 7.0)  return 2;
    if (f >= 7.0)            return 3;
    return 0;
}
// 时长安全下限：0.005 / 0.01 / 0.02 / 0.05
static double FloorForIndex(int i) {
    switch (i) {
        case 1:  return 0.01;
        case 2:  return 0.02;
        case 3:  return 0.05;
        default: return 0.005;
    }
}
static int FloorIndexFor(double f) {
    if (f > 0.0075 && f < 0.015) return 1;
    if (f > 0.015  && f < 0.035) return 2;
    if (f >= 0.035)              return 3;
    return 0;
}
// 转场独立倍率：×1 / ×1.5 / ×2 / ×3
static double TransForIndex(int i) {
    switch (i) {
        case 1:  return 1.5;
        case 2:  return 2.0;
        case 3:  return 3.0;
        default: return 1.0;
    }
}
static int TransIndexFor(double t) {
    if (t > 1.25 && t < 1.75) return 1;
    if (t >= 1.75 && t < 2.5) return 2;
    if (t >= 2.5)             return 3;
    return 0;
}

#pragma mark - UI 小部件构造（v2.1.0 视觉重做）

// 品牌色：祖母绿 → 孔雀蓝 → 深夜蓝，统一贯穿头部 / 强调按钮 / Tab
static UIColor *SIOAccent(void) {
    return [UIColor colorWithRed:0.13 green:0.77 blue:0.55 alpha:1.0];
}

static UILabel *SIOLabel(NSString *t, CGFloat size, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:size];
    l.textColor = color ?: [UIColor labelColor];
    l.numberOfLines = 0;
    return l;
}

// 带副标题的开关行：主标题 16pt + 12pt 灰色说明，右侧控件。
// 副标题让「这个开关到底动什么」一目了然，不再靠长标题硬塞。
static UIView *SIORowSub(NSString *title, NSString *subtitle, UIView *ctrl) {
    UILabel *l = SIOLabel(title, 16, [UIColor labelColor]);
    l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[ l ]];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 2;
    if (subtitle.length) {
        UILabel *s = SIOLabel(subtitle, 12, [UIColor secondaryLabelColor]);
        [v addArrangedSubview:s];
    }
    [v setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[ v, ctrl ]];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.alignment = UIStackViewAlignmentCenter;
    h.spacing = 12;
    return h;
}

// 无副标题的经典行；titleColor 传系统红即表示「高危项」
static UIView *SIORow(NSString *title, UIView *ctrl, UIColor *titleColor) {
    UILabel *l = SIOLabel(title, 16, titleColor);
    l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[ l, ctrl ]];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.alignment = UIStackViewAlignmentCenter;
    h.spacing = 12;
    return h;
}

static UIView *SIOCard(NSArray<UIView *> *items, CGFloat spacing) {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 18;
    // v2.1.0：淡描边 + 柔和阴影，卡片在浅色/深色背景下都能立住轮廓。
    // 这里不设 masksToBounds —— stack 有 16pt 内边距，子视图不会溢出圆角，
    // 关掉裁剪才能让阴影显示出来。
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.06;
    card.layer.shadowRadius = 10;
    card.layer.shadowOffset = CGSizeMake(0, 3);
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:items];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = spacing;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:st];

    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    return card;
}

static UIButton *SIOPill(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.layer.cornerRadius = 12;
    b.layer.masksToBounds = YES;
    [b.heightAnchor constraintEqualToConstant:40].active = YES;
    return b;
}

// v2.1.0：预设大按钮 —— 图标在上、文字在下，比原来的小胶囊好按也好认
static UIButton *SIOPresetButton(NSString *emoji, NSString *title, UIColor *tint) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    b.layer.cornerRadius = 14;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = tint.CGColor;

    UILabel *e = SIOLabel(emoji, 22, tint);
    e.textAlignment = NSTextAlignmentCenter;
    UILabel *t = SIOLabel(title, 13, [UIColor labelColor]);
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    t.textAlignment = NSTextAlignmentCenter;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ e, t ]];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentCenter;
    st.spacing = 4;
    st.userInteractionEnabled = NO;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.centerXAnchor constraintEqualToAnchor:b.centerXAnchor],
        [st.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
        [st.leadingAnchor constraintEqualToAnchor:b.leadingAnchor constant:4],
        [st.trailingAnchor constraintEqualToAnchor:b.trailingAnchor constant:-4],
    ]];
    [b.heightAnchor constraintEqualToConstant:66].active = YES;
    return b;
}

static UILabel *SIOSectionTitle(NSString *t) {
    UILabel *l = [[UILabel alloc] init];
    l.text = [t uppercaseString];
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    l.textColor = [UIColor secondaryLabelColor];
    l.numberOfLines = 0;
    return l;
}

// 渐变头部（CAGradientLayer 子层；QuartzCore 在 App 链接框架内，避免裸 CoreGraphics 符号）
@interface SIOGradientHeader : UIView {
    CAGradientLayer *_grad;
}
- (void)setStatusText:(NSString *)s;
@end
@implementation SIOGradientHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 22;
        self.layer.masksToBounds = YES;
        _grad = [CAGradientLayer layer];
        // v2.1.0：三档渐变（祖母绿 → 孔雀蓝 → 深夜蓝），比原来的两段更有层次
        _grad.colors = @[
            (id)[UIColor colorWithRed:0.06 green:0.62 blue:0.47 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.05 green:0.36 blue:0.52 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.03 green:0.09 blue:0.20 alpha:1.0].CGColor,
        ];
        _grad.locations = @[ @0.0, @0.55, @1.0 ];
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(1, 1);
        [self.layer insertSublayer:_grad atIndex:0];

        // 右上角版本徽章
        UILabel *badge = SIOLabel(SIO_VERSION, 11, [UIColor whiteColor]);
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        badge.layer.cornerRadius = 9;
        badge.layer.masksToBounds = YES;
        badge.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *t = SIOLabel(@"隔壁老王 · 王灿专用", 23, [UIColor whiteColor]);
        t.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
        UILabel *s = SIOLabel(@"SIOriginal · 动画加速超强版", 12,
                              [UIColor colorWithWhite:1 alpha:0.72]);
        UILabel *st2 = SIOLabel(@"等待读取…", 13, [UIColor whiteColor]);
        st2.tag = 99;
        st2.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        // v2.1.9：状态行允许两行 —— 一行塞不下全部状态，之前直接顶到头像底下被遮挡
        st2.numberOfLines = 2;

        for (UIView *v in @[ badge, t, s, st2 ]) {
            if (v != badge) v.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [badge.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
            [badge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [badge.widthAnchor constraintEqualToConstant:58],
            [badge.heightAnchor constraintEqualToConstant:22],

            [s.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [s.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
            [st2.leadingAnchor constraintEqualToAnchor:s.leadingAnchor],
            [st2.bottomAnchor constraintEqualToAnchor:s.topAnchor constant:-6],
            [t.leadingAnchor constraintEqualToAnchor:s.leadingAnchor],
            [t.bottomAnchor constraintEqualToAnchor:st2.topAnchor constant:-4],
            [t.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-8],
        ]];

        // v2.1.9：右上角主人头像（打包资源 Owner.jpg；缺资源时自动隐藏，不影响构建）
        // v2.1.9 修复启动崩溃：头像约束引用了 badge，而原代码在 badge 入层级之前就激活，
        // 触发 NSLayoutConstraintIsPotentiallyDanglyInContainer → SIGABRT（启动 37ms 即崩）。
        // 现在统一挪到所有子视图 addSubview 与主约束激活之后。
        UIImage *ownerImg = [UIImage imageWithContentsOfFile:
                             [[NSBundle mainBundle] pathForResource:@"Owner" ofType:@"jpg"]];
        if (ownerImg) {
            UIImageView *av = [[UIImageView alloc] initWithImage:ownerImg];
            av.contentMode = UIViewContentModeScaleAspectFill;
            av.clipsToBounds = YES;
            av.layer.cornerRadius = 31;
            av.layer.masksToBounds = YES;
            av.layer.borderWidth = 2;
            av.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
            av.translatesAutoresizingMaskIntoConstraints = NO;

            UILabel *cap = SIOLabel(@"👑 主人", 10, [UIColor colorWithWhite:1 alpha:0.9]);
            cap.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
            cap.textAlignment = NSTextAlignmentCenter;
            cap.translatesAutoresizingMaskIntoConstraints = NO;

            [self addSubview:av];
            [self addSubview:cap];
            [NSLayoutConstraint activateConstraints:@[
                [av.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:10],
                [av.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
                [av.widthAnchor constraintEqualToConstant:62],
                [av.heightAnchor constraintEqualToConstant:62],

                [cap.topAnchor constraintEqualToAnchor:av.bottomAnchor constant:3],
                [cap.centerXAnchor constraintEqualToAnchor:av.centerXAnchor],
                [cap.widthAnchor constraintEqualToConstant:70],

                // v2.1.9：文字区让出右侧头像列 —— 标题/状态/副标题都不得越过头像左缘，
                // 修复状态行钻到头像底下被遮挡的问题
                [t.trailingAnchor constraintLessThanOrEqualToAnchor:av.leadingAnchor constant:-10],
                [st2.trailingAnchor constraintLessThanOrEqualToAnchor:av.leadingAnchor constant:-10],
                [s.trailingAnchor constraintLessThanOrEqualToAnchor:av.leadingAnchor constant:-10],
            ]];
        }
    }
    return self;
}
- (void)setStatusText:(NSString *)s {
    for (UIView *v in self.subviews)
        if (v.tag == 99 && [v isKindOfClass:[UILabel class]]) ((UILabel *)v).text = s;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _grad.frame = self.bounds;
}
@end

#pragma mark - 配置模型（持有全部控件，跨 4 个 Tab 统一保存）

@class SIOModel;

@interface SIOModel : NSObject
// 引擎页
@property (strong) UISwitch *swEnabled;
@property (strong) UISegmentedControl *segMode;
@property (strong) UISlider *slSpeed;
@property (strong) UILabel *lblSpeed;
@property (strong) UISegmentedControl *segSlow;
@property (strong) UIView *slowWrap;
@property (strong) UISegmentedControl *segFloor;
@property (strong) UILabel *lblFloor;
@property (strong) UISegmentedControl *segLayer;
@property (strong) UILabel *lblLayer;
@property (strong) UISegmentedControl *segTrans;
@property (strong) UILabel *lblTrans;
@property (strong) UISwitch *swSpring, *swExtra;
// 手感页
@property (strong) UISwitch *swList, *swZoom, *swFastScroll, *swFastTap;
@property (strong) UISwitch *swNotify;
// v2.1.9：瞬时打开三件套（dylib 侧三个键缺键即默认开，这里给它们补上可视化开关）
@property (strong) UISwitch *swInstant, *swHUDFast, *swWKFast;
// 系统页
@property (strong) UISwitch *swRM, *swCF, *swRT;
@property (strong) UISegmentedControl *segDrag;
@property (strong) UILabel *lblDrag;
@property (strong) UISwitch *swFUBG, *swFUBGScene, *swFUBGAudio;
// 高级页：专属覆盖
@property (strong) UITextField *ovBundle;
@property (strong) UISwitch *ovOn, *ovSpring, *ovExtra, *ovList, *ovZoom;
@property (strong) UISwitch *ovFastScroll, *ovFastTap;
// v2.1.10：专属覆盖补上「瞬时打开三件套」。dylib 574~581 行是读这三个键的，
// 但 v2.1.9 的 save() 构造覆盖字典时漏了它们，导致开了专属覆盖的 App
// 无法单独关掉瞬时打开（想用它排查白屏就没招）。
@property (strong) UISwitch *ovInstant, *ovHUDFast, *ovWKFast;
@property (strong) UISlider *ovSpeed;
@property (strong) UILabel *ovSpeedLabel, *ovGuard;
@property (strong) UISegmentedControl *ovMode, *ovLayer, *ovFloor, *ovTrans;
// 高级页：黑名单
@property (strong) UITextView *blacklist;

- (void)loadControlValues;
- (BOOL)save;
- (NSString *)summary;
- (void)applyPreset:(NSInteger)i;
- (NSString *)exportConfig;                 // nil = 失败
- (NSString *)importConfig:(NSString *)json; // nil=成功，否则错误描述
- (NSString *)checkReport;
- (void)refreshOverrides;
@end

@implementation SIOModel

- (void)loadControlValues {
    NSMutableDictionary *c = ReadConfig();
    self.swEnabled.on = [c[@"Enabled"] boolValue];
    int mode = [c[@"Mode"] intValue];
    self.segMode.selectedSegmentIndex = (mode >= 0 && mode <= 2) ? mode : 0;
    double speed = [c[@"Speed"] doubleValue];
    if (speed < 1.0 || speed > 50.0) speed = 15.0;
    self.slSpeed.value = (float)speed;
    self.segSlow.selectedSegmentIndex = SlowIndexForFactor([c[@"SlowFactor"] doubleValue]);
    self.segFloor.selectedSegmentIndex = FloorIndexFor([c[@"FloorDuration"] doubleValue]);
    self.segLayer.selectedSegmentIndex = LayerIndexForBoost([c[@"LayerBoost"] doubleValue]);
    self.segTrans.selectedSegmentIndex = TransIndexFor([c[@"TransitionBoost"] doubleValue]);
    self.swSpring.on = [c[@"Spring"] boolValue];
    self.swExtra.on = [c[@"Extra"] boolValue];

    self.swList.on = [c[@"ListAccel"] boolValue];
    self.swZoom.on = [c[@"ZoomAccel"] boolValue];
    self.swFastScroll.on = [c[@"FastScroll"] boolValue];
    self.swFastTap.on = [c[@"FastTap"] boolValue];
    self.swNotify.on = [c[@"InAppNotify"] boolValue];
    // v2.1.9：缺键视为开（与 dylib 侧默认一致，避免出现「UI 显示关、实际在跑」）
    self.swInstant.on = c[@"InstantTransition"] ? [c[@"InstantTransition"] boolValue] : YES;
    self.swHUDFast.on = c[@"HUDFast"] ? [c[@"HUDFast"] boolValue] : YES;
    self.swWKFast.on  = c[@"WKFastShow"]  ? [c[@"WKFastShow"]  boolValue] : YES;
    self.blacklist.text = [c[@"Blacklist"] componentsJoinedByString:@"\n"];

    self.swRM.on = ReadAx(@"ReduceMotionEnabled");
    self.swCF.on = ReadAx(@"PreferCrossFadeTransitions");
    self.swRT.on = ReadAx(@"ReduceTransparencyEnabled");
    self.segDrag.selectedSegmentIndex = DragIndexForCoeff(ReadUIKitDrag());

    self.swFUBG.on = [c[@"FUBGEnabled"] boolValue];
    self.swFUBGScene.on = [c[@"FUBGSceneFake"] boolValue];
    self.swFUBGAudio.on = [c[@"FUBGAudioKeep"] boolValue];

    // 专属覆盖默认 bundle
    NSDictionary *ovAll = [c[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                          ? c[@"AppOverrides"] : @{};
    NSString *first = ovAll[@"com.sfic.knight"] ? @"com.sfic.knight"
                    : ([ovAll.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject
                       ?: @"com.sfic.knight");
    self.ovBundle.text = first;
    [self refreshOverrides];
    [self refreshDynamicLabels];
}

- (void)refreshDynamicLabels {
    int mode = (int)self.segMode.selectedSegmentIndex;
    self.slSpeed.hidden = (mode != 0);
    self.lblSpeed.hidden = (mode != 0);
    self.slowWrap.hidden = (mode != 1);
    self.lblSpeed.text = [NSString stringWithFormat:@"加速倍率（当前 ×%.1f，上限 ×50）", self.slSpeed.value];

    double fl = FloorForIndex((int)self.segFloor.selectedSegmentIndex);
    self.lblFloor.text = [NSString stringWithFormat:
        @"所有动画的时长下限：%@。追求极致选 0.005s（风险自担）；遇到卡顿/回调异常请调回 0.01s 或更高。瞬切模式也使用该下限。",
        fl < 0.009 ? [NSString stringWithFormat:@"%.3fs", fl]
                   : [NSString stringWithFormat:@"%.2fs", fl]];

    double lb = LayerBoostForIndex((int)self.segLayer.selectedSegmentIndex);
    self.lblLayer.text = lb <= 1.0001
        ? @"×1 = 不额外加速。转圈/进度/旋转/地图相机按全局倍率缩放。"
        : [NSString stringWithFormat:@"转圈/进度/旋转/地图相机等显式动画在全局倍率上再 ÷%.0f。不影响 UIView 块动画与转场；慢放不叠加；受下限保护。", lb];

    double tb = TransForIndex((int)self.segTrans.selectedSegmentIndex);
    self.lblTrans.text = tb <= 1.0001
        ? @"×1 = 不额外加速。push/pop/模态弹窗按全局倍率缩放。"
        : [NSString stringWithFormat:@"导航/模态/Tab 转场在全局倍率上再 ÷%.1f，块动画不受影响；慢放不叠加。", tb];

}

- (void)refreshOverrides {
    // v2.1.9：支持多 ID —— 控件回显按第一个 ID；提示文案说明批量行为
    NSArray *ids = [self ovBundleIDs];
    NSString *bid = ids.firstObject ?: @"com.sfic.knight";
    id allRaw = [NSDictionary dictionaryWithContentsOfFile:PrefPath][@"AppOverrides"];
    NSDictionary *all = [allRaw isKindOfClass:[NSDictionary class]] ? allRaw : @{};
    id mineRaw = all[bid];
    NSDictionary *mine = [mineRaw isKindOfClass:[NSDictionary class]] ? mineRaw : nil;

    self.ovOn.on = (mine != nil);
    double sp = mine[@"Speed"] ? [mine[@"Speed"] doubleValue] : 5.0;
    if (sp < 1.0 || sp > 50.0) sp = 5.0;
    self.ovSpeed.value = (float)sp;
    self.ovSpeedLabel.text = [NSString stringWithFormat:@"专属倍率（当前 ×%.1f）", sp];
    int m = mine[@"Mode"] ? [mine[@"Mode"] intValue] : 0;
    self.ovMode.selectedSegmentIndex = (m >= 0 && m <= 2) ? m : 0;
    self.ovSpring.on = mine[@"Spring"] ? [mine[@"Spring"] boolValue] : YES;
    self.ovExtra.on  = mine[@"Extra"]  ? [mine[@"Extra"] boolValue]  : YES;
    self.ovList.on   = mine[@"ListAccel"] ? [mine[@"ListAccel"] boolValue] : NO;
    self.ovZoom.on   = mine[@"ZoomAccel"] ? [mine[@"ZoomAccel"] boolValue] : NO;
    self.ovFastScroll.on = mine[@"FastScroll"] ? [mine[@"FastScroll"] boolValue] : NO;
    self.ovFastTap.on    = mine[@"FastTap"]    ? [mine[@"FastTap"] boolValue]    : NO;
    self.ovLayer.selectedSegmentIndex = LayerIndexForBoost(mine[@"LayerBoost"] ? [mine[@"LayerBoost"] doubleValue] : 1.0);
    self.ovFloor.selectedSegmentIndex = FloorIndexFor(mine[@"FloorDuration"] ? [mine[@"FloorDuration"] doubleValue] : 0.01);
    self.ovTrans.selectedSegmentIndex = TransIndexFor(mine[@"TransitionBoost"] ? [mine[@"TransitionBoost"] doubleValue] : 1.0);
    // v2.1.10：瞬时打开三件套回显（缺键与 dylib 默认一致 = 开）
    self.ovInstant.on = mine[@"InstantTransition"] ? [mine[@"InstantTransition"] boolValue] : YES;
    self.ovHUDFast.on = mine[@"HUDFast"]           ? [mine[@"HUDFast"]           boolValue] : YES;
    self.ovWKFast.on  = mine[@"WKFastShow"]        ? [mine[@"WKFastShow"]        boolValue] : YES;

    BOOL guarded = [HardGuardBundles() containsObject:bid];
    self.ovList.enabled = !guarded;
    if (guarded) {
        self.ovList.on = NO;
        self.ovGuard.text = [NSString stringWithFormat:
            @"⚠️ %@ 在列表 hook 硬保护名单：列表加速恒关，无法打开（dylib 启动日志 listGuard=1）。其余 hook 正常加速。", bid];
        self.ovGuard.textColor = [UIColor systemOrangeColor];
    } else if (mine) {
        self.ovGuard.text = [NSString stringWithFormat:@"已存在 %@ 的专属配置，改完点右上角「保存」生效。", bid];
        self.ovGuard.textColor = [UIColor secondaryLabelColor];
    } else {
        self.ovGuard.text = [NSString stringWithFormat:@"%@ 暂无专属配置；打开开关并保存即可创建。", bid];
        self.ovGuard.textColor = [UIColor secondaryLabelColor];
    }
    // v2.1.9：多 ID 时追加批量提示
    if (ids.count > 1) {
        NSMutableString *multi = [NSMutableString string];
        [multi appendFormat:@"📦 本次将对 %lu 个 Bundle ID 生效：", (unsigned long)ids.count];
        [multi appendString:[ids componentsJoinedByString:@"、"]];
        [multi appendString:@"\n（上方控件状态显示的是第一个 ID 的情况，保存时下方设置会应用到全部）"];
        self.ovGuard.text = [self.ovGuard.text stringByAppendingString:[NSString stringWithFormat:@"\n%@", multi]];
        self.ovGuard.numberOfLines = 0;
    }
}

- (NSArray *)blacklistFromView {
    NSMutableArray *bl = [NSMutableArray array];
    for (NSString *line in [self.blacklist.text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [bl addObject:t];
    }
    return bl;
}

// v2.1.9：专属覆盖输入框支持一次填多个 Bundle ID（逗号 / 空格 / 换行分隔），去重去空。
- (NSArray<NSString *> *)ovBundleIDs {
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *ids = [NSMutableArray array];
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:
                           @",， \t\n\r；;"];
    for (NSString *tok in [self.ovBundle.text componentsSeparatedByCharactersInSet:sep]) {
        NSString *t = [tok stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && ![seen containsObject:t]) {
            [seen addObject:t];
            [ids addObject:t];
        }
    }
    return ids;
}

- (BOOL)save {
    NSMutableDictionary *cfg = ReadConfig();
    cfg[@"Enabled"] = @(self.swEnabled.on);
    cfg[@"Mode"] = @((int)self.segMode.selectedSegmentIndex);
    cfg[@"Speed"] = @((double)self.slSpeed.value);
    cfg[@"SlowFactor"] = @(SlowFactorForIndex((int)self.segSlow.selectedSegmentIndex));
    cfg[@"Spring"] = @(self.swSpring.on);
    cfg[@"Extra"] = @(self.swExtra.on);
    cfg[@"ListAccel"] = @(self.swList.on);
    cfg[@"ZoomAccel"] = @(self.swZoom.on);
    cfg[@"FastScroll"] = @(self.swFastScroll.on);
    cfg[@"FastTap"] = @(self.swFastTap.on);
    cfg[@"LayerBoost"] = @(LayerBoostForIndex((int)self.segLayer.selectedSegmentIndex));
    cfg[@"FloorDuration"] = @(FloorForIndex((int)self.segFloor.selectedSegmentIndex));
    cfg[@"TransitionBoost"] = @(TransForIndex((int)self.segTrans.selectedSegmentIndex));
    cfg[@"InAppNotify"] = @(self.swNotify.on);
    // v2.1.9：瞬时打开三件套写盘 —— 不写的话这三个键缺失，dylib 依旧默认全开，关不掉
    cfg[@"InstantTransition"] = @(self.swInstant.on);
    cfg[@"HUDFast"] = @(self.swHUDFast.on);
    cfg[@"WKFastShow"] = @(self.swWKFast.on);
    cfg[@"Blacklist"] = [self blacklistFromView];

    cfg[@"FUBGEnabled"] = @(self.swFUBG.on);
    cfg[@"FUBGSceneFake"] = @(self.swFUBGScene.on);
    cfg[@"FUBGAudioKeep"] = @(self.swFUBGAudio.on);

    // App 专属覆盖（保留其它 bundle 的既有条目）
    // v2.1.9：支持一次填多个 Bundle ID（逗号/空格/换行分隔），保存时批量应用
    NSArray *ovIDs = [self ovBundleIDs];
    id ovAllRaw = [NSDictionary dictionaryWithContentsOfFile:PrefPath][@"AppOverrides"];
    NSMutableDictionary *ovOut = [ovAllRaw isKindOfClass:[NSDictionary class]]
                                 ? [ovAllRaw mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *ovBid in ovIDs) {
        if (self.ovOn.on) {
            BOOL guarded = [HardGuardBundles() containsObject:ovBid];
            ovOut[ovBid] = @{
                @"Enabled":   @YES,
                @"Mode":      @((int)self.ovMode.selectedSegmentIndex),
                @"Speed":     @((double)self.ovSpeed.value),
                @"Spring":    @(self.ovSpring.on),
                @"Extra":     @(self.ovExtra.on),
                @"ListAccel": @(guarded ? NO : self.ovList.on),
                @"ZoomAccel": @(self.ovZoom.on),
                @"FastScroll": @(self.ovFastScroll.on),
                @"FastTap":    @(self.ovFastTap.on),
                @"LayerBoost": @(LayerBoostForIndex((int)self.ovLayer.selectedSegmentIndex)),
                @"FloorDuration":   @(FloorForIndex((int)self.ovFloor.selectedSegmentIndex)),
                @"TransitionBoost": @(TransForIndex((int)self.ovTrans.selectedSegmentIndex)),
                // v2.1.10：瞬时打开三件套写入专属覆盖（dylib 会读，v2.1.9 漏了）
                @"InstantTransition": @(self.ovInstant.on),
                @"HUDFast":           @(self.ovHUDFast.on),
                @"WKFastShow":        @(self.ovWKFast.on),
            };
        } else {
            [ovOut removeObjectForKey:ovBid];
        }
    }
    cfg[@"AppOverrides"] = ovOut;

    BOOL ok = WriteConfig(cfg);
    WriteAx(@"ReduceMotionEnabled", self.swRM.on);
    WriteAx(@"PreferCrossFadeTransitions", self.swCF.on);
    WriteAx(@"ReduceTransparencyEnabled", self.swRT.on);
    // v2.1.9：总开关是最高优先级 —— 关闭时把 UIAnimationDragCoefficient 一并清掉。
    // 这是 iOS 原生读取的键，不经过 dylib：不清的话「启用动画引擎」关了，
    // UIKit 照样按 ×5/×10/×20 加速，总开关会被误认为假开关。
    WriteUIKitDrag(self.swEnabled.on
                   ? DragCoeffForIndex((int)self.segDrag.selectedSegmentIndex)
                   : 0.0);
    return ok;
}

- (NSString *)summary {
    int mode = (int)self.segMode.selectedSegmentIndex;
    NSString *detail;
    if (mode == 0) detail = [NSString stringWithFormat:@"加速 ×%.1f", self.slSpeed.value];
    else if (mode == 1) detail = [NSString stringWithFormat:@"慢放 ×%.0f",
                                  SlowFactorForIndex((int)self.segSlow.selectedSegmentIndex)];
    else detail = [NSString stringWithFormat:@"瞬切（下限 %@）",
                   FloorForIndex((int)self.segFloor.selectedSegmentIndex) < 0.009
                     ? [NSString stringWithFormat:@"%.3fs", FloorForIndex((int)self.segFloor.selectedSegmentIndex)]
                     : [NSString stringWithFormat:@"%.2fs", FloorForIndex((int)self.segFloor.selectedSegmentIndex)]];
    // v2.1.9：去掉「长按%@」—— 长按加速已随 v2.1.2 移除，且这里少传一个参数，
    // 会把寄存器里的垃圾（NSString 类对象）当成参数打出来，自检里出现「长按 NSString」。
    return [NSString stringWithFormat:@"%@ · %@ · 显式×%.0f · 转场×%.1f · 弹簧%@ · 滑行%@ · 点按%@",
            self.swEnabled.on ? @"已启用" : @"已暂停", detail,
            LayerBoostForIndex((int)self.segLayer.selectedSegmentIndex),
            TransForIndex((int)self.segTrans.selectedSegmentIndex),
            self.swSpring.on ? @"开" : @"关",
            self.swFastScroll.on ? @"开" : @"关",
            self.swFastTap.on ? @"开" : @"关"];
}

// 一键预设：改控件 → 发通知让页面刷新 → 由调用方负责 save
// v2.1.1：基准值 = 「标准档」，且手感三项一律默认关（曾致全部 APP 闪退）。
// 预设不再替用户打开它们 —— 想开自己在「手感」页手动开。
- (void)applyPreset:(NSInteger)i {
    self.swEnabled.on = YES;
    self.segMode.selectedSegmentIndex = 0;
    self.segFloor.selectedSegmentIndex = 1;   // 0.01s（0.005 属极限值，不用作默认）
    self.segLayer.selectedSegmentIndex = 2;   // ×3
    self.segTrans.selectedSegmentIndex = 2;   // ×2
    self.swSpring.on = YES;
    self.swExtra.on = YES;
    // v2.1.2：加速项全部默认开（长按加速已随崩溃 hook 一并移除）
    self.swList.on = YES;
    self.swZoom.on = YES;
    self.swFastScroll.on = YES;
    self.swFastTap.on = YES;
    self.segSlow.selectedSegmentIndex = 0;
    self.slSpeed.value = 15.0f;
    self.swNotify.on = YES;
    // v2.1.9：预设沿用瞬时打开三件套的默认（开）
    self.swInstant.on = YES;
    self.swHUDFast.on = YES;
    self.swWKFast.on = YES;

    switch (i) {
        case 0: // 极速：倍率再往上顶，显式/转场倍率拉到最大（纯时长缩放，安全）
            self.slSpeed.value = 25.0f;
            self.segLayer.selectedSegmentIndex = 3;  // ×5
            self.segTrans.selectedSegmentIndex = 3;  // ×3
            break;
        case 1: // 标准：基准值即标准档，不做覆盖
            break;
        case 2: // 保守：倍率回落、下限抬高
            self.slSpeed.value = 5.0f;
            self.segFloor.selectedSegmentIndex = 2;  // 0.02s
            self.segLayer.selectedSegmentIndex = 0;  // ×1
            self.segTrans.selectedSegmentIndex = 0;  // ×1
            break;
        case 3: // 瞬切：时长直接压到下限
            self.segMode.selectedSegmentIndex = 2;
            self.segFloor.selectedSegmentIndex = 1;  // 0.01s
            self.segLayer.selectedSegmentIndex = 1;  // ×2
            self.segTrans.selectedSegmentIndex = 2;  // ×2
            break;
    }
    [self refreshDynamicLabels];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAppliedNote object:nil];
}

- (NSString *)exportConfig {
    NSMutableDictionary *d = [ReadConfig() mutableCopy];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"_format"] = @"SIOriginalConfig";
    out[@"_version"] = SIO_VERSION;
    for (NSString *k in SIOConfigKeys()) {
        if (d[k]) out[k] = d[k];
    }
    out[@"UIAnimationDragCoefficient"] = @(ReadUIKitDrag());
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (err || !data) return nil;
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"sioriginal-config-v2.json"];
    [data writeToFile:path atomically:YES];
    [UIPasteboard generalPasteboard].string = str;
    return path;
}

- (NSString *)importConfig:(NSString *)json {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![obj isKindOfClass:[NSDictionary class]])
        return @"剪贴板内容不是有效的 JSON 配置";
    NSDictionary *d = obj;

    // 布尔键
    NSArray *boolKeys = @[ @"Enabled", @"Spring", @"Extra", @"ListAccel", @"ZoomAccel",
                           @"FastScroll", @"FastTap", @"InAppNotify",
                           @"InstantTransition", @"HUDFast", @"WKFastShow",
                           @"FUBGEnabled", @"FUBGSceneFake", @"FUBGAudioKeep" ];
    for (NSString *k in boolKeys) {
        if (d[k]) {
            UISwitch *sw = [self switchForKey:k];
            if (sw && [d[k] isKindOfClass:[NSNumber class]]) sw.on = [d[k] boolValue];
        }
    }
    if ([d[@"Mode"] isKindOfClass:[NSNumber class]]) {
        int m = [d[@"Mode"] intValue];
        if (m >= 0 && m <= 2) self.segMode.selectedSegmentIndex = m;
    }
    if ([d[@"Speed"] isKindOfClass:[NSNumber class]]) {
        double v = [d[@"Speed"] doubleValue];
        if (v >= 1.0 && v <= 50.0) self.slSpeed.value = (float)v;
    }
    if ([d[@"SlowFactor"] isKindOfClass:[NSNumber class]])
        self.segSlow.selectedSegmentIndex = SlowIndexForFactor([d[@"SlowFactor"] doubleValue]);
    if ([d[@"FloorDuration"] isKindOfClass:[NSNumber class]])
        self.segFloor.selectedSegmentIndex = FloorIndexFor([d[@"FloorDuration"] doubleValue]);
    if ([d[@"LayerBoost"] isKindOfClass:[NSNumber class]])
        self.segLayer.selectedSegmentIndex = LayerIndexForBoost([d[@"LayerBoost"] doubleValue]);
    if ([d[@"TransitionBoost"] isKindOfClass:[NSNumber class]])
        self.segTrans.selectedSegmentIndex = TransIndexFor([d[@"TransitionBoost"] doubleValue]);
    if ([d[@"Blacklist"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *lines = [NSMutableArray array];
        for (id x in d[@"Blacklist"])
            if ([x isKindOfClass:[NSString class]]) [lines addObject:x];
        self.blacklist.text = [lines componentsJoinedByString:@"\n"];
    }
    if ([d[@"UIAnimationDragCoefficient"] isKindOfClass:[NSNumber class]])
        self.segDrag.selectedSegmentIndex = DragIndexForCoeff([d[@"UIAnimationDragCoefficient"] doubleValue]);

    // v2.1.10：导出配置里含 AppOverrides，导入却整块丢弃 —— 导出/导入不对称。
    // 覆盖项在 UI 上没有一一对应的控件可逐个回显，所以直接合并写回 plist，
    // 再把第一个 bundle 填进输入框让 refreshOverrides 回显出来。
    if ([d[@"AppOverrides"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cfg = ReadConfig();
        NSMutableDictionary *ov = [cfg[@"AppOverrides"] isKindOfClass:[NSDictionary class]]
                                ? [cfg[@"AppOverrides"] mutableCopy] : [NSMutableDictionary dictionary];
        NSDictionary *inc = d[@"AppOverrides"];
        NSUInteger n = 0;
        for (id bid in inc) {
            if (![bid isKindOfClass:[NSString class]]) continue;
            id v = inc[bid];
            if (![v isKindOfClass:[NSDictionary class]]) continue;
            ov[(NSString *)bid] = v; n++;
        }
        if (n) {
            cfg[@"AppOverrides"] = ov;
            WriteConfig(cfg);
            NSString *first = [ov.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject;
            if (first) self.ovBundle.text = first;
            [self refreshOverrides];
        }
    }

    [self refreshDynamicLabels];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAppliedNote object:nil];
    return nil;
}

- (UISwitch *)switchForKey:(NSString *)k {
    if ([k isEqualToString:@"Enabled"]) return self.swEnabled;
    if ([k isEqualToString:@"Spring"]) return self.swSpring;
    if ([k isEqualToString:@"Extra"]) return self.swExtra;
    if ([k isEqualToString:@"ListAccel"]) return self.swList;
    if ([k isEqualToString:@"ZoomAccel"]) return self.swZoom;
    if ([k isEqualToString:@"FastScroll"]) return self.swFastScroll;
    if ([k isEqualToString:@"FastTap"]) return self.swFastTap;
    if ([k isEqualToString:@"InAppNotify"]) return self.swNotify;
    if ([k isEqualToString:@"InstantTransition"]) return self.swInstant;
    if ([k isEqualToString:@"HUDFast"]) return self.swHUDFast;
    if ([k isEqualToString:@"WKFastShow"]) return self.swWKFast;
    if ([k isEqualToString:@"FUBGEnabled"]) return self.swFUBG;
    if ([k isEqualToString:@"FUBGSceneFake"]) return self.swFUBGScene;
    if ([k isEqualToString:@"FUBGAudioKeep"]) return self.swFUBGAudio;
    return nil;
}

- (NSString *)checkReport {
    NSMutableString *r = [NSMutableString string];
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    [r appendFormat:@"SIOriginal 配置器 %@（build %@）\n",
        info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    [r appendFormat:@"Bundle ID：%@\n", info[@"CFBundleIdentifier"] ?: @"?"];
    [r appendFormat:@"检测时间：%@（点上方按钮可随时刷新）\n\n", [fmt stringFromDate:[NSDate date]]];
    [r appendString:@"⚠️ 自检范围说明：本页只检测配置 App 自身的环境（目录可写、plist 状态、当前配置），\n无法探测 TrollFools 是否已把 dylib 注入目标 App —— 那要看目标 App 顶部是否弹生效提示。\n\n"];

    [r appendString:@"【权限 / 路径自检】\n"];
    const char *dir = "/var/Managed Preferences/mobile";
    [r appendFormat:@"%s 配置目录可写：%@\n", dir, access(dir, W_OK) == 0 ? @"✅" : @"❌"];
    BOOL plistExists = [[NSFileManager defaultManager] fileExistsAtPath:PrefPath];
    [r appendFormat:@"UIKit.plist 存在：%@\n", plistExists ? @"✅" : @"➖ 尚未保存过"];
    BOOL axWritable = access("/var/mobile/Library/Preferences", W_OK) == 0;
    [r appendFormat:@"辅助功能目录可写：%@\n\n", axWritable ? @"✅" : @"❌"];

    [r appendString:@"【当前引擎配置】\n"];
    [r appendFormat:@"%@\n\n", [self summary]];

    [r appendString:@"【注入方式提醒】\n"];
    [r appendString:@"本 App 只负责写配置并发 Darwin 热重载通知；动画引擎 SIOriginal.dylib 需用 TrollFools 注入目标 App。保存配置后，前台目标 App 顶部会出现 1.5 秒生效提示（可在「手感」页关闭）。\n\n"];

    [r appendString:@"【硬保护】\n"];
    [r appendFormat:@"列表 hook 恒关名单：%@、com.apple.springboard（防止黑屏/白苹果）。\n",
        [HardGuardBundles() componentsJoinedByString:@"、"]];

    [r appendString:@"\n【v2.1.2 闪退修复（真凶已定位）】\n"];
    [r appendString:@"· 闪退真凶：长按手势加速 hook 了 UILongPressGestureRecognizer 的 initWithTarget:action:（init 族方法，ARC 所有权约定被破坏）。两份 .ips（微信 8.0.58 / 顺丰同城骑士 11.5.0）崩溃帧完全一致：objc_retain ← sio_LPG_init。\n"];
    [r appendString:@"· 该 hook 一直被无条件安装，开关关不关都崩 —— 所以之前调默认值始终修不好。本版已整体移除。\n"];
    [r appendString:@"· 其余加速项（滑行惯性/点击零延迟/缩放/列表）已全部默认开启。滑行/点按的 hook 按启动时状态安装，从关改开需重启目标 App。\n"];

    [r appendString:@"\n【v2.1.0 变更】\n"];
    [r appendString:@"· 移除假开关「悬浮球」：dylib 侧的悬浮球类从未被实例化，开关无任何消费方，整块死代码已删除。\n"];
    [r appendString:@"· 移除死配置 FUBGExcludeApps：无编辑入口且恒为空表，排除语义统一由黑名单提供。\n"];
    [r appendString:@"· 热路径改为预计算派生量（倒数乘法 + 缓存下限），微信放大态探测开销下调约 30%。\n"];
    return r;
}

@end

#pragma mark - 页面基类

@interface SIOPageVC : UIViewController
@property (weak) SIOModel *model;
@property (strong) UIStackView *stack;
- (void)buildContent;      // 子类重写
- (void)uiApplied;         // 子类重写（预设/导入后刷新）
- (void)saveTapped;
@end

@implementation SIOPageVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(saveTapped)];

    [self buildContent];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(noteApplied)
                                                 name:kAppliedNote object:nil];
}

- (void)noteApplied { [self uiApplied]; }
- (void)buildContent {}
- (void)uiApplied {}

- (void)saveTapped {
    BOOL ok = [self.model save];
    UINotificationFeedbackGenerator *fg = [[UINotificationFeedbackGenerator alloc] init];
    [fg prepare];
    if (ok) {
        [fg notificationOccurred:UINotificationFeedbackTypeSuccess];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"✅ 配置已保存并热重载"
            message:[self.model summary] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [fg notificationOccurred:UINotificationFeedbackTypeError];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"❌ 保存失败"
            message:@"无法写入 com.apple.UIKit.plist，请确认 TrollStore 权限正常。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

#pragma mark - ① 引擎页

@interface SIOEngineVC : SIOPageVC
@property (strong) SIOGradientHeader *header;
- (void)refreshHeader;
@end
@implementation SIOEngineVC

- (void)buildContent {
    SIOModel *m = self.model;

    SIOGradientHeader *header = [[SIOGradientHeader alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header.heightAnchor constraintEqualToConstant:132].active = YES;
    self.header = header;
    [self.stack addArrangedSubview:header];

    // v2.1.0：一键预设改为 2×2 大按钮网格，图标 + 文字，比小胶囊好按
    UIButton *p1 = SIOPresetButton(@"🚀", @"极速", [UIColor systemGreenColor]);
    UIButton *p2 = SIOPresetButton(@"⚖️", @"标准", [UIColor systemBlueColor]);
    UIButton *p3 = SIOPresetButton(@"🛡", @"保守", [UIColor systemGrayColor]);
    UIButton *p4 = SIOPresetButton(@"⚡", @"瞬切", [UIColor systemOrangeColor]);
    p1.tag = 0; p2.tag = 1; p3.tag = 2; p4.tag = 3;
    for (UIButton *b in @[p1,p2,p3,p4])
        [b addTarget:self action:@selector(preset:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *rowA = [[UIStackView alloc] initWithArrangedSubviews:@[p1, p2]];
    UIStackView *rowB = [[UIStackView alloc] initWithArrangedSubviews:@[p3, p4]];
    for (UIStackView *r in @[rowA, rowB]) {
        r.axis = UILayoutConstraintAxisHorizontal;
        r.distribution = UIStackViewDistributionFillEqually;
        r.spacing = 10;
    }
    UIStackView *presetGrid = [[UIStackView alloc] initWithArrangedSubviews:@[rowA, rowB]];
    presetGrid.axis = UILayoutConstraintAxisVertical;
    presetGrid.spacing = 10;
    [self.stack addArrangedSubview:SIOSectionTitle(@"一键预设 · 点击立即套用并保存")];
    [self.stack addArrangedSubview:presetGrid];

    // 总开关 + 模式
    m.swEnabled = [[UISwitch alloc] init];
    m.segMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    [m.segMode addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"启用动画引擎", @"总开关，优先级最高：关闭后所有 hook 旁路，App 专属覆盖也无法再打开，系统拖拽系数一并恢复原生", m.swEnabled),
        SIOLabel(@"模式", 16, [UIColor labelColor]),
        m.segMode,
    ], 12)];

    // 倍率组
    m.lblSpeed = SIOLabel(@"", 16, [UIColor labelColor]);
    m.slSpeed = [[UISlider alloc] init];
    m.slSpeed.minimumValue = 1.0f;
    m.slSpeed.maximumValue = 50.0f;
    [m.slSpeed addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.segSlow = [[UISegmentedControl alloc] initWithItems:@[ @"×2", @"×3", @"×5", @"×10" ]];
    [m.segSlow addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    UIStackView *slowStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        SIOLabel(@"慢放倍率", 16, [UIColor labelColor]), m.segSlow ]];
    slowStack.axis = UILayoutConstraintAxisVertical;
    slowStack.spacing = 8;
    m.slowWrap = slowStack;
    [self.stack addArrangedSubview:SIOCard(@[
        m.lblSpeed, m.slSpeed,
        m.slowWrap,
    ], 10)];

    // v2.0.0 新引擎组
    UILabel *ft = SIOLabel(@"动画时长下限", 16, [UIColor labelColor]);
    m.segFloor = [[UISegmentedControl alloc] initWithItems:@[ @"0.005", @"0.01", @"0.02", @"0.05" ]];
    [m.segFloor addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.lblFloor = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);

    UILabel *lt = SIOLabel(@"显式动画额外倍率", 16, [UIColor labelColor]);
    m.segLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    [m.segLayer addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.lblLayer = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);

    UILabel *tt = SIOLabel(@"转场独立额外倍率", 16, [UIColor labelColor]);
    m.segTrans = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×1.5", @"×2", @"×3" ]];
    [m.segTrans addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    m.lblTrans = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:SIOCard(@[
        ft, m.segFloor, m.lblFloor,
        lt, m.segLayer, m.lblLayer,
        tt, m.segTrans, m.lblTrans,
    ], 10)];

    // 弹簧 / 转场开关
    m.swSpring = [[UISwitch alloc] init];
    m.swExtra = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"弹簧参数缩放", @"同步缩放 CASpring 的 mass/stiffness/damping，保持物理一致性", m.swSpring),
        SIORowSub(@"进阶转场", @"导航栈 push/pop、模态弹窗、Tab 切换", m.swExtra),
    ], 14)];

    UILabel *hint = SIOLabel(
        @"出厂默认：加速 ×15 + 显式 ×3 + 转场 ×2 + 下限 0.01s。倍率是纯时长缩放，安全。"
        @"「手感」页三项已改为默认关 —— 它们曾在 v2.0.5 导致全部 App 闪退，想用请逐个开并实测。"
        @"若动画完成回调异常（转圈闪没、工具栏不回位），把时长下限调回 0.01s 或更高。",
        12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:hint];
    [self refreshHeader];
}

- (void)refreshHeader {
    if (!self.header) return;
    SIOModel *m = self.model;
    NSString *s = m.swEnabled.on ? [m summary] : @"已暂停 · 全部 hook 旁路";
    [self.header setStatusText:s];
}

- (void)changed {
    [self.model refreshDynamicLabels];
    [self refreshHeader];
    // v2.1.9：总开关等改动实时广播，系统页的拖拽系数提示同步刷新
    [[NSNotificationCenter defaultCenter] postNotificationName:kAppliedNote object:nil];
}
- (void)uiApplied { [self.model refreshDynamicLabels]; [self refreshHeader]; }

- (void)preset:(UIButton *)b {
    // v2.1.9：预设按钮的文字画在内部 stack 里，titleForState: 恒为 nil，
    // 弹窗标题会变成「套用预设 （null）？」—— 改按 tag 取名字。
    NSString *name = (@[ @"极速", @"标准", @"保守", @"瞬切" ])[b.tag];
    if (!name) name = @"预设";
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"套用预设 %@？", name]
        message:@"预设会覆盖当前引擎/手感参数（黑名单与 App 专属覆盖不受影响），并立即保存热重载。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"套用并保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
        [self.model applyPreset:b.tag];
        BOOL ok = [self.model save];
        UIAlertController *r = [UIAlertController
            alertControllerWithTitle:ok ? [NSString stringWithFormat:@"✅ %@ 已生效", name] : @"❌ 保存失败"
            message:ok ? [self.model summary] : @"请确认 TrollStore 写权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:r animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - ② 手感页

@interface SIOFeelVC : SIOPageVC
@end
@implementation SIOFeelVC

- (void)buildContent {
    SIOModel *m = self.model;
    self.title = @"手感 · 列表";

    m.swFastScroll = [[UISwitch alloc] init];
    m.swFastTap = [[UISwitch alloc] init];
    m.swNotify = [[UISwitch alloc] init];

    [self.stack addArrangedSubview:SIOSectionTitle(@"交互跟手 · 默认开")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"滑行惯性加急", @"decelerationRate=Fast，松手后更快停在目标位置", m.swFastScroll),
        SIORowSub(@"点击零延迟", @"delaysContentTouches=NO，省掉约 150ms 的滚动/点击判定", m.swFastTap),
        SIORowSub(@"保存后弹生效提示", @"在目标 App 顶部显示 1.5s 提示条，不拦截触摸", m.swNotify),
    ], 14)];

    m.swZoom = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOSectionTitle(@"滚动 / 缩放 · 默认开")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"缩放动画加速", @"图片预览缩放事务加速，异常就关", m.swZoom),
    ], 14)];

    // v2.1.9：瞬时打开三件套 —— 这三个键原先在 App 里没有入口，dylib 缺键即默认开，
    // 等于一直生效且无法关闭。现在补上开关，出兼容性问题时可以逐项关掉排查。
    m.swInstant = [[UISwitch alloc] init];
    m.swHUDFast = [[UISwitch alloc] init];
    m.swWKFast = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOSectionTitle(@"瞬时打开 · 默认全开")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"瞬时打开页面", @"把导航/模态转场直接压到 1ms，点链接秒开新页（绕过转场倍率与时长下限）", m.swInstant),
        SIORowSub(@"加载圈 / HUD 加速", @"转圈延后 0.15s 才显形，SVProgressHUD/MBProgressHUD 立即消失", m.swHUDFast),
        SIORowSub(@"网页提前显形", @"WKWebView 加载进度过 10% 后拒绝再被隐藏，网页更早露出来", m.swWKFast),
    ], 14)];
    UILabel *instantNote = SIOLabel(
        @"注：IM 与支付类 App 在 dylib 内置保护名单内，这三项对它们自动不生效。"
        "若某个 App 出现打开白屏、内容没渲染完就切走，优先关掉「瞬时打开页面」和「网页提前显形」。",
        12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:instantNote];

    // 列表加速（高危组）
    m.swList = [[UISwitch alloc] init];
    m.swList.onTintColor = [UIColor systemRedColor];
    [self.stack addArrangedSubview:SIOSectionTitle(@"高危项 · 默认开")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"列表加速 TV/CV", @"会改写列表更新事务，个别重列表 App 可能卡顿，卡就关", m.swList),
    ], 14)];

    UILabel *feelNote = SIOLabel(
        @"注：滑行惯性 / 点击零延迟的 hook 是在目标 App 启动时按开关状态安装的 —— "
        "把这两项从关改开后，需要杀掉目标 App 重开才会生效；从开改关则热重载立即生效。",
        12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:feelNote];

    UILabel *warn = SIOLabel(
        @"⚠️ 硬保护名单：顺丰同城骑士 com.sfic.knight、桌面进程 com.apple.springboard —— 列表加速恒为关闭，任何配置都打不开（SpringBoard 打开会黑屏/白苹果）。淘宝/京东等重列表 App 也建议保持关闭。",
        12, [UIColor systemOrangeColor]);
    [self.stack addArrangedSubview:warn];

    UILabel *blacklistTitle = SIOSectionTitle(@"黑名单（每行一个 Bundle ID，命中则完全不加速）");
    m.blacklist = [[UITextView alloc] init];
    m.blacklist.font = [UIFont systemFontOfSize:14];
    m.blacklist.layer.borderColor = [UIColor separatorColor].CGColor;
    m.blacklist.layer.borderWidth = 0.5;
    m.blacklist.layer.cornerRadius = 10;
    [m.blacklist.heightAnchor constraintEqualToConstant:110].active = YES;
    [self.stack addArrangedSubview:blacklistTitle];
    [self.stack addArrangedSubview:m.blacklist];
}

- (void)changed { [self.model refreshDynamicLabels]; }
- (void)uiApplied { [self.model refreshDynamicLabels]; }

@end

#pragma mark - ③ 系统页（保活 + 辅助功能 + UIKit 系数）

@interface SIOSystemVC : SIOPageVC
@end
@implementation SIOSystemVC

- (void)buildContent {
    SIOModel *m = self.model;
    self.title = @"保活 · 系统";

    m.swFUBG = [[UISwitch alloc] init];
    m.swFUBGScene = [[UISwitch alloc] init];
    m.swFUBGAudio = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOSectionTitle(@"真后台保活（FUBackground · 已精简）")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"启用真后台保活", @"注入的 App 退到后台后继续保活", m.swFUBG),
        SIORowSub(@"场景伪装引擎", @"推荐。让系统认为 App 仍在前台", m.swFUBGScene),
        SIORowSub(@"音频断言兜底", @"静音白噪，需 App 声明 audio 后台模式", m.swFUBGAudio),
    ], 14)];

    m.swRM = [[UISwitch alloc] init];
    m.swCF = [[UISwitch alloc] init];
    m.swRT = [[UISwitch alloc] init];
    [self.stack addArrangedSubview:SIOSectionTitle(@"系统动态效果 · 写入辅助功能，需注销生效")];
    [self.stack addArrangedSubview:SIOCard(@[
        SIORowSub(@"减弱动态效果", @"系统级开关，iOS 原生减弱动画", m.swRM),
        SIORowSub(@"首选交叉淡出过渡", @"把推挤式转场换成淡入淡出", m.swCF),
        SIORowSub(@"减少透明度", @"关闭毛玻璃，降低 GPU 负载", m.swRT),
    ], 14)];

    m.segDrag = [[UISegmentedControl alloc] initWithItems:@[ @"关闭", @"×5", @"×10", @"×20", @"极端" ]];
    [m.segDrag addTarget:self action:@selector(dragChanged) forControlEvents:UIControlEventValueChanged];
    m.lblDrag = SIOLabel(@"", 12, [UIColor systemOrangeColor]);
    [self.stack addArrangedSubview:SIOSectionTitle(@"UIKit 全局动画系数（需注销/重启目标 App）")];
    [self.stack addArrangedSubview:SIOCard(@[ m.segDrag, m.lblDrag ], 10)];
    [self dragChanged];
}

- (void)dragChanged {
    SIOModel *m = self.model;
    int idx = (int)m.segDrag.selectedSegmentIndex;
    double c = DragCoeffForIndex(idx);
    if (!m.swEnabled.on) {
        m.lblDrag.textColor = [UIColor secondaryLabelColor];
        m.lblDrag.text = @"总开关当前关闭：保存后此项会被清成原生值（v2.1.10 起），先开总开关再选档位。";
        return;
    }
    if (idx == 4) {
        m.lblDrag.text = @"「极端」写 0.0001：全系统动画≈归零，绕过 dylib 安全下限，可能触发回调配对错乱；不要与 dylib 加速同时拉满。";
    } else if (c <= 0.0) {
        m.lblDrag.textColor = [UIColor secondaryLabelColor];
        m.lblDrag.text = @"未启用。选 ×5 / ×10 / ×20 可全系统加速，不建议与 dylib 加速同时拉满（两机制叠加）。";
    } else {
        m.lblDrag.textColor = [UIColor systemOrangeColor];
        m.lblDrag.text = [NSString stringWithFormat:@"已选 ×%d（写入 %.2f），全系统生效，需注销/重启目标 App。",
                          DragMultiplierForCoeff(c), c];
    }
}

- (void)uiApplied { [self dragChanged]; }

@end

#pragma mark - ④ 高级页（专属覆盖 / 导入导出 / 自检 / 电源）

@interface SIOAdvancedVC : SIOPageVC <UITextFieldDelegate>
@property (strong) UITextView *reportView;
@property (strong) UIButton  *checkPill;   // v2.1.9：保留引用以便点击后改标题给反馈
@end
@implementation SIOAdvancedVC

- (void)buildContent {
    SIOModel *m = self.model;
    self.title = @"高级";

    // ---- App 专属覆盖 ----
    // v2.1.9：输入框支持多个 Bundle ID（逗号/空格/换行分隔），保存时批量生效
    [self.stack addArrangedSubview:SIOSectionTitle(@"App 专属覆盖（可一次填多个 Bundle ID）")];
    m.ovBundle = [[UITextField alloc] init];
    m.ovBundle.placeholder = @"com.sfic.knight（多个用逗号/空格分隔）";
    m.ovBundle.borderStyle = UITextBorderStyleRoundedRect;
    m.ovBundle.font = [UIFont systemFontOfSize:14];
    m.ovBundle.autocapitalizationType = UITextAutocapitalizationTypeNone;
    m.ovBundle.autocorrectionType = UITextAutocorrectionTypeNo;
    m.ovBundle.spellCheckingType = UITextSpellCheckingTypeNo;
    m.ovBundle.keyboardType = UIKeyboardTypeURL;
    m.ovBundle.clearButtonMode = UITextFieldViewModeWhileEditing;
    m.ovBundle.returnKeyType = UIReturnKeyDone;
    m.ovBundle.delegate = self;
    [m.ovBundle addTarget:self action:@selector(ovBundleEdited)
         forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
    [m.ovBundle.heightAnchor constraintEqualToConstant:38].active = YES;

    m.ovOn = [[UISwitch alloc] init];
    [m.ovOn addTarget:self action:@selector(ovToggled) forControlEvents:UIControlEventValueChanged];
    m.ovSpeedLabel = SIOLabel(@"专属倍率（当前 ×5.0）", 16, [UIColor labelColor]);
    m.ovSpeed = [[UISlider alloc] init];
    m.ovSpeed.minimumValue = 1.0f;
    m.ovSpeed.maximumValue = 50.0f;
    [m.ovSpeed addTarget:self action:@selector(ovSpeedChanged) forControlEvents:UIControlEventValueChanged];
    m.ovMode = [[UISegmentedControl alloc] initWithItems:@[ @"加速", @"慢放", @"瞬切" ]];
    m.ovLayer = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×2", @"×3", @"×5", @"×10" ]];
    m.ovFloor = [[UISegmentedControl alloc] initWithItems:@[ @"0.005", @"0.01", @"0.02", @"0.05" ]];
    m.ovTrans = [[UISegmentedControl alloc] initWithItems:@[ @"×1", @"×1.5", @"×2", @"×3" ]];
    m.ovSpring = [[UISwitch alloc] init];
    m.ovExtra = [[UISwitch alloc] init];
    m.ovList = [[UISwitch alloc] init];
    m.ovList.onTintColor = [UIColor systemRedColor];
    m.ovZoom = [[UISwitch alloc] init];
    m.ovFastScroll = [[UISwitch alloc] init];
    m.ovFastTap = [[UISwitch alloc] init];
    // v2.1.10：专属覆盖版「瞬时打开三件套」（与手感页同名，但只作用于这里填的 Bundle ID）
    m.ovInstant = [[UISwitch alloc] init];
    m.ovHUDFast = [[UISwitch alloc] init];
    m.ovWKFast  = [[UISwitch alloc] init];
    m.ovGuard = SIOLabel(@"", 12, [UIColor secondaryLabelColor]);

    [self.stack addArrangedSubview:SIOCard(@[
        m.ovBundle,
        SIORow(@"为该 App 启用专属配置", m.ovOn, nil),
        m.ovSpeedLabel, m.ovSpeed,
        SIOLabel(@"专属模式", 15, [UIColor labelColor]), m.ovMode,
        SIOLabel(@"显式动画额外倍率", 15, [UIColor labelColor]), m.ovLayer,
        SIOLabel(@"时长下限", 15, [UIColor labelColor]), m.ovFloor,
        SIOLabel(@"转场额外倍率", 15, [UIColor labelColor]), m.ovTrans,
        SIORow(@"弹簧参数缩放", m.ovSpring, nil),
        SIORow(@"进阶转场", m.ovExtra, nil),
        SIORow(@"列表加速（高危）", m.ovList, [UIColor systemRedColor]),
        SIORow(@"缩放动画加速", m.ovZoom, nil),
        SIORow(@"滑行惯性加急", m.ovFastScroll, nil),
        SIORow(@"点击零延迟", m.ovFastTap, nil),
        // v2.1.10：瞬时打开三件套的专属覆盖版。某个 App 白屏/转场抽搐时，
        // 在这里单独关掉它的「瞬时打开页面」，不用动全局。
        SIOLabel(@"瞬时打开（专属）", 15, [UIColor labelColor]),
        SIORow(@"瞬时打开页面", m.ovInstant, nil),
        SIORow(@"加载圈 / HUD 加速", m.ovHUDFast, nil),
        SIORow(@"网页提前显形", m.ovWKFast, nil),
        m.ovGuard,
    ], 10)];

    // ---- 导入 / 导出 ----
    [self.stack addArrangedSubview:SIOSectionTitle(@"配置导入 / 导出（JSON，经剪贴板）")];
    UIButton *exp = SIOPill(@"📤 导出配置到剪贴板", [UIColor systemBlueColor], [UIColor whiteColor]);
    UIButton *imp = SIOPill(@"📥 从剪贴板导入并保存", [UIColor systemTealColor], [UIColor whiteColor]);
    [exp addTarget:self action:@selector(doExport) forControlEvents:UIControlEventTouchUpInside];
    [imp addTarget:self action:@selector(doImport) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *ioRow = [[UIStackView alloc] initWithArrangedSubviews:@[exp, imp]];
    ioRow.axis = UILayoutConstraintAxisHorizontal;
    ioRow.distribution = UIStackViewDistributionFillEqually;
    ioRow.spacing = 8;
    [ioRow.heightAnchor constraintEqualToConstant:38].active = YES;
    [self.stack addArrangedSubview:ioRow];

    // ---- 自检 ----
    // v2.1.9：按钮点击加可感知反馈（标题变化 + 震动 + 报告加时间戳），
    // 修复「看起来点了没反应」的问题；报告区禁止文本选中，避免长按手势抢触摸。
    [self.stack addArrangedSubview:SIOSectionTitle(@"注入 / 环境自检")];
    self.checkPill = SIOPill(@"🔍 重新检测", [UIColor systemTealColor], [UIColor whiteColor]);
    [self.checkPill addTarget:self action:@selector(doCheck)
             forControlEvents:UIControlEventTouchUpInside];
    self.reportView = [[UITextView alloc] init];
    self.reportView.editable = NO;
    self.reportView.selectable = NO;   // selectable 的 UITextView 有长按/拖动手势，会跟滚动抢触摸
    self.reportView.showsVerticalScrollIndicator = YES;
    self.reportView.showsHorizontalScrollIndicator = NO;
    self.reportView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.reportView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.reportView.layer.cornerRadius = 12;
    self.reportView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.reportView.heightAnchor constraintEqualToConstant:300].active = YES;
    [self.stack addArrangedSubview:SIOCard(@[ self.checkPill, self.reportView ], 10)];
    [self doCheck];

    // ---- 电源 ----
    [self.stack addArrangedSubview:SIOSectionTitle(@"电源操作（会先自动保存）")];
    UIButton *rs = SIOPill(@"🔄 注销 SpringBoard", [UIColor whiteColor], [UIColor systemBlueColor]);
    rs.layer.borderWidth = 1;
    rs.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [rs addTarget:self action:@selector(doRespring) forControlEvents:UIControlEventTouchUpInside];
    UIButton *rb = SIOPill(@"⏻ 硬重启设备", [UIColor whiteColor], [UIColor systemRedColor]);
    rb.layer.borderWidth = 1;
    rb.layer.borderColor = [UIColor systemRedColor].CGColor;
    [rb addTarget:self action:@selector(doReboot) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:SIOCard(@[ rs, rb ], 10)];

    UILabel *hint = SIOLabel(
        [NSString stringWithFormat:@"%@：支持可调时长下限、转场独立倍率、App 专属覆盖多 ID 批量生效、setter 强黏手感与热重载生效提示。dylib 与配置器版本必须配套。", SIO_VERSION],
        12, [UIColor secondaryLabelColor]);
    [self.stack addArrangedSubview:hint];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    [self.model refreshOverrides];
    return YES;
}
- (void)ovBundleEdited { [self.model refreshOverrides]; }
- (void)ovSpeedChanged {
    self.model.ovSpeedLabel.text =
        [NSString stringWithFormat:@"专属倍率（当前 ×%.1f）", self.model.ovSpeed.value];
}
- (void)ovToggled {
    SIOModel *m = self.model;
    NSArray *ids = [m ovBundleIDs];
    NSString *bid = ids.firstObject ?: @"com.sfic.knight";
    NSString *scope = ids.count > 1
        ? [NSString stringWithFormat:@"%lu 个 Bundle ID（%@ 等）", (unsigned long)ids.count, bid]
        : bid;
    BOOL anyGuarded = NO;
    for (NSString *i in ids) if ([HardGuardBundles() containsObject:i]) { anyGuarded = YES; break; }
    if (anyGuarded) {
        m.ovGuard.text = [NSString stringWithFormat:@"⚠️ 含硬保护名单内的 Bundle ID：名单内 App 列表加速恒关。", bid];
        m.ovGuard.textColor = [UIColor systemOrangeColor];
    } else if (m.ovOn.on) {
        m.ovGuard.text = [NSString stringWithFormat:@"保存后将为 %@ 创建专属配置。", scope];
        m.ovGuard.textColor = [UIColor secondaryLabelColor];
    } else {
        m.ovGuard.text = [NSString stringWithFormat:@"保存后将删除 %@ 的专属配置，回到全局配置。", scope];
        m.ovGuard.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)doExport {
    NSString *path = [self.model exportConfig];
    UIAlertController *a;
    if (path) {
        a = [UIAlertController alertControllerWithTitle:@"✅ 已导出"
            message:[NSString stringWithFormat:@"JSON 已复制到剪贴板，并保存到：\n%@", path]
            preferredStyle:UIAlertControllerStyleAlert];
    } else {
        a = [UIAlertController alertControllerWithTitle:@"❌ 导出失败"
            message:@"JSON 序列化失败。" preferredStyle:UIAlertControllerStyleAlert];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doImport {
    NSString *json = [UIPasteboard generalPasteboard].string;
    if (!json.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板为空"
            message:@"请先复制一份 SIOriginal JSON 配置。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSString *err = [self.model importConfig:json];
    if (err) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"❌ 导入失败"
            message:err preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    BOOL ok = [self.model save];
    [self doCheck];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:ok ? @"✅ 导入成功并已保存" : @"⚠️ 已导入但保存失败"
        message:ok ? [self.model summary] : @"控件已更新，但 plist 写入失败，请检查权限。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doCheck {
    // v2.1.9：点击反馈 —— 震动 + 按钮标题短暂变化 + 报告含检测时间，肉眼可见「真的重新检测了」
    self.reportView.text = [self.model checkReport];
    [self.reportView setContentOffset:CGPointZero animated:NO];
    if (self.checkPill) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc]
                                        initWithStyle:UIImpactFeedbackStyleLight];
        [g impactOccurred];
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"HH:mm:ss";
        });
        NSString *ts = [fmt stringFromDate:[NSDate date]];
        [self.checkPill setTitle:[NSString stringWithFormat:@"✅ 已重新检测 · %@", ts]
                        forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.checkPill setTitle:@"🔍 重新检测" forState:UIControlStateNormal];
        });
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self doCheck];
}

- (void)doRespring {
    [self.model save];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ Respring(); });
}

- (void)doReboot {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"确认硬重启"
        message:@"将以 root 权限直接重启设备（不是注销）。未保存数据可能丢失。"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *x) {
            [self.model save];
            SIOReboot();
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)uiApplied { [self doCheck]; }

@end

#pragma mark - App Delegate

@interface SIOAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) SIOModel *model;
@end

@implementation SIOAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    SIO_MigrateV211();   // v2.1.1：先洗掉 v2.1.0 留下的致闪退配置，再读控件初值
    self.model = [[SIOModel alloc] init];
    SIOModel *model = self.model;

    SIOEngineVC *e = [[SIOEngineVC alloc] init];
    e.model = model; e.title = @"引擎";
    SIOFeelVC *f = [[SIOFeelVC alloc] init];
    f.model = model; f.title = @"手感";
    SIOSystemVC *s = [[SIOSystemVC alloc] init];
    s.model = model; s.title = @"系统";
    SIOAdvancedVC *a = [[SIOAdvancedVC alloc] init];
    a.model = model; a.title = @"高级";

    // 立即加载所有页面，保证 model 的全部控件在任何 save/预设前已创建
    for (UIViewController *vc in @[e,f,s,a]) [vc loadViewIfNeeded];
    [model loadControlValues];
    [e refreshHeader];   // v2.1.0：载入配置后立刻刷新头部的实时状态行

    UINavigationController *(^nav)(UIViewController *, NSString *, NSString *) =
        ^(UIViewController *vc, NSString *icon, NSString *title) {
        UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc];
        n.tabBarItem = [[UITabBarItem alloc] initWithTitle:title
                                                     image:[UIImage systemImageNamed:icon]
                                                       tag:0];
        n.navigationBar.prefersLargeTitles = NO;
        // v2.1.0：导航栏统一为不透明品牌色 + 白字，四个 Tab 观感一致
        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
            [ap configureWithOpaqueBackground];
            ap.backgroundColor = [UIColor colorWithRed:0.04 green:0.32 blue:0.28 alpha:1.0];
            ap.titleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
            n.navigationBar.standardAppearance = ap;
            n.navigationBar.scrollEdgeAppearance = ap;
        }
        n.navigationBar.tintColor = [UIColor whiteColor];
        return n;
    };
    UITabBarController *tab = [[UITabBarController alloc] init];
    tab.viewControllers = @[ nav(e, @"bolt.fill", @"引擎"),
                             nav(f, @"hand.tap", @"手感"),
                             nav(s, @"gear", @"系统"),
                             nav(a, @"wrench.fill", @"高级") ];
    tab.tabBar.tintColor = SIOAccent();
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *ta = [[UITabBarAppearance alloc] init];
        [ta configureWithOpaqueBackground];
        tab.tabBar.standardAppearance = ta;
        if (@available(iOS 15.0, *)) tab.tabBar.scrollEdgeAppearance = ta;
    }

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];

    // v2.1.1：若确实清洗过旧配置，明确告知用户发生了什么（不静默改设置）
    if (gMigratedDirty) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"已清理致闪退的旧配置"
                message:@"已清理旧版遗留的「长按手势加速」配置项。\n\n"
                        @"该功能挂钩了 UILongPressGestureRecognizer 的 init 方法，是 v2.0.0 起"
                        @"所有注入 App 闪退的真正元凶（两份崩溃日志同帧实锤），本版已整个移除。\n\n"
                        @"其余加速项已全部默认开启。"
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
            [tab presentViewController:a animated:YES completion:nil];
        });
    }
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--sio-reboot-helper"]) {
            reboot(RB_AUTOBOOT);
            pid_t pid;
            posix_spawnattr_t attr;
            posix_spawnattr_init(&attr);
            posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
            posix_spawnattr_set_persona_uid_np(&attr, 0);
            posix_spawnattr_set_persona_gid_np(&attr, 0);
            char *a[] = { "/usr/bin/killall", "-9", "launchd", NULL };
            posix_spawn(&pid, "/usr/bin/killall", NULL, &attr, a, environ);
            posix_spawnattr_destroy(&attr);
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SIOAppDelegate class]));
    }
}
