#import "AIGlassOpusDecoder.h"
#include "opus.h"

@interface AIGlassOpusDecoder () {
    OpusDecoder *_decoder;
    int _sampleRate;
    int _channels;
}
@end

@implementation AIGlassOpusDecoder

- (nullable instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }
    int err = OPUS_OK;
    _decoder = opus_decoder_create(sampleRate, channels, &err);
    if (!_decoder || err != OPUS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIGlassOpus" code:err userInfo:@{
                NSLocalizedDescriptionKey: @"创建 Opus decoder failed"
            }];
        }
        return nil;
    }
    _sampleRate = sampleRate;
    _channels = channels;
    return self;
}

- (void)dealloc {
    if (_decoder) {
        opus_decoder_destroy(_decoder);
        _decoder = NULL;
    }
}

- (nullable NSData *)decodeFrame:(NSData *)frame error:(NSError **)error {
    if (frame.length == 0) {
        return [NSData data];
    }
    // An Opus packet may contain up to 120 ms, including multiple frames.
    // A 20 ms output capacity rejects valid longer packets (OPUS_BUFFER_TOO_SMALL).
    int frameSamples = _sampleRate * 120 / 1000;
    if (frameSamples <= 0) {
        frameSamples = 320;
    }
    NSMutableData *pcm = [NSMutableData dataWithLength:(NSUInteger)frameSamples * (NSUInteger)_channels * sizeof(opus_int16)];
    int samples = opus_decode(
        _decoder,
        frame.bytes,
        (opus_int32)frame.length,
        (opus_int16 *)pcm.mutableBytes,
        frameSamples,
        0
    );
    if (samples < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIGlassOpus" code:samples userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Opus decode failed (%d)", samples]
            }];
        }
        return nil;
    }
    pcm.length = (NSUInteger)samples * (NSUInteger)_channels * sizeof(opus_int16);
    return pcm;
}

@end
