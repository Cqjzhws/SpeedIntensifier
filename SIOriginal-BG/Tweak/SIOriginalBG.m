// SIOriginalBG — 真后台保活（v3.0.1-BG）
//
// SIOriginal v2.4.1 精简版：按「只保留真后台，其他功能全部删除」重制。
// 已整体删除（代码级移除，不是关闭开关）：
//   · 动画加速（CAAnimation / CATransaction / UIView 块动画 / UISpring /
//     UIViewPropertyAnimator / 转场 / 导航模态 Tab / LayerBoost / TransitionBoost）
//   · 手感（UIScrollView decelerationRate / delaysContentTouches / setZoomScale）
//   · HUD 快速显示（WKWebView / SVProgressHUD / MBProgressHUD / UIActivityIndicatorView）
//   · 命中统计浮层、生效 toast、安全启动自愈、安全模式、配置快照/预设/历史
//   · 微信图片预览放大态旁路探测器
// 保留：FUBG 真后台保活双引擎（含 v2.3.x 全部修正）
//   引擎一 场景伪装 SceneFake —— 拦截 FrontBoard 下发的后台化 scene diff
//   引擎二 音频断言 AudioKeep —— 静音白噪 + AVAudioSession 断言防挂起
//
// ===================== v3.0.1 通话感知避让（修忙线拒接/来电通知延迟）=====================
// 真机反馈：装了黄白助手「忙线拒接」后，① 该功能与保活冲突；② 停留在微信页面时
// 来电不通知、过一会才通知。根因是音频断言在前台**只 pause 不释放会话**：
// 我们的静音 Playback 会话长期激活，微信自身要激活 PlayAndRecord 才能响铃/推送
// VoIP 通知时会被推迟；忙线拒接检测通话/忙线状态同样被这层会话干扰。
// 本版三处修正：
//   [1] 会话归属跟踪 gSessionOurs：只有我们亲手激活的会话才允许 setActive:NO，
//       绝不误关 App 自己的音频（否则会打断微信语音/视频播放）。
//   [2] 回前台彻底释放会话（原来只 pause），前台本就不需要保活。
//   [3] 通话感知 CallAware（默认开）：看门狗 / 线路变化 / 中断恢复三处检测
//       AVAudioSession.category 变成 PlayAndRecord / Record（别人占用）时，
//       立刻暂停播放并释放会话，并进入 15s 避让窗口，期间不自愈、不重抢。
//       中断恢复（ShouldResume）也改成「仅在没人占用时才重新激活」。
// =========================================================================================
//
// ===================== v3.0.2 后台定时刷新（修解锁后消息不刷新）=====================
// 真机反馈：锁屏来微信消息 → 解锁进去微信没有那条消息，界面「秒开」不刷新，
// 只有杀进程重进才有。根因：场景伪装把「后台→前台」转场整条吞了，UIKit 不再
// 投递 UIApplicationWillEnterForegroundNotification，App 自己的同步/刷新分支
// 永远等不到触发点；而 applicationState 又被伪装成 Active，App 更认为「我一直在
// 前台，没有新消息需要拉」。杀进程是冷启动，走的是另一条全量同步路径，所以有消息。
// 本版对症解法：真后台期间周期性投递 WillEnterForeground 通知（默认 30s，
// 可在配置 App 调整 10–600s，置 0 关闭），直接触发 App 自己的刷新分支。
// 安全性：
//   · 只在**物理真后台**时投递。真实状态通过原始 IMP 取（gOrigAppState），
//     不会递归进我们自己的 applicationState hook。
//   · 复用 v3.0.1 通话避让：别人占着音频会话（来电/录音/忙线拒接）或避让窗口内
//     一律不刷，避免打扰。
//   · 顺手自愈音频引擎（后台却没在播 = 异常，先救活再刷）。
// =========================================================================================
//
// 配置：/var/Managed Preferences/mobile/com.local.sioriginalbg.plist
//   Enabled      总开关（缺键 = 开）
//   SceneFake    场景伪装（缺键 = 开）
//   AudioKeep    音频断言（缺键 = 开）
//   CallAware    通话感知避让（缺键 = 开；v3.0.1 新增，配合忙线拒接等插件）
//   BgRefresh    后台定时刷新（缺键 = 开；v3.0.2 新增）
//   BgRefreshInterval  刷新周期秒数（缺键 = 30；钳制 10–600，<=0 = 关闭刷新）
//   Blacklist    排除名单，NSArray；精确匹配，条目结尾写 * 表示前缀匹配
//   AppOverrides App 级覆盖：{ "bundle id" = { Enabled/SceneFake/AudioKeep/CallAware/BgRefresh = 0/1; BgRefreshInterval = 秒; }; }
// 热重载：Darwin 通知 com.local.sioriginalbg.settingschanged

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>     // strstr：_fbg_appState 热路径上的 C 字符串判定（零分配）
#import <dlfcn.h>
#import "FUBGNoiseData.h"

