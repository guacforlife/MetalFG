#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <atomic>
#import <notify.h>
#import <os/lock.h>

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

// Frame pacing of everything shown on the game layer (native and generated), from presentedTime.
// Buckets: intervals up to ~1, 2, 3 and more than 3 refreshes of a 120 Hz screen.
static os_unfair_lock gPaceLock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval gPaceLast;
static uint64_t gPaceCount, gPaceBuckets[4];
static double gPaceSum, gPaceSumSq, gPaceMax;

static std::atomic<int> gTrace{0};  // frames left to trace after a settings reload

// Freeze guard. Taking over a frame hides the game's own present; if MetalFG's presents then stop
// reaching the screen (seen once after re-enabling mid-session: the pill kept counting while the
// game layer stayed frozen until a relaunch), suspend frame generation so the game shows its own
// frames again. Triggers: a GPU error on a MetalFG present, or kMaxTakeoversUnshown game frames
// taken over with nothing shown in between.
static const int kMaxTakeoversUnshown = 45;
static std::atomic<int> gTakeoversSinceShown{0};
static std::atomic<uint64_t> gStatGpuErrors{0};

// Native frame interval (smoothed), measured where the game's presents are intercepted, so it keeps
// updating while frame generation is paused
static std::atomic<double> gNativeInterval{0};
static std::atomic<uint64_t> gStatPausedSlow{0}, gStatPausedFast{0};

static void NoteNativeFrame(void) {
    static std::atomic<double> last{0};
    CFTimeInterval now = CACurrentMediaTime(), prev = last.exchange(now);
    double dt = now - prev, ema = gNativeInterval.load();
    // Slow average (~20 frames): one long frame must not flip frame generation on or off
    if (prev > 0 && dt > 0.002 && dt < 0.25) gNativeInterval = ema > 0 ? ema * 0.95 + dt * 0.05 : dt;
}

// Frame generation only pays off when the game renders well below the screen rate, and (minNativeFps)
// only when the user wants it: returns NO for frames that must stay native
static BOOL MFGNativeRateWantsGeneration(MetalFGSynchronizer *sync) {
    static std::atomic<int> state{-1};   // 0 generating, 1 too slow, 2 no headroom
    double interval = gNativeInterval.load(), refresh = sync.refreshInterval;
    float minFps = sync.minNativeFps;
    int was = state.load(), now = 0;
    // Hysteresis around the minimum: pause below 84% of it, resume above 96% (minimum 50: pause
    // under 42 fps, resume over 48), so TrumpetDismiss's idle 40 and touching 60 sit clearly apart
    double needFps = minFps * (was == 1 ? 0.96 : 0.84);
    if (interval > 0 && minFps > 0 && 1.0 / interval < needFps) now = 1;
    // Under 1.6 refreshes per native frame there is no room for a frame in between
    // (above ~75 fps on a 120 Hz screen, above ~37 on 60 Hz)
    else if (interval > 0 && refresh > 0 && interval < refresh * 1.6) now = 2;
    if (state.exchange(now) != now && was != -1) {
        MFGLog(@"frame generation %@ (native %.1f fps, min %.0f, screen %.0f Hz)",
               now == 0 ? @"active" : now == 1 ? @"paused: native rate below the minimum" : @"paused: native rate near the screen rate",
               interval > 0 ? 1.0 / interval : 0, minFps, refresh > 0 ? 1.0 / refresh : 0);
    }
    if (now == 1) gStatPausedSlow++;
    if (now == 2) gStatPausedFast++;
    return now == 0;
}

static void SuspendFrameGeneration(NSString *why) {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    if (!sync.isEnabled) return;
    [sync suspendFrameGeneration];
    gTakeoversSinceShown = 0;
    MFGLog(@"frame generation suspended (%@): the game shows its own frames; tap the pill or relaunch to retry", why);
}

// Returns NO when the game frame must be left to the game (frame generation off or just suspended)
static BOOL MFGMayTakeOver(void) {
    MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
    NoteNativeFrame();
    if (!sync.isEnabled || !MFGNativeRateWantsGeneration(sync)) return NO;
    if (++gTakeoversSinceShown > kMaxTakeoversUnshown) {
        SuspendFrameGeneration([NSString stringWithFormat:@"%d game frames taken over, none shown", kMaxTakeoversUnshown]);
        return NO;
    }
    return YES;
}

