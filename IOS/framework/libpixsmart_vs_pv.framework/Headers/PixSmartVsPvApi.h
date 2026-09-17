/*******************************************************************************
Copyright(c) PixSmart, All right reserved.

This file is PixSmart's property. It contains PixSmart 's trade secret, proprietary
and confidential information.

The information and code contained in this file is only for authorized PixSmart
employees to design, create, modify, or review.

DO NOT DISTRIBUTE, DO NOT DUPLICATE OR TRANSMIT IN ANY FORM WITHOUT PROPER
AUTHORIZATION.

If you are not an intended recipient of this file, you must not copy,
distribute, modify, or take any action in reliance on it.

If you have received this file in error, please immediately notify PixSmart and
permanently delete the original and any copy of any file and any printout
thereof.
*******************************************************************************/

#ifndef PIXSMART_VS_PV_API_H
#define PIXSMART_VS_PV_API_H

#include "pixsmart_comdef.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PIXSMART_VS_PV_API
#define PIXSMART_VS_PV_API __attribute__((visibility("default")))
#endif

#define PIXSMART_VS_PV_VERSION_NAME "PIXSMART_VS_PV_1.2.4"

/* Error code */
#define PIXSMART_VS_PV_SUCCESS 0
#define PIXSMART_VS_PV_NOT_INIT -1
#define PIXSMART_VS_PV_ERR -2

typedef enum {
    BT709 = 0,
    BT709_FULLRANGE = 1,
    BT601 = 2,
    BT601_FULLRANGE = 3,
} PIXSMART_VS_PV_COLOR_STANDARD;

typedef struct _tag_PIXSMART_VS_PARAM
{
    MUInt32 inWidth;
    MUInt32 inHeight;
    MUInt32 outWidth;
    MUInt32 outHeight;
    MFloat outScale;
    MFloat dregScale;
    MFloat stdev;
    PIXSMART_VS_PV_COLOR_STANDARD colorStandard;
    MPCChar reserved1;
} PIXSMART_VS_PV_PARAM, *LPPIXSMART_VS_PV_PARAM;

// Struct holding capture information of frame data
typedef struct _tag_PIXSMART_VS_PV_FRAMEINFO
{
    MInt64 llTimestamp;
} PIXSMART_VS_PV_FRAMEINFO, *LPPIXSMART_VS_PV_FRAMEINFO;

typedef enum {
    FORMAT_I420 = 0,
    FORMAT_NV21 = 1,
    FORMAT_NV12 = 2,
} PIXSMART_VS_PV_FRAME_YUV_FORMAT;

typedef struct {
    void * mDataY;
    void * mDataUv;
} PIXSMART_VS_PV_FRAME_YUV_DATA;

typedef struct {
    int mY;
    int mUv;
} PIXSMART_VS_PV_FRAME_YUV_DATA_STRIDE;

typedef struct _tag_PIXSMART_VS_PV_FRAME_YUV
{
    MInt32                                  i32Width;
    MInt32                                  i32Height;
    PIXSMART_VS_PV_FRAME_YUV_FORMAT         format;
    PIXSMART_VS_PV_FRAME_YUV_DATA           data;
    PIXSMART_VS_PV_FRAME_YUV_DATA_STRIDE    stride;
} PIXSMART_VS_PV_FRAME_YUV, *LPPIXSMART_VS_PV_FRAME_YUV;

typedef struct _tag_PIXSMART_VS_PV_FRAME_GL
{
    MInt32                                  i32Width;
    MInt32                                  i32Height;
    MInt32                                  texture;
    MInt32                                  frameBuffer;
    MInt32                                  isOes;
} PIXSMART_VS_PV_FRAME_GL, *LPPIXSMART_VS_PV_FRAME_GL;

typedef struct _tag_PIXSMART_VS_PV_TOKEN_RESULT{
    int result;
    char expiringDate[20];
    char sn[100];
    char license_data[4096];
} PIXSMART_VS_PV_TOKEN_RESULT, *LPPIXSMART_VS_PV_TOKEN_RESULT;

#if defined(__ANDROID__)
#include <jni.h>

PIXSMART_VS_PV_API void PixSmartVsPvCheckLicense(
        JNIEnv *env, jobject thiz,
        MPCChar licensePath,                                // [in] licensePath
        MPCChar serialNumber,                               // [in] serialNumber
        MPCChar expireDate,                                 // [in] expireDate
        LPPIXSMART_VS_PV_TOKEN_RESULT pTokenResultParam     // [out] Token result
);
#endif

#if defined(__APPLE__)
PIXSMART_VS_PV_API void PixSmartVsPvCheckLicense(
        MPCChar licensePath,
        MPCChar serialNumber,
        MPCChar expireDate,
        LPPIXSMART_VS_PV_TOKEN_RESULT pTokenResultParam
);
#endif

// Initialize the algorithm engine
PIXSMART_VS_PV_API int PixSmartVsPvInit(
        MHandle *pHandle,                                   // [in] Pointer to the handle of the algorithm engine
        LPPIXSMART_VS_PV_PARAM pParam                       // [in]  The parameters for algorithm engine
);

// Deinitialize the algorithm engine
PIXSMART_VS_PV_API void PixSmartVsPvUninit(
        MHandle *pHandle                                    // [in] Pointer to the handle of the algorithm engine
);

// Stabilize image
PIXSMART_VS_PV_API long PixSmartVsPvProcessYuv(
        MHandle *pHandle,                                   // [in] Pointer to the handle of the algorithm engine
        LPPIXSMART_VS_PV_FRAMEINFO pFrameInfo,              // [in]  The capture information of source image
        LPPIXSMART_VS_PV_FRAME_YUV pSrcFrame,               // [in]  The source frame
        LPPIXSMART_VS_PV_FRAME_YUV pDstFrame                // [in/out] The result frame
);

// Stabilize image
PIXSMART_VS_PV_API long PixSmartVsPvProcess(
        MHandle *pHandle,                                   // [in] Pointer to the handle of the algorithm engine
        LPPIXSMART_VS_PV_FRAMEINFO pFrameInfo,              // [in]  The capture information of source image
        LPPIXSMART_VS_PV_FRAME_YUV pSrcFrame,               // [in]  The source frame
        LPPIXSMART_VS_PV_FRAME_GL pDstFrame                 // [in/out] The result frame
);

PIXSMART_VS_PV_API void PixSmartVsPvSetLogEnable(
        MHandle *pHandle,                                   // [in] Pointer to the handle of the algorithm engine
        MInt32 enable                                       // [in] Enable for log
);

PIXSMART_VS_PV_API void PixSmartVsPvSetDumpPath(
        MHandle *pHandle,                                   // [in] Pointer to the handle of the algorithm engine
        MPCChar path                                        // [in] Dump path
);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif //PIXSMART_VS_PV_API_H
