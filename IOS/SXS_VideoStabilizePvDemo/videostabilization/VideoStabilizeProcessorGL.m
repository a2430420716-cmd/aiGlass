#import "VideoStabilizeProcessorGL.h"

#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#include "libpixsmart_vs_pv.framework/Headers/PixSmartVsPvApi.h"
#include "PixSmartVideoProfile.h"
#include <stdatomic.h>
#include <math.h>
#include <limits.h>
#import "CMTimeDualQueue.h"

_Static_assert(BT709 == 0 && BT709_FULLRANGE == 1, "PixSmart profile color constants changed");

@interface VideoStabilizeProcessorGL () {
    MHandle _vsHandle;
    dispatch_queue_t _processingQueue;
    ProcessorState _currentState;
    
    // Video info
    CGSize _inputSize;
    CGSize _outputSize;
    NSInteger _totalFrames;
    
    NSInteger _currentFrameIndex;
    CMTime _lastPresentationTime;
    CMTimeDualQueue *queue;
    
    AVAssetReader *_assetReader;
    AVAssetReaderTrackOutput *_videoOutput;
    AVAssetWriter *_assetWriter;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInputPixelBufferAdaptor *_pbAdaptor;
    
    // GL
    EAGLContext *_glContext;
    GLuint _fbo;
    CVOpenGLESTextureCacheRef _textureCache;
    
    int delayNum;

    // Gen1 cancellation is observed by the worker; never synchronously wait for it.
    atomic_bool _gen1Cancelled;
    BOOL _gen1Initialized;
    BOOL _gen1Completed;
    BOOL _gen1Finishing;
    BOOL _gen1WriterSessionStarted;
    NSInteger _gen1SubmittedFrames;
    CMTime _gen1FallbackDuration;
}
@end

@implementation VideoStabilizeProcessorGL

#pragma mark - Init
- (instancetype)initWithEisData:(EisData *)eisData delegate:(id<VideoStabilizeProcessorDelegate>)delegate {
    self = [super init];
    if (self = [super initWithEisData:eisData delegate:delegate]) {
        NSLog(@"VideoStabilizeProcessorGL init");
        _processingQueue = dispatch_queue_create("com.pixsmart.videostabilize.processorgl", DISPATCH_QUEUE_SERIAL);
        _currentState = ProcessorStateIdle;
        atomic_init(&_gen1Cancelled, false);
    }
    return self;
}

#pragma mark - Public
- (void)startProcessing {
    if (_currentState != ProcessorStateIdle) return;
    _currentState = ProcessorStateInitializing;
    
    dispatch_async(_processingQueue, ^{
        if (self.useGen1Configuration) {
            [self _processingGen1];
        } else {
            [self _processing];
        }
    });
}

- (void)stopProcessing {
    if (self.useGen1Configuration) {
        atomic_store(&_gen1Cancelled, true);
        dispatch_async(_processingQueue, ^{
            // During synchronous processing the loop handles cancellation. During
            // asynchronous writer finalization the queue is free to cancel it here.
            if (self->_gen1Finishing && !self->_gen1Completed) {
                [self _completeGen1WithFailure:@"Video stabilization cancelled"];
            }
        });
        return;
    }
    dispatch_sync(_processingQueue, ^{
        _currentState = ProcessorStateStopped;
    });
}

