#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PixSmartVideoProgressBlock)(NSInteger current, NSInteger total);
typedef void (^PixSmartVideoCompletionBlock)(BOOL success, NSString *_Nullable errorMessage);

/// Cooperative cancellation. Completion follows native cleanup, never a live writer.
@interface PixSmartVideoStabilizationTask : NSObject
- (void)cancel;
@end

/// PixSmart 视频 EIS 封装。异步处理，失败时由调用方回退原视频。
@interface PixSmartVideoStabilizer : NSObject

+ (void)stabilizeVideoAtURL:(NSURL *)inputURL
                  outputURL:(NSURL *)outputURL
                   progress:(nullable PixSmartVideoProgressBlock)progress
                 completion:(PixSmartVideoCompletionBlock)completion;

/// First-generation Android profile. The existing entry point remains Gen2.
+ (PixSmartVideoStabilizationTask *)stabilizeGen1VideoAtURL:(NSURL *)inputURL
                    outputURL:(NSURL *)outputURL
                     progress:(nullable PixSmartVideoProgressBlock)progress
                   completion:(PixSmartVideoCompletionBlock)completion
    NS_SWIFT_NAME(stabilizeGen1Video(at:outputURL:progress:completion:));

@end

NS_ASSUME_NONNULL_END
