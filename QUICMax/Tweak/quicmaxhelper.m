// quicmaxhelper — QUICMax TSRootBinary (以 root 运行)
// 用法:
//   quicmaxhelper replace <src> <dst> <perm-octal> <owner> <group>
//        原子替换 dst 为 src, chmod/chown dst
//   quicmaxhelper lock <path>     / unlock <path>
//        chflags SF_IMMUTABLE / 清除
//   quicmaxhelper backup <src> <dst>     以 root 复制
//   quicmaxhelper install-profile <mobileconfig-path> <provider-name>
//        复制 .mobileconfig 到 ConfigurationProfiles 目录, 写入 provider 标记
//   quicmaxhelper remove-profile          移除 QUIC Max DoH 配置
//   quicmaxhelper list-profiles           输出 "INSTALLED:<provider>" 或 "NONE"
//   quicmaxhelper respring                killall SpringBoard
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <pwd.h>
#import <grp.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <stdlib.h>
#import <sys/sysctl.h>

// SF_IMMUTABLE on macOS/iOS = 0x00000002 (system immutable, root-only to clear)
#ifndef SF_IMMUTABLE
#define SF_IMMUTABLE 0x00000002
#endif

#define PROFILES_DIR @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles"
#define MARKER_PATH  @"/var/tmp/com.local.quicmax.doh.provider"
// .mobileconfig 文件名前缀 (UUID 由 main app 生成的 PayloadUUID, 但安装时我们用固定名便于卸载)
#define PROFILE_FILENAME @"QUICMax-DoH.mobileconfig"

static int setPermOwner(NSString *path, int perm, NSString *owner, NSString *group) {
    chmod(path.UTF8String, (mode_t)perm);
    // lookup uid/gid
    struct passwd *pw = getpwnam(owner.UTF8String);
    struct group  *gr = getgrnam(group.UTF8String);
    uid_t uid = pw ? pw->pw_uid : 0;
    gid_t gid = gr ? gr->gr_gid : 0;
    if (chown(path.UTF8String, uid, gid) != 0) {
        fprintf(stderr, "chown failed: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int doReplace(NSString *src, NSString *dst, int perm, NSString *owner, NSString *group) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) {
        fprintf(stderr, "src not found: %s\n", src.UTF8String);
        return 1;
    }
    // 清除 dst 上的 SF_IMMUTABLE (如果存在)
    chflags(dst.UTF8String, 0);
    // 删除 dst (若存在)
    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:nil]) {
            fprintf(stderr, "remove dst failed\n");
            return 2;
        }
    }
    // 移动 src → dst
    NSError *err = nil;
    if (![fm moveItemAtPath:src toPath:dst error:&err]) {
        // move 跨文件系统会失败, 回退到 copy + remove
        if (![fm copyItemAtPath:src toPath:dst error:&err]) {
            fprintf(stderr, "copy failed: %s\n", err.localizedDescription.UTF8String);
            return 3;
        }
        [fm removeItemAtPath:src error:nil];
    }
    if (setPermOwner(dst, perm, owner, group) != 0) return 4;
    fprintf(stdout, "replaced %s\n", dst.UTF8String);
    return 0;
}

static int doLock(NSString *path, BOOL lock) {
    if (lock) {
        // 先 chflags SF_IMMUTABLE
        if (chflags(path.UTF8String, SF_IMMUTABLE) != 0) {
            fprintf(stderr, "chflags SF_IMMUTABLE failed: %s\n", strerror(errno));
            return 1;
        }
        fprintf(stdout, "locked %s\n", path.UTF8String);
    } else {
        if (chflags(path.UTF8String, 0) != 0) {
            fprintf(stderr, "chflags clear failed: %s\n", strerror(errno));
            return 1;
        }
        fprintf(stdout, "unlocked %s\n", path.UTF8String);
    }
    return 0;
}

static int doBackup(NSString *src, NSString *dst) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) {
        fprintf(stderr, "src not found: %s\n", src.UTF8String);
        return 1;
    }
    // 确保 dst 父目录存在
    NSString *parent = [dst stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parent]) {
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // 清除已有备份
    if ([fm fileExistsAtPath:dst]) [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:src toPath:dst error:&err]) {
        fprintf(stderr, "backup copy failed: %s\n", err.localizedDescription.UTF8String);
        return 2;
    }
    chmod(dst.UTF8String, 0644);
    chown(dst.UTF8String, 0, 0);
    fprintf(stdout, "backed up %s → %s\n", src.UTF8String, dst.UTF8String);
    return 0;
}

