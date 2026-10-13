#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../IOS/SXS_VideoStabilizePvDemo/videostabilization/PixSmartVideoProfile.h"
#include "../IOS/framework/libpixsmart_vs_pv.framework/Headers/PixSmartVsPvApi.h"

int main(void) {
    const unsigned sizes[][2] = {{1920, 1080}, {1080, 1920}, {3840, 2160}, {1280, 720}, {2560, 1440}};
    int checks = 0;
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
        const unsigned width = sizes[i][0], height = sizes[i][1];
        const float longest = width > height ? width : height;
        const PixSmartVideoProfile gen1 = PixSmartVideoProfileForSize(true, width, height);
        const PixSmartVideoProfile gen2 = PixSmartVideoProfileForSize(false, width, height);
        assert(fabsf(gen1.dregScale - 240.f / longest) < 1e-6f); ++checks;
        assert(fabsf(gen2.dregScale - 360.f / longest) < 1e-6f); ++checks;
        assert(gen1.colorStandard == BT709_FULLRANGE); ++checks;
        assert(gen2.colorStandard == BT709); ++checks;
        assert(gen1.outScale == .8f && gen2.outScale == .8f); ++checks;
        assert(gen1.stdev == 3.f && gen2.stdev == 3.f); ++checks;
    }
    printf("PixSmart video profile: %d assertions passed\n", checks);
    return 0;
}
