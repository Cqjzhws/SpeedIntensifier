//
//  HUDWidget.m
//  Helium Max — Widget 数据引擎
//
#import "HUDWidget.h"
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/sysctl.h>
#import <sys/statvfs.h>
#import <mach/mach.h>
#import <mach/host_info.h>
#import <mach/mach_host.h>
#import <IOKit/IOKitLib.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - 网速状态
static uint64_t prevInBytes = 0, prevOutBytes = 0;
static NSTimeInterval prevSpeedTime = 0;

#pragma mark - 电池信息
static NSDictionary *getBatteryInfo(void) {
    CFDictionaryRef matching = IOServiceMatching("IOPMPowerSource");
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    if (!service) return nil;
    CFMutableDictionaryRef prop = NULL;
    IORegistryEntryCreateCFProperties(service, &prop, NULL, 0);
    IOObjectRelease(service);
    return (__bridge_transfer NSDictionary *)prop;
}

#pragma mark - 网速
static void getNetBytes(uint64_t *inB, uint64_t *outB) {
    struct ifaddrs *ifa_list = NULL;
    *inB = 0; *outB = 0;
    if (getifaddrs(&ifa_list) == -1) return;
    for (struct ifaddrs *ifa = ifa_list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr || !ifa->ifa_data) continue;
        if (AF_LINK != ifa->ifa_addr->sa_family) continue;
        if (strncmp(ifa->ifa_name, "en", 2) && strncmp(ifa->ifa_name, "pdp_ip", 6)) continue;
        struct if_data *d = (struct if_data *)ifa->ifa_data;
        *inB  += d->ifi_ibytes;
        *outB += d->ifi_obytes;
    }
    freeifaddrs(ifa_list);
}

static NSString *formatSpeed(uint64_t bytesPerSec, BOOL bits) {
    double v = bits ? bytesPerSec * 8.0 : (double)bytesPerSec;
    if (bits) {
        if (v < 1000)      return [NSString stringWithFormat:@"%.0f b/s", v];
        if (v < 1000000)   return [NSString stringWithFormat:@"%.0f Kb/s", v/1000];
        if (v < 1e9)       return [NSString stringWithFormat:@"%.2f Mb/s", v/1e6];
        return [NSString stringWithFormat:@"%.2f Gb/s", v/1e9];
    } else {
        if (v < 1024)      return [NSString stringWithFormat:@"%.0f B/s", v];
        if (v < 1048576)   return [NSString stringWithFormat:@"%.0f KB/s", v/1024];
        if (v < 1073741824) return [NSString stringWithFormat:@"%.2f MB/s", v/1048576];
        return [NSString stringWithFormat:@"%.2f GB/s", v/1073741824];
    }
}

#pragma mark - CPU
static double cpuUsage(void) {
    kern_return_t kr;
    mach_msg_type_number_t count;
    host_cpu_load_info_data_t load;
    count = HOST_CPU_LOAD_INFO_COUNT;
    kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count);
    if (kr != KERN_SUCCESS) return 0;
    static uint64_t prevUser=0, prevSys=0, prevIdle=0, prevNice=0;
    uint64_t user = load.cpu_ticks[CPU_STATE_USER];
    uint64_t sys  = load.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t idle = load.cpu_ticks[CPU_STATE_IDLE];
    uint64_t nice = load.cpu_ticks[CPU_STATE_NICE];
    uint64_t total = (user - prevUser) + (sys - prevSys) + (idle - prevIdle) + (nice - prevNice);
    uint64_t used  = (user - prevUser) + (sys - prevSys) + (nice - prevNice);
    prevUser=user; prevSys=sys; prevIdle=idle; prevNice=nice;
    if (total == 0) return 0;
    return (double)used / (double)total * 100.0;
}

#pragma mark - 内存
static NSString *memoryInfo(void) {
    mach_port_t host = mach_host_self();
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
        return @"?? MB";
    uint64_t page = vm_kernel_page_size ?: 16384;
    uint64_t active   = (uint64_t)vm.active_count   * page;
    uint64_t wired    = (uint64_t)vm.wire_count     * page;
    uint64_t compressed = (uint64_t)vm.compressor_page_count * page;
    uint64_t used = active + wired + compressed;
    uint64_t total = [NSProcessInfo processInfo].physicalMemory;
    double usedMB = used / 1048576.0;
    double totalMB = total / 1048576.0;
    return [NSString stringWithFormat:@"%.0f/%.0f MB", usedMB, totalMB];
}