#define kPrefPath   @"/var/Managed Preferences/mobile/com.local.sioriginalbg.plist"
#define kNotifyName @"com.local.sioriginalbg.settingschanged"
#define SIOBG_VERSION @"v3.0.2-BG"
// v3.0.1：检测到别人占用音频会话后的避让窗口（秒）。覆盖来电响铃 + VoIP 通知推送全程。
#define SIOBG_YIELD_WINDOW 15.0
// v3.0.2：后台定时刷新的周期钳制范围（秒）。下限 10s 防止把 App 刷到耗电异常，
// 上限 600s 防止用户误填巨大值等于没开。
#define SIOBG_REFRESH_MIN 10.0
#define SIOBG_REFRESH_MAX 600.0
#define SIOBG_REFRESH_DEF 30.0

// ---------- 全局状态 ----------
static NSString *gSelfBundle = nil;

static BOOL    gFUBGEnabled = YES;   // 总开关
static BOOL    gSceneFake   = YES;   // 引擎一：场景伪装
static BOOL    gAudioKeep   = YES;   // 引擎二：音频断言
static NSArray *gExclude    = nil;   // 排除名单（黑名单）

static BOOL gActive   = NO;   // 本 App 最终是否参与保活（总开关 ∧ 排除名单）
static BOOL gUseScene = NO;   // 本 App 是否启用场景伪装
static BOOL gUseAudio = NO;   // 本 App 是否启用音频断言
static BOOL gPhysBg   = NO;   // 物理上是否处于后台（由真实生命周期通知维护）

static BOOL gHasAudioMode   = NO;   // 宿主 App 是否声明 UIBackgroundModes=audio
static BOOL gHasAppOverride = NO;   // 是否命中 App 级覆盖（仅用于日志）
static BOOL gCallAware      = YES;  // v3.0.1 通话感知避让（配合忙线拒接等插件）

// v3.0.2 后台定时刷新：默认开，周期 30s。
static BOOL           gBgRefresh         = YES;
static NSTimeInterval gBgRefreshInterval = SIOBG_REFRESH_DEF;

// ---------- 基础工具 ----------

static NSString *SIOBG_bundleID(void) {
    if (!gSelfBundle) gSelfBundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return gSelfBundle;
}

// AppOverrides 结构：
//   AppOverrides = { "com.tencent.xin" = { Enabled = 1; SceneFake = 0; AudioKeep = 1; }; }
// 命中当前进程则返回该字典，否则 nil。优先级：App 覆盖 > 全局。
static NSDictionary *SIOBG_appOverride(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    id ov = root[@"AppOverrides"];
    if (![ov isKindOfClass:[NSDictionary class]]) return nil;
    NSString *bid = SIOBG_bundleID();
    if (!bid.length) return nil;
    id mine = ((NSDictionary *)ov)[bid];
    return [mine isKindOfClass:[NSDictionary class]] ? (NSDictionary *)mine : nil;
}

// 内置排除名单：桌面进程本身就是场景宿主，在它内部吞掉 scene 更新会影响全局所有 App。
static BOOL SIOBG_builtinExcluded(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ list = @[ @"com.apple.springboard" ]; });
    NSString *bid = SIOBG_bundleID();
    return bid.length && [list containsObject:bid];
}

// ---------- 配置 ----------

static void SIOBG_resetDefaults(void) {
    gFUBGEnabled = YES;
    gSceneFake   = YES;
    gAudioKeep   = YES;
    gCallAware   = YES;   // v3.0.1：缺键 = 开（兼容项，fail-safe 方向是"不打扰别人"）
    gBgRefresh   = YES;   // v3.0.2：缺键 = 开
    gBgRefreshInterval = SIOBG_REFRESH_DEF;
    gExclude     = @[];
}

