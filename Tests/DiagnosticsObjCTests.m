#import "../AIGlass/Debug/AIGlassDiagnostics.h"

static int evaluations;
static NSString *message(void) {
    evaluations += 1;
    return @"DIAGNOSTICS_OBJC_MARKER";
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL enabled = argc > 1 && strcmp(argv[1], "enabled") == 0;
        AIGlassDebugLog(@"%@", message());
        if (evaluations != (enabled ? 1 : 0)) { return 1; }
    }
    return 0;
}
