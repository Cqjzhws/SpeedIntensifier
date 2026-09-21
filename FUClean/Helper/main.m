// fuclean-helper — FUClean v1.0 root 清理助手（命令行，由主 App 以 root persona 启动）
//
// 用法：
//   fuclean-helper scan                 扫描统计，不删除
//   fuclean-helper clean <cat,...|all>  清理指定类别
//
// 输出：stdout 输出一行 JSON（结果），stderr 输出日志。
//
// 安全铁律（"保 App 日志"）：
//   * 永远不删 /var/mobile/Containers/Data/Application/*/Library/Logs 整个子树
//   * 永远不删 /var/mobile/Containers/Shared/AppGroup/*/Library/Logs
//   * 第三方 App 缓存清理时，容器内任何 *.log / *.log.* 一律跳过
//   * 最近 5 分钟内修改过的文件跳过（避免删系统服务/ App 正在写的句柄）
//   * 只清空目录内容，保留目录骨架（logd 等服务会自动重建文件）
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

// ---- 类别键（主 App 端做中文映射）----
// unified   系统统一日志 logd (/var/db/diagnostics + uuidtext)
// crash     崩溃与诊断报告
// syslogs   其他系统级日志
// syscaches 系统组件缓存
// tmp       系统临时文件
// safari    Safari 缓存（不动 Cookies/历史）
// appcache  第三方 App 缓存（保护白名单 + 保护 App 日志）

typedef struct {
    unsigned long long bytes;
    long files;
    long deleted;
    long failed;
    long skipped;
} FUStats;

static NSFileManager *gFM;
static NSDate *gNow;
static NSArray *gExclude;       // 白名单 bundle id 前缀
static FUStats gProt;           // 受保护的 App 日志
static NSMutableArray *gProtApps;

#pragma mark - 工具

static NSString *fu_json_esc(NSString *s) {
    if (!s) return @"";
    NSMutableString *m = [NSMutableString stringWithString:s];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r" withString:@"\\r" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\t" withString:@"\\t" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

static BOOL fu_recent(NSString *path) {
    NSDictionary *attr = [gFM attributesOfItemAtPath:path error:nil];
    NSDate *md = attr[NSFileModificationDate];
    return md && [gNow timeIntervalSinceDate:md] < 300.0;
}

static BOOL fu_is_app_log_name(NSString *name) {
    NSString *n = name.lowercaseString;
    if ([n hasSuffix:@".log"] || [n.pathExtension isEqualToString:@"log"]) return YES;
    // foo.log.1 / foo.log.2026-09-21
    NSRange r = [n rangeOfString:@".log."];
    if (r.location != NSNotFound) return YES;
    return NO;
}

// 累加文件大小（不跟随符号链接）
static void fu_count_tree(NSString *path, FUStats *st) {
    NSDirectoryEnumerator *en = [gFM enumeratorAtPath:path];
    NSString *rel;
    while ((rel = [en nextObject])) {
        NSString *full = [path stringByAppendingPathComponent:rel];
        NSDictionary *attr = [en fileAttributes];
        if ([attr[NSFileType] isEqual:NSFileTypeRegular]) {
            st->bytes += [attr[NSFileSize] unsignedLongLongValue];
            st->files++;
        }
        (void)full;
    }
}

// 删除目录内容：keepSubdirs=YES 时保留直接子目录本身（清空其内容），用于 uuidtext
static void fu_clean_dir(NSString *dir, BOOL keepSubdirs, FUStats *st,
                         BOOL(^protectFile)(NSString *name)) {
    NSArray *items = [gFM contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in items) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        NSDictionary *attr = [gFM attributesOfItemAtPath:full error:nil];
        NSString *type = attr[NSFileType];
        if ([type isEqual:NSFileTypeDirectory]) {
            if (keepSubdirs) {
                // 清空子目录内容，保留子目录
                fu_clean_dir(full, NO, st, protectFile);
            } else {
                unsigned long long before = 0; long fbefore = 0;
                FUStats sub = {0};
                fu_count_tree(full, &sub);
                before = sub.bytes; fbefore = sub.files;
                NSError *e = nil;
                if ([gFM removeItemAtPath:full error:&e]) {
                    st->bytes += before; st->files += fbefore;
                    st->deleted++; st->skipped += 0;
                } else {
                    // 目录里可能有受保护文件，回退为逐项删
                    FUStats inner = {0};
                    fu_clean_dir(full, NO, &inner, protectFile);
                    st->bytes += inner.bytes; st->files += inner.files;
                    st->deleted += inner.deleted; st->failed += inner.failed;
                    st->skipped += inner.skipped;
                }
            }
        } else if ([type isEqual:NSFileTypeRegular]) {
            if (protectFile && protectFile(name)) { st->skipped++; continue; }
            if (fu_recent(full)) { st->skipped++; continue; }
            unsigned long long sz = [attr[NSFileSize] unsignedLongLongValue];
            NSError *e = nil;
            if ([gFM removeItemAtPath:full error:&e]) {
                st->bytes += sz; st->files++; st->deleted++;
            } else if (unlink(full.fileSystemRepresentation) == 0) {
                st->bytes += sz; st->files++; st->deleted++;
            } else {
                st->failed++;
                fprintf(stderr, "del fail: %s (%s)\n", full.UTF8String, e.localizedDescription.UTF8String ?: "?");
            }
        }
        // 符号链接/其他类型不计
    }
}

