#import "PixSmartImageStabilizer.h"

#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#include <libpixsmart_vs_pv/PixSmartVsPvApi.h>
#endif

static NSString *const kPixSmartEISErrorDomain = @"PixSmartEIS";

@implementation PixSmartImageStabilizer

+ (BOOL)isAvailable {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return [self ensureLicenseChecked];
#endif
}

+ (BOOL)prewarmLicense {
    return [self isAvailable];
}

+ (nullable NSData *)stabilizeImageData:(NSData *)imageData
                    compressionQuality:(CGFloat)quality
                                 error:(NSError *__autoreleasing  _Nullable *)error {
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                     code:-100
                                 userInfo:@{NSLocalizedDescriptionKey: @"模拟器不支持 PixSmart EIS"}];
    }
    return nil;
#else
    // Demo 走 PixSmartVsPvProcess(OpenGL)，ProcessYuv 会空指针崩。必须 GL 路径。
    __block NSData *resultData = nil;
    __block NSError *blockError = nil;

    // GL 需串行上下文；避免与主线程其它 GL 抢。
    static dispatch_queue_t glQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        glQueue = dispatch_queue_create("com.aiglass.pixsmart.eis.gl", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_sync(glQueue, ^{
        resultData = [self stabilizeImageDataOnGLQueue:imageData
                                   compressionQuality:quality
                                                error:&blockError];
    });

    if (!resultData && error) {
        *error = blockError;
    }
    return resultData;
#endif
}

#if !TARGET_OS_SIMULATOR