static void WatchSyntheticPresent(id<MTLCommandBuffer> commandBuffer) {
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        if (cb.status != MTLCommandBufferStatusError) return;
        if (++gStatGpuErrors <= 3) MFGLog(@"GPU error in %@: %@", cb.label, cb.error);
        [[MetalFGSynchronizer sharedSynchronizer] noteGpuFault];
        SuspendFrameGeneration(@"GPU error");
    }];
}

static void PaceRecord(CFTimeInterval t) {
    os_unfair_lock_lock(&gPaceLock);
    if (gPaceLast > 0 && t > gPaceLast && t - gPaceLast < 0.25) {  // longer gaps are pauses, not pacing
        double dt = t - gPaceLast;
        gPaceCount++;
        gPaceSum += dt;
        gPaceSumSq += dt * dt;
        if (dt > gPaceMax) gPaceMax = dt;
        gPaceBuckets[dt <= 0.0104 ? 0 : dt <= 0.0188 ? 1 : dt <= 0.0271 ? 2 : 3]++;
    }
    if (t > gPaceLast) gPaceLast = t;
    os_unfair_lock_unlock(&gPaceLock);
}

// `notifyutil -p com.dnullptr.metalfg.stats` logs the rates and pacing since the previous call
static void MFGLogWindowStats(void) {
    static CFTimeInterval lastAt;
    static uint64_t lastNative, lastShown;
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t native = gStatSuppressed.load() + gStatPassThrough.load(), shown = gStatPresented.load();
    os_unfair_lock_lock(&gPaceLock);
    uint64_t n = gPaceCount, b0 = gPaceBuckets[0], b1 = gPaceBuckets[1], b2 = gPaceBuckets[2], b3 = gPaceBuckets[3];
    double sum = gPaceSum, sumSq = gPaceSumSq, max = gPaceMax;
    gPaceCount = gPaceBuckets[0] = gPaceBuckets[1] = gPaceBuckets[2] = gPaceBuckets[3] = 0;
    gPaceSum = gPaceSumSq = gPaceMax = 0;
    os_unfair_lock_unlock(&gPaceLock);
    if (lastAt > 0) {
        double dt = now - lastAt, mean = n ? sum / n : 0, sd = n ? sqrt(MAX(0.0, sumSq / n - mean * mean)) : 0;
        MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
        MFGLog(@"window %.1f s: native %.1f fps, shown %.1f fps | interval mean %.2f ms sd %.2f max %.1f | <=10ms %llu <=19ms %llu <=27ms %llu >27ms %llu | FG %@ preset %ld | gpu errors %llu | drawable %.0fx%.0f | paused slow %llu fast %llu",
               dt, (native - lastNative) / dt, (shown - lastShown) / dt, mean * 1000, sd * 1000, max * 1000,
               b0, b1, b2, b3, sync.isEnabled ? @"on" : @"off", (long)sync.currentPreset, gStatGpuErrors.load(),
               sync.activeLayer.drawableSize.width, sync.activeLayer.drawableSize.height, gStatPausedSlow.load(), gStatPausedFast.load());
    }
    lastAt = now;
    lastNative = native;
    lastShown = shown;
}

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

// No UIScreen.maximumFramesPerSecond override: with CADisableMinimumFrameDurationOnPhone forced on
// (below) UIKit already reports 120 on ProMotion screens, and a hard-coded 120 made 60 Hz phones
// (iPhone 7 Plus) look like ProMotion to the game and to TrumpetDismiss, which then picked frame
// rates that do not divide 60 and paced unevenly.

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
            CFTimeInterval t = d.presentedTime;
            if (gTrace.load() > 0) MFGLog(@"trace presented %p t %.4f synthetic %@", d, t, objc_getAssociatedObject(d, &kMetalFGIsSyntheticKey));
            if (t > 0) {
                gTakeoversSinceShown = 0;
                gStatPresented++;
                PaceRecord(t);
            } else {
                gStatPresentDropped++;
            }
        }];
    }
    return drawable;
}

%end

