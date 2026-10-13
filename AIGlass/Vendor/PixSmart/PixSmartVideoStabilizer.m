#import "PixSmartVideoStabilizer.h"

#import <TargetConditionals.h>

#import "PixSmartImageStabilizer.h"
#import "../../../IOS/SXS_VideoStabilizePvDemo/videostabilization/EisData.h"
#import "../../../IOS/SXS_VideoStabilizePvDemo/videostabilization/VideoStabilizeProcessorGL.h"

@interface PixSmartVideoStabilizationTask () {
    BOOL _cancelled;
    __weak VideoStabilizeProcessorGL *_processor;
}
- (BOOL)isCancelled;
- (void)attachProcessor:(VideoStabilizeProcessorGL *)processor;
@end

@implementation PixSmartVideoStabilizationTask
- (void)cancel {
    VideoStabilizeProcessorGL *processor;
    @synchronized (self) { _cancelled = YES; processor = _processor; }
    [processor stopProcessing];
}
- (BOOL)isCancelled {
    @synchronized (self) { return _cancelled; }
}
- (void)attachProcessor:(VideoStabilizeProcessorGL *)processor {
    BOOL cancelled;
    @synchronized (self) { _processor = processor; cancelled = _cancelled; }
    if (cancelled) [processor stopProcessing];
}
@end

@interface PixSmartVideoStabilizer () <VideoStabilizeProcessorDelegate>

@property (nonatomic, strong) VideoStabilizeProcessorGL *processor;
@property (nonatomic, copy, nullable) PixSmartVideoProgressBlock progressBlock;
@property (nonatomic, copy) PixSmartVideoCompletionBlock completionBlock;
@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, assign) BOOL completed;
@property (nonatomic, assign) BOOL usesGen1Configuration;
@property (nonatomic, assign) BOOL timedOut;
@property (nonatomic, strong, nullable) PixSmartVideoStabilizationTask *cancellationTask;

+ (void)stabilizeVideoAtURL:(NSURL *)inputURL
                outputURL:(NSURL *)outputURL
     useGen1Configuration:(BOOL)useGen1Configuration
         cancellationTask:(nullable PixSmartVideoStabilizationTask *)cancellationTask
                 progress:(nullable PixSmartVideoProgressBlock)progress
               completion:(PixSmartVideoCompletionBlock)completion;

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
    [self stabilizeVideoAtURL:inputURL outputURL:outputURL useGen1Configuration:NO cancellationTask:nil progress:progress completion:completion];
}

+ (PixSmartVideoStabilizationTask *)stabilizeGen1VideoAtURL:(NSURL *)inputURL
                    outputURL:(NSURL *)outputURL
                     progress:(PixSmartVideoProgressBlock)progress
                   completion:(PixSmartVideoCompletionBlock)completion {
    PixSmartVideoStabilizationTask *task = [[PixSmartVideoStabilizationTask alloc] init];
    // License activation can involve network I/O; a local recovery must not block UI.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self stabilizeVideoAtURL:inputURL outputURL:outputURL useGen1Configuration:YES cancellationTask:task progress:progress completion:completion];
    });
    return task;
}

+ (void)stabilizeVideoAtURL:(NSURL *)inputURL
                outputURL:(NSURL *)outputURL
     useGen1Configuration:(BOOL)useGen1Configuration
         cancellationTask:(PixSmartVideoStabilizationTask *)cancellationTask
                 progress:(PixSmartVideoProgressBlock)progress
               completion:(PixSmartVideoCompletionBlock)completion {
#if TARGET_OS_SIMULATOR
    completion(NO, @"模拟器不支持 PixSmart 视频 EIS");
#else
    if ([cancellationTask isCancelled]) {
        completion(NO, @"视频防抖任务已取消");
        return;
    }
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
    worker.usesGen1Configuration = useGen1Configuration;
    worker.cancellationTask = cancellationTask;

    EisData *data = [[EisData alloc] init];
    data.srcVideoPath = inputURL.path;
    data.dstVideoPath = outputURL.path;
    worker.processor = [[VideoStabilizeProcessorGL alloc] initWithEisData:data delegate:worker];
    worker.processor.useGen1Configuration = useGen1Configuration;
    [cancellationTask attachProcessor:worker.processor];

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([cancellationTask isCancelled]) {
            completion(NO, @"视频防抖任务已取消");
            return;
        }
        // Do not overlap a Gen1 session with another video engine. A timed-out
        // Gen1 worker stays registered until the native writer has actually stopped.
        BOOL gen1WorkerActive = NO;
        for (PixSmartVideoStabilizer *active in [self activeWorkers]) {
            if (active.usesGen1Configuration) { gen1WorkerActive = YES; break; }
        }
        if ((useGen1Configuration && [self activeWorkers].count > 0) || gen1WorkerActive) {
            completion(NO, @"另一个视频防抖任务正在处理");
            return;
        }
        [[self activeWorkers] addObject:worker];
        NSLog(@"[PixSmartVideoEIS] start generation=%@ input=%@ output=%@", useGen1Configuration ? @"gen1" : @"gen2", inputURL.path, outputURL.path);
        [worker.processor startProcessing];

        // Android uses a 30-minute deadline. Gen1 requests cooperative cancellation
        // and waits for native cleanup; an in-flight SDK call cannot be force-killed.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * 60 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                if (!worker.completed) {
                    NSLog(@"[PixSmartVideoEIS] timeout");
                    if (worker.usesGen1Configuration) {
                        worker.timedOut = YES;
                        [worker.processor stopProcessing];
                    } else {
                        [worker finishWithSuccess:NO error:@"PixSmart 视频 EIS 处理超时"];
                    }
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
        BOOL cancelled = [self.cancellationTask isCancelled];
        self.completionBlock(self.timedOut || cancelled ? NO : success,
                             self.timedOut ? @"PixSmart 视频 EIS 处理超时" : (cancelled ? @"视频防抖任务已取消" : errorMessage));
        self.processor = nil;
        [[PixSmartVideoStabilizer activeWorkers] removeObject:self];
    });
}

@end