+ (nullable NSData *)stabilizeImageDataOnGLQueue:(NSData *)imageData
                             compressionQuality:(CGFloat)quality
                                          error:(NSError *__autoreleasing  _Nullable *)error {
    if (imageData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"空图片数据"}];
        }
        return nil;
    }

    if (![self ensureLicenseChecked]) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"PixSmart 鉴权失败"}];
        }
        return nil;
    }

    UIImage *image = [UIImage imageWithData:imageData];
    if (!image || !image.CGImage) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解码图片"}];
        }
        return nil;
    }

    int width = (int)CGImageGetWidth(image.CGImage) & ~1;
    int height = (int)CGImageGetHeight(image.CGImage) & ~1;
    if (width < 16 || height < 16) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @"图片尺寸过小"}];
        }
        return nil;
    }

    CVPixelBufferRef srcPB = [self createNV12PixelBufferFromImage:image width:width height:height];
    if (!srcPB) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-5
                                     userInfo:@{NSLocalizedDescriptionKey: @"创建 NV12 源缓冲失败"}];
        }
        return nil;
    }

    EAGLContext *glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!glContext || ![EAGLContext setCurrentContext:glContext]) {
        CVPixelBufferRelease(srcPB);
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-9
                                     userInfo:@{NSLocalizedDescriptionKey: @"创建 OpenGL 上下文失败"}];
        }
        return nil;
    }

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);

    CVOpenGLESTextureCacheRef textureCache = NULL;
    CVReturn cacheRet = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, glContext, NULL, &textureCache);
    if (cacheRet != kCVReturnSuccess || !textureCache) {
        if (fbo) glDeleteFramebuffers(1, &fbo);
        [EAGLContext setCurrentContext:nil];
        CVPixelBufferRelease(srcPB);
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-10
                                     userInfo:@{NSLocalizedDescriptionKey: @"创建纹理缓存失败"}];
        }
        return nil;
    }

    float dregScale = 240.0f / (float)MAX(width, height);
    PIXSMART_VS_PV_PARAM vsParam = {
        .inWidth = (MUInt32)width,
        .inHeight = (MUInt32)height,
        .outWidth = (MUInt32)width,
        .outHeight = (MUInt32)height,
        .outScale = 0.8f,
        .dregScale = dregScale,
        .stdev = 10.0f,
        .colorStandard = BT709_FULLRANGE,
        .reserved1 = NULL
    };

    MHandle handle = NULL;
    int initRet = PixSmartVsPvInit(&handle, &vsParam);
    if (initRet != PIXSMART_VS_PV_SUCCESS || handle == NULL) {
        CVOpenGLESTextureCacheFlush(textureCache, 0);
        CFRelease(textureCache);
        if (fbo) glDeleteFramebuffers(1, &fbo);
        [EAGLContext setCurrentContext:nil];
        CVPixelBufferRelease(srcPB);
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:initRet
                                     userInfo:@{NSLocalizedDescriptionKey: @"EIS 引擎初始化失败"}];
        }
        return nil;
    }
    PixSmartVsPvSetLogEnable(&handle, FALSE);

    const int delayNum = 15;
    const int feedCount = delayNum + 2;
    CVPixelBufferRef outPB = NULL;
    BOOL gotOutput = NO;

    CVPixelBufferLockBaseAddress(srcPB, kCVPixelBufferLock_ReadOnly);
    PIXSMART_VS_PV_FRAME_YUV srcFrame = {
        .i32Width = width,
        .i32Height = height,
        .format = FORMAT_NV12,
        .data = {
            .mDataY = CVPixelBufferGetBaseAddressOfPlane(srcPB, 0),
            .mDataUv = CVPixelBufferGetBaseAddressOfPlane(srcPB, 1)
        },
        .stride = {
            .mY = (int)CVPixelBufferGetBytesPerRowOfPlane(srcPB, 0),
            .mUv = (int)CVPixelBufferGetBytesPerRowOfPlane(srcPB, 1)
        }
    };

    // 同一帧反复喂入，再 flush（与 demo delayNum 管线一致）。
    for (int i = 0; i < feedCount && !gotOutput; i++) {
        CVPixelBufferRef dstPB = [self createEmptyBGRAPixelBufferWidth:width height:height];
        if (!dstPB) { break; }

        CVOpenGLESTextureRef dstTex = NULL;
        CVReturn texRet = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            dstPB,
            NULL,
            GL_TEXTURE_2D,
            GL_RGBA,
            width,
            height,
            GL_BGRA,
            GL_UNSIGNED_BYTE,
            0,
            &dstTex
        );
        if (texRet != kCVReturnSuccess || !dstTex) {
            NSLog(@"[PixSmartEIS] texture create failed: %d", texRet);
            CVPixelBufferRelease(dstPB);
            break;
        }

        GLuint texID = CVOpenGLESTextureGetName(dstTex);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glBindTexture(GL_TEXTURE_2D, texID);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texID, 0);

        PIXSMART_VS_PV_FRAMEINFO frameInfo;
        frameInfo.llTimestamp = (MInt64)i * 33333333LL;

        PIXSMART_VS_PV_FRAME_GL dstFrame = {
            .i32Width = width,
            .i32Height = height,
            .texture = (MInt32)texID,
            .frameBuffer = (MInt32)fbo,
            .isOes = 0
        };

        long timestampOut = PixSmartVsPvProcess(&handle, &frameInfo, &srcFrame, &dstFrame);
        glFlush();

        glBindTexture(GL_TEXTURE_2D, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        if (timestampOut >= 0) {
            if (outPB) CVPixelBufferRelease(outPB);
            outPB = dstPB;
            gotOutput = YES;
            CFRelease(dstTex);
            break;
        }

        CFRelease(dstTex);
        CVPixelBufferRelease(dstPB);
    }

    // flush 延迟帧
    for (int i = 0; i < delayNum && !gotOutput; i++) {
        CVPixelBufferRef dstPB = [self createEmptyBGRAPixelBufferWidth:width height:height];
        if (!dstPB) { break; }

        CVOpenGLESTextureRef dstTex = NULL;
        CVReturn texRet = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            dstPB,
            NULL,
            GL_TEXTURE_2D,
            GL_RGBA,
            width,
            height,
            GL_BGRA,
            GL_UNSIGNED_BYTE,
            0,
            &dstTex
        );
        if (texRet != kCVReturnSuccess || !dstTex) {
            CVPixelBufferRelease(dstPB);
            break;
        }

        GLuint texID = CVOpenGLESTextureGetName(dstTex);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texID, 0);

        PIXSMART_VS_PV_FRAMEINFO frameInfo;
        frameInfo.llTimestamp = -1;
        PIXSMART_VS_PV_FRAME_YUV emptySrc = {
            .i32Width = 0,
            .i32Height = 0,
            .format = FORMAT_NV12,
            .data = { .mDataY = NULL, .mDataUv = NULL },
            .stride = { .mY = 0, .mUv = 0 }
        };
        PIXSMART_VS_PV_FRAME_GL dstFrame = {
            .i32Width = width,
            .i32Height = height,
            .texture = (MInt32)texID,
            .frameBuffer = (MInt32)fbo,
            .isOes = 0
        };

        long timestampOut = PixSmartVsPvProcess(&handle, &frameInfo, &emptySrc, &dstFrame);
        glFlush();
        glBindTexture(GL_TEXTURE_2D, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        if (timestampOut >= 0) {
            outPB = dstPB;
            gotOutput = YES;
            CFRelease(dstTex);
            break;
        }
        CFRelease(dstTex);
        CVPixelBufferRelease(dstPB);
    }

    CVPixelBufferUnlockBaseAddress(srcPB, kCVPixelBufferLock_ReadOnly);
    PixSmartVsPvUninit(&handle);

    if (fbo) {
        glDeleteFramebuffers(1, &fbo);
    }
    if (textureCache) {
        CVOpenGLESTextureCacheFlush(textureCache, 0);
        CFRelease(textureCache);
    }
    if ([EAGLContext currentContext] == glContext) {
        [EAGLContext setCurrentContext:nil];
    }
    CVPixelBufferRelease(srcPB);

    if (!gotOutput || !outPB) {
        if (outPB) CVPixelBufferRelease(outPB);
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-6
                                     userInfo:@{NSLocalizedDescriptionKey: @"EIS 未产出结果帧"}];
        }
        return nil;
    }

    UIImage *outImage = [self imageFromBGRAPixelBuffer:outPB];
    CVPixelBufferRelease(outPB);
    if (!outImage) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-7
                                     userInfo:@{NSLocalizedDescriptionKey: @"输出帧转 UIImage 失败"}];
        }
        return nil;
    }

    NSData *jpeg = UIImageJPEGRepresentation(outImage, MAX(0.1, MIN(quality, 1.0)));
    if (!jpeg) {
        if (error) {
            *error = [NSError errorWithDomain:kPixSmartEISErrorDomain
                                         code:-8
                                     userInfo:@{NSLocalizedDescriptionKey: @"JPEG 编码失败"}];
        }
        return nil;
    }
    NSLog(@"[PixSmartEIS] stabilize ok (GL) %dx%d -> %lu bytes", width, height, (unsigned long)jpeg.length);
    return jpeg;
}

