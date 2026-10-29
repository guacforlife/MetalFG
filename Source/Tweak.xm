#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <atomic>

#import "../Headers/ShaderTypes.h"
#import "../Headers/TouchTracker.h"
#import "../Headers/MetalFGWarper.h"
#import "../Headers/MetalFGSynchronizer.h"
#import "../Headers/MetalFGOverlay.h"

// Minimum dimension threshold to filter out tiny HUDs/overlays (e.g. MetalHUD, CAPerfHud)
static const CGFloat kMinHUDDimension = 200.0;

// Global reference to the active game layer
static __weak CAMetalLayer *gActiveMetalLayer = nil;

// ============================================================================
// Diagnostics: file log in the app's tmp dir (NSLog output is suppressed on iOS 16)
// ============================================================================
static NSString *MFGLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@".metalfg.log"];
}

static void MFGLog(NSString *fmt, ...) {
    static dispatch_queue_t logQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logQueue = dispatch_queue_create("com.metalfg.log", DISPATCH_QUEUE_SERIAL);
    });
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    dispatch_async(logQueue, ^{
        NSString *path = MFGLogPath();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

// Present-path counters, logged every 5s for the first 2 minutes
static std::atomic<uint64_t> gStatNextDrawable{0};          // game-layer drawables handed out
static std::atomic<uint64_t> gStatPresented{0};             // game-layer drawables that reached the screen
static std::atomic<uint64_t> gStatPresentDropped{0};        // game-layer drawables released without being shown
static std::atomic<uint64_t> gStatCommandBufferPresent{0};  // -[_MTLCommandBuffer presentDrawable*] calls
static std::atomic<uint64_t> gStatDrawablePresent{0};       // -[CAMetalDrawable present / presentAtTime:] calls
static std::atomic<uint64_t> gStatSuppressed{0};            // native presents taken over by MetalFG
static std::atomic<uint64_t> gStatPassThrough{0};           // native presents left to the original
static std::atomic<uint64_t> gStatNativeProcessed{0};       // frames handed to the synchronizer
static std::atomic<uint64_t> gStatLayerMismatch{0};         // frames dropped: drawable not on the active layer

// Helper: Determine if a layer is a candidate for the primary game rendering layer
static inline BOOL IsGameLayerCandidate(CAMetalLayer *layer) {
    if (!layer) return NO;
    
    // Ignore layers with names or classes indicating HUD/debug/metrics
    NSString *className = NSStringFromClass([layer class]);
    if ([className containsString:@"HUD"] ||
        [className containsString:@"Perf"] ||
        [className containsString:@"Debug"] ||
        [className containsString:@"Overlay"]) {
        return NO;
    }
    
    // If size is set, check that it's larger than tiny HUD overlays
    CGSize drawableSize = layer.drawableSize;
    if (drawableSize.width > 0 && drawableSize.height > 0) {
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) {
            return NO;
        }
    }
    
    return YES;
}

// ============================================================================
// Hook: Unlock 120Hz ProMotion on iOS 16 Devices
// ============================================================================
%hook UIScreen

- (NSInteger)maximumFramesPerSecond {
    return 120;
}

%end

// ============================================================================
// Hook: NSBundle to enable ProMotion 120Hz for any game
// (Bypasses iOS 16 ProMotion 60Hz throttle on games lacking this plist key)
// ============================================================================
%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CADisableMinimumFrameDurationOnPhone"]) {
        return @YES;
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (orig && !orig[@"CADisableMinimumFrameDurationOnPhone"]) {
        NSMutableDictionary *dict = [orig mutableCopy];
        dict[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
        return dict;
    }
    return orig;
}

%end

// ============================================================================
// Hook: CAMetalLayer Lifecycle & Swapchain Headroom
// ============================================================================
%hook CAMetalLayer

- (void)setFramebufferOnly:(BOOL)framebufferOnly {
    if (IsGameLayerCandidate(self)) {
        %orig(NO);
    } else {
        %orig(framebufferOnly);
    }
}

- (void)setDevice:(id<MTLDevice>)device {
    %orig(device);
    
    if (IsGameLayerCandidate(self)) {
        self.maximumDrawableCount = 3;
        self.framebufferOnly = NO;
        if (@available(iOS 16.0, *)) {
            // Avoid driver deadlocks when GPU queue backpressure is high
            self.allowsNextDrawableTimeout = YES;
        }
        gActiveMetalLayer = self;
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                    device:device
                                                               pixelFormat:self.pixelFormat];
    }
}