#pragma mark - Main Pipeline
- (void)_processing {
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self.eisData.srcVideoPath]];
    AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    _inputSize = videoTrack.naturalSize;
    _outputSize = _inputSize;
    
    Float64 durationSeconds = CMTimeGetSeconds(videoTrack.timeRange.duration);
    Float64 nominalFrameRate = videoTrack.nominalFrameRate;
    _totalFrames = (NSInteger)ceil(durationSeconds * nominalFrameRate - 1e-6); // 添加小量避免浮点误差
    
    float sourceBitRate = videoTrack.estimatedDataRate;
    
    CGAffineTransform transform = videoTrack.preferredTransform;
    CGFloat rotationAngle = 0;
    if (transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0) {
        rotationAngle = 90; // 顺时针旋转90°
    } else if (transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0) {
        rotationAngle = 270; // 顺时针旋转270°
    } else if (transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0) {
        rotationAngle = 0; // 无旋转
    } else if (transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0) {
        rotationAngle = 180; // 旋转180°
    }
    
    if (_totalFrames < 30) {
        [self _notifyFailure:@"Insufficient video frames"];
        return;
    }
    NSLog(@"VideoStabilizeProcessorYUV inputSize: %dx%d, totalFrames: %ld, rotation: %f, sourceBitRate: %.2f Mbps",
          (uint32_t)_inputSize.width, (uint32_t)_inputSize.height, _totalFrames, rotationAngle, sourceBitRate/1000000);
    
    NSError *error = nil;
    _assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
    [_assetReader addOutput:_videoOutput];
    [_assetReader startReading];
    
    if (![self _setupVideoWriter:sourceBitRate withTransform:transform]) {
        [self _notifyFailure:@"setupVideoWriter failed"];
        return;
    }
    
    _glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:_glContext];
    const GLubyte *ver = glGetString(GL_VERSION);
    const GLubyte *ren = glGetString(GL_RENDERER);
    NSLog(@"GL_VERSION = %s GL_RENDERER = %s", ver ? (const char *)ver : "NULL", ren ? (const char *)ren : "NULL");
    
    glGenFramebuffers(1, &_fbo);
    
    CVReturn ret = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _glContext, NULL, &_textureCache);
    if (ret != kCVReturnSuccess) {
        return;
    }
    
    // 与 Android 导入流程保持一致（Gen2眼镜参数）。
    PixSmartVideoProfile profile = PixSmartVideoProfileForSize(false,
        (uint32_t)_inputSize.width, (uint32_t)_inputSize.height);
    PIXSMART_VS_PV_PARAM vsParam = {
        .inWidth = (uint32_t)_inputSize.width,
        .inHeight = (uint32_t)_inputSize.height,
        .outWidth = (uint32_t)_outputSize.width,
        .outHeight = (uint32_t)_outputSize.height,
        .outScale = profile.outScale,
        .dregScale = profile.dregScale,
        .stdev = profile.stdev,
        .colorStandard = (PIXSMART_VS_PV_COLOR_STANDARD)profile.colorStandard
    };
    PixSmartVsPvInit(&_vsHandle, &vsParam);
    PixSmartVsPvSetLogEnable(&_vsHandle, FALSE);
    delayNum = 15;
    
    queue = [[CMTimeDualQueue alloc] init];
    
    _currentState = ProcessorStateProcessing;
    _currentFrameIndex = 0;
    
    while (_currentState == ProcessorStateProcessing && _assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sample = [_videoOutput copyNextSampleBuffer];
        if (!sample) break;
        
        CVImageBufferRef srcImageBuffer = CMSampleBufferGetImageBuffer(sample);
        CVPixelBufferLockBaseAddress(srcImageBuffer, 0);
        
        int width = (int)CVPixelBufferGetWidth(srcImageBuffer);
        int height = (int)CVPixelBufferGetHeight(srcImageBuffer);
        CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sample);
        CMTime nanoTime = CMTimeConvertScale(presentationTimeStamp, 1000000000, kCMTimeRoundingMethod_RoundTowardZero);
        CMTime duration = CMSampleBufferGetDuration(sample);
        
        CMTime safePTS = presentationTimeStamp;
        if (_currentFrameIndex > 0 &&
            CMTimeCompare(safePTS, _lastPresentationTime) <= 0) {
            safePTS = CMTimeAdd(_lastPresentationTime, duration);
        }
        _lastPresentationTime = safePTS;
        [queue enqueuePTS:safePTS duration:duration];
        
        CMTime ptsNs = CMTimeConvertScale(safePTS,
                                          1000000000,
                                          kCMTimeRoundingMethod_Default);
        PIXSMART_VS_PV_FRAMEINFO frameInfo;
        frameInfo.llTimestamp = ptsNs.value;
        
        PIXSMART_VS_PV_FRAME_YUV srcFrame = {
            .i32Width = width,
            .i32Height = height,
            .format = FORMAT_NV12,
            .data = {
                .mDataY = CVPixelBufferGetBaseAddressOfPlane(srcImageBuffer, 0),
                .mDataUv = CVPixelBufferGetBaseAddressOfPlane(srcImageBuffer, 1)
            },
            .stride = {
                .mY = (int)CVPixelBufferGetBytesPerRowOfPlane(srcImageBuffer, 0),
                .mUv = (int)CVPixelBufferGetBytesPerRowOfPlane(srcImageBuffer, 1)
            }
        };
        
        CVPixelBufferRef dstPB = NULL;
        CVPixelBufferPoolCreatePixelBuffer(NULL, _pbAdaptor.pixelBufferPool, &dstPB);
        
        CVPixelBufferLockBaseAddress(dstPB, 0);
        memset(CVPixelBufferGetBaseAddress(dstPB), 0, CVPixelBufferGetDataSize(dstPB));
        CVPixelBufferUnlockBaseAddress(dstPB, 0);
        
        CVOpenGLESTextureRef dstTex = NULL;
        CVReturn texRet = CVOpenGLESTextureCacheCreateTextureFromImage(
                                                                       kCFAllocatorDefault,
                                                                       _textureCache,
                                                                       dstPB,
                                                                       NULL,
                                                                       GL_TEXTURE_2D,
                                                                       GL_RGBA,
                                                                       (int)_outputSize.width,
                                                                       (int)_outputSize.height,
                                                                       GL_BGRA,
                                                                       GL_UNSIGNED_BYTE,
                                                                       0,
                                                                       &dstTex);
        if (texRet != kCVReturnSuccess || !dstTex) {
            NSLog(@"❌ texture creation failed: %d", texRet);
        }
        
        GLuint texID = CVOpenGLESTextureGetName(dstTex);
        glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
        glBindTexture(GL_TEXTURE_2D, texID);
        glFramebufferTexture2D(GL_FRAMEBUFFER,
                               GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D,
                               texID,
                               0);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"❌ FBO incomplete: 0x%x, _currentFrameIndex = %d texID = %d _fbo = %d",
                  status, _currentFrameIndex, texID, _fbo);
        }
        
        PIXSMART_VS_PV_FRAME_GL dstFrame = {
            .i32Width  = (int)_outputSize.width,
            .i32Height = (int)_outputSize.height,
            .texture   = texID,
            .frameBuffer = _fbo,
            .isOes = 0
        };
        
        long timestampOut = PixSmartVsPvProcess(
                                                &_vsHandle,
                                                &frameInfo,
                                                &srcFrame,
                                                &dstFrame
                                                );
        
        CVPixelBufferUnlockBaseAddress(srcImageBuffer, 0);
        
        if (timestampOut >= 0) {
            CMTime outPTS = [queue dequeuePTS];
            CMTime outDur = [queue dequeueDuration];
            
            if (_currentFrameIndex == 0) {
                [_assetWriter startSessionAtSourceTime:outPTS];
            }
            
            glFlush();
            
            while (!_videoInput.readyForMoreMediaData) {
                usleep(1000);
            }
//            NSLog(@"VS OUT FRAME"
//                  "\n  frameIndex      = %ld"
//                  "\n  timestampOut(ns)= %ld"
//                  "\n  outPTS(ns)      = %lld"
//                  "\n  outDur          = {value=%lld, timescale=%d}",
//                  (long)_currentFrameIndex,
//                  timestampOut,
//                  outPTS.value,
//                  outPTS.timescale,
//                  outDur.value,
//                  outDur.timescale
//            );
            
            [_pbAdaptor appendPixelBuffer:dstPB
                     withPresentationTime:outPTS];
            
            _currentFrameIndex++;
            [self.delegate onProcess:_currentFrameIndex
                               total:_totalFrames];
        }
        
        glBindTexture(GL_TEXTURE_2D, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glFlush();

        if (dstTex) CFRelease(dstTex);
        if (dstPB)  CFRelease(dstPB);
        CFRelease(sample);

        if (_currentFrameIndex % 10 == 0) {
            CVOpenGLESTextureCacheFlush(_textureCache, 0);
        }
    }
    for (int i = 0; i < delayNum - 1; i++) {
        PIXSMART_VS_PV_FRAMEINFO frameInfo;
        frameInfo.llTimestamp = -1;
        PIXSMART_VS_PV_FRAME_YUV srcFrame = {
            .i32Width = 0,
            .i32Height = 0,
            .format = FORMAT_NV12,
            .data = { .mDataY = NULL, .mDataUv = NULL },
            .stride = { .mY = 0, .mUv = 0 }
        };
        
        CVPixelBufferRef dstPB = NULL;
        CVPixelBufferPoolCreatePixelBuffer(
                                           NULL, _pbAdaptor.pixelBufferPool, &dstPB);
        
        CVOpenGLESTextureRef dstTex = NULL;
        CVOpenGLESTextureCacheCreateTextureFromImage(
                                                     kCFAllocatorDefault,
                                                     _textureCache,
                                                     dstPB,
                                                     NULL,
                                                     GL_TEXTURE_2D,
                                                     GL_RGBA,
                                                     (int)_outputSize.width,
                                                     (int)_outputSize.height,
                                                     GL_BGRA,
                                                     GL_UNSIGNED_BYTE,
                                                     0,
                                                     &dstTex);
        
        GLuint texID = CVOpenGLESTextureGetName(dstTex);
        glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER,
                               GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D,
                               texID,
                               0);
        
        PIXSMART_VS_PV_FRAME_GL dstFrame = {
            .i32Width  = (int)_outputSize.width,
            .i32Height = (int)_outputSize.height,
            .texture   = texID,
            .frameBuffer = _fbo,
            .isOes = 0
        };
        
        long timestampOut = PixSmartVsPvProcess(
                                                &_vsHandle,
                                                &frameInfo,
                                                &srcFrame,
                                                &dstFrame
                                                );
        
        if (timestampOut >= 0) {
            CMTime outPTS = [queue dequeuePTS];
            CMTime outDur = [queue dequeueDuration];
            
            glFlush();
            
            while (!_videoInput.readyForMoreMediaData) {
                usleep(1000);
            }
            
            [_pbAdaptor appendPixelBuffer:dstPB
                     withPresentationTime:outPTS];
            
            _currentFrameIndex++;
            [self.delegate onProcess:_currentFrameIndex
                               total:_totalFrames];
        }

        glBindTexture(GL_TEXTURE_2D, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glFlush();

        if (dstTex) CFRelease(dstTex);
        if (dstPB)  CFRelease(dstPB);
    }
    
    while (![queue isEmpty]) {
        [queue dequeuePTS];
        [queue dequeueDuration];
    }
    
    if (_fbo) {
        glDeleteFramebuffers(1, &_fbo);
        _fbo = 0;
    }
    if (_textureCache) {
        CVOpenGLESTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
    
    [_videoInput markAsFinished];

    [_assetWriter finishWritingWithCompletionHandler:^{
        if (self->_assetWriter.status == AVAssetWriterStatusCompleted) {
            [self.delegate onProcessFinish:@{
                @"width": @(self->_outputSize.width),
                @"height": @(self->_outputSize.height),
                @"frames": @(self->_totalFrames),
                @"srcVideoPath" : self.eisData.srcVideoPath,
                @"dstVideoPath" : self.eisData.dstVideoPath,
            }];
        } else {
            [self _notifyFailure:@"视频写入失败"];
        }
    }];
    
    _currentState = ProcessorStateStopped;
    PixSmartVsPvUninit(&_vsHandle);
    
    if ([EAGLContext currentContext] == _glContext) {
        [EAGLContext setCurrentContext:nil];
    }
    _glContext = nil;

    [_assetReader cancelReading];
    _assetReader = nil;
    _videoOutput = nil;
}