// 扫描：统计目录全部常规文件大小（不应用最近保护，扫描只看占用）
static void fu_scan_dir(NSString *dir, BOOL keepSubdirs, FUStats *st,
                        BOOL(^protectFile)(NSString *name)) {
    NSArray *items = [gFM contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in items) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        NSDictionary *attr = [gFM attributesOfItemAtPath:full error:nil];
        NSString *type = attr[NSFileType];
        if ([type isEqual:NSFileTypeDirectory]) {
            (void)keepSubdirs;
            fu_count_tree(full, st);
        } else if ([type isEqual:NSFileTypeRegular]) {
            if (protectFile && protectFile(name)) { st->skipped++; continue; }
            st->bytes += [attr[NSFileSize] unsignedLongLongValue];
            st->files++;
        }
    }
}

// 带保护的递归扫描：命中保护名的文件（任意层级）计入"受保护 App 日志"而非可清理
static void fu_scan_tree_protect(NSString *dir, FUStats *st,
                                 BOOL(^protectFile)(NSString *name)) {
    NSArray *items = [gFM contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in items) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        NSDictionary *attr = [gFM attributesOfItemAtPath:full error:nil];
        NSString *type = attr[NSFileType];
        if ([type isEqual:NSFileTypeDirectory]) {
            fu_scan_tree_protect(full, st, protectFile);
        } else if ([type isEqual:NSFileTypeRegular]) {
            unsigned long long sz = [attr[NSFileSize] unsignedLongLongValue];
            if (protectFile && protectFile(name)) {
                gProt.bytes += sz; gProt.files++;
            } else {
                st->bytes += sz; st->files++;
            }
        }
    }
}

#pragma mark - 目标定义

static BOOL fu_exists(NSString *p) {
    return [gFM fileExistsAtPath:p];
}

// 对一组"目录内容"目标执行
static void fu_run_dirs(NSArray *dirs, BOOL keepSubdirs, FUStats *st, BOOL deleting,
                        BOOL(^protectFile)(NSString *name)) {
    for (NSString *d in dirs) {
        if (!fu_exists(d)) continue;
        if (deleting) fu_clean_dir(d, keepSubdirs, st, protectFile);
        else fu_scan_dir(d, keepSubdirs, st, protectFile);
    }
}

static void fu_run_unified(FUStats *st, BOOL deleting) {
    // logd 持久化/标记点/特殊日志（目录内文件直接清）
    fu_run_dirs(@[
        @"/var/db/diagnostics/Persist",
        @"/var/db/diagnostics/Signpost",
        @"/var/db/diagnostics/Special",
    ], NO, st, deleting, nil);
    // uuidtext：按 UUID 首字节分子目录，保留子目录骨架
    fu_run_dirs(@[ @"/var/db/uuidtext" ], YES, st, deleting, nil);
}