- (id<CAMetalDrawable>)nextDrawable {
    if (IsGameLayerCandidate(self)) {
        if (self.maximumDrawableCount < 3) {
            self.maximumDrawableCount = 3;
        }
        if (self.framebufferOnly) {
            self.framebufferOnly = NO;
        }
        if (@available(iOS 16.0, *)) {
            self.allowsNextDrawableTimeout = YES;
        }
        
        gActiveMetalLayer = self;
        
        if ([MetalFGSynchronizer sharedSynchronizer].activeLayer != self) {
            MFGLog(@"binding game layer %@ drawableSize %.0fx%.0f pixelFormat %lu",
                   self, self.drawableSize.width, self.drawableSize.height, (unsigned long)self.pixelFormat);
            [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:self
                                                                        device:self.device
                                                                   pixelFormat:self.pixelFormat];
        }
    }
    id<CAMetalDrawable> drawable = %orig;
    if (drawable && IsGameLayerCandidate(self)) {
        uint64_t n = gStatNextDrawable++;
        if (n < 2) {
            MFGLog(@"nextDrawable #%llu: %s on layer %p (%.0fx%.0f)", n, object_getClassName(drawable), self,
                   self.drawableSize.width, self.drawableSize.height);
        }
        [drawable addPresentedHandler:^(id<MTLDrawable> d) {
            if (d.presentedTime > 0) gStatPresented++; else gStatPresentDropped++;
        }];
    }
    return drawable;
}

%end

// ============================================================================
// Helper: Process Native Frame Presentation
// ============================================================================
static inline void ProcessNativePresentation(id<CAMetalDrawable> drawable) {
    if (!drawable) return;
    
    // 1. Recursion guard: ignore our own synthetic warp frames
    NSNumber *isSynthetic = objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey);
    if (isSynthetic && [isSynthetic boolValue]) {
        return;
    }
    
    id<MTLTexture> texture = drawable.texture;
    if (!texture) return;
    
    // 3. HUD / Overlay guard: ignore small textures (e.g. CAPerfHud / MetalHUD)
    if (texture.width < 250 || texture.height < 150) {
        return;
    }
    
    // 4. Bind active layer if not already bound
    CAMetalLayer *activeLayer = [MetalFGSynchronizer sharedSynchronizer].activeLayer;
    if (!activeLayer && drawable.layer) {
        activeLayer = drawable.layer;
        activeLayer.framebufferOnly = NO;
        [[MetalFGSynchronizer sharedSynchronizer] startSynchronizerWithLayer:activeLayer
                                                                    device:activeLayer.device
                                                               pixelFormat:activeLayer.pixelFormat];
    }
    
    // 5. If layer is set, ensure this drawable belongs to the game layer
    if (activeLayer && drawable.layer && drawable.layer != activeLayer) {
        if (gStatLayerMismatch++ < 3) {
            MFGLog(@"drop: drawable layer %@ is not the active layer %@", drawable.layer, activeLayer);
        }
        return;
    }

    gStatNativeProcessed++;
    [[MetalFGSynchronizer sharedSynchronizer] notifyNativeFrameRendered:drawable];
}

// ============================================================================
// Shared native-present interception for every presentDrawable variant.
// Returns YES when MetalFG took over the presentation (caller must NOT call the original).
// ============================================================================
static const char kMFGPresentHandledKey = '\0';  // drawable already went through a presentDrawable hook

static BOOL InterceptNativePresent(id<MTLCommandBuffer> commandBuffer, id<MTLDrawable> drawable) {
    if (![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        return NO;
    }
    id<CAMetalDrawable> metalDrawable = (id<CAMetalDrawable>)drawable;
    NSNumber *isSynthetic = objc_getAssociatedObject(metalDrawable, &kMetalFGIsSyntheticKey);
    if (isSynthetic && [isSynthetic boolValue]) {
        return NO;
    }
    objc_setAssociatedObject(metalDrawable, &kMFGPresentHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<MTLTexture> tex = metalDrawable.texture;
    BOOL isGameDrawable = (tex && tex.width >= 250 && tex.height >= 150 && IsGameLayerCandidate(metalDrawable.layer));
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        ProcessNativePresentation(metalDrawable);
    }];
    if (isGameDrawable && [MetalFGSynchronizer sharedSynchronizer].isEnabled) {
        gStatSuppressed++;
        return YES; // Suppress direct presentation: Option 3 presents S_{N-0.5} upon completion!
    }
    gStatPassThrough++;
    return NO;
}

