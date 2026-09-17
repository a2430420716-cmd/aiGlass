#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// PixSmart 纯图像 EIS：对照片做防抖处理。
@interface PixSmartImageStabilizer : NSObject

/// 是否可用（真机 + 鉴权通过）。模拟器恒为 NO。
+ (BOOL)isAvailable;

/// 提前鉴权（应在有公网时调用；连眼镜热点前）。
+ (BOOL)prewarmLicense;

/// 对 JPEG/PNG 图片数据做 EIS。失败返回 nil（调用方应回退原图）。
+ (nullable NSData *)stabilizeImageData:(NSData *)imageData
                          compressionQuality:(CGFloat)quality
                                       error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
