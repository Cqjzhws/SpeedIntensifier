// FUBackground v1.0.0 — TrollStore 真后台保活 dylib（纯 ObjC runtime，无 substrate）
//
// 原理：iOS App 进后台后默认约 30 秒被 assertiond 挂起。纯巨魔环境没有越狱级
// assertiond hook，唯一稳定通道是借用系统【音频后台断言】：
//   1. 进后台 → AVAudioSession 切 playback + mixWithOthers（不打断用户正在听的音乐）
//   2. 播放一段无限循环的内嵌静音 WAV（不依赖任何 bundle 资源，构造于 tmp）
//   3. 系统因"正在播放音频"授予持续后台时间，进程不被挂起
//   4. beginBackgroundTask 作为音频栈启动的 30 秒桥接宽限
//   5. 看门狗 timer 每 5 秒自愈：player 停了重启、session 掉了重新激活
//   6. 音频中断（来电/闹钟）结束后自动恢复播放
// 回前台 → pause + 停用 session（通知别的 App 可以恢复音频）
//
// 【必要前提】目标 App 的 Info.plist UIBackgroundModes 必须包含 "audio"，
// 否则进后台约 10 秒后仍会被挂起（系统在 launch 时读取该声明，运行时无法补）。
// 微信/QQ/抖音/快手/网易云/QQ音乐/B站等主流 App 自带 audio 声明。
// dylib 装载时会检测并在系统日志打印 [FUBG] audio mode = YES/NO。
//
// 配置：/var/Managed Preferences/mobile/com.local.fubg.plist
//   Enabled（总开关，默认 YES）
//   ExcludeApps（排除名单，bundle id 前缀匹配，命中则不保活）
// Darwin 通知 com.local.fubg.settingschanged 热重载。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static NSString *const kFBGPrefPath = @"/var/Managed Preferences/mobile/com.local.fubg.plist";
static NSString *const kFBGNotify   = @"com.local.fubg.settingschanged";

static BOOL    gEnabled = YES;
static NSArray *gExclude = nil;
static BOOL    gActive = NO;             // 当前 App 是否参与保活
static BOOL    gHasAudioMode = NO;       // Info.plist 是否声明了 audio 后台模式

static AVAudioPlayer *gPlayer = nil;
static UIBackgroundTaskIdentifier gTask = UIBackgroundTaskInvalid;
static NSTimer *gWatchdog = nil;

// ================================ 配置 ================================
static void _fbg_loadPref(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kFBGPrefPath];
        if (d) {
            if (d[@"Enabled"]) gEnabled = [d[@"Enabled"] boolValue];
            id ex = d[@"ExcludeApps"];
            if ([ex isKindOfClass:[NSArray class]]) gExclude = ex;
        }
    } @catch (__unused NSException *e) {}
    if (!gExclude) gExclude = @[];

    gActive = gEnabled;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *b in gExclude) {
        if ([b isKindOfClass:[NSString class]] && b.length && [bid hasPrefix:b]) {
            gActive = NO; break;
        }
    }

    NSArray *modes = [[NSBundle mainBundle] infoDictionary][@"UIBackgroundModes"];
    gHasAudioMode = [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"audio"];
}

// ================================ 内嵌静音 WAV ================================
// 1 秒 / 8000Hz / mono / 16bit PCM，全零采样；44 字节头 + 16000 字节数据。
// arm64 小端与 WAV 一致，字段可直接写内存。
static NSURL *_fbg_silenceURL(void) {
    static NSURL *url = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t sampleRate = 8000, dataSize = 16000, totalSize = 36 + dataSize;
        uint16_t fmtPCM = 1, ch = 1, bps = 16;
        uint32_t fmtSize = 16, byteRate = sampleRate * ch * (bps / 8);
        uint16_t blockAlign = ch * (bps / 8);
        NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
        [wav appendData:[@"RIFF" dataUsingEncoding:NSASCIIStringEncoding]];
        [wav appendBytes:&totalSize length:4];
        [wav appendData:[@"WAVE" dataUsingEncoding:NSASCIIStringEncoding]];
        [wav appendData:[@"fmt " dataUsingEncoding:NSASCIIStringEncoding]];
        [wav appendBytes:&fmtSize length:4];
        [wav appendBytes:&fmtPCM length:2];
        [wav appendBytes:&ch length:2];
        [wav appendBytes:&sampleRate length:4];
        [wav appendBytes:&byteRate length:4];
        [wav appendBytes:&blockAlign length:2];
        [wav appendBytes:&bps length:2];
        [wav appendData:[@"data" dataUsingEncoding:NSASCIIStringEncoding]];
        [wav appendBytes:&dataSize length:4];
        [wav increaseLengthBy:dataSize];   // 追加 16000 个 0x00
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fubg_silence.wav"];
        [wav writeToFile:path atomically:YES];
        url = [NSURL fileURLWithPath:path];
    });
    return url;
}