// ============================================================================
// Scheduled-handler presents. Unity games such as Z Route: Redemption never call presentDrawable::
// they add their own scheduled handler that calls [drawable present]. Every scheduled handler is
// wrapped so the present hook knows which command buffer rendered the frame; it waits for that
// command buffer to complete off-thread, then hands the drawable to the synchronizer exactly like
// the presentDrawable path does.
// ============================================================================
static thread_local __unsafe_unretained id<MTLCommandBuffer> tlsSchedulingCommandBuffer = nil;  // valid only inside a wrapped handler
static dispatch_queue_t gScheduledPresentQueue;

// Returns YES when MetalFG took over the presentation (caller must NOT call the original).
static BOOL InterceptScheduledDrawablePresent(id<CAMetalDrawable> drawable) {
    id<MTLCommandBuffer> commandBuffer = tlsSchedulingCommandBuffer;
    if (!commandBuffer || objc_getAssociatedObject(drawable, &kMFGPresentHandledKey)) {
        return NO;
    }
    NSNumber *isSynthetic = objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey);
    if (isSynthetic && [isSynthetic boolValue]) {
        return NO;
    }
    id<MTLTexture> tex = drawable.texture;
    if (!tex || tex.width < 250 || tex.height < 150 || !IsGameLayerCandidate(drawable.layer)) {
        return NO;
    }
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true)) {
        MFGLog(@"game presents from a scheduled handler on %s: intercepting", object_getClassName(commandBuffer));
    }
    BOOL takeOver = [MetalFGSynchronizer sharedSynchronizer].isEnabled;
    dispatch_async(gScheduledPresentQueue, ^{
        [commandBuffer waitUntilCompleted];
        ProcessNativePresentation(drawable);
    });
    if (takeOver) gStatSuppressed++; else gStatPassThrough++;
    return takeOver;
}

// ============================================================================
// Hook: CAMetalDrawable Direct Presentations
// ============================================================================
%hook CAMetalDrawable

- (void)present {
    gStatDrawablePresent++;
    if (InterceptScheduledDrawablePresent((id<CAMetalDrawable>)self)) return;
    %orig;
}

- (void)presentAtTime:(CFTimeInterval)presentationTime {
    gStatDrawablePresent++;
    if (InterceptScheduledDrawablePresent((id<CAMetalDrawable>)self)) return;
    %orig(presentationTime);
}

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    NSNumber *isSynthetic = objc_getAssociatedObject(self, &kMetalFGIsSyntheticKey);
    if ((!isSynthetic || ![isSynthetic boolValue]) && [MetalFGSynchronizer sharedSynchronizer].isEnabled) {
        CFTimeInterval durationCap = duration / 2.0;
        %orig(durationCap);
        return;
    }
    %orig(duration);
}

%end

// ============================================================================
// Hook: MTLCommandBuffer Presentations
// ============================================================================
@interface _MTLCommandBuffer : NSObject <MTLCommandBuffer>
@end

%hook _MTLCommandBuffer

- (void)presentDrawable:(id<MTLDrawable>)drawable {
    gStatCommandBufferPresent++;
    if (InterceptNativePresent((id<MTLCommandBuffer>)self, drawable)) return;
    %orig(drawable);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)presentationTime {
    gStatCommandBufferPresent++;
    if (InterceptNativePresent((id<MTLCommandBuffer>)self, drawable)) return;
    %orig(drawable, presentationTime);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration {
    gStatCommandBufferPresent++;
    if (InterceptNativePresent((id<MTLCommandBuffer>)self, drawable)) return;
    %orig(drawable, duration);
}

- (void)addScheduledHandler:(MTLCommandBufferHandler)block {
    if (!block) {
        %orig(block);
        return;
    }
    MTLCommandBufferHandler wrapped = ^(id<MTLCommandBuffer> commandBuffer) {
        id<MTLCommandBuffer> outer = tlsSchedulingCommandBuffer;
        tlsSchedulingCommandBuffer = commandBuffer;
        block(commandBuffer);
        tlsSchedulingCommandBuffer = outer;
    };
    %orig(wrapped);
}

%end

// ============================================================================
// Hook: UIWindow makeKeyAndVisible & touch event dispatching
// ============================================================================
%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    %orig(event);
    if (event.type == UIEventTypeTouches) {
        [[MetalFGTouchTracker sharedTracker] processTouchEvent:event];
    }
}

