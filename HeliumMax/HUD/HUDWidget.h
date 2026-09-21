//
//  HUDWidget.h
//  Helium Max — Widget 数据引擎
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Widget ID
typedef NS_ENUM(NSInteger, HMWidgetID) {
    HMWidgetNone          = 0,
    HMWidgetDate          = 1,
    HMWidgetNetworkSpeed  = 2,
    HMWidgetDeviceTemp    = 3,
    HMWidgetBatteryDetail = 4,
    HMWidgetTime          = 5,
    HMWidgetText          = 6,
    HMWidgetBatteryPct    = 7,
    HMWidgetCharging      = 8,
    HMWidgetWeather       = 9,
    // —— 新增 widget ——
    HMWidgetCPU           = 10,
    HMWidgetMemory        = 11,
    HMWidgetDisk          = 12,
    HMWidgetUptime        = 13,
    HMWidgetIPAddress     = 14,
    HMWidgetBrightness    = 15,
    HMWidgetCarrier       = 16,
    HMWidgetWiFi          = 17,
    HMWidgetVolume        = 18,
    HMWidgetTotalTraffic  = 19,
};

@interface HMWidget : NSObject

// 返回 widget 的显示字符串（含颜色信息的 NSAttributedString）
+ (nullable NSAttributedString *)stringForWidgetID:(HMWidgetID)wid
                                          options:(nullable NSDictionary *)opts
                                         fontSize:(double)fontSize
                                        textColor:(UIColor *)color;

// 所有可用 widget 列表（ID + 中文名 + 描述）
+ (NSArray<NSDictionary *> *)allWidgets;

// widget 中文名称
+ (NSString *)nameForWidgetID:(HMWidgetID)wid;

@end

NS_ASSUME_NONNULL_END
