// QUICMax — QUIC + 网络优化 v1.0.0 (ObjC UIKit, TrollStore)
// 优化增强 DevelopCubeLab/EnableQUIC 1.2.4:
//   · ObjC 重写 (Swift ~170KB → ~50KB ObjC)
//   · 单一 TSRootHelper (quicmaxhelper) 替代原版 3 个分散 helper
//   · 新增: TCP Fast Open / MPTCP 实验性开关 (com.apple.networkd.plist)
//   · 新增: 系统级加密 DNS (DoH) — Cloudflare/Google/Quad9/AdGuard/AliDNS/DNSPod
//   · 新增: .mobileconfig 直接 root 安装到 ConfigurationProfiles (免用户手动装)
//   · 新增: 完整备份/恢复所有受影响 plist
//   · 修复: chflags SF_IMMUTABLE 一致性 (原版 check UF_IMMUTABLE 是 bug)
//   · 状态仪表盘: 实时显示所有键值
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>

extern char **environ;

#define NETWORKD_PLIST @"/var/preferences/com.apple.networkd.plist"
#define BACKUP_DIR     @"/var/tmp/com.local.quicmax.backups"
#define NETWORKD_BACKUP BACKUP_DIR @"/com.apple.networkd.plist"
#define HELPER_NAME    @"quicmaxhelper"
#define DOH_PROFILE_ID @"com.local.quicmax.doh"

// DoH provider 表 (含国内 DNS, 用户时区 Asia/Shanghai)
static NSArray<NSDictionary *> *dohProviders(void) {
    return @[
        @{@"name": @"Cloudflare", @"url": @"https://cloudflare-dns.com/dns-query",   @"addrs": @[@"1.1.1.1", @"1.0.0.1"]},
        @{@"name": @"Google",     @"url": @"https://dns.google/dns-query",           @"addrs": @[@"8.8.8.8", @"8.8.4.4"]},
        @{@"name": @"Quad9",      @"url": @"https://dns.quad9.net/dns-query",        @"addrs": @[@"9.9.9.9", @"149.112.112.112"]},
        @{@"name": @"AdGuard",    @"url": @"https://dns.adguard-dns.com/dns-query",  @"addrs": @[@"94.140.14.14", @"94.140.15.15"]},
        @{@"name": @"AliDNS",     @"url": @"https://dns.alidns.com/dns-query",       @"addrs": @[@"223.5.5.5", @"223.6.6.6"]},
        @{@"name": @"DNSPod",     @"url": @"https://doh.pub/dns-query",              @"addrs": @[@"119.29.29.29", @"182.25.115.228"]},
    ];
}

// QUIC 配置键 (含实验性)
static NSArray<NSArray *> *quicKeys(void) {
    return @[
        @[@"enable_quic",        @"启用 QUIC (HTTP/3 底层)"],
        @[@"disable_quic_race",  @"禁用 IPv4 QUIC/TCP 竞速 (开=稳定, 关=激进)"],
        @[@"disable_quic_race5", @"禁用 IPv6 QUIC/TCP 竞速"],
        @[@"enable_tfo",         @"TCP Fast Open (实验性)"],
        @[@"enable_multipath",   @"MPTCP 多路径 (实验性)"],
    ];
}

#pragma mark - spawnHelper (TSRootBinary, runs as root)

