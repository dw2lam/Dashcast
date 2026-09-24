#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Private CoreGraphics virtual-display API (the one DeskPad, BetterDisplay and FluffyDisplay use).
// Signatures were checked against the Objective-C runtime on macOS 27; scalar fields are
// `unsigned int`. Releasing the CGVirtualDisplay object removes the display.

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject

@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;

/// Width/height are in points; with `hiDPI` the backing store is 2x.
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;

@end

@interface CGVirtualDisplaySettings : NSObject

@property (strong, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
/// 1 = HiDPI (2x backing), 0 = 1x.
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;

- (instancetype)init;

@end

@interface CGVirtualDisplayDescriptor : NSObject

@property (strong, nonatomic, nullable) dispatch_queue_t queue;
@property (strong, nonatomic) NSString *name;
/// Largest backing size in pixels any mode may use.
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
/// Called on `queue` when the system tears the display down.
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable reason, CGVirtualDisplay *display);

- (instancetype)init;

@end

@interface CGVirtualDisplay : NSObject

@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) unsigned int vendorID;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int serialNum;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

NS_ASSUME_NONNULL_END
