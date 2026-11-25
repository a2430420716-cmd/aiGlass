#import "AIGlassDiagnostics.h"
#import <JLLogHelper/JLLogManager.h>

void AIGlassConfigureSDKDiagnostics(BOOL enabled) {
    [JLLogManager setLog:enabled IsMore:enabled Level:JLLOG_DEBUG];
    [JLLogManager saveLogAsFile:enabled];
}