// v3.0.2：刷新周期钳制。<=0 = 关闭；其余夹到 [10, 600]。
// plist 里可能是 NSNumber 也可能是字符串，doubleValue 两者都吃。
static NSTimeInterval SIOBG_clampInterval(id raw, NSTimeInterval fallback) {
    if (!raw) return fallback;
    double v = [raw doubleValue];
    if (!(v > 0)) return 0.0;   // 0/负数/非数字（NaN 比较为假）都视为关闭
    return MIN(MAX(v, SIOBG_REFRESH_MIN), SIOBG_REFRESH_MAX);
}

static BOOL SIOBG_isExcluded(void) {
    if (SIOBG_builtinExcluded()) return YES;   // 内置排除优先级最高，配置无法打开
    NSString *bid = SIOBG_bundleID();
    for (NSString *b in gExclude) {
        if (![b isKindOfClass:[NSString class]] || !b.length) continue;
        if ([b hasSuffix:@"*"]) {
            if (b.length > 1 && [bid hasPrefix:[b substringToIndex:b.length - 1]]) return YES;
        } else if ([bid isEqualToString:b]) {
            return YES;
        }
    }
    return NO;
}

static void SIOBG_recalc(void) {
    gActive   = gFUBGEnabled && !SIOBG_isExcluded();
    gUseScene = gActive && gSceneFake;
    gUseAudio = gActive && gAudioKeep;
}

static void SIOBG_loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        if (!d) {
            // 缺文件即回出厂默认，并留痕 —— 「删 plist 恢复默认」这条排障契约必须成立。
            SIOBG_resetDefaults();
            NSLog(@"[SIOBG] prefs file missing/unreadable at %@ — reset to factory defaults", kPrefPath);
        } else {
            if (d[@"Enabled"])   gFUBGEnabled = [d[@"Enabled"] boolValue];
            if (d[@"SceneFake"]) gSceneFake   = [d[@"SceneFake"] boolValue];
            if (d[@"AudioKeep"]) gAudioKeep   = [d[@"AudioKeep"] boolValue];
            if (d[@"CallAware"]) gCallAware   = [d[@"CallAware"] boolValue];
            if (d[@"BgRefresh"]) gBgRefresh   = [d[@"BgRefresh"] boolValue];
            gBgRefreshInterval = SIOBG_clampInterval(d[@"BgRefreshInterval"], SIOBG_REFRESH_DEF);

            // 排除名单：兼容 NSArray / 逗号分隔字符串两种写法；
            // 清洗非字符串元素（plist 手工编辑很容易混进 NSNumber，不洗会 unrecognized selector）。
            NSMutableArray *clean = [NSMutableArray array];
            id bl = d[@"Blacklist"];
            if ([bl isKindOfClass:[NSArray class]]) {
                for (id it in (NSArray *)bl) {
                    if (![it isKindOfClass:[NSString class]]) continue;
                    NSString *s = [(NSString *)it stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
                    if (s.length) [clean addObject:s];
                }
            } else if ([bl isKindOfClass:[NSString class]] && [(NSString *)bl length]) {
                for (NSString *it in [(NSString *)bl componentsSeparatedByString:@","]) {
                    NSString *s = [it stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
                    if (s.length) [clean addObject:s];
                }
            }
            gExclude = clean;

            NSDictionary *ovr = SIOBG_appOverride(d);
            gHasAppOverride = (ovr != nil);
            if (ovr) {
                if (ovr[@"Enabled"])   gFUBGEnabled = [ovr[@"Enabled"] boolValue];
                if (ovr[@"SceneFake"]) gSceneFake   = [ovr[@"SceneFake"] boolValue];
                if (ovr[@"AudioKeep"]) gAudioKeep   = [ovr[@"AudioKeep"] boolValue];
                if (ovr[@"CallAware"]) gCallAware   = [ovr[@"CallAware"] boolValue];
                if (ovr[@"BgRefresh"]) gBgRefresh   = [ovr[@"BgRefresh"] boolValue];
                if (ovr[@"BgRefreshInterval"])
                    gBgRefreshInterval = SIOBG_clampInterval(ovr[@"BgRefreshInterval"], gBgRefreshInterval);
            }
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];

    SIOBG_recalc();
}

// ---------- 引擎一：场景伪装 ----------
// 移植/修改自 ImmortalizerJailed main.m（GPLv3, Serge Alagon），致谢 @khanhduytran0

static void (*gOrigSceneUpdate)(id, SEL, id, id, id, id);

// 由后台化 diff 的描述特征判断这是否是一条"让 App 退到后台"的场景更新
static BOOL SIOBG_isBackgroundingDiff(NSString *desc) {
    if (!desc) return NO;
    if ([desc containsString:@"foreground = NotSet"] ||
        [desc containsString:@"foreground = No"] ||
        [desc containsString:@"foreground = BSSettingFlagNo"] ||
        [desc containsString:@"foreground = NO"]) {
        return YES;
    }
    // 后台切换器快照相关更新同样吞掉，避免快照暴露/状态推进
    if ([desc containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [desc containsString:@"targetOfEventDeferringEnvironments = (empty)"] ||
        [desc containsString:@"FBSceneSnapshotAction:"]) {
        return YES;
    }
    return NO;
}

static void SIOBG_sceneUpdate(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (gUseScene) {
        @try {
            if (SIOBG_isBackgroundingDiff([arg2 description])) {
                NSLog(@"[SIOBG] swallowed backgrounding scene diff");
                return;
            }
        } @catch (__unused NSException *e) {}
    }
    gOrigSceneUpdate(self, _cmd, arg1, arg2, arg3, arg4);
}

// ---- applicationState 伪装 ----
// 物理在后台时对绝大多数调用方返回 Active；但推送/通知框架需要真实答案
// （前台态时它们不会建立后台接收通道），用 dladdr 识别调用者如实返回。

static UIApplicationState (*gOrigAppState)(id, SEL);
static void *gAsLastRet = NULL;      // 调用点缓存：同址重复调用退化为两次指针比较
static BOOL  gAsLastBg  = NO;

static UIApplicationState SIOBG_appState(id self, SEL _cmd) {
    if (gUseScene && gPhysBg) {
        void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
        BOOL bg;
        if (ret != NULL && ret == gAsLastRet) {
            bg = gAsLastBg;
        } else {
            bg = NO;
            Dl_info info;
            if (dladdr(ret, &info) && info.dli_fname) {
                if (strstr(info.dli_fname, "UserNotifications") ||
                    strstr(info.dli_fname, "PushKit")) {
                    bg = YES;
                }
            }
            gAsLastRet = ret;
            gAsLastBg  = bg;
        }
        return bg ? UIApplicationStateBackground : UIApplicationStateActive;
    }
    return gOrigAppState ? gOrigAppState(self, _cmd) : UIApplicationStateActive;
}

// ---- 通知横幅伪装 ----
// App 自以为在前台，系统默认不弹横幅；物理在后台时强制弹。
// orig 按类存储：App 先后设置两个 delegate 时，全局单例会记错 IMP（self 与 IMP 不匹配）。

typedef void (*SIOBG_WillPresentIMP)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                                     void (^)(UNNotificationPresentationOptions));
static NSMapTable *gOrigWillPresentMap = nil;

static void SIOBG_setOrigWillPresent(Class c, IMP imp) {
    if (!c || !imp) return;
    if (!gOrigWillPresentMap)
        gOrigWillPresentMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                                   valueOptions:NSMapTableStrongMemory];
    [gOrigWillPresentMap setObject:[NSValue valueWithPointer:(void *)imp] forKey:(id)c];
}

