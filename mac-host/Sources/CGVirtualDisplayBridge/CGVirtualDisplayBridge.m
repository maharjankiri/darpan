#import "CGVirtualDisplay.h"
#import <objc/runtime.h>

VirtualDisplayHandle CreateVirtualDisplay(
    NSUInteger width,
    NSUInteger height,
    double refreshRate,
    const char *name,
    bool hiDPI
) {
    VirtualDisplayHandle handle = {0};

    // Verify the private classes exist at runtime
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");

    if (!displayClass || !descriptorClass || !modeClass) {
        NSLog(@"[VirtualDisplay] Private API classes not found. "
              @"CGVirtualDisplay=%p, Descriptor=%p, Mode=%p",
              displayClass, descriptorClass, modeClass);
        return handle;
    }

    @try {
        // Create display mode
        CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width
                                                              height:height
                                                         refreshRate:refreshRate];
        if (!mode) {
            NSLog(@"[VirtualDisplay] Failed to create display mode %lux%lu@%.0fHz",
                  (unsigned long)width, (unsigned long)height, refreshRate);
            return handle;
        }

        // Create descriptor (no modes or hiDPI — those go on Settings)
        CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
        descriptor.name = [NSString stringWithUTF8String:name];
        // maxPixels must be 2x the mode resolution for HiDPI backing store
        descriptor.maxPixelsWide = hiDPI ? width * 2 : width;
        descriptor.maxPixelsHigh = hiDPI ? height * 2 : height;
        // Physical size of Galaxy Tab S10 Ultra (326.4 x 208.6 mm)
        // This helps macOS calculate the correct default scaling
        descriptor.sizeInMillimeters = CGSizeMake(326, 209);
        descriptor.vendorID = 0x1234;
        descriptor.productID = 0x5678;
        descriptor.serialNum = 0x0001;

        // Descriptor needs a dispatch queue
        dispatch_queue_t queue = dispatch_queue_create("com.secondscreen.virtualdisplay", DISPATCH_QUEUE_SERIAL);
        descriptor.dispatchQueue = queue;

        // Create virtual display
        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            NSLog(@"[VirtualDisplay] Failed to create virtual display");
            return handle;
        }

        CGDirectDisplayID displayID = [display displayID];
        if (displayID == 0) {
            NSLog(@"[VirtualDisplay] Virtual display created but got displayID=0");
            return handle;
        }

        // Apply settings with modes and hiDPI
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        if (settingsClass) {
            CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
            settings.modes = @[mode];
            settings.hiDPI = hiDPI ? 1 : 0;
            [display applySettings:settings];
        }

        NSLog(@"[VirtualDisplay] Created virtual display: %lux%lu@%.0fHz, displayID=%u",
              (unsigned long)width, (unsigned long)height, refreshRate, displayID);

        // Retain the display object so it stays alive
        handle.display = (__bridge_retained void *)display;
        handle.displayID = displayID;

    } @catch (NSException *exception) {
        NSLog(@"[VirtualDisplay] Exception: %@", exception);
    }

    return handle;
}

void DestroyVirtualDisplay(VirtualDisplayHandle handle) {
    if (handle.display) {
        NSLog(@"[VirtualDisplay] Destroying virtual display %u", handle.displayID);
        // Release the retained display object — this tears down the virtual display
        CGVirtualDisplay *display = (__bridge_transfer CGVirtualDisplay *)handle.display;
        (void)display; // ARC will release it
    }
}
