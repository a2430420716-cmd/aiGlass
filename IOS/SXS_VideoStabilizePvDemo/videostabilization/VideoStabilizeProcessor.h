#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#import "EisData.h"

NS_ASSUME_NONNULL_BEGIN

@protocol VideoStabilizeProcessorDelegate <NSObject>
- (void)onProcessFinish:(NSDictionary *)videoInfo;
- (void)onProcess:(NSInteger)current total:(NSInteger)total;
- (void)onProcessFailed:(NSDictionary *)errorInfo;
@end

@interface VideoStabilizeProcessor : NSObject

@property (nonatomic, weak) id<VideoStabilizeProcessorDelegate> delegate;
@property (nonatomic, strong) EisData *eisData;

typedef NS_ENUM(NSInteger, ProcessorState) {
    ProcessorStateIdle,
    ProcessorStateInitializing,
    ProcessorStateProcessing,
    ProcessorStateStopped
};

// 初始化方法
- (instancetype)initWithEisData:(EisData *)eisData delegate:(id<VideoStabilizeProcessorDelegate>)delegate;

// 启动处理流程
- (void)startProcessing;

// 停止处理
- (void)stopProcessing;

@end

NS_ASSUME_NONNULL_END
