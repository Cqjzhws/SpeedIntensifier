// resset — ResSetterMax TSRootBinary
// 以 root 权限运行（TrollStore TSRootBinaries 机制）
// 用法:
//   resset <canvas_height> <canvas_width>  → 写 plist + respring
//   resset restore                         → 恢复备份 + respring
//   resset respring                        → 仅 respring
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <spawn.h>

#define PLIST_PATH  @"/var/mobile/Library/Preferences/com.apple.iokit.IOMobileGraphicsFamily.plist"
#define BACKUP_PATH @"/var/tmp/com.ressettermax.backup.plist"

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

static void writePlist(int height, int width) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 备份原始 plist（仅首次）
    if (![fm fileExistsAtPath:BACKUP_PATH] && [fm fileExistsAtPath:PLIST_PATH]) {
        [fm copyItemAtPath:PLIST_PATH toPath:BACKUP_PATH error:nil];
    }
    // 写入新 plist（仅 canvas_height + canvas_width）
    NSDictionary *d = @{
        @"canvas_height" : @(height),
        @"canvas_width"  : @(width),
    };
    [d writeToFile:PLIST_PATH atomically:YES];
    NSLog(@"[resset] wrote plist h=%d w=%d", height, width);
}

static void restorePlist(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:BACKUP_PATH]) {
        if ([fm fileExistsAtPath:PLIST_PATH]) {
            [fm removeItemAtPath:PLIST_PATH error:nil];
        }
        [fm copyItemAtPath:BACKUP_PATH toPath:PLIST_PATH error:nil];
        NSLog(@"[resset] restored from backup");
    } else {
        // 无备份，删除 plist（恢复系统默认）
        [fm removeItemAtPath:PLIST_PATH error:nil];
        NSLog(@"[resset] no backup, removed plist");
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "restore") != 0) {
            // resset <height> <width>
            int h = atoi(argv[1]);
            int w = atoi(argv[2]);
            if (h > 0 && w > 0) {
                writePlist(h, w);
                killSpringBoard();
            }
        } else if (argc == 2 && strcmp(argv[1], "restore") == 0) {
            restorePlist();
            killSpringBoard();
        } else {
            // 默认 respring
            killSpringBoard();
        }
    }
    return 0;
}