// ================================ 音频栈 ================================
static BOOL _fbg_activateSession(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback
            withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e] || e) {
        NSLog(@"[FUBG] setCategory failed: %@", e); return NO;
    }
    e = nil;
    if (![s setActive:YES error:&e] || e) {
        NSLog(@"[FUBG] setActive failed: %@", e); return NO;
    }
    return YES;
}

static void _fbg_ensurePlayer(void) {
    if (gPlayer) return;
    NSError *e = nil;
    gPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:_fbg_silenceURL() error:&e];
    if (e || !gPlayer) { NSLog(@"[FUBG] player init failed: %@", e); gPlayer = nil; return; }
    gPlayer.numberOfLoops = -1;       // 无限循环
    gPlayer.volume = 0.0f;            // 双保险：PCM 本身就是静音
    [gPlayer prepareToPlay];
}

static void _fbg_start(void) {
    if (!gActive) return;
    @try {
        // 桥接宽限：给音频栈启动留时间；音频断言生效后不会被调用过期
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask == UIBackgroundTaskInvalid) {
            gTask = [app beginBackgroundTaskWithName:@"fubg-bridge" expirationHandler:^{
                NSLog(@"[FUBG] bridge task expired (audio assertion not granted)");
                if (gTask != UIBackgroundTaskInvalid) {
                    [app endBackgroundTask:gTask];
                    gTask = UIBackgroundTaskInvalid;
                }
            }];
        }
        if (_fbg_activateSession()) {
            _fbg_ensurePlayer();
            if (!gPlayer.isPlaying) [gPlayer play];
        }
        NSLog(@"[FUBG] keep-alive started (audioMode=%d)", gHasAudioMode);
    } @catch (__unused NSException *e) {}
}

static void _fbg_stop(void) {
    @try {
        if (gPlayer.isPlaying) [gPlayer pause];
        NSError *e = nil;
        [[AVAudioSession sharedInstance] setActive:NO
                                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                            error:&e];
        UIApplication *app = [UIApplication sharedApplication];
        if (gTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:gTask];
            gTask = UIBackgroundTaskInvalid;
        }
        NSLog(@"[FUBG] keep-alive stopped");
    } @catch (__unused NSException *e) {}
}

// 看门狗：音频断言生效时后台 RunLoop 正常运转，timer 每 5 秒自愈一次
static void _fbg_watchdogFire(NSTimer *t) {
    (void)t;
    if (!gActive) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateBackground) return;
    @try {
        if (!gPlayer || !gPlayer.isPlaying) {
            NSLog(@"[FUBG] watchdog: player stopped, restarting");
            _fbg_activateSession();
            _fbg_ensurePlayer();
            [gPlayer play];
        }
    } @catch (__unused NSException *e) {}
}

// ================================ 通知回调 ================================
static void _fbg_onEnterBackground(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    _fbg_start();
}
static void _fbg_onEnterForeground(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    _fbg_stop();
}
static void _fbg_onInterruption(NSNotification *note) {
    if (!gActive) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        NSLog(@"[FUBG] interruption began");
        return;
    }
    // Ended：系统提示可恢复时立刻重启播放
    NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
    if (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) {
        NSLog(@"[FUBG] interruption ended, resuming");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
                _fbg_activateSession();
                _fbg_ensurePlayer();
                [gPlayer play];
            }
        });
    }
}
static void _fbg_onRouteChange(NSNotification *note) {
    // 拔耳机/蓝牙断开等场景 player 可能被停；看门狗会兜底，这里立即补一次
    if (!gActive) return;
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gPlayer && !gPlayer.isPlaying) [gPlayer play];
        });
    }
}
static void _fbg_onPrefReload(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    _fbg_loadPref();
    NSLog(@"[FUBG] prefs reloaded: enabled=%d active=%d", gEnabled, gActive);
    // 配置变为不启用且当前在后台，立即停
    if (!gActive && [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        _fbg_stop();
    }
}

__attribute__((constructor))
static void _fbg_entry(void) {
    @autoreleasepool {
        _fbg_loadPref();

        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onEnterBackground,
            (__bridge CFStringRef)UIApplicationDidEnterBackgroundNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onEnterForeground,
            (__bridge CFStringRef)UIApplicationWillEnterForegroundNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, _fbg_onPrefReload,
            (__bridge CFStringRef)kFBGNotify, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // AVAudioSession 通知走 NSNotificationCenter（block 形式无需持有者）
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ _fbg_onInterruption(n); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n){ _fbg_onRouteChange(n); }];

        // 音频栈与看门狗放到主线程 RunLoop 起来后初始化
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gActive) {
                _fbg_ensurePlayer();
                gWatchdog = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES
                                                              block:^(NSTimer *t){ _fbg_watchdogFire(t); }];
                [[NSRunLoop mainRunLoop] addTimer:gWatchdog forMode:NSRunLoopCommonModes];
            }
        });

        NSLog(@"[FUBG] v1.0.0 loaded in %@: enabled=%d active=%d audioMode=%d%@",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
              gEnabled, gActive, gHasAudioMode,
              gHasAudioMode ? @"" : @" (WARNING: no UIBackgroundModes audio — will suspend)");
    }
}
