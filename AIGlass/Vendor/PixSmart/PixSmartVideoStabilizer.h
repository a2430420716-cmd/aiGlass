#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PixSmartVideoProgressBlock)(NSInteger current, NSInteger total);
typedef void (^PixSmartVideoCompletionBlock)(BOOL success, NSString *_Nullable errorMessage);

/// PixSmart 视频 EIS 封装。异步处理，失败时由调用方回退原视频。
@interface PixSmartVideoStabilizer : NSObject

+ (void)stabilizeVideoAtURL:(NSURL *)inputURL
                  outputURL:(NSURL *)outputURL
                   progress:(nullable PixSmartVideoProgressBlock)progress
                 completion:(PixSmartVideoCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