// ============================================================================
// Helper: Process Native Frame Presentation
// ============================================================================
// takenOver: the hook hid the game's present of this drawable, so it must still reach the screen
static inline void ProcessNativePresentation(id<CAMetalDrawable> drawable, BOOL takenOver) {
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
        if (takenOver) [drawable present];
        return;
    }

    gStatNativeProcessed++;
    if (gTrace.load() > 0) {
        MFGLog(@"trace process %p | %@", drawable, [[MetalFGSynchronizer sharedSynchronizer] debugState]);
        gTrace--;
    }
    [[MetalFGSynchronizer sharedSynchronizer] notifyNativeFrameRendered:drawable takenOver:takenOver];
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
        WatchSyntheticPresent(commandBuffer);
        return NO;
    }
    objc_setAssociatedObject(metalDrawable, &kMFGPresentHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<MTLTexture> tex = metalDrawable.texture;
    BOOL isGameDrawable = (tex && tex.width >= 250 && tex.height >= 150 && IsGameLayerCandidate(metalDrawable.layer));
    BOOL takeOver = isGameDrawable && MFGMayTakeOver();
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        ProcessNativePresentation(metalDrawable, takeOver);
    }];
    if (takeOver) {
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
    BOOL takeOver = MFGMayTakeOver();
    if (gTrace.load() > 0) MFGLog(@"trace native present %p takeOver %d", drawable, takeOver);
    dispatch_async(gScheduledPresentQueue, ^{
        [commandBuffer waitUntilCompleted];
        ProcessNativePresentation(drawable, takeOver);
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
    if (gTrace.load() > 0) MFGLog(@"trace cb %s %p synthetic %@", sel_getName(_cmd), drawable, objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey));
    if (InterceptNativePresent((id<MTLCommandBuffer>)self, drawable)) return;
    %orig(drawable);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)presentationTime {
    gStatCommandBufferPresent++;
    if (gTrace.load() > 0) MFGLog(@"trace cb %s %p synthetic %@", sel_getName(_cmd), drawable, objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey));
    if (InterceptNativePresent((id<MTLCommandBuffer>)self, drawable)) return;
    %orig(drawable, presentationTime);
}

- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration {
    gStatCommandBufferPresent++;
    if (gTrace.load() > 0) MFGLog(@"trace cb %s %p synthetic %@", sel_getName(_cmd), drawable, objc_getAssociatedObject(drawable, &kMetalFGIsSyntheticKey));
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
        
        // iOS holds an iPhone app to 60 Hz on a ProMotion screen unless its Info.plist sets
        // CADisableMinimumFrameDurationOnPhone. Core Animation reads the bundle's own info dictionary,
        // which the NSBundle hooks below do not change (they return a modified copy), so Google Maps
        // stayed at 60 Hz. The main bundle's dictionary is mutable: set the key in it before UIKit and
        // QuartzCore read it (TrumpetDismiss does the same for Z Route).
        NSString *promotionKey = @"CADisableMinimumFrameDurationOnPhone";
        @try {
            id info = NSBundle.mainBundle.infoDictionary;
            if ([info isKindOfClass:[NSMutableDictionary class]]) [(NSMutableDictionary *)info setObject:@YES forKey:promotionKey];
        } @catch (id e) {}
        
        gScheduledPresentQueue = dispatch_queue_create("com.metalfg.scheduledpresent",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        
        // Initialize Logos hooks strictly for this app process
        %init;

        [[NSFileManager defaultManager] removeItemAtPath:MFGLogPath() error:nil];
        MFGLog(@"loaded into %s, %@ = %@", progname, promotionKey, [NSBundle.mainBundle objectForInfoDictionaryKey:promotionKey]);

        int statsToken, reloadToken;
        notify_register_dispatch("com.dnullptr.metalfg.stats", &statsToken, dispatch_get_main_queue(), ^(int t) {
            MFGLogWindowStats();
        });
        // `notifyutil -p com.dnullptr.metalfg.reload` applies an edited settings file without a relaunch
        notify_register_dispatch("com.dnullptr.metalfg.reload", &reloadToken, dispatch_get_main_queue(), ^(int t) {
            MetalFGSynchronizer *sync = [MetalFGSynchronizer sharedSynchronizer];
            [sync reloadPreferences];
            gTrace = 30;
            MFGLog(@"reload state: %@", [sync debugState]);
            MFGLog(@"settings reloaded: FG %@ preset %ld motion %.2f ghost %.2f ui %.3f deadzone %.4f min native %.0f fps", sync.isEnabled ? @"on" : @"off",
                   (long)sync.currentPreset, sync.motionScale, sync.disocclusionThreshold, sync.uiSensitivity, sync.motionDeadzone, sync.minNativeFps);
        });
        
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
