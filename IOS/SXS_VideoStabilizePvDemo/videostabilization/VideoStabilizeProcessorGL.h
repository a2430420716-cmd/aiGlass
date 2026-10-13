#import "VideoStabilizeProcessor.h"

@interface VideoStabilizeProcessorGL : VideoStabilizeProcessor

/// Defaults to NO. Gen1 uses Android's 240/max-size, BT709 full-range profile.
/// Set before startProcessing; do not change during processing.
@property (nonatomic) BOOL useGen1Configuration;

@end