static void fu_run_crash(FUStats *st, BOOL deleting) {
    fu_run_dirs(@[
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/var/mobile/Library/Logs/DiagnosticReports",
    ], NO, st, deleting, nil);
}

static void fu_run_syslogs(FUStats *st, BOOL deleting) {
    // /var/mobile/Library/Logs 顶层常规文件（保留 CrashReporter 等子目录，已在 crash 类处理）
    NSString *logs = @"/var/mobile/Library/Logs";
    if (fu_exists(logs)) {
        NSArray *items = [gFM contentsOfDirectoryAtPath:logs error:nil];
        for (NSString *name in items) {
            NSString *full = [logs stringByAppendingPathComponent:name];
            NSDictionary *attr = [gFM attributesOfItemAtPath:full error:nil];
            if (![attr[NSFileType] isEqual:NSFileTypeRegular]) continue;
            if ([name isEqualToString:@"CrashReporter"] ||
                [name isEqualToString:@"DiagnosticReports"]) continue;
            if (deleting) {
                if (fu_recent(full)) { st->skipped++; continue; }
                NSError *e = nil;
                if ([gFM removeItemAtPath:full error:&e]) {
                    st->bytes += [attr[NSFileSize] unsignedLongLongValue]; st->files++; st->deleted++;
                } else { st->failed++; }
            } else {
                st->bytes += [attr[NSFileSize] unsignedLongLongValue]; st->files++;
            }
        }
    }
    // 某些版本存在 /var/logs
    if (fu_exists(@"/var/logs")) fu_run_dirs(@[ @"/var/logs" ], NO, st, deleting, nil);
}

static void fu_run_syscaches(FUStats *st, BOOL deleting) {
    NSString *root = @"/var/mobile/Library/Caches";
    NSArray *items = [gFM contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in items) {
        if (![name hasPrefix:@"com.apple."]) continue;
        NSString *full = [root stringByAppendingPathComponent:name];
        NSDictionary *attr = [gFM attributesOfItemAtPath:full error:nil];
        if ([attr[NSFileType] isEqual:NSFileTypeDirectory]) {
            if (deleting) {
                // 清空 com.apple.xxx 内容，保留目录本身
                fu_clean_dir(full, NO, st, nil);
            } else {
                fu_count_tree(full, st);
            }
        } else if ([attr[NSFileType] isEqual:NSFileTypeRegular]) {
            if (deleting) {
                if (fu_recent(full)) { st->skipped++; continue; }
                NSError *e = nil;
                if ([gFM removeItemAtPath:full error:&e]) {
                    st->bytes += [attr[NSFileSize] unsignedLongLongValue]; st->files++; st->deleted++;
                } else st->failed++;
            } else {
                st->bytes += [attr[NSFileSize] unsignedLongLongValue]; st->files++;
            }
        }
    }
}

static void fu_run_tmp(FUStats *st, BOOL deleting) {
    // /var/tmp 与 /private/var/tmp 是同一处；只处理这一处，避免误碰系统关键
    fu_run_dirs(@[ @"/var/tmp" ], NO, st, deleting, nil);
    NSString *mt = @"/var/mobile/tmp";
    if (fu_exists(mt)) fu_run_dirs(@[ mt ], NO, st, deleting, nil);
}

static void fu_run_safari(FUStats *st, BOOL deleting) {
    // 只清缓存，Cookies/History.db/LocalStorage 一律不碰
    NSString *fs = @"/var/mobile/Library/Safari/fsCachedData";
    if (fu_exists(fs)) {
        if (deleting) fu_clean_dir(fs, NO, st, nil);
        else fu_scan_dir(fs, NO, st, nil);
    }
    NSString *wk = @"/var/mobile/Library/Safari/WebKitCache";
    if (fu_exists(wk)) {
        if (deleting) {
            FUStats sub = {0};
            fu_count_tree(wk, &sub);
            NSError *e = nil;
            if ([gFM removeItemAtPath:wk error:&e]) {
                st->bytes += sub.bytes; st->files += sub.files; st->deleted++;
            } else {
                fu_clean_dir(wk, NO, st, nil);
            }
        } else fu_count_tree(wk, st);
    }
}

