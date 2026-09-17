#ifndef PIXSMART_COMDEF_H
#define PIXSMART_COMDEF_H

typedef long                    MLong;
typedef float                   MFloat;
typedef double                  MDouble;
typedef unsigned char           MByte;
typedef unsigned short          MWord;
typedef unsigned int            MDWord;
typedef void*                   MHandle;
typedef char                    MChar;
typedef long                    MBool;
typedef void                    MVoid;
typedef void*                   MPVoid;
typedef char*                   MPChar;
typedef short                   MShort;
typedef const char*             MPCChar;
typedef MLong                   MRESULT;
typedef MDWord                  MCOLORREF;
typedef signed      char        MInt8;
typedef unsigned    char        MUInt8;
typedef signed      short       MInt16;
typedef unsigned    short       MUInt16;
typedef signed      int         MInt32;
typedef unsigned    int         MUInt32;

#if !defined(M_UNSUPPORT64)
#if defined(_MSC_VER)
typedef signed      __int64     MInt64;
typedef unsigned    __int64     MUInt64;
#else
typedef signed      long long   MInt64;
typedef unsigned    long long   MUInt64;
#endif
#endif

typedef struct __tag_rect
{
    MInt32 left;
    MInt32 top;
    MInt32 right;
    MInt32 bottom;
} MRECT, *PMRECT;

typedef struct __tag_point
{
    MInt32 x;
    MInt32 y;
} MPOINT, *PMPOINT;

typedef struct __tag_point3
{
    MInt32 x;
    MInt32 y;
    MInt32 z;
} MPOINT3, *PMPOINT3;

typedef struct __tag_rectf
{
    MFloat left;
    MFloat top;
    MFloat right;
    MFloat bottom;
} MRECTF, *PMRECTF;

typedef struct __tag_pointf
{
    MFloat x;
    MFloat y;
} MPOINTF, *PMPOINTF;

typedef struct __tag_point3f
{
    MFloat x;
    MFloat y;
    MFloat z;
} MPOINT3F, *PMPOINT3F;

#define MNull       0
#define MFalse      0
#define MTrue       1

#endif //PIXSMART_COMDEF_H
