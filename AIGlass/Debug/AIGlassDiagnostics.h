#import <Foundation/Foundation.h>

#if !AIGLASS_PRODUCTION && (DEBUG || AIGLASS_DIAGNOSTICS)
#define AIGlassDebugLog(...) NSLog(__VA_ARGS__)
#else
#define AIGlassDebugLog(...) do {} while (0)
#endif

FOUNDATION_EXPORT void AIGlassConfigureSDKDiagnostics(BOOL enabled);