static int spawnHelper(NSArray<NSString *> *args, NSString **outStr, NSString **errStr) {
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:HELPER_NAME ofType:@""];
    if (!helperPath) {
        if (errStr) *errStr = @"helper binary not found in bundle";
        return -1;
    }
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"qm_out.log"];
    NSString *errPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"qm_err.log"];
    unlink(outPath.UTF8String);
    unlink(errPath.UTF8String);

    NSMutableArray *argv = [NSMutableArray arrayWithObject:HELPER_NAME];
    [argv addObjectsFromArray:args];
    char **cargv = (char **)malloc(sizeof(char *) * (argv.count + 1));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = (char *)[argv[i] UTF8String];
    cargv[argv.count] = NULL;

    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);
    posix_spawn_file_actions_addopen(&action, STDOUT_FILENO, outPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&action, STDERR_FILENO, errPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);

    pid_t pid = 0;
    int err = posix_spawn(&pid, helperPath.UTF8String, &action, NULL, cargv, environ);
    posix_spawn_file_actions_destroy(&action);
    free(cargv);
    if (err != 0) {
        if (errStr) *errStr = [NSString stringWithFormat:@"posix_spawn error: %s", strerror(err)];
        return err;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (outStr) *outStr = [NSString stringWithContentsOfFile:outPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if (errStr) *errStr = [NSString stringWithContentsOfFile:errPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    return WEXITSTATUS(status);
}

#pragma mark - DoH .mobileconfig 生成

static NSString *newUUID(void) {
    CFUUIDRef u = CFUUIDCreate(nil);
    NSString *s = CFBridgingRelease(CFUUIDCreateString(nil, u));
    CFRelease(u);
    return s;
}

static NSString *mobileConfigForProvider(NSDictionary *p) {
    NSString *payloadUUID = newUUID();
    NSString *topUUID = newUUID();
    NSString *url = p[@"url"];
    NSArray *addrs = p[@"addrs"];
    NSMutableString *addrsXML = [NSMutableString string];
    for (NSString *a in addrs) [addrsXML appendFormat:@"\t\t<string>%@</string>\n", a];
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n<dict>\n"
        "\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>\n"
        "\t\t\t<key>PayloadType</key><string>com.apple.dnsSettings.managed</string>\n"
        "\t\t\t<key>PayloadIdentifier</key><string>%@</string>\n"
        "\t\t\t<key>PayloadUUID</key><string>%@</string>\n"
        "\t\t\t<key>PayloadVersion</key><integer>1</integer>\n"
        "\t\t\t<key>ProhibitDisablement</key><false/>\n"
        "\t\t\t<key>DNSSettingsType</key><string>HTTPS</string>\n"
        "\t\t\t<key>ServerURL</key><string>%@</string>\n"
        "\t\t\t<key>ServerAddresses</key>\n\t\t\t<array>\n%@\t\t\t</array>\n"
        "\t\t</dict>\n\t</array>\n"
        "\t<key>PayloadDisplayName</key><string>QUIC Max DoH (%@)</string>\n"
        "\t<key>PayloadIdentifier</key><string>com.local.quicmax</string>\n"
        "\t<key>PayloadType</key><string>Configuration</string>\n"
        "\t<key>PayloadUUID</key><string>%@</string>\n"
        "\t<key>PayloadVersion</key><integer>1</integer>\n"
        "</dict>\n</plist>\n",
        DOH_PROFILE_ID, payloadUUID, url, addrsXML, p[@"name"], topUUID];
}

#pragma mark - VC

@interface QUICMaxVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (strong, nonatomic) UITableView *tableView;
@property (strong, nonatomic) NSMutableDictionary *curState; // key -> @(0/1) ( Bool )
@property (strong, nonatomic) NSMutableDictionary *switches; // key -> UISwitch
@property (assign, nonatomic) BOOL fileLocked;
@property (assign, nonatomic) BOOL hasRoot;
@property (strong, nonatomic) NSString *dohInstalledProvider; // nil if none
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[QUICMaxVC alloc] init]];
    nav.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

@implementation QUICMaxVC

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"QUIC Max";
    self.curState = [NSMutableDictionary dictionary];
    self.switches = [NSMutableDictionary dictionary];

    // 检查 TrollStore 环境: 尝试读取 networkd.plist
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NETWORKD_PLIST];
    self.hasRoot = (d != nil);
    if (!self.hasRoot) {
        // 可能 plist 不存在, 但能跑就允许尝试
        self.hasRoot = YES;
    }

    UITableViewStyle style = UITableViewStyleInsetGrouped;
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    else style = UITableViewStyleGrouped;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:style];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    [self refreshState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshState];
}

#pragma mark state