static SIOBG_WillPresentIMP SIOBG_origWillPresentFor(Class c) {
    if (!gOrigWillPresentMap) return NULL;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        NSValue *v = [gOrigWillPresentMap objectForKey:k];
        if (v) return (SIOBG_WillPresentIMP)[v pointerValue];
    }
    return NULL;
}

static void SIOBG_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center,
                              UNNotification *note,
                              void (^handler)(UNNotificationPresentationOptions)) {
    if (gUseScene && gPhysBg) {
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
        return;
    }
    SIOBG_WillPresentIMP orig = SIOBG_origWillPresentFor([self class]);
    if (orig) {
        orig(self, _cmd, center, note, handler);
    } else {
        // UNUserNotificationCenterDelegate 契约要求 completionHandler 必须恰好调用一次，
        // 不调用会让该条通知的呈现被挂起。按 fail-safe 哲学：绝不吞掉 handler。
        handler(UNNotificationPresentationOptionBanner |
                UNNotificationPresentationOptionSound |
                UNNotificationPresentationOptionBadge);
    }
}

static void (*gOrigUNSetDelegate)(id, SEL, id);

static void SIOBG_unSetDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (gOrigUNSetDelegate) gOrigUNSetDelegate(self, _cmd, delegate);
    if (delegate) {
        Class dc = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(dc, sel);
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)SIOBG_willPresent) {
                // class_getInstanceMethod 可能返回父类的 Method；先尝试 class_addMethod
                // 新增子类覆写，失败（本类已有实现）才 method_setImplementation。
                if (!class_addMethod(dc, sel, (IMP)SIOBG_willPresent, method_getTypeEncoding(m))) {
                    method_setImplementation(m, (IMP)SIOBG_willPresent);
                }
                SIOBG_setOrigWillPresent(dc, cur);
            }
        }
    }
}

