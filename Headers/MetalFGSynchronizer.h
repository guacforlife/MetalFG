#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import "MetalFGWarper.h"
#import "TouchTracker.h"

NS_ASSUME_NONNULL_BEGIN

@interface MetalFGSynchronizer : NSObject

// Singleton
+ (instancetype)sharedSynchronizer;

@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL debugTint;         // Visual tint for synthetic frames

// Dynamic Tuning Parameters
@property (nonatomic, assign) float motionScale;             // Default: 0.45 (Range: 0.10 - 0.70)
@property (nonatomic, assign) float disocclusionThreshold;   // Default: 0.16 (Range: 0.08 - 0.35)
@property (nonatomic, assign) float uiSensitivity;           // Default: 0.035 (Range: 0.01 - 0.08)
@property (nonatomic, assign) float motionDeadzone;          // Default: 0.0004 (Range: 0.0001 - 0.0020)
@property (nonatomic, assign) NSInteger currentPreset;       // 0: Crisp, 1: Balanced, 2: Ultra Smooth, 3: Custom
// Generate frames only while the game renders at least this many fps (0 = always). With
// TrumpetDismiss at 60 while touching and 40 idle, 50 means: frame generation while you play,
// plain native frames (and no GPU cost) while the screen sits idle or the game is hidden
@property (nonatomic, assign) float minNativeFps;
// The display link's refresh interval (1/120 on ProMotion, 1/60 otherwise)
@property (nonatomic, readonly) CFTimeInterval refreshInterval;

- (void)applyPreset:(NSInteger)presetIndex;
- (void)savePreferences;
- (void)loadPreferences;
- (void)reloadPreferences;
- (NSString *)debugState;
- (void)suspendFrameGeneration;
// A MetalFG command buffer failed: its queue may now ignore all later work, so the next time frame
// generation is switched on it starts from a new warper (new command queue)
- (void)noteGpuFault;

// Active Metal resources
@property (nonatomic, weak, nullable) CAMetalLayer *activeLayer;
@property (nonatomic, strong, nullable) MetalFGWarper *warper;

// Start/stop frame synchronizer
- (void)startSynchronizerWithLayer:(CAMetalLayer *)layer
                            device:(id<MTLDevice>)device
                       pixelFormat:(MTLPixelFormat)pixelFormat;
- (void)stopSynchronizer;

// Called by hooks whenever the game completes rendering a native frame (v2.0.0)
- (void)notifyNativeFrameRendered:(id<CAMetalDrawable>)drawable;
// takenOver: the hook hid the game's own present of this drawable. Only such frames may be drawn
// into and presented; a frame the game already presented must never be touched again.
- (void)notifyNativeFrameRendered:(id<CAMetalDrawable>)drawable takenOver:(BOOL)takenOver;

// Legacy presentation notification
- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                             layer:(nullable CAMetalLayer *)layer
                       atTimestamp:(CFTimeInterval)timestamp;

- (void)notifyNativeFramePresented:(id<MTLTexture>)texture
                       atTimestamp:(CFTimeInterval)timestamp
                       orientation:(simd_quatf)orientation;

@end

NS_ASSUME_NONNULL_END
