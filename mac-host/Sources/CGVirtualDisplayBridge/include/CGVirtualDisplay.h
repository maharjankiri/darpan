#ifndef CGVirtualDisplay_h
#define CGVirtualDisplay_h

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Private API forward declarations
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (CGDirectDisplayID)displayID;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// C wrapper functions callable from Swift
typedef struct {
    void *display;          // Retained CGVirtualDisplay*
    CGDirectDisplayID displayID;
} VirtualDisplayHandle;

VirtualDisplayHandle CreateVirtualDisplay(
    NSUInteger width,
    NSUInteger height,
    double refreshRate,
    const char *name,
    bool hiDPI
);

void DestroyVirtualDisplay(VirtualDisplayHandle handle);

#endif /* CGVirtualDisplay_h */