static void SIOBG_installSceneHooks(void) {
    Class wsClass = objc_getClass("FBSWorkspaceScenesClient");
    Method sceneM = wsClass ? class_getInstanceMethod(
        wsClass, @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:)) : NULL;
    if (sceneM) {
        IMP cur = method_getImplementation(sceneM);
        if (cur != (IMP)SIOBG_sceneUpdate) {
            gOrigSceneUpdate = (void (*)(id, SEL, id, id, id, id))cur;
            method_setImplementation(sceneM, (IMP)SIOBG_sceneUpdate);
            NSLog(@"[SIOBG] scene hook installed");
        } else {
            NSLog(@"[SIOBG] scene hook already installed (skip duplicate)");
        }
    } else {
        NSLog(@"[SIOBG] FBSWorkspaceScenesClient method not found, scene engine disabled");
    }

    Method stateM = class_getInstanceMethod([UIApplication class], @selector(applicationState));
    if (stateM) {
        IMP cur = method_getImplementation(stateM);
        if (cur != (IMP)SIOBG_appState) {
            gOrigAppState = (UIApplicationState (*)(id, SEL))cur;
            method_setImplementation(stateM, (IMP)SIOBG_appState);
        }
    }

    Class unClass = [UNUserNotificationCenter class];
    Method delM = class_getInstanceMethod(unClass, @selector(setDelegate:));
    if (delM) {
        IMP cur = method_getImplementation(delM);
        if (cur != (IMP)SIOBG_unSetDelegate) {
            gOrigUNSetDelegate = (void (*)(id, SEL, id))cur;
            method_setImplementation(delM, (IMP)SIOBG_unSetDelegate);
        }
    }
}

// ---------- 引擎二：音频断言 ----------

static AVAudioPlayer *gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = 0;   // 0 = 无桥接任务
static NSTimer *gWatchdog = nil;
static NSMutableArray *gObs = nil;             // 强引用 block 观察者 token，释放即注销
static BOOL gSessionOurs = NO;                 // v3.0.1：当前激活的会话是否由我们持有
static NSTimeInterval gForeignAt = 0;          // v3.0.1：最近一次检测到别人占用会话的时刻

static BOOL SIOBG_activateSession(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback
            withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e] || e) {
        NSLog(@"[SIOBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e]) {
        NSLog(@"[SIOBG] setActive failed: %@", e); return NO;
    }
    gSessionOurs = YES;   // 只有走到这里，之后才允许我们 setActive:NO
    return YES;
}

// v3.0.1：只释放「我们自己持有」的会话。误关 App 自己的会话会直接打断微信语音/
// 视频播放，这比不保活糟得多，所以必须先判归属。
static void SIOBG_releaseSession(void) {
    if (!gSessionOurs) return;
    @try {
        [[AVAudioSession sharedInstance] setActive:NO
                                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                            error:nil];
    } @catch (__unused NSException *e) {}
    gSessionOurs = NO;
}

// v3.0.1：别人（微信自身通话、忙线拒接等插件）把会话改成录音/通话类时返回 YES。
// AVAudioSession 是进程内单例，category 被改掉我们这边同样读得到。
static BOOL SIOBG_foreignSessionActive(void) {
    @try {
        NSString *cat = [[AVAudioSession sharedInstance] category];
        return [cat isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
               [cat isEqualToString:AVAudioSessionCategoryRecord];
    } @catch (__unused NSException *e) { return NO; }
}

// v3.0.1：让位 —— 暂停播放、释放会话、记下避让起点。
static void SIOBG_yieldForForeignSession(void) {
    if (!SIOBG_foreignSessionActive()) return;
    gForeignAt = CACurrentMediaTime();
    if (gPlayer.isPlaying) { @try { [gPlayer pause]; } @catch (__unused NSException *e) {} }
    SIOBG_releaseSession();
    NSLog(@"[SIOBG] yielded audio session to a foreign (call/record) session");
}

// 白噪是编译期常量，解码一次缓存复用。
static NSData *SIOBG_noiseData(void) {
    static NSData *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        d = [[NSData alloc] initWithBase64EncodedString:kFBGNoiseB64
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
    });
    return d;
}

