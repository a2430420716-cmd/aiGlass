#import "VideoStabilizeProcessor.h"

@implementation VideoStabilizeProcessor

- (instancetype)initWithEisData:(EisData *)eisData
                      delegate:(id<VideoStabilizeProcessorDelegate>)delegate {
    if (self = [super init]) {
        _eisData = eisData;
        _delegate = delegate;
    }
    return self;
}

- (void)startProcessing {
    // 基础实现（子类需重写）
}

- (void)stopProcessing {
    // 基础实现（子类需重写）
}

@end