static int doInstallProfile(NSString *srcPath, NSString *provider) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:srcPath]) {
        fprintf(stderr, "mobileconfig not found: %s\n", srcPath.UTF8String);
        return 1;
    }
    // 确保 profiles 目录存在
    if (![fm fileExistsAtPath:PROFILES_DIR]) {
        [fm createDirectoryAtPath:PROFILES_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *dst = [PROFILES_DIR stringByAppendingPathComponent:PROFILE_FILENAME];
    // 覆盖已有
    if ([fm fileExistsAtPath:dst]) [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:srcPath toPath:dst error:&err]) {
        fprintf(stderr, "install copy failed: %s\n", err.localizedDescription.UTF8String);
        return 2;
    }
    chmod(dst.UTF8String, 0644);
    chown(dst.UTF8String, 0, 0);
    // 写 provider 标记
    [provider writeToFile:MARKER_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(MARKER_PATH.UTF8String, 0644);
    chown(MARKER_PATH.UTF8String, 0, 0);
    fprintf(stdout, "installed profile: %s (provider=%s)\n", dst.UTF8String, provider.UTF8String);
    // 提示: profiled 自动加载新配置; 也可发信号
    return 0;
}

static int doRemoveProfile(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dst = [PROFILES_DIR stringByAppendingPathComponent:PROFILE_FILENAME];
    BOOL removed = NO;
    if ([fm fileExistsAtPath:dst]) {
        removed = [fm removeItemAtPath:dst error:nil];
    }
    if ([fm fileExistsAtPath:MARKER_PATH]) {
        [fm removeItemAtPath:MARKER_PATH error:nil];
    }
    fprintf(stdout, "%s\n", removed ? "removed" : "not-installed");
    return removed ? 0 : 0; // 返回 0 即使未安装
}

static int doListProfiles(void) {
    NSString *dst = [PROFILES_DIR stringByAppendingPathComponent:PROFILE_FILENAME];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst] && [fm fileExistsAtPath:MARKER_PATH]) {
        NSString *provider = [NSString stringWithContentsOfFile:MARKER_PATH encoding:NSUTF8StringEncoding error:nil];
        if (provider.length) {
            fprintf(stdout, "INSTALLED:%s\n", provider.UTF8String);
            return 0;
        }
    }
    fprintf(stdout, "NONE\n");
    return 0;
}

static void killSpringBoard(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    if (size == 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) { free(procs); return; }
    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "SpringBoard") == 0) {
            kill(procs[i].kp_proc.p_pid, SIGTERM);
            break;
        }
    }
    free(procs);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <mode> [args]\n", argv[0]);
            return 64;
        }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];

        if ([mode isEqualToString:@"replace"] && argc == 7) {
            NSString *src = [NSString stringWithUTF8String:argv[2]];
            NSString *dst = [NSString stringWithUTF8String:argv[3]];
            int perm = (int)strtol(argv[4], NULL, 8);
            NSString *owner = [NSString stringWithUTF8String:argv[5]];
            NSString *group = [NSString stringWithUTF8String:argv[6]];
            return doReplace(src, dst, perm, owner, group);
        }
        if ([mode isEqualToString:@"lock"] && argc == 3) {
            return doLock([NSString stringWithUTF8String:argv[2]], YES);
        }
        if ([mode isEqualToString:@"unlock"] && argc == 3) {
            return doLock([NSString stringWithUTF8String:argv[2]], NO);
        }
        if ([mode isEqualToString:@"backup"] && argc == 4) {
            return doBackup([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        }
        if ([mode isEqualToString:@"install-profile"] && argc == 4) {
            return doInstallProfile([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        }
        if ([mode isEqualToString:@"remove-profile"] && argc == 2) {
            return doRemoveProfile();
        }
        if ([mode isEqualToString:@"list-profiles"] && argc == 2) {
            return doListProfiles();
        }
        if ([mode isEqualToString:@"respring"] && argc == 2) {
            killSpringBoard();
            return 0;
        }
        fprintf(stderr, "unknown mode or wrong arg count: %s\n", mode.UTF8String);
        return 64;
    }
}