static void SIOBG_buildAndPlay(void) {
    @try {
        NSData *data = SIOBG_noiseData();
        if (!data.length) return;
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:data error:nil];
        if (!p) return;
        p.numberOfLoops = -1;
        p.volume = 0.0f;
        [p prepareToPlay];
        [p play];
        gPlayer = p;
    } @catch (__unused NSException *e) {}
}

static void SIOBG_startAudio(void) {
    if (!gUseAudio) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == 0) {
            gTask = [app beginBackgroundTaskWithName:@"sibg-bridge" expirationHandler:^{
                NSLog(@"[SIOBG] bridge task expired");
                if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
            }];
        }
        if (SIOBG_activateSession() && (!gPlayer || !gPlayer.isPlaying)) {
            if (gPlayer) { [gPlayer play]; }
            else { SIOBG_buildAndPlay(); }
        }
        NSLog(@"[SIOBG] audio keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void SIOBG_stopAudio(BOOL releaseSession) {
    @try {
        if (gPlayer.isPlaying) [gPlayer pause];
        // mix 模式下保持 session 激活、不主动 setActive:NO，避免与目标 App 自身音频会话
        // 打架造成的卡顿；仅彻底关闭时通知他人恢复。
        if (releaseSession) SIOBG_releaseSession();
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != 0) { [app endBackgroundTask:gTask]; gTask = 0; }
    } @catch (__unused NSException *e) {}
}

// 看门狗按需装卸：只在真正进入后台时安装（后台无滚动，NSDefaultRunLoopMode 足够），
// 回前台即卸载；prefs 里关掉音频保活时同样卸载。周期 3s，低电量 6s。
static void SIOBG_watchdogStop(void) {
    if (gWatchdog) { [gWatchdog invalidate]; gWatchdog = nil; }
}

static void SIOBG_watchdogFire(NSTimer *t);

static int gWatchdogStrikes = 0;
static int gWatchdogBackoff = 0;
static NSTimeInterval gWatchdogStep = 3.0;

static void SIOBG_watchdogStart(void) {
    if (gWatchdog || !gUseAudio || !gPhysBg) return;
    BOOL lowPower = NO;
    @try { lowPower = [NSProcessInfo processInfo].isLowPowerModeEnabled; } @catch (__unused NSException *e) {}
    NSTimeInterval step = lowPower ? 6.0 : 3.0;
    gWatchdogStep = step;   // 退避按「秒」换算，不假设固定周期
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:step repeats:YES
                                                  block:^(NSTimer *t){ SIOBG_watchdogFire(t); }];
    NSLog(@"[SIOBG] watchdog started, interval=%.1fs (lowPower=%d)", step, lowPower);
}

// 自愈轮询：仅在停摆时重建。连续 3 次失败退避约 30s（按实际周期换算），恢复时打日志。
// v3.0.1：避让窗口内不自愈、不重抢会话（来电响铃 / VoIP 通知期间）。
static void SIOBG_watchdogFire(__unused NSTimer *t) {
    if (!gUseAudio || !gPhysBg) return;
    if (gWatchdogBackoff > 0) {
        if (--gWatchdogBackoff == 0) {
            gWatchdogStrikes = 0;
            NSLog(@"[SIOBG] watchdog: backoff ended, strike counter reset");
        }
        return;
    }
    if (gCallAware && gForeignAt > 0 && (CACurrentMediaTime() - gForeignAt) < SIOBG_YIELD_WINDOW)
        return;   // 通话/插件正用着会话，别抢
    if (gCallAware) SIOBG_yieldForForeignSession();
    @try {
        if (!gPlayer || !gPlayer.isPlaying) {
            NSLog(@"[SIOBG] watchdog: player stopped, rebuilding (strike %d)", gWatchdogStrikes + 1);
            SIOBG_activateSession();
            if (gPlayer) { [gPlayer play]; }
            else { SIOBG_buildAndPlay(); }
            if (gPlayer && gPlayer.isPlaying) {
                if (gWatchdogStrikes > 0)
                    NSLog(@"[SIOBG] watchdog: recovered after %d failed rebuild(s)", gWatchdogStrikes);
                gWatchdogStrikes = 0;
            } else if (++gWatchdogStrikes >= 3) {
                double step = (gWatchdogStep > 0.5) ? gWatchdogStep : 3.0;
                gWatchdogBackoff = (int)MAX(1.0, round(30.0 / step));
                NSLog(@"[SIOBG] watchdog: 3 consecutive rebuilds failed, backing off %.0fs (%d ticks @ %.1fs)",
                      30.0, gWatchdogBackoff, step);
            }
        } else {
            gWatchdogStrikes = 0;
        }
    } @catch (__unused NSException *e) {}
}