#pragma mark - Gen1 guarded pipeline

// Keep the existing Gen2 pipeline above unchanged. The Gen1 branch must tolerate
// damaged/short device files and be cancellable without releasing a live engine.
- (void)_processingGen1 {
    if (atomic_load(&_gen1Cancelled)) {
        [self _completeGen1WithFailure:@"Video stabilization cancelled"];
        return;
    }
    NSString *inputPath = self.eisData.srcVideoPath;
    NSString *outputPath = self.eisData.dstVideoPath;
    if (inputPath.length == 0 || outputPath.length == 0 ||
        [inputPath.stringByStandardizingPath isEqualToString:outputPath.stringByStandardizingPath] ||
        ![[NSFileManager defaultManager] isReadableFileAtPath:inputPath]) {
        [self _completeGen1WithFailure:@"Invalid source or destination video"];
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:inputPath]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    _inputSize = track.naturalSize;
    _outputSize = _inputSize;
    double width = _inputSize.width, height = _inputSize.height;
    double fps = track.nominalFrameRate;
    double seconds = CMTimeGetSeconds(track.timeRange.duration);
    double frameEstimate = ceil(seconds * fps - 1e-6);
    if (!track || !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 ||
        width > INT_MAX || height > INT_MAX || floor(width) != width || floor(height) != height ||
        ((uint32_t)width % 2) != 0 || ((uint32_t)height % 2) != 0) {
        [self _completeGen1WithFailure:@"Unsupported video dimensions"];
        return;
    }
    if (!isfinite(fps) || fps <= 0 || !isfinite(frameEstimate) ||
        frameEstimate <= 15 || frameEstimate >= (double)NSIntegerMax) {
        [self _completeGen1WithFailure:@"Insufficient video frames for stabilization"];
        return;
    }
    _totalFrames = (NSInteger)frameEstimate;
    _gen1FallbackDuration = CMTimeMakeWithSeconds(1.0 / fps, 1000000000);
    queue = [[CMTimeDualQueue alloc] init];

    NSError *readerError = nil;
    _assetReader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }];
    if (!_assetReader || ![_assetReader canAddOutput:_videoOutput]) {
        [self _completeGen1WithFailure:readerError.localizedDescription ?: @"Cannot read source video"];
        return;
    }
    [_assetReader addOutput:_videoOutput];
    if (![_assetReader startReading]) {
        [self _completeGen1WithFailure:_assetReader.error.localizedDescription ?: @"Cannot start video reader"];
        return;
    }
    float bitRate = track.estimatedDataRate;
    if (!isfinite(bitRate) || bitRate <= 0) bitRate = 8000000;
    if (![self _setupVideoWriter:bitRate withTransform:track.preferredTransform]) {
        [self _completeGen1WithFailure:@"Cannot initialize video writer"];
        return;
    }
    _glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!_glContext || ![EAGLContext setCurrentContext:_glContext]) {
        [self _completeGen1WithFailure:@"Cannot create OpenGL context"];
        return;
    }
    GLint maxTextureSize = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
    if (maxTextureSize <= 0 || width > maxTextureSize || height > maxTextureSize) {
        [self _completeGen1WithFailure:@"Video dimensions exceed GPU texture limit"];
        return;
    }
    glGenFramebuffers(1, &_fbo);
    CVReturn cacheResult = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL,
                                                     _glContext, NULL, &_textureCache);
    if (_fbo == 0 || cacheResult != kCVReturnSuccess || !_textureCache) {
        [self _completeGen1WithFailure:@"Cannot allocate OpenGL resources"];
        return;
    }
    if (atomic_load(&_gen1Cancelled)) {
        [self _completeGen1WithFailure:@"Video stabilization cancelled"];
        return;
    }
    PixSmartVideoProfile profile = PixSmartVideoProfileForSize(true, (uint32_t)width, (uint32_t)height);
    PIXSMART_VS_PV_PARAM parameters = {
        .inWidth = (uint32_t)width, .inHeight = (uint32_t)height,
        .outWidth = (uint32_t)width, .outHeight = (uint32_t)height,
        .outScale = profile.outScale, .dregScale = profile.dregScale,
        .stdev = profile.stdev,
        .colorStandard = (PIXSMART_VS_PV_COLOR_STANDARD)profile.colorStandard
    };
    int initResult = PixSmartVsPvInit(&_vsHandle, &parameters);
    if (initResult != PIXSMART_VS_PV_SUCCESS || !_vsHandle) {
        [self _completeGen1WithFailure:[NSString stringWithFormat:@"Stabilization initialization failed (%d)", initResult]];
        return;
    }
    _gen1Initialized = YES;
    PixSmartVsPvSetLogEnable(&_vsHandle, FALSE);
    _currentState = ProcessorStateProcessing;
    NSLog(@"PixSmart Gen1 profile: %.0fx%.0f, dregScale=%.6f, colorStandard=%d",
          width, height, profile.dregScale, profile.colorStandard);

    NSString *failure = nil;
    while (!atomic_load(&_gen1Cancelled) && _assetReader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef sample = [_videoOutput copyNextSampleBuffer];
            if (!sample) break;
            BOOL processed = [self _processGen1Sample:sample failure:&failure];
            CFRelease(sample);
            if (!processed) break;
        }
    }
    if (atomic_load(&_gen1Cancelled)) failure = @"Video stabilization cancelled";
    if (!failure && _assetReader.status != AVAssetReaderStatusCompleted) {
        failure = _assetReader.error.localizedDescription ?: @"Source video did not finish decoding";
    }
    if (!failure && (_gen1SubmittedFrames <= 15 || _currentFrameIndex == 0)) {
        // As on Android, flushing an engine that produced no output can crash
        // inside the vendor library. Leave the source available for fallback.
        failure = @"Video produced no stabilization output";
    }
    if (!failure) {
        for (int index = 0; index < 14; index++) {
            if (![self _processGen1Sample:NULL failure:&failure]) break;
        }
    }
    if (failure) {
        [self _completeGen1WithFailure:failure];
        return;
    }
    [self _cleanupGen1Engine];
    if (atomic_load(&_gen1Cancelled)) {
        [self _completeGen1WithFailure:@"Video stabilization cancelled"];
        return;
    }
    [_videoInput markAsFinished];
    _gen1Finishing = YES;
    [_assetWriter finishWritingWithCompletionHandler:^{
        dispatch_async(self->_processingQueue, ^{
            if (self->_gen1Completed) return;
            NSString *writeFailure = nil;
            if (atomic_load(&self->_gen1Cancelled)) {
                writeFailure = @"Video stabilization cancelled";
            } else if (self->_assetWriter.status != AVAssetWriterStatusCompleted) {
                writeFailure = self->_assetWriter.error.localizedDescription ?: @"Video writing failed";
            }
            [self _completeGen1WithFailure:writeFailure];
        });
    }];
}