#pragma mark - 磁盘
static NSString *diskFree(void) {
    struct statvfs st;
    if (statvfs("/var", &st) != 0) return @"?? GB";
    uint64_t free = (uint64_t)st.f_bavail * st.f_frsize;
    uint64_t total = (uint64_t)st.f_blocks * st.f_frsize;
    return [NSString stringWithFormat:@"%.1f/%.1f GB", free/1e9, total/1e9];
}

#pragma mark - Uptime
static NSString *uptimeStr(void) {
    struct timeval boottime;
    size_t len = sizeof(boottime);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &boottime, &len, NULL, 0) != 0) return @"??";
    NSTimeInterval up = [[NSDate date] timeIntervalSince1970] - boottime.tv_sec;
    long days = (long)(up / 86400);
    long hours = ((long)up % 86400) / 3600;
    long mins = ((long)up % 3600) / 60;
    if (days > 0) return [NSString stringWithFormat:@"%ld天%ld时", days, hours];
    return [NSString stringWithFormat:@"%ld时%ld分", hours, mins];
}

#pragma mark - IP 地址
static NSString *localIP(void) {
    struct ifaddrs *ifa_list = NULL;
    NSString *ip = nil;
    if (getifaddrs(&ifa_list) == 0) {
        for (struct ifaddrs *ifa = ifa_list; ifa; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr->sa_family == AF_INET &&
                strcmp(ifa->ifa_name, "en0") == 0) {
                char buf[INET_ADDRSTRLEN];
                struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
                inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
                ip = [NSString stringWithUTF8String:buf];
                break;
            }
        }
        freeifaddrs(ifa_list);
    }
    return ip ?: @"无网";
}

#pragma mark - 运营商
static NSString *carrierName(void) {
    CTTelephonyNetworkInfo *info = [[CTTelephonyNetworkInfo alloc] init];
    CTCarrier *c = info.subscriberCellularProvider;
    return c.carrierName.length ? c.carrierName : @"无SIM";
}

#pragma mark - Widget 渲染
@implementation HMWidget

+ (NSArray<NSDictionary *> *)allWidgets {
    return @[
        @{@"id":@(HMWidgetDate),          @"name":@"日期",           @"desc":@"当前日期"},
        @{@"id":@(HMWidgetTime),          @"name":@"时间",           @"desc":@"当前时间"},
        @{@"id":@(HMWidgetNetworkSpeed),  @"name":@"网速",           @"desc":@"实时上下行速率"},
        @{@"id":@(HMWidgetTotalTraffic),  @"name":@"流量",           @"desc":@"累计下载/上传"},
        @{@"id":@(HMWidgetDeviceTemp),    @"name":@"温度",           @"desc":@"电池温度"},
        @{@"id":@(HMWidgetBatteryDetail), @"name":@"电池功率",       @"desc":@"充电功率(W)"},
        @{@"id":@(HMWidgetBatteryPct),    @"name":@"电量",           @"desc":@"电池百分比"},
        @{@"id":@(HMWidgetCharging),      @"name":@"充电图标",       @"desc":@"充电状态闪电"},
        @{@"id":@(HMWidgetCPU),           @"name":@"CPU",            @"desc":@"CPU 使用率"},
        @{@"id":@(HMWidgetMemory),        @"name":@"内存",           @"desc":@"已用/总量"},
        @{@"id":@(HMWidgetDisk),          @"name":@"磁盘",           @"desc":@"可用/总量"},
        @{@"id":@(HMWidgetUptime),        @"name":@"运行时长",       @"desc":@"开机至今"},
        @{@"id":@(HMWidgetIPAddress),     @"name":@"IP 地址",        @"desc":@"局域网 IP"},
        @{@"id":@(HMWidgetBrightness),    @"name":@"亮度",           @"desc":@"屏幕亮度"},
        @{@"id":@(HMWidgetCarrier),       @"name":@"运营商",         @"desc":@"SIM 运营商"},
        @{@"id":@(HMWidgetVolume),        @"name":@"音量",           @"desc":@"系统音量"},
        @{@"id":@(HMWidgetText),          @"name":@"自定义文本",     @"desc":@"任意文字"},
    ];
}

+ (NSString *)nameForWidgetID:(HMWidgetID)wid {
    for (NSDictionary *w in [self allWidgets]) {
        if ([w[@"id"] integerValue] == wid) return w[@"name"];
    }
    return @"未知";
}