// ---------- v3.0.2：后台定时刷新 ----------
// 场景伪装吞掉转场后，App 收不到 WillEnterForeground，解锁「秒开不刷新」。
// 这里在物理真后台期间周期性补投这条通知，触发 App 自己的同步分支。

static NSTimer *gRefreshTimer = nil;

static void SIOBG_refreshFire(NSTimer *t);   // 前向声明：refreshStart 的 block 里引用

// 真实应用状态：直接调原始 IMP。绝不能调 [UIApplication applicationState]，
// 那会递归进我们自己的 hook，永远拿到伪造的 Active。
static UIApplicationState SIOBG_realAppState(void) {
    if (gOrigAppState) {
        @try {
            return gOrigAppState([UIApplication sharedApplication], @selector(applicationState));
        } @catch (__unused NSException *e) {}
    }
    return UIApplicationStateActive;
}

static void SIOBG_refreshStop(void) {
    if (gRefreshTimer) { [gRefreshTimer invalidate]; gRefreshTimer = nil; }
}

static void SIOBG_refreshStart(void) {
    if (gRefreshTimer) return;                              // 已在跑
    if (!gBgRefresh || gBgRefreshInterval <= 0) return;     // 功能关 / 周期置 0
    if (!gPhysBg) return;                                   // 只在真后台跑
    gRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:gBgRefreshInterval
                                                     repeats:YES
                                                       block:^(NSTimer *t){ SIOBG_refreshFire(t); }];
    NSLog(@"[SIOBG] background refresh armed, interval=%.0fs", gBgRefreshInterval);
}

static void SIOBG_refreshFire(__unused NSTimer *t) {
    if (!gBgRefresh || !gPhysBg) return;
    // 双保险：gPhysBg 之外再验一次真实状态（防生命周期通知漏调的极端情况）
    if (SIOBG_realAppState() != UIApplicationStateBackground) return;
    // v3.0.1 避让语义复用：通话/录音/忙线拒插插件正用会话时保持安静
    if (gCallAware && gForeignAt > 0 && (CACurrentMediaTime() - gForeignAt) < SIOBG_YIELD_WINDOW) return;
    if (gCallAware && SIOBG_foreignSessionActive()) return;
    // 后台却没在播 = 音频引擎异常，先救活再刷（与看门狗同一套重建逻辑）
    if (gUseAudio && (!gPlayer || !gPlayer.isPlaying)) {
        @try {
            SIOBG_activateSession();
            if (gPlayer) { [gPlayer play]; } else { SIOBG_buildAndPlay(); }
        } @catch (__unused NSException *e) {}
    }
    // 同步投递：定时器本就在主线程，App 的刷新分支立即执行
    [[NSNotificationCenter defaultCenter]
        postNotificationName:UIApplicationWillEnterForegroundNotification object:nil];
    NSLog(@"[SIOBG] background refresh fired");
}

static void SIOBG_onInterruption(NSNotification *note) {
    if (!gUseAudio) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
    if (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // v3.0.1：别人（来电/忙线拒接）还占着会话时，绝不重新激活去抢。
            if (gUseAudio && gPhysBg && !(gCallAware && SIOBG_foreignSessionActive())) {
                SIOBG_activateSession();
                if (gPlayer) { [gPlayer play]; } else { SIOBG_buildAndPlay(); }
            }
        });
    }
}

// ---------- 生命周期 / 热重载 ----------

static void SIOBG_onEnterBackground(NSNotification *note) {
    gPhysBg = YES;
    SIOBG_startAudio();
    SIOBG_watchdogStart();
    SIOBG_refreshStart();   // v3.0.2：后台定时刷新装弹
}

static void SIOBG_onEnterForeground(NSNotification *note) {
    gPhysBg = NO;
    SIOBG_watchdogStop();
    SIOBG_refreshStop();    // v3.0.2：回前台即停，前台不需要补刷新
    // v3.0.1：回前台不只 pause，还要**彻底释放会话**。
    // 旧行为让静音 Playback 会话在前台长期激活：微信要激活 PlayAndRecord 才能响铃 /
    // 推 VoIP 通知时会被这层会话推迟 —— 真机表现就是「停在微信页面，来电过一会才通知」，
    // 忙线拒接的通话/忙线检测也被干扰。前台不需要保活，完整让出。
    if (gPlayer.isPlaying) { @try { [gPlayer pause]; } @catch (__unused NSException *e) {} }
    SIOBG_releaseSession();
    if (gTask != 0) {
        [[UIApplication sharedApplication] endBackgroundTask:gTask];
        gTask = 0;
    }
}