// A NULL sample means one delayed output frame, only called after real output.
- (BOOL)_processGen1Sample:(CMSampleBufferRef)sample failure:(NSString **)failure {
    if (atomic_load(&_gen1Cancelled)) {
        *failure = @"Video stabilization cancelled";
        return NO;
    }
    CVImageBufferRef source = sample ? CMSampleBufferGetImageBuffer(sample) : NULL;
    BOOL sourceLocked = NO;
    CVPixelBufferRef destination = NULL;
    CVOpenGLESTextureRef texture = NULL;
    PIXSMART_VS_PV_FRAMEINFO frameInfo = { .llTimestamp = -1 };
    PIXSMART_VS_PV_FRAME_YUV sourceFrame = {
        .i32Width = 0, .i32Height = 0, .format = FORMAT_NV12,
        .data = { .mDataY = NULL, .mDataUv = NULL }, .stride = { .mY = 0, .mUv = 0 }
    };
    do {
        if (sample) {
            if (!source || CVPixelBufferGetWidth(source) != (size_t)_inputSize.width ||
                CVPixelBufferGetHeight(source) != (size_t)_inputSize.height ||
                CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                CVPixelBufferGetPlaneCount(source) != 2 ||
                CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
                *failure = @"Invalid decoded video frame";
                break;
            }
            sourceLocked = YES;
            void *luma = CVPixelBufferGetBaseAddressOfPlane(source, 0);
            void *chroma = CVPixelBufferGetBaseAddressOfPlane(source, 1);
            size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0);
            size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1);
            if (!luma || !chroma || lumaStride < (size_t)_inputSize.width ||
                chromaStride < (size_t)_inputSize.width || lumaStride > INT_MAX || chromaStride > INT_MAX) {
                *failure = @"Invalid decoded video planes";
                break;
            }
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            CMTime duration = CMSampleBufferGetDuration(sample);
            if (!CMTIME_IS_NUMERIC(pts) || pts.value < 0) {
                *failure = @"Invalid video frame timestamp";
                break;
            }
            if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
                duration = _gen1FallbackDuration;
            }
            if (_gen1SubmittedFrames > 0 && CMTimeCompare(pts, _lastPresentationTime) <= 0) {
                pts = CMTimeAdd(_lastPresentationTime, duration);
            }
            CMTime nanoseconds = CMTimeConvertScale(pts, 1000000000, kCMTimeRoundingMethod_Default);
            if (!CMTIME_IS_NUMERIC(nanoseconds) || nanoseconds.value < 0) {
                *failure = @"Video frame timestamp exceeds stabilization limits";
                break;
            }
            _lastPresentationTime = pts;
            [queue enqueuePTS:pts duration:duration];
            if (!_gen1WriterSessionStarted) {
                [_assetWriter startSessionAtSourceTime:pts];
                _gen1WriterSessionStarted = YES;
            }
            frameInfo.llTimestamp = nanoseconds.value;
            sourceFrame.i32Width = (int)_inputSize.width;
            sourceFrame.i32Height = (int)_inputSize.height;
            sourceFrame.data.mDataY = luma;
            sourceFrame.data.mDataUv = chroma;
            sourceFrame.stride.mY = (int)lumaStride;
            sourceFrame.stride.mUv = (int)chromaStride;
        }
        if (!_pbAdaptor.pixelBufferPool ||
            CVPixelBufferPoolCreatePixelBuffer(NULL, _pbAdaptor.pixelBufferPool, &destination) != kCVReturnSuccess ||
            !destination) {
            *failure = @"Cannot allocate output video frame";
            break;
        }
        CVReturn textureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
            _textureCache, destination, NULL, GL_TEXTURE_2D, GL_RGBA, (int)_outputSize.width,
            (int)_outputSize.height, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
        if (textureResult != kCVReturnSuccess || !texture) {
            *failure = @"Cannot allocate output video texture";
            break;
        }
        GLuint textureID = CVOpenGLESTextureGetName(texture);
        glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
        glBindTexture(GL_TEXTURE_2D, textureID);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textureID, 0);
        if (textureID == 0 || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            *failure = @"Incomplete output video framebuffer";
            break;
        }
        PIXSMART_VS_PV_FRAME_GL destinationFrame = {
            .i32Width = (int)_outputSize.width, .i32Height = (int)_outputSize.height,
            .texture = textureID, .frameBuffer = _fbo, .isOes = 0
        };
        long timestampOut = PixSmartVsPvProcess(&_vsHandle, &frameInfo, &sourceFrame, &destinationFrame);
        if (sample) _gen1SubmittedFrames++;
        if (sourceLocked) {
            CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
            sourceLocked = NO;
        }
        if (atomic_load(&_gen1Cancelled)) {
            *failure = @"Video stabilization cancelled";
            break;
        }
        if (timestampOut >= 0) {
            CMTime outputPTS = [queue dequeuePTS];
            [queue dequeueDuration];
            if (!CMTIME_IS_NUMERIC(outputPTS)) {
                *failure = @"Stabilization returned an unexpected frame";
                break;
            }
            glFlush();
            NSTimeInterval writeDeadline = NSProcessInfo.processInfo.systemUptime + 15;
            while (!_videoInput.readyForMoreMediaData &&
                   _assetWriter.status == AVAssetWriterStatusWriting &&
                   !atomic_load(&_gen1Cancelled) && NSProcessInfo.processInfo.systemUptime < writeDeadline) {
                usleep(1000);
            }
            if (atomic_load(&_gen1Cancelled)) {
                *failure = @"Video stabilization cancelled";
                break;
            }
            if (_assetWriter.status != AVAssetWriterStatusWriting || !_videoInput.readyForMoreMediaData ||
                ![_pbAdaptor appendPixelBuffer:destination withPresentationTime:outputPTS]) {
                *failure = _assetWriter.error.localizedDescription ?: @"Cannot write stabilized video frame";
                break;
            }
            _currentFrameIndex++;
            [self.delegate onProcess:_currentFrameIndex total:_totalFrames];
        }
    } while (NO);
    if (sourceLocked) CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glFlush();
    if (texture) CFRelease(texture);
    if (destination) CFRelease(destination);
    if (_textureCache && _gen1SubmittedFrames % 10 == 0) CVOpenGLESTextureCacheFlush(_textureCache, 0);
    return *failure == nil;
}

