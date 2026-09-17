//////////////////////////////////////////////////////////////////////////
//                  PixSmart纯图像EIS算法SDK（IOS）                 //
//////////////////////////////////////////////////////////////////////////

文件列表:
|---framework
    |---libpixsmart_vs_pv.framework                    防抖算法库
|---SXS_VideoStabilizePvDemo                           参考代码
|---readme.txt

算法集成/调用说明：
1、替换鉴权文件PixSmartSample/EIS_DATA_1/SXS_VideoStabilizePv_License_IOS.data
2、调用PixSmartVsPvCheckLicense检查权限，PIXSMART_VS_PV_TOKEN_RESULT的result为0表示鉴权通过，license_data为单台设备使用的鉴权标识码
3、调用VideoStabilizePvProcessorGL进行处理