+ (NSAttributedString *)stringForWidgetID:(HMWidgetID)wid
                                  options:(NSDictionary *)opts
                                 fontSize:(double)fontSize
                                textColor:(UIColor *)color {
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium],
                             NSForegroundColorAttributeName: color };
    NSString *str = nil;

    switch (wid) {
        case HMWidgetDate: {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = opts[@"dateFormat"] ?: @"MM-dd EEE";
            str = [f stringFromDate:[NSDate date]];
            break;
        }
        case HMWidgetTime: {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = opts[@"timeFormat"] ?: @"HH:mm:ss";
            str = [f stringFromDate:[NSDate date]];
            break;
        }
        case HMWidgetNetworkSpeed: {
            uint64_t inB=0, outB=0;
            getNetBytes(&inB, &outB);
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            NSTimeInterval dt = (prevSpeedTime > 0) ? (now - prevSpeedTime) : 1.0;
            if (dt < 0.1) dt = 0.1;
            uint64_t down = (inB > prevInBytes) ? (inB - prevInBytes) / (uint64_t)dt : 0;
            uint64_t up   = (outB > prevOutBytes) ? (outB - prevOutBytes) / (uint64_t)dt : 0;
            prevInBytes = inB; prevOutBytes = outB; prevSpeedTime = now;
            BOOL bits = [opts[@"bits"] boolValue];
            str = [NSString stringWithFormat:@"↓%@ ↑%@", formatSpeed(down, bits), formatSpeed(up, bits)];
            break;
        }
        case HMWidgetTotalTraffic: {
            uint64_t inB=0, outB=0;
            getNetBytes(&inB, &outB);
            str = [NSString stringWithFormat:@"↓%.1fGB ↑%.1fGB", inB/1e9, outB/1e9];
            break;
        }
        case HMWidgetDeviceTemp: {
            NSDictionary *bi = getBatteryInfo();
            double t = [bi[@"Temperature"] doubleValue] / 100.0;
            if (t > 0) {
                BOOL f = [opts[@"fahrenheit"] boolValue];
                str = f ? [NSString stringWithFormat:@"%.0f°F", t*9/5+32] : [NSString stringWithFormat:@"%.0f°C", t];
            } else str = @"--°C";
            break;
        }
        case HMWidgetBatteryDetail: {
            NSDictionary *bi = getBatteryInfo();
            NSInteger type = [opts[@"batteryType"] integerValue];
            if (type == 0) {
                int w = [bi[@"AdapterDetails"][@"Watts"] intValue];
                str = [NSString stringWithFormat:@"%dW", w];
            } else if (type == 1) {
                double c = [bi[@"AdapterDetails"][@"Current"] doubleValue];
                str = [NSString stringWithFormat:@"%.0fmA", c];
            } else if (type == 2) {
                double a = [bi[@"Amperage"] doubleValue];
                str = [NSString stringWithFormat:@"%.0fmA", a];
            } else {
                str = [bi[@"CycleCount"] stringValue];
            }
            break;
        }
        case HMWidgetBatteryPct: {
            [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
            str = [NSString stringWithFormat:@"%d%%", (int)([UIDevice currentDevice].batteryLevel * 100)];
            break;
        }
        case HMWidgetCharging: {
            [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
            if ([UIDevice currentDevice].batteryState != UIDeviceBatteryStateUnplugged) {
                NSTextAttachment *a = [[NSTextAttachment alloc] init];
                UIImage *img = [UIImage systemImageNamed:@"bolt.fill"
                                       withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:fontSize]];
                a.image = [img imageWithTintColor:color];
                return [NSAttributedString attributedStringWithAttachment:a];
            }
            str = @"";
            break;
        }
        case HMWidgetCPU: {
            str = [NSString stringWithFormat:@"CPU %.0f%%", cpuUsage()];
            break;
        }
        case HMWidgetMemory: {
            str = memoryInfo();
            break;
        }
        case HMWidgetDisk: {
            str = diskFree();
            break;
        }
        case HMWidgetUptime: {
            str = uptimeStr();
            break;
        }
        case HMWidgetIPAddress: {
            str = localIP();
            break;
        }
        case HMWidgetBrightness: {
            str = [NSString stringWithFormat:@"☀️%d%%", (int)([UIScreen mainScreen].brightness * 100)];
            break;
        }
        case HMWidgetCarrier: {
            str = carrierName();
            break;
        }
        case HMWidgetVolume: {
            AVAudioSession *s = [AVAudioSession sharedInstance];
            str = [NSString stringWithFormat:@"🔊%d%%", (int)(s.outputVolume * 100)];
            break;
        }
        case HMWidgetText: {
            str = opts[@"text"] ?: @"";
            break;
        }
        case HMWidgetWeather:
        case HMWidgetNone:
        default:
            str = nil;
            break;
    }
    if (!str) return nil;
    return [[NSAttributedString alloc] initWithString:str attributes:attrs];
}

@end