- (void)_cleanupGen1Engine {
    if (_glContext) [EAGLContext setCurrentContext:_glContext];
    if (_gen1Initialized && _gen1SubmittedFrames > 0) {
        PixSmartVsPvUninit(&_vsHandle);
    } else if (_vsHandle) {
        // Mirrors Android's safety guard: vendor Uninit may crash with no real
        // input. There is no safe release API for this exceptional engine state.
        NSLog(@"PixSmart Gen1 skips unsafe zero-frame/failed-init release");
    }
    _vsHandle = NULL;
    _gen1Initialized = NO;
    if (_fbo) { glDeleteFramebuffers(1, &_fbo); _fbo = 0; }
    if (_textureCache) {
        CVOpenGLESTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
    if ([EAGLContext currentContext] == _glContext) [EAGLContext setCurrentContext:nil];
    _glContext = nil;
    [_assetReader cancelReading];
    _assetReader = nil;
    _videoOutput = nil;
    queue = nil;
}

- (void)_completeGen1WithFailure:(NSString *)failure {
    if (_gen1Completed) return;
    _gen1Completed = YES;
    _gen1Finishing = NO;
    _currentState = ProcessorStateStopped;
    if (failure && _assetWriter.status != AVAssetWriterStatusCompleted &&
        _assetWriter.status != AVAssetWriterStatusCancelled) {
        [_assetWriter cancelWriting];
    }
    [self _cleanupGen1Engine];
    _pbAdaptor = nil;
    _videoInput = nil;
    _assetWriter = nil;
    // Terminal callback follows all native work and writer cleanup. The bridge
    // may now safely release the worker, remove output, or start another engine.
    if (failure) {
        [self _notifyFailure:failure];
    } else {
        NSDictionary *result = @{
            @"width": @(_outputSize.width), @"height": @(_outputSize.height),
            @"frames": @(_currentFrameIndex), @"srcVideoPath": self.eisData.srcVideoPath,
            @"dstVideoPath": self.eisData.dstVideoPath
        };
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate onProcessFinish:result]; });
    }
}

