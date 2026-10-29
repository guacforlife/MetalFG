#import "../Headers/MetalFGSynchronizer.h"
#import "../Headers/MetalFGOverlay.h"
#import "../Headers/TouchTracker.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>

@interface MetalFGSynchronizer () {
    BOOL _gpuFaulted;
    CFTimeInterval _refreshInterval;   // the display link's frame length: 1/120 on ProMotion, 1/60 otherwise
    NSThread *_syncThread;
    CADisplayLink *_displayLink;
    BOOL _shouldStopThread;
    
    CFTimeInterval _lastNativeFrameTime;
    os_unfair_lock _syncLock;
    
    // Performance statistics
    uint64_t _nativeFrameCount;
    uint64_t _syntheticFrameCount;
    CFTimeInterval _lastStatsLogTime;
    
    BOOL _isBackgrounded;
    BOOL _hasInjectedForCurrentNativeFrame;
    BOOL _hasPendingNativePresent;
    CFTimeInterval _smoothedNativeInterval;
}

@end

@implementation MetalFGSynchronizer

+ (instancetype)sharedSynchronizer {
    static MetalFGSynchronizer *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[MetalFGSynchronizer alloc] init];
    });
    return sShared;
}

static NSString * const kRootlessPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist";
static NSString * const kStandardPrefsPath = @"/var/mobile/Library/Preferences/com.dnullptr.metalfg.plist";
static NSString * const kCurrentPrefsSchema = @"2.3.0";

- (NSString *)preferencesFilePath {
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        return kRootlessPrefsPath;
    }
    // A sandboxed app can't write /var/mobile/Library/Preferences (on roothide /var/jb isn't visible
    // to apps either), so settings never persisted: keep them in the app's own container
    NSString *home = NSHomeDirectory();
    if ([home containsString:@"/Containers/Data/Application/"]) {
        return [home stringByAppendingPathComponent:@"Library/Preferences/com.dnullptr.metalfg.plist"];
    }
    return kStandardPrefsPath;
}

- (void)loadPreferences {
    NSString *path = [self preferencesFilePath];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *savedSchema = dict ? dict[@"prefsVersion"] : nil;
    
    if (dict && [savedSchema isEqualToString:kCurrentPrefsSchema]) {
        _isEnabled = (dict[@"isEnabled"] != nil) ? [dict[@"isEnabled"] boolValue] : YES;
        _currentPreset = (dict[@"currentPreset"] != nil) ? [dict[@"currentPreset"] integerValue] : 1;
        _motionScale = (dict[@"motionScale"] != nil) ? [dict[@"motionScale"] floatValue] : 0.50f;
        _disocclusionThreshold = (dict[@"disocclusionThreshold"] != nil) ? [dict[@"disocclusionThreshold"] floatValue] : 0.18f;
        _uiSensitivity = (dict[@"uiSensitivity"] != nil) ? [dict[@"uiSensitivity"] floatValue] : 0.035f;
        _motionDeadzone = (dict[@"motionDeadzone"] != nil) ? [dict[@"motionDeadzone"] floatValue] : 0.0003f;
        _debugTint = (dict[@"debugTint"] != nil) ? [dict[@"debugTint"] boolValue] : NO;
        _minNativeFps = [dict[@"minNativeFps"] floatValue];
    } else {
        // Initialize clean v2.3.0 defaults (True 50% Midpoint Interpolation)
        _isEnabled = (dict && dict[@"isEnabled"] != nil) ? [dict[@"isEnabled"] boolValue] : YES;
        _currentPreset = 1; // Balanced (True 50% Midpoint)
        _motionScale = 0.50f;
        _disocclusionThreshold = 0.18f;
        _uiSensitivity = 0.035f;
        _motionDeadzone = 0.0003f;
        _debugTint = (dict && dict[@"debugTint"] != nil) ? [dict[@"debugTint"] boolValue] : NO;
        [self savePreferences];
    }
}

// Turn frame generation off for this session only (not saved): the pill shows OFF, a tap re-arms it
- (void)suspendFrameGeneration {
    _isEnabled = NO;
}