#endif

#pragma mark - License

#if !TARGET_OS_SIMULATOR

+ (BOOL)ensureLicenseChecked {
    static NSLock *lock;
    static BOOL licensed = NO;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        lock = [[NSLock alloc] init];
        // 清掉旧版误存的失败 license_data（传给 serialNumber 会 SIGABRT）。
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *bad = [docs.firstObject stringByAppendingPathComponent:@"SXS_VideoStabilizePv_IOS_Activation.data"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:bad]) {
            [[NSFileManager defaultManager] removeItemAtPath:bad error:nil];
            NSLog(@"[PixSmartEIS] removed legacy activation cache");
        }
    });

    [lock lock];
    if (licensed) {
        [lock unlock];
        return YES;
    }

    NSString *path = [self licenseFilePath];
    if (!path) {
        NSLog(@"[PixSmartEIS] license file missing in bundle");
        [lock unlock];
        return NO;
    }

    // 与 demo 完全一致：serialNumber / expireDate 都传空串。
    // 成功后 SDK 自己在 Documents 写 _Info.data，下次空串也能过。
    PIXSMART_VS_PV_TOKEN_RESULT result;
    memset(&result, 0, sizeof(result));
    PixSmartVsPvCheckLicense(path.UTF8String, "", "", &result);

    licensed = (result.result == 0);
    NSLog(@"[PixSmartEIS] license result=%d sn=%s exp=%s",
          result.result, result.sn, result.expiringDate);
    if (!licensed) {
        NSLog(@"[PixSmartEIS] auth failed code=%d ( -21 = need online activate once )", result.result);
    } else {
        NSLog(@"[PixSmartEIS] auth OK");
    }
    [lock unlock];
    return licensed;
}

