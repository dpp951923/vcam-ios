#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <unistd.h>

// All frames are extracted from the MP4 before installation.
static NSString *const kFrameDirectory = @"/tmp/vcam-frames";
static const char *kDebugLogPath = "/tmp/vcam-debug.txt";

static void VCamDebugLog(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        NSString *line = [NSString stringWithFormat:@"%@ pid=%d %@\n", [NSDate date], getpid(), message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open(kDebugLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        const uint8_t *bytes = data.bytes;
        NSUInteger remaining = data.length;
        while (remaining > 0) {
            ssize_t written = write(fd, bytes, remaining);
            if (written <= 0) break;
            bytes += written;
            remaining -= (NSUInteger)written;
        }
        close(fd);
    }
}

static NSArray<UIImage *> *replacementFrames = nil;
static double sourceFPS = 30.0;
static CFTimeInterval playbackStartTime = 0;
static CIContext *sharedCIContext = nil;
static NSObject *vcamLock = nil;
static BOOL didLogDraw = NO;

void loadReplacementMedia(void) {
    if (!vcamLock) vcamLock = [[NSObject alloc] init];
    VCamDebugLog(@"sequence load entered directory=%@", kFrameDirectory);

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *fpsPath = [kFrameDirectory stringByAppendingPathComponent:@"fps.txt"];
    NSString *fpsText = [NSString stringWithContentsOfFile:fpsPath encoding:NSUTF8StringEncoding error:NULL];
    double parsedFPS = fpsText.doubleValue;
    if (isfinite(parsedFPS) && parsedFPS > 0 && parsedFPS <= 240) sourceFPS = parsedFPS;

    NSString *countPath = [kFrameDirectory stringByAppendingPathComponent:@"frame_count.txt"];
    NSString *countText = [NSString stringWithContentsOfFile:countPath encoding:NSUTF8StringEncoding error:NULL];
    NSInteger expectedCount = countText.integerValue;
    if (expectedCount <= 0) {
        VCamDebugLog(@"abort: missing/invalid frame_count.txt path=%@", countPath);
        return;
    }

    NSMutableArray<UIImage *> *frames = [[NSMutableArray alloc] initWithCapacity:(NSUInteger)expectedCount];
    for (NSInteger index = 0; index < expectedCount; index++) {
        NSString *path = [kFrameDirectory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"frame_%03ld.png", (long)index]];
        if (![fileManager isReadableFileAtPath:path]) {
            VCamDebugLog(@"abort: frame missing/unreadable index=%ld path=%@", (long)index, path);
            return;
        }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (!image || !image.CGImage) {
            VCamDebugLog(@"abort: frame decode failed index=%ld path=%@", (long)index, path);
            return;
        }
        [frames addObject:image];
    }

    replacementFrames = [frames copy];
    playbackStartTime = 0;
    sharedCIContext = [CIContext context];
    if (replacementFrames.count > 0) {
        UIImage *first = replacementFrames[0];
        VCamDebugLog(@"sequence ready and all images loaded frames=%lu expected=%ld fps=%.5f first=%zux%zu ciContext=%d",
                     (unsigned long)replacementFrames.count, (long)expectedCount, sourceFPS,
                     CGImageGetWidth(first.CGImage), CGImageGetHeight(first.CGImage),
                     sharedCIContext != nil);
    } else {
        VCamDebugLog(@"sequence NOT ready: zero frames");
    }
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    @synchronized(vcamLock) {
        if (!didLogDraw) {
            didLogDraw = YES;
            VCamDebugLog(@"draw entered target=%zux%zu frames=%lu fps=%.5f",
                         targetBuffer ? CVPixelBufferGetWidth(targetBuffer) : 0,
                         targetBuffer ? CVPixelBufferGetHeight(targetBuffer) : 0,
                         (unsigned long)replacementFrames.count, sourceFPS);
        }
        if (!targetBuffer || replacementFrames.count == 0 || !sharedCIContext) return;

        CFTimeInterval now = CACurrentMediaTime();
        if (playbackStartTime == 0) playbackStartTime = now;
        NSUInteger frameIndex = (NSUInteger)floor((now - playbackStartTime) * sourceFPS)
                                % replacementFrames.count;
        UIImage *frame = replacementFrames[frameIndex];
        CIImage *replacementCIImage = [CIImage imageWithCGImage:frame.CGImage];
        CGFloat targetWidth = CVPixelBufferGetWidth(targetBuffer);
        CGFloat targetHeight = CVPixelBufferGetHeight(targetBuffer);
        CGRect sourceExtent = replacementCIImage.extent;
        CGFloat scale = MAX(targetWidth / sourceExtent.size.width,
                            targetHeight / sourceExtent.size.height);
        CIImage *scaled = [replacementCIImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = scaled.extent;
        CGFloat offsetX = (targetWidth - scaledExtent.size.width) / 2.0;
        CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;
        CIImage *finalImage = [scaled imageByApplyingTransform:
                              CGAffineTransformMakeTranslation(offsetX, offsetY)];
        [sharedCIContext render:finalImage toCVPixelBuffer:targetBuffer];
    }
}