static void SIOBG_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                               const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    // Darwin 回调在通知线程上执行，直接改全局会与主线程上的 hook 并发读写。
    // 统一丢主线程串行执行；_fbg_loadPref 换 gExclude 时若另线程正在遍历旧数组会野指针。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SIOBG_loadPref();
            NSLog(@"[SIOBG] prefs reloaded: active=%d scene=%d audio=%d callAware=%d refresh=%d interval=%.0f override=%d physBg=%d",
                  gActive, gUseScene, gUseAudio, gCallAware, gBgRefresh, gBgRefreshInterval, gHasAppOverride, gPhysBg);
            if (!gUseAudio && gPhysBg) { SIOBG_stopAudio(NO); SIOBG_watchdogStop(); }
            if (gUseAudio && gPhysBg && (!gPlayer || !gPlayer.isPlaying)) {
                SIOBG_startAudio(); SIOBG_watchdogStart();
            }
            // v3.0.2：刷新开关/周期改了要即时重装弹（interval 变了必须重建定时器才生效）
            SIOBG_refreshStop();
            if (gPhysBg) SIOBG_refreshStart();
        } @catch (__unused NSException *e) {}
    });
}

// ---------- 入口 ----------

__attribute__((constructor))
static void SIOBGEntry(void) {
    @autoreleasepool {
    // 全程 @try 包裹：保活引擎装不上也不能拖垮目标 App。
    @try {
        SIOBG_loadPref();

        // hook 一次性安装，内部按全局开关决定行为
        dispatch_async(dispatch_get_main_queue(), ^{
            SIOBG_installSceneHooks();
        });

        gObs = [NSMutableArray array];

        // 前后台感知必须注册到**进程内** NSNotificationCenter：Darwin 中心是系统级广播
        // 总线，只收 notify_post() 发出的名字，这两个通知永远不会出现在上面 ——
        // 注册错了 gPhysBg 恒为 NO，音频断言/看门狗/横幅伪装/中断恢复会全部静默失效。
        // block 观察者的返回值必须持有，否则立即自动注销。
        id obBg = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *n){ SIOBG_onEnterBackground(n); }];
        id obFg = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(__unused NSNotification *n){ SIOBG_onEnterForeground(n); }];
        if (obBg) [gObs addObject:obBg];
        if (obFg) [gObs addObject:obFg];

        id obInt = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ SIOBG_onInterruption(n); }];
        id obRoute = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *n){
                // v3.0.1：线路变化先让位检测（来电/挂断会改 route 与 category）
                if (gCallAware && gPhysBg) SIOBG_yieldForForeignSession();
                if (gUseAudio && gPhysBg) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        // 线路变化后 player 可能已被系统释放（nil），只 play 不重建会永久失效。
                        if (gCallAware && SIOBG_foreignSessionActive()) return;
                        if (gPlayer) {
                            if (!gPlayer.isPlaying) [gPlayer play];
                        } else {
                            SIOBG_buildAndPlay();
                        }
                    });
                }
            }];
        if (obInt)   [gObs addObject:obInt];
        if (obRoute) [gObs addObject:obRoute];

        // 配置热重载是跨进程的（配置 App 用 Darwin 广播），这一条继续走 Darwin 中心。
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, SIOBG_onPrefReload,
            (__bridge CFStringRef)kNotifyName, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        NSLog(@"[SIOBG] %@ loaded in %@: active=%d scene=%d audio=%d callAware=%d refresh=%d interval=%.0f audioMode=%d%@",
              SIOBG_VERSION,
              SIOBG_bundleID().length ? SIOBG_bundleID() : @"?",
              gActive, gUseScene, gUseAudio, gCallAware, gBgRefresh, gBgRefreshInterval, gHasAudioMode,
              (gHasAudioMode || gUseScene) ? @"" : @" (WARNING: no audio mode & no scene engine)");
    } @catch (NSException *e) {
        NSLog(@"[SIOBG] keep-alive install failed (app unaffected): %@", e);
    }
    }
}
