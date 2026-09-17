#import "PixSmartVideoStabilizer.h"

#import <TargetConditionals.h>

#import "PixSmartImageStabilizer.h"
#import "../../../IOS/SXS_VideoStabilizePvDemo/videostabilization/EisData.h"
#import "../../../IOS/SXS_VideoStabilizePvDemo/videostabilization/VideoStabilizeProcessorGL.h"

@interface PixSmartVideoStabilizer () <VideoStabilizeProcessorDelegate>

@property (nonatomic, strong) VideoStabilizeProcessorGL *processor;
@property (nonatomic, copy, nullable) PixSmartVideoProgressBlock progressBlock;
@property (nonatomic, copy) PixSmartVideoCompletionBlock completionBlock;
@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, assign) BOOL completed;

@end

@implementation PixSmartVideoStabilizer

+ (NSMutableSet<PixSmartVideoStabilizer *> *)activeWorkers {
    static NSMutableSet<PixSmartVideoStabilizer *> *workers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        workers = [NSMutableSet set];
    });
    return workers;
}

+ (void)stabilizeVideoAtURL:(NSURL *)inputURL
                  outputURL:(NSURL *)outputURL
                   progress:(PixSmartVideoProgressBlock)progress
                 completion:(PixSmartVideoCompletionBlock)completion {
#if TARGET_OS_SIMULATOR
    completion(NO, @"模拟器不支持 PixSmart 视频 EIS");
#else
    if (![PixSmartImageStabilizer isAvailable]) {
        completion(NO, @"PixSmart 鉴权失败");
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:inputURL.path]) {
        completion(NO, @"视频输入文件不存在");
        return;
    }

    PixSmartVideoStabilizer *worker = [[PixSmartVideoStabilizer alloc] init];
    worker.progressBlock = progress;
    worker.completionBlock = completion;
    worker.outputURL = outputURL;

    EisData *data = [[EisData alloc] init];
    data.srcVideoPath = inputURL.path;
    data.dstVideoPath = outputURL.path;
    worker.processor = [[VideoStabilizeProcessorGL alloc] initWithEisData:data delegate:worker];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[self activeWorkers] addObject:worker];
        NSLog(@"[PixSmartVideoEIS] start input=%@ output=%@", inputURL.path, outputURL.path);
        [worker.processor startProcessing];

        // 与 Android 一致设 30 分钟上限，防止 SDK 异常时永久卡住导入任务。
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * 60 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                if (!worker.completed) {
                    NSLog(@"[PixSmartVideoEIS] timeout");
                    [worker finishWithSuccess:NO error:@"PixSmart 视频 EIS 处理超时"];
                }
            }
        );
    });
#endif
}

- (void)onProcess:(NSInteger)current total:(NSInteger)total {
    if (self.progressBlock) {
        self.progressBlock(current, total);
    }
}

- (void)onProcessFinish:(NSDictionary *)videoInfo {
    unsigned long long size = [[[NSFileManager defaultManager]
        attributesOfItemAtPath:self.outputURL.path error:nil] fileSize];
    BOOL valid = [[NSFileManager defaultManager] fileExistsAtPath:self.outputURL.path] && size > 0;
    NSLog(@"[PixSmartVideoEIS] finish valid=%d bytes=%llu info=%@", valid, size, videoInfo);
    [self finishWithSuccess:valid error:valid ? nil : @"EIS 输出视频为空"];
}

- (void)onProcessFailed:(NSDictionary *)errorInfo {
    NSString *message = errorInfo[@"error"] ?: @"PixSmart 视频 EIS 失败";
    NSLog(@"[PixSmartVideoEIS] failed: %@", message);
    [self finishWithSuccess:NO error:message];
}

- (void)finishWithSuccess:(BOOL)success error:(nullable NSString *)errorMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.completed) {
            return;
        }
        self.completed = YES;
        self.completionBlock(success, errorMessage);
        self.processor = nil;
        [[PixSmartVideoStabilizer activeWorkers] removeObject:self];
    });
}

@end
