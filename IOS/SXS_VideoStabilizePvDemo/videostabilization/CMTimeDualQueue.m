#import "CMTimeDualQueue.h"

@implementation CMTimeDualQueue {
    NSMutableArray<NSValue *> *_ptsQueue;
    NSMutableArray<NSValue *> *_durationQueue;
}

- (instancetype)init {
    if (self = [super init]) {
        _ptsQueue = [NSMutableArray array];
        _durationQueue = [NSMutableArray array];
    }
    return self;
}

- (void)enqueuePTS:(CMTime)pts duration:(CMTime)duration {
    [_ptsQueue addObject:[NSValue valueWithCMTime:pts]];
    [_durationQueue addObject:[NSValue valueWithCMTime:duration]];
}

- (CMTime)dequeuePTS {
    if (_ptsQueue.count == 0) return kCMTimeInvalid;
    CMTime value = [_ptsQueue.firstObject CMTimeValue];
    [_ptsQueue removeObjectAtIndex:0];
    return value;
}

- (CMTime)dequeueDuration {
    if (_durationQueue.count == 0) return kCMTimeInvalid;
    CMTime value = [_durationQueue.firstObject CMTimeValue];
    [_durationQueue removeObjectAtIndex:0];
    return value;
}

- (BOOL)isEmpty {
    return _ptsQueue.count == 0 || _durationQueue.count == 0;
}
@end