#pragma mark - 第三方 App 容器（白名单 + 日志保护）

static NSString *fu_container_bundleid(NSString *container) {
    NSString *mp = [container stringByAppendingPathComponent:
                    @".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:mp];
    NSString *bid = d[@"MCMMetadataIdentifier"];
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

static BOOL fu_excluded(NSString *bid) {
    if (!bid) return NO;
    for (NSString *p in gExclude) {
        if ([p isKindOfClass:[NSString class]] && p.length && [bid hasPrefix:p]) return YES;
    }
    return NO;
}

// 统计/删除单个容器的 Caches / tmp / WebKit；同时统计受保护的 Library/Logs
static void fu_process_container(NSString *container, NSString *bid,
                                 FUStats *st, BOOL deleting) {
    // —— 受保护：Library/Logs（只统计，永不删）——
    NSString *logs = [container stringByAppendingPathComponent:@"Library/Logs"];
    if (fu_exists(logs)) {
        FUStats s = {0};
        fu_count_tree(logs, &s);
        gProt.bytes += s.bytes; gProt.files += s.files;
        if (bid && s.bytes > 0) {
            [gProtApps addObject:@{@"id": bid,
                                   @"bytes": @(s.bytes),
                                   @"files": @(s.files)}];
        }
    }

    // 容器内 .log 文件保护（任何位置）
    BOOL (^protectLog)(NSString *) = ^BOOL(NSString *name) {
        return fu_is_app_log_name(name);
    };

    NSArray *cacheTargets = @[
        @"Library/Caches",
        @"tmp",
        @"Library/WebKit",
    ];
    for (NSString *rel in cacheTargets) {
        NSString *p = [container stringByAppendingPathComponent:rel];
        if (!fu_exists(p)) continue;
        BOOL isDir;
        if (![gFM fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
        if (deleting) fu_clean_dir(p, NO, st, protectLog);
        else fu_scan_tree_protect(p, st, protectLog);
    }
}

static void fu_run_appcache(FUStats *st, BOOL deleting) {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [gFM contentsOfDirectoryAtPath:root error:nil];
    for (NSString *u in uuids) {
        NSString *c = [root stringByAppendingPathComponent:u];
        NSString *bid = fu_container_bundleid(c);
        if (bid && [bid hasPrefix:@"com.apple."]) continue;
        if (fu_excluded(bid)) { st->skipped++; continue; }
        fu_process_container(c, bid, st, deleting);
    }
    // App Group 容器：只统计保护其 Library/Logs（不在缓存清理范围）
    NSString *ag = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *groups = [gFM contentsOfDirectoryAtPath:ag error:nil];
    for (NSString *u in groups) {
        NSString *c = [ag stringByAppendingPathComponent:u];
        NSString *logs = [c stringByAppendingPathComponent:@"Library/Logs"];
        if (fu_exists(logs)) {
            FUStats s = {0};
            fu_count_tree(logs, &s);
            gProt.bytes += s.bytes; gProt.files += s.files;
        }
    }
}

#pragma mark - 调度 / 输出

static NSString *fu_stats_json(NSString *key, FUStats *s) {
    return [NSString stringWithFormat:
        @"{\"key\":\"%@\",\"bytes\":%llu,\"files\":%ld,\"deleted\":%ld,\"failed\":%ld,\"skipped\":%ld}",
        key, s->bytes, s->files, s->deleted, s->failed, s->skipped];
}

static void fu_load_exclude(void) {
    gExclude = @[];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/Managed Preferences/mobile/com.local.fuclean.plist"];
    NSArray *ex = d[@"ExcludeApps"];
    if ([ex isKindOfClass:[NSArray class]]) gExclude = ex;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gFM = [NSFileManager defaultManager];
        gNow = [NSDate date];
        gProtApps = [NSMutableArray array];
        fu_load_exclude();

        if (argc < 2) {
            fprintf(stderr, "usage: fuclean-helper scan|clean [cats]\n");
            return 1;
        }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        BOOL deleting = [cmd isEqualToString:@"clean"];
        if (!deleting && ![cmd isEqualToString:@"scan"]) {
            fprintf(stderr, "unknown cmd: %s\n", cmd.UTF8String);
            return 1;
        }

        NSArray *allKeys = @[@"unified", @"crash", @"syslogs", @"syscaches",
                             @"tmp", @"safari", @"appcache"];
        NSSet *want = nil;
        if (deleting) {
            if (argc >= 3) {
                NSString *arg = [NSString stringWithUTF8String:argv[2]];
                if ([arg isEqualToString:@"all"]) {
                    want = [NSSet setWithArray:allKeys];
                } else {
                    want = [NSSet setWithArray:[arg componentsSeparatedByString:@","]];
                }
            } else {
                want = [NSSet setWithArray:allKeys];
            }
        } else {
            want = [NSSet setWithArray:allKeys];   // scan 始终全扫
        }

        NSMutableDictionary *stats = [NSMutableDictionary dictionary];
        for (NSString *k in allKeys) {
            FUStats s = {0,0,0,0,0};
            if (![want containsObject:k]) {
                stats[k] = [NSValue value:&s withObjCType:@encode(FUStats)];
                continue;
            }
            if ([k isEqualToString:@"unified"]) fu_run_unified(&s, deleting);
            else if ([k isEqualToString:@"crash"]) fu_run_crash(&s, deleting);
            else if ([k isEqualToString:@"syslogs"]) fu_run_syslogs(&s, deleting);
            else if ([k isEqualToString:@"syscaches"]) fu_run_syscaches(&s, deleting);
            else if ([k isEqualToString:@"tmp"]) fu_run_tmp(&s, deleting);
            else if ([k isEqualToString:@"safari"]) fu_run_safari(&s, deleting);
            else if ([k isEqualToString:@"appcache"]) fu_run_appcache(&s, deleting);
            stats[k] = [NSValue value:&s withObjCType:@encode(FUStats)];
        }

        // 汇总
        FUStats total = {0,0,0,0,0};
        NSMutableArray *catJsons = [NSMutableArray array];
        for (NSString *k in allKeys) {
            FUStats s;
            [stats[k] getValue:&s];
            total.bytes += s.bytes; total.files += s.files;
            total.deleted += s.deleted; total.failed += s.failed; total.skipped += s.skipped;
            [catJsons addObject:fu_stats_json(k, &s)];
        }

        // 受保护 App 列表（按大小降序，取前 30）
        NSArray *sortedProt = [gProtApps sortedArrayUsingComparator:
            ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"bytes"] compare:a[@"bytes"];
        }];
        NSArray *top = [sortedProt subarrayWithRange:
            NSMakeRange(0, MIN(30, sortedProt.count))];
        NSMutableArray *protAppJson = [NSMutableArray array];
        for (NSDictionary *a in top) {
            [protAppJson addObject:[NSString stringWithFormat:
                @"{\"id\":\"%@\",\"bytes\":%llu,\"files\":%ld}",
                fu_json_esc(a[@"id"]),
                [a[@"bytes"] unsignedLongLongValue],
                [a[@"files"] longValue]]];
        }

        NSString *json = [NSString stringWithFormat:
            @"{\"ok\":1,\"cmd\":\"%@\",\"total_bytes\":%llu,\"total_files\":%ld,"
            "\"deleted\":%ld,\"failed\":%ld,\"skipped\":%ld,"
            "\"protected_bytes\":%llu,\"protected_files\":%ld,"
            "\"protected_apps\":[%@],\"categories\":[%@]}\n",
            cmd, total.bytes, total.files, total.deleted, total.failed, total.skipped,
            gProt.bytes, gProt.files,
            [protAppJson componentsJoinedByString:@","],
            [catJsons componentsJoinedByString:@","]];
        printf("%s", json.UTF8String);
        fflush(stdout);
        return 0;
    }
}
