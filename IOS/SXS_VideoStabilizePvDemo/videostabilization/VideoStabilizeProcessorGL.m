#import "VideoStabilizeProcessorGL.h"

#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#include "libpixsmart_vs_pv.framework/Headers/PixSmartVsPvApi.h"
#import "CMTimeDualQueue.h"

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
    }
    return self;
}

#pragma mark - Public
- (void)startProcessing {
    if (_currentState != ProcessorStateIdle) return;
    _currentState = ProcessorStateInitializing;
    
    dispatch_async(_processingQueue, ^{
        [self _processing];
    });
}

- (void)stopProcessing {
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
    
    if (_totalFrames < 15) {
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
    
    // 与 Android 导入流程保持一致（二代眼镜参数）。
    float dregScale = 360.0f / MAX(_inputSize.width, _inputSize.height);
    PIXSMART_VS_PV_PARAM vsParam = {
        .inWidth = (uint32_t)_inputSize.width,
        .inHeight = (uint32_t)_inputSize.height,
        .outWidth = (uint32_t)_outputSize.width,
        .outHeight = (uint32_t)_outputSize.height,
        .outScale = 0.8,
        .dregScale = dregScale,
        .stdev = 3,
        .colorStandard = BT709
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

#pragma mark - VideoWriter
- (BOOL)_setupVideoWriter:(float)targetBitRate withTransform:(CGAffineTransform)transform {
    NSError *error;
    NSURL *outputURL = [NSURL fileURLWithPath:self.eisData.dstVideoPath];
    // 检查父目录是否存在且可写
    NSString *parentDir = [self.eisData.dstVideoPath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] isWritableFileAtPath:parentDir]) {
        [self _notifyFailure:@"输出目录无写入权限"];
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