- (void)makeKeyAndVisible {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (![className containsString:@"MetalFGOverlay"] && gActiveMetalLayer != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MetalFGOverlay sharedOverlay] show];
        });
    }
}

%end

// ============================================================================
// Constructor & Safe Process Filtering (Dopamine Userspace Reboot Safe)
// ============================================================================
%ctor {
    @autoreleasepool {
        const char *progname = getprogname();
        if (!progname) return;
        
        // Verify executable path via dyld first
        char execPath[1024];
        uint32_t size = sizeof(execPath);
        if (_NSGetExecutablePath(execPath, &size) != 0) {
            return;
        }
        
        // POSITIVE WHITELIST: Strictly require user/AppStore/TrollStore app bundle path!
        // On iOS 15/16, all third-party games reside in /var/containers/Bundle/Application/<UUID>/<App>.app/
        // System daemons (backboardd, SpringBoard, PreBoard, launchd, CARenderServer) and jailbreak utilities
        // NEVER reside in /var/containers/Bundle/Application/, preventing any userspace reboot freeze.
        if (strstr(execPath, "/var/containers/Bundle/Application/") == NULL) {
            return;
        }
        
        // Strictly ensure this binary is inside a main .app bundle and NOT an app extension (.appex) or XPC service
        if (strstr(execPath, ".app/") == NULL ||
            strstr(execPath, ".appex/") != NULL ||
            strstr(execPath, ".xpc/") != NULL) {
            return;
        }
        
        // Reject known non-game utilities & package managers even if installed in user containers
        if (strcmp(progname, "Sileo") == 0 ||
            strcmp(progname, "Zebra") == 0 ||
            strcmp(progname, "Dopamine") == 0 ||
            strcmp(progname, "TrollStore") == 0 ||
            strcmp(progname, "Filza") == 0) {
            return;
        }
        
        // Check CFBundleIdentifier if available at constructor time
        CFBundleRef mainBundle = CFBundleGetMainBundle();
        if (mainBundle) {
            CFStringRef cfBundleId = CFBundleGetIdentifier(mainBundle);
            if (cfBundleId) {
                if (CFStringHasPrefix(cfBundleId, CFSTR("com.apple.")) ||
                    CFStringHasPrefix(cfBundleId, CFSTR("com.opa334.")) ||
                    CFStringHasPrefix(cfBundleId, CFSTR("org.coolstar."))) {
                    return;
                }
            }
        }
        
        NSLog(@"==================================================");
        NSLog(@"[MetalFG] Initializing MetalFG v2.3.0 (SMFG 1.1 True-Midpoint Engine) for target: %s (%s)", progname, execPath);
        NSLog(@"==================================================");
        
        gScheduledPresentQueue = dispatch_queue_create("com.metalfg.scheduledpresent",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        
        // Initialize Logos hooks strictly for this app process
        %init;

        [[NSFileManager defaultManager] removeItemAtPath:MFGLogPath() error:nil];
        MFGLog(@"loaded into %s", progname);

        static dispatch_source_t statsTimer;
        static int statsTicks = 0;
        statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(statsTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(statsTimer, ^{
            MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
            MFGLog(@"stats: nextDrawable %llu presented %llu dropped %llu | cbPresent %llu drawablePresent %llu | suppressed %llu passThrough %llu nativeProcessed %llu layerMismatch %llu | enabled %d",
                   gStatNextDrawable.load(), gStatPresented.load(), gStatPresentDropped.load(),
                   gStatCommandBufferPresent.load(), gStatDrawablePresent.load(), gStatSuppressed.load(),
                   gStatPassThrough.load(), gStatNativeProcessed.load(), gStatLayerMismatch.load(), sync.isEnabled);
            if (++statsTicks >= 24) dispatch_source_cancel(statsTimer);
        });
        dispatch_resume(statsTimer);
        
        // Ensure overlay is shown when application becomes active or scene activates (only if a game Metal layer is active)
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            if (gActiveMetalLayer != nil) {
                [[MetalFGOverlay sharedOverlay] show];
            }
        }];
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            if (gActiveMetalLayer != nil) {
                [[MetalFGOverlay sharedOverlay] show];
            }
        }];
    }
}
