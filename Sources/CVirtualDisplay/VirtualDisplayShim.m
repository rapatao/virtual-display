#if !__has_feature(objc_arc)
#error "VirtualDisplayShim requires ARC"
#endif

#import <Foundation/Foundation.h>
#import "VirtualDisplayShim.h"

// Private classes, declared only so messages can be sent. They are never referenced as
// symbols: the classes are found with NSClassFromString.
@interface VDMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface VDSettings : NSObject
- (void)setHiDPI:(unsigned int)hiDPI;
- (void)setModes:(NSArray *)modes;
@end

@interface VDDescriptor : NSObject
- (void)setName:(NSString *)name;
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setMaxPixelsWide:(unsigned int)value;
- (void)setMaxPixelsHigh:(unsigned int)value;
- (void)setSizeInMillimeters:(CGSize)value;
- (void)setQueue:(dispatch_queue_t)queue;
@end

@interface VDDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (unsigned int)displayID;
- (BOOL)applySettings:(id)settings;
@end

static id VDSettingsFor(uint32_t width, uint32_t height, double refreshRate) {
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!modeClass || !settingsClass) return nil;
    if (![modeClass instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) return nil;
    VDMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    VDSettings *settings = [[settingsClass alloc] init];
    if (!mode || !settings
        || ![settings respondsToSelector:@selector(setHiDPI:)]
        || ![settings respondsToSelector:@selector(setModes:)]) return nil;
    [settings setHiDPI:0];
    [settings setModes:@[mode]];
    return settings;
}

void *VDVirtualDisplayCreate(const char *name,
                             uint32_t vendorID, uint32_t productID, uint32_t serial,
                             uint32_t maxWidth, uint32_t maxHeight,
                             double widthMM, double heightMM,
                             uint32_t width, uint32_t height, double refreshRate,
                             CGDirectDisplayID *displayID) {
    @try {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        if (!descriptorClass || !displayClass) return NULL;

        VDDescriptor *descriptor = [[descriptorClass alloc] init];
        SEL required[] = {
            @selector(setName:), @selector(setVendorID:), @selector(setProductID:),
            @selector(setSerialNum:), @selector(setMaxPixelsWide:), @selector(setMaxPixelsHigh:),
            @selector(setSizeInMillimeters:), @selector(setQueue:),
        };
        for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); i++) {
            if (![descriptor respondsToSelector:required[i]]) return NULL;
        }
        [descriptor setName:[NSString stringWithUTF8String:name]];
        [descriptor setVendorID:vendorID];
        [descriptor setProductID:productID];
        [descriptor setSerialNum:serial];
        [descriptor setMaxPixelsWide:maxWidth];
        [descriptor setMaxPixelsHigh:maxHeight];
        [descriptor setSizeInMillimeters:CGSizeMake(widthMM, heightMM)];
        [descriptor setQueue:dispatch_get_main_queue()];

        if (![displayClass instancesRespondToSelector:@selector(initWithDescriptor:)]) return NULL;
        VDDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display
            || ![display respondsToSelector:@selector(displayID)]
            || ![display respondsToSelector:@selector(applySettings:)]) return NULL;

        id settings = VDSettingsFor(width, height, refreshRate);
        if (!settings || ![display applySettings:settings]) return NULL;
        unsigned int identifier = [display displayID];
        if (identifier == 0) return NULL;
        *displayID = identifier;
        return (void *)CFBridgingRetain(display);
    } @catch (NSException *exception) {
        return NULL;
    } @catch (id other) {
        return NULL;
    }
}

bool VDVirtualDisplayApplyMode(void *handle, uint32_t width, uint32_t height, double refreshRate) {
    @try {
        VDDisplay *display = (__bridge VDDisplay *)handle;
        id settings = VDSettingsFor(width, height, refreshRate);
        return settings && [display applySettings:settings];
    } @catch (NSException *exception) {
        return false;
    } @catch (id other) {
        return false;
    }
}

void VDVirtualDisplayRelease(void *handle) {
    CFRelease(handle);
}