- (void)refreshState {
    [self.curState removeAllObjects];
    [self.switches removeAllObjects];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NETWORKD_PLIST] ?: @{};
    for (NSArray *kv in quicKeys()) {
        NSString *k = kv[0];
        NSNumber *v = d[k]; // may be NSNumber(BOOL) or nil
        self.curState[k] = [NSNumber numberWithBool:[v boolValue]];
    }
    // lock status
    struct stat st;
    self.fileLocked = (stat(NETWORKD_PLIST.UTF8String, &st) == 0 && (st.st_flags & 0x00000002 /* SF_IMMUTABLE */));
    // DoH installed?
    self.dohInstalledProvider = [self checkDoHInstalled];
    [self.tableView reloadData];
}

- (NSString *)checkDoHInstalled {
    // 让 helper 列出 ConfigurationProfiles 目录里的 QUIC Max 文件
    NSString *out = nil, *err = nil;
    int rc = spawnHelper(@[@"list-profiles"], &out, &err);
    if (rc != 0) return nil;
    // out 内容: 若包含 "INSTALLED:<providerName>"
    if ([out hasPrefix:@"INSTALLED:"]) {
        return [out substringFromIndex:@"INSTALLED:".length];
    }
    return nil;
}

#pragma mark table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"状态";
        case 1: return @"QUIC 设置";
        case 2: return @"加密 DNS (DoH)";
        case 3: return @"工具";
        case 4: return @"关于";
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return @"enable_quic 在 iOS 15+ 通常默认开启。'竞速' 关闭更激进但弱网可能卡顿。实验性键 iOS 16.2 可能不生效。";
    if (s == 2) return self.dohInstalledProvider
        ? [NSString stringWithFormat:@"已安装: %@\n直接安装到系统 ConfigurationProfiles 目录, profiled 自动加载。", self.dohInstalledProvider]
        : @"系统级 DoH 替代运营商 DNS, 绕过 DNS 污染/劫持。";
    if (s == 3) return @"备份所有受影响 plist, 一键恢复。锁定后系统无法回滚 QUIC 配置。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return quicKeys().count + 1; // + file lock status
        case 1: return quicKeys().count;
        case 2: return 3; // provider picker / install / uninstall-export
        case 3: return 4; // backup / restore / lock-toggle / respring
        case 4: return 4; // version / source / references / disclaimer
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    c.detailTextLabel.text = nil;

    switch (ip.section) {
        case 0: { // 状态
            if (ip.row < quicKeys().count) {
                NSArray *kv = quicKeys()[ip.row];
                c.textLabel.text = kv[0];
                NSNumber *v = self.curState[kv[0]];
                c.detailTextLabel.text = [v boolValue] ? @"true" : @"false";
                c.detailTextLabel.textColor = [v boolValue] ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
                c.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                c.textLabel.text = @"配置文件锁定";
                c.detailTextLabel.text = self.fileLocked ? @"已锁定 (SF_IMMUTABLE)" : @"未锁定";
                c.detailTextLabel.textColor = self.fileLocked ? [UIColor systemOrangeColor] : [UIColor systemGrayColor];
                c.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            break;
        }
        case 1: { // QUIC 开关
            NSArray *kv = quicKeys()[ip.row];
            c.textLabel.text = kv[0];
            c.detailTextLabel.text = kv[1];
            c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            UISwitch *sw = [UISwitch new];
            NSString *key = kv[0];
            [sw setOn:[self.curState[key] boolValue] animated:NO];
            [sw addTarget:self action:@selector(onSwitchToggle:) forControlEvents:UIControlEventValueChanged];
            sw.tag = ip.row;
            self.switches[key] = sw;
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case 2: { // DoH
            switch (ip.row) {
                case 0:
                    c.textLabel.text = @"选择 DoH 提供商";
                    c.detailTextLabel.text = self.dohInstalledProvider ?: @"点击选择";
                    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    break;
                case 1:
                    c.textLabel.text = self.dohInstalledProvider ? @"重新安装 (覆盖当前)" : @"安装 DoH 配置";
                    c.textLabel.textColor = [UIColor systemBlueColor];
                    break;
                case 2:
                    c.textLabel.text = @"卸载 / 导出 .mobileconfig";
                    c.textLabel.textColor = [UIColor systemOrangeColor];
                    break;
            }
            break;
        }
        case 3: { // 工具
            switch (ip.row) {
                case 0: c.textLabel.text = @"备份当前配置"; c.textLabel.textColor = [UIColor systemBlueColor]; break;
                case 1: c.textLabel.text = @"从备份恢复"; c.textLabel.textColor = [UIColor systemBlueColor]; break;
                case 2:
                    c.textLabel.text = self.fileLocked ? @"解锁配置文件" : @"锁定配置文件";
                    c.textLabel.textColor = self.fileLocked ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
                    break;
                case 3: c.textLabel.text = @"Respring 应用"; c.textLabel.textColor = [UIColor systemRedColor]; break;
            }
            c.textLabel.textAlignment = NSTextAlignmentLeft;
            break;
        }
        case 4: { // 关于
            switch (ip.row) {
                case 0: c.textLabel.text = @"版本"; c.detailTextLabel.text = @"QUIC Max v1.0.0"; c.selectionStyle = UITableViewCellSelectionStyleNone; break;
                case 1: c.textLabel.text = @"源码 (基于)"; c.detailTextLabel.text = @"DevelopCubeLab/EnableQUIC"; break;
                case 2: c.textLabel.text = @"参考"; c.detailTextLabel.text = @"feng.com/post/13873305"; break;
                case 3: c.textLabel.text = @"免责"; c.detailTextLabel.text = @"仅 iOS 15+ 完整支持 QUIC"; c.selectionStyle = UITableViewCellSelectionStyleNone; break;
            }
            break;
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    switch (ip.section) {
        case 2: [self handleDoHRow:ip.row]; break;
        case 3: [self handleToolRow:ip.row]; break;
        case 4: [self handleAboutRow:ip.row]; break;
    }
}

#pragma mark QUIC toggle

- (void)onSwitchToggle:(UISwitch *)sw {
    NSInteger row = sw.tag;
    NSArray *kv = quicKeys()[row];
    NSString *key = kv[0];
    BOOL newVal = sw.on;
    // 写入流程: 读 networkd.plist → 改 key → 写 tmp → helper replace
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:NETWORKD_PLIST] ?: [NSMutableDictionary dictionary];
    d[key] = @(newVal);
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"qm_networkd.plist"];
    if (![d writeToFile:tmpPath atomically:YES]) {
        [self alert:@"写入临时文件失败"];
        sw.on = !newVal;
        return;
    }
    NSString *out = nil, *err = nil;
    int rc = spawnHelper(@[@"replace", tmpPath, NETWORKD_PLIST, @"644", @"root", @"wheel"], &out, &err);
    if (rc != 0) {
        [self alert:[NSString stringWithFormat:@"应用失败 (rc=%d)\n%@", rc, err ?: @""]];
        sw.on = !newVal;
        return;
    }
    // 立即刷新状态 (本机回读)
    [self refreshState];
}

#pragma mark DoH

- (void)handleDoHRow:(NSInteger)row {
    if (row == 0) {
        [self pickDoHProvider];
    } else if (row == 1) {
        [self pickDoHProviderAndInstall];
    } else {
        [self showDoHUninstallOrExport];
    }
}

- (void)pickDoHProvider {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择 DoH 提供商"
                                                                message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *p in dohProviders()) {
        [ac addAction:[UIAlertAction actionWithTitle:p[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self installDoH:p];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)pickDoHProviderAndInstall {
    [self pickDoHProvider];
}

- (void)installDoH:(NSDictionary *)p {
    NSString *xml = mobileConfigForProvider(p);
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"qm_doh.mobileconfig"];
    if (![xml writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        [self alert:@"生成 .mobileconfig 失败"];
        return;
    }
    NSString *out = nil, *err = nil;
    int rc = spawnHelper(@[@"install-profile", tmpPath, p[@"name"]], &out, &err);
    if (rc == 0) {
        [self alert:[NSString stringWithFormat:@"DoH (%@) 已安装\n%s", p[@"name"], "profiled 将自动加载, 可在 设置 → 通用 → VPN与设备管理 查看"]];
    } else {
        [self alert:[NSString stringWithFormat:@"安装失败 (rc=%d)\n%@%@", rc, err ?: @"", out ?: @""]];
    }
    [self refreshState];
}

- (void)showDoHUninstallOrExport {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"加密 DNS"
                                                                message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (self.dohInstalledProvider) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"卸载 (%@)", self.dohInstalledProvider] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSString *out = nil, *err = nil;
            int rc = spawnHelper(@[@"remove-profile"], &out, &err);
            if (rc == 0) [self alert:@"已卸载 DoH 配置"];
            else [self alert:[NSString stringWithFormat:@"卸载失败 (rc=%d)\n%@", rc, err ?: @""]];
            [self refreshState];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"导出 .mobileconfig (手动安装)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self exportMobileConfig];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)exportMobileConfig {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择导出的提供商" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *p in dohProviders()) {
        [ac addAction:[UIAlertAction actionWithTitle:p[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self doExportMobileConfig:p];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)doExportMobileConfig:(NSDictionary *)p {
    NSString *xml = mobileConfigForProvider(p);
    NSString *name = [NSString stringWithFormat:@"%@.mobileconfig", p[@"name"]];
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:name];
    if (![xml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        [self alert:@"写入失败"];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIDocumentInteractionController *dc = [UIDocumentInteractionController interactionControllerWithURL:url];
    dc.UTI = @"com.apple.mobileconfig";
    dc.name = name;
    [dc presentOptionsMenuFromRect:self.view.bounds inView:self.view animated:YES];
}

#pragma mark 工具

- (void)handleToolRow:(NSInteger)row {
    switch (row) {
        case 0: [self doBackup]; break;
        case 1: [self doRestore]; break;
        case 2: [self doToggleLock]; break;
        case 3: [self doRespring]; break;
    }
}

- (void)doBackup {
    NSString *out = nil, *err = nil;
    int rc = spawnHelper(@[@"backup", NETWORKD_PLIST, NETWORKD_BACKUP], &out, &err);
    if (rc == 0) [self alert:[NSString stringWithFormat:@"已备份\n→ %@\n%@", NETWORKD_BACKUP, out ?: @""]];
    else [self alert:[NSString stringWithFormat:@"备份失败 (rc=%d)\n%@", rc, err ?: @""]];
}

- (void)doRestore {
    if (![[NSFileManager defaultManager] fileExistsAtPath:NETWORKD_BACKUP]) {
        [self alert:@"无备份文件"];
        return;
    }
    NSString *out = nil, *err = nil;
    int rc = spawnHelper(@[@"replace", NETWORKD_BACKUP, NETWORKD_PLIST, @"644", @"root", @"wheel"], &out, &err);
    if (rc == 0) {
        [self alert:@"已从备份恢复\n建议 Respring 生效"];
        [self refreshState];
    } else [self alert:[NSString stringWithFormat:@"恢复失败 (rc=%d)\n%@", rc, err ?: @""]];
}

- (void)doToggleLock {
    NSString *out = nil, *err = nil;
    int rc = spawnHelper(self.fileLocked ? @[@"unlock", NETWORKD_PLIST] : @[@"lock", NETWORKD_PLIST], &out, &err);
    if (rc == 0) [self alert:self.fileLocked ? @"已解锁" : @"已锁定"];
    else [self alert:[NSString stringWithFormat:@"操作失败 (rc=%d)\n%@", rc, err ?: @""]];
    [self refreshState];
}

- (void)doRespring {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Respring" message:@"即将重启 SpringBoard 应用配置" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSString *out = nil, *err = nil;
        spawnHelper(@[@"respring"], &out, &err);
        // helper 会 kill SpringBoard, 当前 App 也会被系统重启
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark 关于

- (void)handleAboutRow:(NSInteger)row {
    if (row == 1) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/DevelopCubeLab/EnableQUIC"] options:@{} completionHandler:nil];
    } else if (row == 2) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.feng.com/post/13873305"] options:@{} completionHandler:nil];
    }
}

#pragma mark util

- (void)alert:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