#pragma mark - VideoWriter
- (BOOL)_setupVideoWriter:(float)targetBitRate withTransform:(CGAffineTransform)transform {
    NSError *error;
    NSURL *outputURL = [NSURL fileURLWithPath:self.eisData.dstVideoPath];
    // 检查父目录是否存在且可写
    NSString *parentDir = [self.eisData.dstVideoPath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] isWritableFileAtPath:parentDir]) {
        if (!self.useGen1Configuration) [self _notifyFailure:@"输出目录无写入权限"];
        return NO;
    }
    
    // 删除已存在的文件
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.eisData.dstVideoPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.eisData.dstVideoPath error:nil];
    }
    
    _assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL
                                             fileType:AVFileTypeMPEG4
                                                error:&error];
    if (error) {
        NSLog(@"AssetWriter初始化失败: %@", error);
        return NO;
    }
    
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(_outputSize.width),
        AVVideoHeightKey: @(_outputSize.height),
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(targetBitRate),
            AVVideoMaxKeyFrameIntervalKey: @(30),
            AVVideoAllowFrameReorderingKey: @YES,
            AVVideoExpectedSourceFrameRateKey: @(30),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        }
    };
    
    _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                     outputSettings:videoSettings];
    _videoInput.expectsMediaDataInRealTime = NO;
    _videoInput.transform = transform;
    
    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @((int)_outputSize.width),
        (id)kCVPixelBufferHeightKey : @((int)_outputSize.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferPoolMinimumBufferCountKey : @(6)
    };
    
    _pbAdaptor = [AVAssetWriterInputPixelBufferAdaptor
                  assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput
                  sourcePixelBufferAttributes:pbAttrs];
    
    if ([_assetWriter canAddInput:_videoInput]) {
        [_assetWriter addInput:_videoInput];
    } else {
        NSLog(@"add video input failed");
        return NO;
    }
    
    if (![_assetWriter startWriting]) {
        NSLog(@"startWriting failed: %@", _assetWriter.error);
        return NO;
    }
    
    NSLog(@"VideoStabilizeProcessorYUV setupVideoWriter done");
    return YES;
}

#pragma mark - Error
- (void)_notifyFailure:(NSString *)errorMsg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate onProcessFailed:@{@"error": errorMsg}];
    });
}

@end
