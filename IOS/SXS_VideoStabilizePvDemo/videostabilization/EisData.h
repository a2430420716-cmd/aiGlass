#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EisData : NSObject <NSSecureCoding>

#pragma mark - Static Constants
@property (class, nonatomic, readonly) NSString *LICENSE_FILE_NAME;
@property (class, nonatomic, readonly) NSString *EIS_DATA;
@property (class, nonatomic, readonly) NSString *DATA_VIDEO_FILE;
@property (class, nonatomic, readonly) NSString *DATA_ACCEL_FILE;
@property (class, nonatomic, readonly) NSString *DATA_GYRO_FILE;
@property (class, nonatomic, readonly) NSString *DATA_INFO_FILE;
@property (class, nonatomic, readonly) NSString *DVS_CONFIG_BIN;
@property (class, nonatomic, readonly) NSString *DESCRIBE_FILE;
@property (class, nonatomic, readonly) NSString *SRC_VIDEO_FILE;
@property (class, nonatomic, readonly) NSString *EIS_VIDEO_FILE;

#pragma mark - Class Methods
+ (BOOL)isEisDataDirectory:(NSURL *)directory;
+ (EisData *)eisDataFromFolderPath:(NSString *)folderPath;

#pragma mark - Instance Properties
@property (nonatomic, copy) NSString *dataPath;
@property (nonatomic, copy) NSString *binPath;
@property (nonatomic, copy) NSString *srcVideoPath;
@property (nonatomic, copy) NSString *dstVideoPath;
@property (nonatomic, copy) NSString *describe;
@property (nonatomic, copy) NSString *licensesFilePath;
@property (nonatomic, copy) NSString *licensesFilePathLdc;
@property (nonatomic, copy) NSString *activationCodeFilePath;
@property (nonatomic, copy, nullable) NSString *serialNumber;


@end

NS_ASSUME_NONNULL_END
