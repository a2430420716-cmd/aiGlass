#ifndef PIXSMART_VIDEO_PROFILE_H
#define PIXSMART_VIDEO_PROFILE_H

#include <stdbool.h>
#include <stdint.h>

// Values match PIXSMART_VS_PV_COLOR_STANDARD; checked against the SDK at compile time.
typedef struct {
    float outScale;
    float dregScale;
    float stdev;
    int colorStandard;
} PixSmartVideoProfile;

static inline PixSmartVideoProfile PixSmartVideoProfileForSize(bool useGen1,
                                                             uint32_t width,
                                                             uint32_t height) {
    uint32_t maxSize = width > height ? width : height;
    return (PixSmartVideoProfile){
        .outScale = 0.8f,
        .dregScale = maxSize > 0 ? (useGen1 ? 240.0f : 360.0f) / maxSize : 0.0f,
        .stdev = 3.0f,
        .colorStandard = useGen1 ? 1 : 0
    };
}

#endif
