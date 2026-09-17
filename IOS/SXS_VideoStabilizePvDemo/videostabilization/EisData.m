#import "EisData.h"

@implementation EisData

#pragma mark - Static Constants
static NSString *const LICENSE_FILE_NAME = @"SXS_VideoStabilizePv_IOS_License.data";
static NSString *const EIS_DATA = @"EIS_DATA";
static NSString *const DATA_VIDEO_FILE = @"data_video.txt";
static NSString *const DATA_ACCEL_FILE = @"data_accel.txt";
static NSString *const DATA_GYRO_FILE = @"data_gyro.txt";
static NSString *const DVS_CONFIG_BIN = @"dvs_config.bin";
static NSString *const DESCRIBE_FILE = @"describe.txt";
static NSString *const SRC_VIDEO_FILE = @"src.mp4";
static NSString *const EIS_VIDEO_FILE = @"eis.mp4";

#pragma mark - Class Constants Getters
+ (NSString *)LICENSE_FILE_NAME { return LICENSE_FILE_NAME; }
+ (NSString *)EIS_DATA { return EIS_DATA; }
+ (NSString *)DATA_VIDEO_FILE { return DATA_VIDEO_FILE; }
+ (NSString *)DATA_ACCEL_FILE { return DATA_ACCEL_FILE; }
+ (NSString *)DATA_GYRO_FILE { return DATA_GYRO_FILE; }
+ (NSString *)DVS_CONFIG_BIN { return DVS_CONFIG_BIN; }
+ (NSString *)DESCRIBE_FILE { return DESCRIBE_FILE; }
+ (NSString *)SRC_VIDEO_FILE { return SRC_VIDEO_FILE; }
+ (NSString *)EIS_VIDEO_FILE { return EIS_VIDEO_FILE; }

#pragma mark - Class Methods
+ (BOOL)isEisDataDirectory:(NSURL *)directory {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:directory.path isDirectory:&isDirectory] || !isDirectory) {
        return NO;
    }
    
    // Check directory name contains EIS_DATA
    if (![directory.lastPathComponent containsString:EIS_DATA]) {
        return NO;
    }
    
    // Check required files
    __block BOOL hasVideo = NO;
    __block BOOL hasDataCamera = NO;
    __block BOOL hasDataGyro = NO;
    __block BOOL hasConfigBin = NO;
    
    NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:directory
                                   includingPropertiesForKeys:nil
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        error:nil];
    [contents enumerateObjectsUsingBlock:^(NSURL * _Nonnull url, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *fileName = url.lastPathComponent;
        if ([fileName isEqualToString:SRC_VIDEO_FILE]) {
            hasVideo = YES;
        } else if ([fileName isEqualToString:DATA_VIDEO_FILE]) {
            hasDataCamera = YES;
        } else if ([fileName isEqualToString:DATA_GYRO_FILE]) {
            hasDataGyro = YES;
        } else if ([fileName isEqualToString:DVS_CONFIG_BIN]) {
            hasConfigBin = YES;
        }
    }];
    
    return hasVideo/* && hasDataCamera && hasDataGyro && hasConfigBin*/;
}

#pragma mark - 从文件夹路径创建EisData对象
+ (EisData *)eisDataFromFolderPath:(NSString *)folderPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 检查是否是合法的EIS数据文件夹
    if (![self isEisDataDirectory:[NSURL fileURLWithPath:folderPath]]) {
        return nil;
    }
    
    EisData *eisData = [[EisData alloc] init];
    
    // 基础路径
    eisData.dataPath = folderPath;
    
    // 关键文件路径拼接
    eisData.srcVideoPath = [folderPath stringByAppendingPathComponent:SRC_VIDEO_FILE];
    eisData.binPath = folderPath;//[folderPath stringByAppendingPathComponent:DVS_CONFIG_BIN];
//    eisData.dstVideoPath = [folderPath stringByAppendingPathComponent:EIS_VIDEO_FILE];
    
    // 描述文件内容读取
    NSString *describePath = [folderPath stringByAppendingPathComponent:DESCRIBE_FILE];
    if ([fm fileExistsAtPath:describePath]) {
        eisData.describe = [NSString stringWithContentsOfFile:describePath encoding:NSUTF8StringEncoding error:nil];
    }
    
    // 授权文件路径（根据需求调整）
    eisData.licensesFilePath = [folderPath stringByAppendingPathComponent:LICENSE_FILE_NAME];
    
    return eisData;
}


#pragma mark - NSCoding
// 根据需求实现NSSecureCoding协议方法（可选）
+ (BOOL)supportsSecureCoding { return YES; }

@end
