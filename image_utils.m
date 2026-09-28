#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>

// Frames are extracted from the MP4 before installation: frame_000.png ... frame_059.png.
static NSString *const kFrameDirectory = @"/tmp/vcam-frames";
static const char *kDebugLogPath = "/tmp/vcam-debug.txt";
static const NSUInteger kMaxFrames = 60;

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
static NSUInteger currentFrameIndex = 0;
static CIContext *sharedCIContext = nil;
static NSObject *vcamLock = nil;
static BOOL didLogDraw = NO;

void loadReplacementMedia(void) {
    if (!vcamLock) vcamLock = [[NSObject alloc] init];
    VCamDebugLog(@"sequence load entered directory=%@", kFrameDirectory);

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<UIImage *> *frames = [[NSMutableArray alloc] init];
    for (NSUInteger index = 0; index < kMaxFrames; index++) {
        NSString *path = [kFrameDirectory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"frame_%03lu.png", (unsigned long)index]];
        if (![fileManager isReadableFileAtPath:path]) {
            VCamDebugLog(@"frame missing/unreadable index=%lu path=%@", (unsigned long)index, path);
            break;
        }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (!image || !image.CGImage) {
            VCamDebugLog(@"frame decode failed index=%lu path=%@", (unsigned long)index, path);
            break;
        }
        [frames addObject:image];
    }

    replacementFrames = [frames copy];
    currentFrameIndex = 0;
    sharedCIContext = [CIContext context];
    if (replacementFrames.count > 0) {
        UIImage *first = replacementFrames[0];
        VCamDebugLog(@"sequence ready frames=%lu first=%zux%zu ciContext=%d",
                     (unsigned long)replacementFrames.count,
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
            VCamDebugLog(@"draw entered target=%zux%zu frames=%lu",
                         targetBuffer ? CVPixelBufferGetWidth(targetBuffer) : 0,
                         targetBuffer ? CVPixelBufferGetHeight(targetBuffer) : 0,
                         (unsigned long)replacementFrames.count);
        }
        if (!targetBuffer || replacementFrames.count == 0 || !sharedCIContext) return;

        UIImage *frame = replacementFrames[currentFrameIndex];
        currentFrameIndex = (currentFrameIndex + 1) % replacementFrames.count;
        CIImage *replacementCIImage = [CIImage imageWithCGImage:frame.CGImage];
        CGFloat targetWidth = CVPixelBufferGetWidth(targetBuffer);
        CGFloat targetHeight = CVPixelBufferGetHeight(targetBuffer);
        CGRect sourceExtent = replacementCIImage.extent;
        CGFloat scale = MIN(targetWidth / sourceExtent.size.width,
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