- (NSString *)debugState {
    os_unfair_lock_lock(&_syncLock);
    NSString *st = [NSString stringWithFormat:@"bg %d pending %d warper %@ ready %d gpuBusy %d interval %.1f ms", _isBackgrounded,
                    _hasPendingNativePresent, _warper ? @"yes" : @"nil", _warper.isReady, [_warper isGpuBusy], _smoothedNativeInterval * 1000];
    os_unfair_lock_unlock(&_syncLock);
    return st;
}

// Re-read the settings file and push the values into the running warper
- (void)reloadPreferences {
    [self loadPreferences];
    if (_isEnabled) [self replaceWarperAfterGpuFault];
    self.motionScale = _motionScale;
    self.disocclusionThreshold = _disocclusionThreshold;
    self.uiSensitivity = _uiSensitivity;
    self.motionDeadzone = _motionDeadzone;
    self.debugTint = _debugTint;
}

- (void)savePreferences {
    NSString *path = [self preferencesFilePath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"prefsVersion"] = kCurrentPrefsSchema;
    dict[@"isEnabled"] = @(_isEnabled);
    dict[@"currentPreset"] = @(_currentPreset);
    dict[@"motionScale"] = @(_motionScale);
    dict[@"disocclusionThreshold"] = @(_disocclusionThreshold);
    dict[@"uiSensitivity"] = @(_uiSensitivity);
    dict[@"motionDeadzone"] = @(_motionDeadzone);
    dict[@"debugTint"] = @(_debugTint);
    dict[@"minNativeFps"] = @(_minNativeFps);
    [dict writeToFile:path atomically:YES];
}

- (void)applyPreset:(NSInteger)presetIndex {
    _currentPreset = presetIndex;
    switch (presetIndex) {
        case 0: // Crisp (True 50% Midpoint + tight disocclusion cutoff for zero ghosting)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.14f;
            self.uiSensitivity = 0.038f;
            self.motionDeadzone = 0.0004f;
            break;
        case 1: // Balanced (True 50% Midpoint + SMFG Round 53 head/silhouette occlusion guard)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.18f;
            self.uiSensitivity = 0.035f;
            self.motionDeadzone = 0.0003f;
            break;
        case 2: // Ultra Smooth (True 50% Midpoint + wide bilateral fluid blend)
            self.motionScale = 0.50f;
            self.disocclusionThreshold = 0.24f;
            self.uiSensitivity = 0.028f;
            self.motionDeadzone = 0.0002f;
            break;
        default:
            break;
    }
    [self savePreferences];
}

