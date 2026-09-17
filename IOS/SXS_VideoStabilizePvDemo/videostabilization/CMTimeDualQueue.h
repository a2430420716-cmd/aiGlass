#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

@interface CMTimeDualQueue : NSObject
- (void)enqueuePTS:(CMTime)pts duration:(CMTime)duration;
- (CMTime)dequeuePTS;
- (CMTime)dequeueDuration;
- (BOOL)isEmpty;
@end
