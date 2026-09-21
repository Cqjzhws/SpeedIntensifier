//
//  HUDManager.h
//  Helium Max — HUD 窗口管理
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "HUDWidget.h"

NS_ASSUME_NONNULL_BEGIN

@interface HUDManager : NSObject

+ (instancetype)shared;

// 启动 HUD 窗口
- (void)start;
// 停止
- (void)stop;
// 重新加载配置
- (void)reloadConfig;

@end

NS_ASSUME_NONNULL_END