- (void)setMotionScale:(float)motionScale {
    _motionScale = motionScale;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.motionScale = motionScale;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setDisocclusionThreshold:(float)disocclusionThreshold {
    _disocclusionThreshold = disocclusionThreshold;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.disocclusionThreshold = disocclusionThreshold;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setUiSensitivity:(float)uiSensitivity {
    _uiSensitivity = uiSensitivity;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.uiSensitivity = uiSensitivity;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setMotionDeadzone:(float)motionDeadzone {
    _motionDeadzone = motionDeadzone;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.motionDeadzone = motionDeadzone;
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (void)setDebugTint:(BOOL)debugTint {
    _debugTint = debugTint;
    os_unfair_lock_lock(&_syncLock);
    if (_warper) {
        _warper.debugTintEnabled = debugTint;
    }
    os_unfair_lock_unlock(&_syncLock);
    [self savePreferences];
}

- (void)setIsEnabled:(BOOL)isEnabled {
    _isEnabled = isEnabled;
    if (isEnabled) [self replaceWarperAfterGpuFault];
    [self savePreferences];
}

- (CFTimeInterval)refreshInterval {
    return _refreshInterval;
}

- (void)noteGpuFault {
    os_unfair_lock_lock(&_syncLock);
    _gpuFaulted = YES;
    os_unfair_lock_unlock(&_syncLock);
}

- (void)replaceWarperAfterGpuFault {
    os_unfair_lock_lock(&_syncLock);
    if (_gpuFaulted && _warper) {
        MetalFGWarper *fresh = [[MetalFGWarper alloc] initWithDevice:_warper.device pixelFormat:_warper.pixelFormat];
        if (fresh) {
            fresh.debugTintEnabled = _debugTint;
            fresh.motionScale = _motionScale;
            fresh.disocclusionThreshold = _disocclusionThreshold;
            fresh.uiSensitivity = _uiSensitivity;
            fresh.motionDeadzone = _motionDeadzone;
            _warper = fresh;
            _hasPendingNativePresent = NO;
            _gpuFaulted = NO;
        }
    }
    os_unfair_lock_unlock(&_syncLock);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _syncLock = OS_UNFAIR_LOCK_INIT;
        _lastNativeFrameTime = 0.0;
        _shouldStopThread = NO;
        _isBackgrounded = NO;
        _hasInjectedForCurrentNativeFrame = NO;
        _hasPendingNativePresent = NO;
        _smoothedNativeInterval = 1.0 / 60.0;
        _refreshInterval = 1.0 / 60.0;
        _nativeFrameCount = 0;
        _syntheticFrameCount = 0;
        _lastStatsLogTime = CACurrentMediaTime();
        _debugTint = NO;
        
        [self loadPreferences];
        
        // Listen to app lifecycle events to avoid GPU crashes in background
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleAppDidEnterBackground {
    os_unfair_lock_lock(&_syncLock);
    _isBackgrounded = YES;
    _hasPendingNativePresent = NO;
    if (_displayLink) {
        _displayLink.paused = YES;
    }
    os_unfair_lock_unlock(&_syncLock);
    
    [[MetalFGTouchTracker sharedTracker] reset];
    NSLog(@"[MetalFG] Application entered background. Suspended frame synchronizer.");
}

- (void)handleAppDidBecomeActive {
    os_unfair_lock_lock(&_syncLock);
    _isBackgrounded = NO;
    if (_displayLink) {
        _displayLink.paused = NO;
    }
    _lastNativeFrameTime = CACurrentMediaTime();
    os_unfair_lock_unlock(&_syncLock);
    
    [[MetalFGOverlay sharedOverlay] show];
    NSLog(@"[MetalFG] Application became active. Resumed frame synchronizer.");
}

- (void)startSynchronizerWithLayer:(CAMetalLayer *)layer
                            device:(id<MTLDevice>)device
                       pixelFormat:(MTLPixelFormat)pixelFormat {
    os_unfair_lock_lock(&_syncLock);
    
    _activeLayer = layer;
    
    // Recreate warper if device or pixelFormat changed
    if (!_warper || _warper.device != device || _warper.pixelFormat != pixelFormat) {
        _warper = [[MetalFGWarper alloc] initWithDevice:device pixelFormat:pixelFormat];
        _warper.debugTintEnabled = _debugTint;
        _warper.motionScale = _motionScale;
        _warper.disocclusionThreshold = _disocclusionThreshold;
        _warper.uiSensitivity = _uiSensitivity;
        _warper.motionDeadzone = _motionDeadzone;
    }
    
    if (!_syncThread || !_syncThread.isExecuting) {
        _shouldStopThread = NO;
        _syncThread = [[NSThread alloc] initWithTarget:self selector:@selector(syncThreadEntryPoint) object:nil];
        _syncThread.name = @"com.metalfg.synchronizer";
        _syncThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_syncThread start];
    }
    
    os_unfair_lock_unlock(&_syncLock);
    
    // Show on-screen status overlay
    [[MetalFGOverlay sharedOverlay] show];
    NSLog(@"[MetalFG] Synchronizer started on dedicated 120Hz display link thread.");
}

- (void)stopSynchronizer {
    os_unfair_lock_lock(&_syncLock);
    _shouldStopThread = YES;
    [_displayLink invalidate];
    _displayLink = nil;
    os_unfair_lock_unlock(&_syncLock);
    
    [[MetalFGTouchTracker sharedTracker] reset];
    NSLog(@"[MetalFG] Synchronizer stopped.");
}

- (void)syncThreadEntryPoint {
    @autoreleasepool {
        NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
        
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayTick:)];
        
        // Target 120Hz ProMotion display refresh rate on iOS 15+
        if (@available(iOS 15.0, *)) {
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, 120.0f, 120.0f);
        }
        _displayLink.preferredFramesPerSecond = 120;
        
        [_displayLink addToRunLoop:currentRunLoop forMode:NSRunLoopCommonModes];
        
        while (!_shouldStopThread) {
            @autoreleasepool {
                [currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }
        }
    }
}

- (void)notifyNativeFrameRendered:(id<CAMetalDrawable>)drawable {
    [self notifyNativeFrameRendered:drawable takenOver:YES];
}

- (void)notifyNativeFrameRendered:(id<CAMetalDrawable>)drawable takenOver:(BOOL)takenOver {
    if (!drawable) return;
    if (_isBackgrounded) {
        if (takenOver) [drawable present];
        return;
    }
    
    id<MTLTexture> texture = drawable.texture;
    if (!texture || texture.width < 250 || texture.height < 150) {
        return;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    
    os_unfair_lock_lock(&_syncLock);
    CFTimeInterval interval = now - _lastNativeFrameTime;
    if (interval > 0.005 && interval < 0.200) {
        _smoothedNativeInterval = _smoothedNativeInterval * 0.85 + interval * 0.15;
    }
    _lastNativeFrameTime = now;
    _nativeFrameCount++;
    if (drawable.layer && drawable.layer != _activeLayer) {
        _activeLayer = drawable.layer;
    }
    MetalFGWarper *currentWarper = _warper;
    BOOL enabled = _isEnabled;
    CFTimeInterval nativeInterval = _smoothedNativeInterval;
    os_unfair_lock_unlock(&_syncLock);
    
    if (!takenOver && enabled && currentWarper) {
        // Frame generation is on but paused for this frame (native rate outside its range): drop the
        // pending real-frame present, which would now be older than what the game just showed, and
        // start the next interpolation from a fresh frame
        os_unfair_lock_lock(&_syncLock);
        _hasPendingNativePresent = NO;
        os_unfair_lock_unlock(&_syncLock);
        [currentWarper resetHistory];
        return;
    }
    
    if (takenOver && !(enabled && currentWarper)) {
        // Taken over just before frame generation went off: show the game's frame as it is
        [drawable present];
        return;
    }
    
    if (enabled && currentWarper && takenOver) {
        // Split each native frame's refreshes between the generated and the real frame, the
        // generated one getting half rounded down (2 ms margin to latch on the earlier refresh):
        // on 120 Hz, 30 fps native -> 2 + 2 refreshes, 40 -> 1 + 2, 60 -> 1 + 1
        CFTimeInterval refresh = _refreshInterval;
        long refreshesPerFrame = lround(nativeInterval / refresh);
        currentWarper.syntheticMinDuration = MAX(1L, refreshesPerFrame / 2) * refresh - 0.002;
        // Option 3: Full 1-Frame Latency True Interpolation Model (LSFG / DLSS 3)
        // 1. Warper saves Ground Truth Frame N into double-buffered cache.
        // 2. Warper computes coarse-to-fine motion field between Frame N-1 and Frame N.
        // 3. Warper synthesizes S_{N-0.5} into the native drawable and presents it with
        //    afterMinimumDuration:(1/120 - 0.0005) (latches on VSYNC Tick 2k for 8.33ms).
        BOOL didInterpolate = [currentWarper processAndInterpolateNativeDrawable:drawable];
        
        os_unfair_lock_lock(&_syncLock);
        if (didInterpolate) {
            _syntheticFrameCount++;
            _hasPendingNativePresent = YES;
        } else {
            // First frame after startup/toggle: Frame 0 was presented directly as F_0
            _hasPendingNativePresent = NO;
        }
        os_unfair_lock_unlock(&_syncLock);
    }
}

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                             layer:(nullable CAMetalLayer *)layer
                       atTimestamp:(CFTimeInterval)timestamp {
    if (_isBackgrounded || !texture) return;
    
    if (texture.width < 250 || texture.height < 150) {
        return;
    }
    
    os_unfair_lock_lock(&_syncLock);
    _lastNativeFrameTime = timestamp;
    _nativeFrameCount++;
    _hasInjectedForCurrentNativeFrame = NO;
    if (layer && layer != _activeLayer) {
        _activeLayer = layer;
    }
    MetalFGWarper *currentWarper = _warper;
    BOOL enabled = _isEnabled;
    os_unfair_lock_unlock(&_syncLock);
    
    if (enabled && currentWarper) {
        simd_float2 touchVel = [[MetalFGTouchTracker sharedTracker] normalizedVelocityForScreenSize:CGSizeMake(texture.width, texture.height)];
        [currentWarper captureBaseTexture:texture withTimestamp:timestamp touchVelocity:touchVel];
    }
}

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation {
    [self notifyNativeFramePresented:texture layer:_activeLayer atTimestamp:timestamp];
}

- (void)onDisplayTick:(CADisplayLink *)link {
    @autoreleasepool {
        CFTimeInterval frame = link.targetTimestamp - link.timestamp;
        if (frame > 0.004 && frame < 0.05) _refreshInterval = frame;
        if (_isBackgrounded) return;
        
        // Periodic FPS logging & On-Screen Overlay update (every 1.0s, evaluated on display link tick)
        CFTimeInterval statsNow = CACurrentMediaTime();
        if (statsNow - _lastStatsLogTime >= 1.0) {
            double duration = statsNow - _lastStatsLogTime;
            
            os_unfair_lock_lock(&_syncLock);
            double nativeFps = (double)_nativeFrameCount / duration;
            double syntheticFps = (double)_syntheticFrameCount / duration;
            _nativeFrameCount = 0;
            _syntheticFrameCount = 0;
            _lastStatsLogTime = statsNow;
            os_unfair_lock_unlock(&_syncLock);
            
            // Update floating on-screen indicator
            [[MetalFGOverlay sharedOverlay] updateWithNativeFPS:nativeFps syntheticFPS:syntheticFps];
            
            NSLog(@"[MetalFG] Performance: Native: %.1f FPS | Synthetic: %.1f FPS | Total: %.1f FPS",
                  nativeFps, syntheticFps, nativeFps + syntheticFps);
        }
        
        if (!_isEnabled) return;
        
        os_unfair_lock_lock(&_syncLock);
        BOOL pendingNative = _hasPendingNativePresent;
        CAMetalLayer *layer = _activeLayer;
        MetalFGWarper *warper = _warper;
        os_unfair_lock_unlock(&_syncLock);
        
        if (!pendingNative || !layer || !warper || !warper.isReady) return;
        
        // Ignore HUD/sub-layers smaller than 250x150
        CGSize drawableSize = layer.drawableSize;
        if (drawableSize.width < 250.0 || drawableSize.height < 150.0) return;
        
        // Wait only until S_{N-0.5} has finished rendering on the GPU (typically ~0.6ms).
        // Because S_{N-0.5} was presented with afterMinimumDuration:(1/120 - 0.0005),
        // CARenderServer guarantees S_{N-0.5} stays visible for a full 8.33ms 120Hz cycle
        // and automatically latches Ground Truth Frame N on the very next 120Hz VSYNC tick!
        if ([warper isGpuBusy]) return;
        
        id<CAMetalDrawable> nativeDrawable = [layer nextDrawable];
        if (!nativeDrawable || !nativeDrawable.texture) return;
        
        // Present cached Ground Truth Frame N onto the display for the second 120Hz refresh cycle
        BOOL presented = [warper presentCachedNativeFrameToDrawable:nativeDrawable];
        if (presented) {
            os_unfair_lock_lock(&_syncLock);
            _hasPendingNativePresent = NO;
            os_unfair_lock_unlock(&_syncLock);
        }
    }
}

@end
