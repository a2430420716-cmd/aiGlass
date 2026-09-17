//
//  ViewController.m
//  videostabilization
//
//  Created by PixSmart on 2025/2/13.
//

#import "ViewController.h"
#import "EisData.h"
#import "VideoStabilizeProcessorGL.h"
#import <AVKit/AVKit.h>

#include "libpixsmart_vs_pv.framework/Headers/PixSmartVsPvApi.h"

@interface ViewController ()

@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;
@property (weak, nonatomic) IBOutlet UIButton *processButton;

@end

static CFAbsoluteTime _startTime;
#define TICK _startTime = CFAbsoluteTimeGetCurrent()
#define TOCK NSLog(@"耗时: %.6f 秒", CFAbsoluteTimeGetCurrent() - _startTime)

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.frame = CGRectMake(20, 100, self.view.bounds.size.width - 40, 10);
    self.progressView.hidden = YES;
    [self.view addSubview:self.progressView];
    
    // 文字标签
    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.font = [UIFont systemFontOfSize:14];
    self.progressLabel.textColor = [UIColor darkGrayColor];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.hidden = YES;
    self.progressLabel.numberOfLines = 0; // 关键：允许无限多行
    self.progressLabel.lineBreakMode = NSLineBreakByWordWrapping; // 按词换行
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progressLabel];
    [NSLayoutConstraint activateConstraints:@[
        // 水平定位
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        // 垂直定位（根据原代码的 y=120 换算）
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:120],
        // 不固定高度，由内容自动撑开
    ]];
}

// 生成临时文件路径（确保唯一性）
- (NSString *)generateTempVideoPath {
    // 获取 Documents 目录
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];
    
    // 创建临时视频子目录（如果不存在）
    NSString *tempVideoDir = [documentsDir stringByAppendingPathComponent:@"TempVideos"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:tempVideoDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:tempVideoDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    
    // 生成唯一文件名（避免覆盖）
    NSString *timestamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    NSString *filename = [NSString stringWithFormat:@"temp_video_%@.mp4", timestamp];
    
    return [tempVideoDir stringByAppendingPathComponent:filename];
}

- (IBAction)process:(id)sender {

    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *pixSmartSamplePath = [resourcePath stringByAppendingPathComponent:@"PixSmartSample"];
    NSLog(@"PixSmartSample源文件夹路径: %@", pixSmartSamplePath);

    NSError *error;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *allItems = [fileManager contentsOfDirectoryAtPath:pixSmartSamplePath error:&error];
    
    NSMutableArray *eisDataArray = [NSMutableArray array];
    for (NSString *item in allItems) {
        NSString *fullPath = [pixSmartSamplePath stringByAppendingPathComponent:item];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory] && isDirectory) {
            if ([item hasPrefix:@"EIS_DATA_"]) {
                EisData *data = [EisData eisDataFromFolderPath:fullPath];
                if (data) {
                    [eisDataArray addObject:data];
                }
            }
        }
    }
    
//    for (EisData *data in eisDataArray) {}
    EisData *data = eisDataArray.firstObject;

    // 获取 Documents 目录路径
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];
    data.dstVideoPath = [documentsDir stringByAppendingPathComponent:EisData.EIS_VIDEO_FILE];
    
    if (TRUE) {
        PIXSMART_VS_PV_TOKEN_RESULT result;
        PixSmartVsPvCheckLicense(data.licensesFilePath.UTF8String, "", "", &result);
//        return;
    }
    if (data) {
        self.processButton.enabled = FALSE;
        NSLog(@"数据包路径: %@", data.dataPath);
        NSLog(@"源视频路径: %@", data.srcVideoPath);
        NSLog(@"目标视频路径: %@", data.dstVideoPath);
        if (data.serialNumber) {
            NSLog(@"设备序列号: %@", data.serialNumber);
        } else {
            NSLog(@"未找到序列号");
        }
        NSLog(@"describe: %@", data.describe);

        TICK;

        VideoStabilizeProcessor *processor;
        processor = [[VideoStabilizeProcessorGL alloc] initWithEisData:data delegate:self];
        [processor startProcessing];
    }
}

#pragma mark - Delegate
- (void)onProcess:(NSInteger)current total:(NSInteger)total {
    float progress = (float)current / MAX(total, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressView.hidden = NO;
        self.progressLabel.hidden = NO;
        self.progressView.progress = progress;
        self.progressLabel.text = [NSString stringWithFormat:@"正在处理中 %ld / %ld", (long)current, (long)total];
    });
}

#pragma mark - Delegate
- (void)onProcessFinish:(NSDictionary *)videoInfo {
    NSLog(@"处理完成，info: %@", videoInfo);
    TOCK;

    
    NSString *srcVideoPath = videoInfo[@"srcVideoPath"];
    NSString *dstVideoPath = videoInfo[@"dstVideoPath"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dstVideoPath]) {
        NSLog(@"视频文件不存在: %@", dstVideoPath);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressLabel.text = [NSString stringWithFormat:@"处理完成，info: %@", videoInfo];
        [self playTwoVideosSideBySideWithPath1:srcVideoPath path2:dstVideoPath];
    });
}

- (void)onProcessFailed:(NSDictionary *)errorInfo {
    NSLog(@"处理失败: %@", errorInfo[@"error"]);
    self.progressView.hidden = YES;
    self.progressLabel.text = errorInfo[@"error"];
    self.processButton.enabled = YES;
}

- (void)playTwoVideosSideBySideWithPath1:(NSString *)path1 path2:(NSString *)path2 {
    NSURL *url1 = [NSURL fileURLWithPath:path1];
    NSURL *url2 = [NSURL fileURLWithPath:path2];

    AVPlayer *player1 = [AVPlayer playerWithURL:url1];
    AVPlayer *player2 = [AVPlayer playerWithURL:url2];

    AVPlayerLayer *layer1 = [AVPlayerLayer playerLayerWithPlayer:player1];
    AVPlayerLayer *layer2 = [AVPlayerLayer playerLayerWithPlayer:player2];

    CGFloat width = self.view.bounds.size.width / 2;
    CGFloat height = self.view.bounds.size.height;

    layer1.frame = CGRectMake(0, 0, width, height);
    layer2.frame = CGRectMake(width, 0, width, height);

    [self.view.layer addSublayer:layer1];
    [self.view.layer addSublayer:layer2];

   __block BOOL finished1 = NO;
   __block BOOL finished2 = NO;

   id observer1 = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                     object:player1.currentItem
                                                                      queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification *note) {
       finished1 = YES;
       dispatch_async(dispatch_get_main_queue(), ^{
           if (finished2) [self _hidePlaybackView];
       });
   }];

   id observer2 = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                     object:player2.currentItem
                                                                      queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(NSNotification *note) {
       finished2 = YES;
       dispatch_async(dispatch_get_main_queue(), ^{
           if (finished1) [self _hidePlaybackView];
       });
   }];

   [player1 play];
   [player2 play];
}

- (void)_hidePlaybackView {
    NSLog(@"hidePlaybackView");
    for (CALayer *layer in self.view.layer.sublayers.copy) {
        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            [layer removeFromSuperlayer];
        }
    }

    self.progressView.hidden = YES;
    self.progressLabel.hidden = YES;
    self.processButton.enabled = YES;
}


@end
