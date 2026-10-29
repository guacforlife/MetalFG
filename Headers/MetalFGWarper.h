#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import "ShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif
extern const char kMetalFGIsSyntheticKey;
#ifdef __cplusplus
}
#endif

@interface MetalFGWarper : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) MTLPixelFormat pixelFormat;
@property (nonatomic, readonly) BOOL isReady;

// Dynamic tuning parameters
@property (nonatomic, assign) float motionScale;             // Default 0.45 (timeOffsetFactor)
@property (nonatomic, assign) float disocclusionThreshold;   // Default 0.20 (color distance cutoff)
@property (nonatomic, assign) float uiSensitivity;           // Default 0.035 (static UI threshold)
@property (nonatomic, assign) float motionDeadzone;          // Default 0.0004 (velocity cutoff)
@property (nonatomic, assign) BOOL debugTintEnabled;
// How long the generated frame stays up before the real one may replace it (the minimum duration
// of the real frame's present). The synchronizer sets half the native frame interval, so each frame
// gets an equal share (30 fps native -> 16.7 + 16.7 ms)
@property (nonatomic, assign) CFTimeInterval syntheticMinDuration;

// Lifecycle
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat;

// Capture the game's rendered frame into double-buffered cache and dispatch BME
- (void)captureBaseTexture:(id<MTLTexture>)sourceTexture
             withTimestamp:(CFTimeInterval)timestamp
             touchVelocity:(simd_float2)touchVelocity;

// Render and present synthetic motion-interpolated frame into target drawable
- (BOOL)renderSyntheticFrameToDrawable:(id<CAMetalDrawable>)targetDrawable
                        targetTimeHint:(CFTimeInterval)targetTimeHint;

// Unified 1:1 Phase-Locked Pipeline: capture, estimate motion, warp, and present in a single command buffer
- (BOOL)synthesizeAndPresentWithSourceTexture:(id<MTLTexture>)sourceTexture
                                        layer:(CAMetalLayer *)layer
                                touchVelocity:(simd_float2)touchVelocity;

// Option 3: Full 1-Frame Latency True Interpolation Pipeline (v2.0.0)
- (BOOL)processAndInterpolateNativeDrawable:(id<CAMetalDrawable>)drawable;
- (BOOL)presentCachedNativeFrameToDrawable:(id<CAMetalDrawable>)targetDrawable;

// Check if a synthetic frame is currently processing on GPU
- (BOOL)isGpuBusy;
// Forget the cached previous frame: the next native frame is shown as is, not interpolated
- (void)resetHistory;

@end

NS_ASSUME_NONNULL_END