+ (nullable NSString *)licenseFilePath {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"SXS_VideoStabilizePv_IOS_License"
                                                     ofType:@"data"
                                                inDirectory:@"Vendor/PixSmart"];
    if (!path) {
        path = [[NSBundle mainBundle] pathForResource:@"SXS_VideoStabilizePv_IOS_License"
                                               ofType:@"data"];
    }
    return path;
}

#endif

#pragma mark - Pixel buffer helpers

+ (CVPixelBufferRef)createEmptyNV12PixelBufferWidth:(int)width height:(int)height {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        (__bridge CFDictionaryRef)attrs,
        &pb
    );
    if (ret != kCVReturnSuccess || !pb) {
        return NULL;
    }
    return pb;
}

+ (CVPixelBufferRef)createEmptyBGRAPixelBufferWidth:(int)width height:(int)height {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pb
    );
    if (ret != kCVReturnSuccess || !pb) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    if (base) {
        memset(base, 0, CVPixelBufferGetDataSize(pb));
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

+ (CVPixelBufferRef)createNV12PixelBufferFromImage:(UIImage *)image
                                             width:(int)width
                                            height:(int)height {
    NSDictionary *bgraAttrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef bgra = NULL;
    CVReturn ret = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)bgraAttrs,
        &bgra
    );
    if (ret != kCVReturnSuccess || !bgra) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(bgra, 0);
    void *base = CVPixelBufferGetBaseAddress(bgra);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(bgra);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        base, width, height, 8, bytesPerRow, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(bgra, 0);
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    CGContextClearRect(ctx, CGRectMake(0, 0, width, height));
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image.CGImage);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(bgra, 0);

    CVPixelBufferRef nv12 = [self createEmptyNV12PixelBufferWidth:width height:height];
    if (!nv12) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }

    [self convertBGRA:bgra toNV12:nv12 width:width height:height];
    CVPixelBufferRelease(bgra);
    return nv12;
}

+ (void)convertBGRA:(CVPixelBufferRef)bgra
             toNV12:(CVPixelBufferRef)nv12
              width:(int)width
             height:(int)height {
    CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(nv12, 0);

    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(bgra);
    size_t srcRow = CVPixelBufferGetBytesPerRow(bgra);
    uint8_t *yDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv12, 0);
    uint8_t *uvDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv12, 1);
    size_t yRow = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0);
    size_t uvRow = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1);

    for (int y = 0; y < height; y++) {
        const uint8_t *srcRowPtr = src + y * srcRow;
        uint8_t *yRowPtr = yDst + y * yRow;
        for (int x = 0; x < width; x++) {
            const uint8_t *p = srcRowPtr + x * 4;
            int B = p[0], G = p[1], R = p[2];
            int Y = ((66 * R + 129 * G + 25 * B + 128) >> 8) + 16;
            yRowPtr[x] = (uint8_t)MAX(0, MIN(255, Y));
        }
    }
    for (int y = 0; y < height; y += 2) {
        const uint8_t *row0 = src + y * srcRow;
        const uint8_t *row1 = src + MIN(y + 1, height - 1) * srcRow;
        uint8_t *uvRowPtr = uvDst + (y / 2) * uvRow;
        for (int x = 0; x < width; x += 2) {
            const uint8_t *p0 = row0 + x * 4;
            const uint8_t *p1 = row0 + MIN(x + 1, width - 1) * 4;
            const uint8_t *p2 = row1 + x * 4;
            const uint8_t *p3 = row1 + MIN(x + 1, width - 1) * 4;
            int R = (p0[2] + p1[2] + p2[2] + p3[2]) / 4;
            int G = (p0[1] + p1[1] + p2[1] + p3[1]) / 4;
            int B = (p0[0] + p1[0] + p2[0] + p3[0]) / 4;
            int U = ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
            int V = ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;
            uvRowPtr[x] = (uint8_t)MAX(0, MIN(255, U));
            uvRowPtr[x + 1] = (uint8_t)MAX(0, MIN(255, V));
        }
    }

    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(nv12, 0);
}

+ (UIImage *)imageFromBGRAPixelBuffer:(CVPixelBufferRef)pb {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pb];
    if (!ciImage) { return nil; }
    CIContext *context = [CIContext contextWithOptions:nil];
    CGRect rect = CGRectMake(0, 0, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
    CGImageRef cgImage = [context createCGImage:ciImage fromRect:rect];
    if (!cgImage) { return nil; }
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

@end
