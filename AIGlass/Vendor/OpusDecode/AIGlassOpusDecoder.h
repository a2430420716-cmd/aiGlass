#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AIGlassOpusDecoder : NSObject
- (nullable instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels error:(NSError **)error;
- (nullable NSData *)decodeFrame:(NSData *)frame error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
