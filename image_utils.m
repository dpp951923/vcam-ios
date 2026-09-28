#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>

static NSString *const kReplacementMediaPath = @"/tmp/test.mp4";
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
        if (fd >= 0) {
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
}

typedef enum {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
} VCamMode;

static VCamMode currentMode = VCamModeNone;
static CGImageRef replacementImage = NULL;
static NSMutableArray *videoFrames = NULL;
static NSUInteger currentFrameIndex = 0;
static CIContext *sharedCIContext = NULL;
static NSObject *vcamLock = nil;
static BOOL didLogDraw = NO;

void loadReplacementMedia(void) {
    VCamDebugLog(@"load entered path=%@", kReplacementMediaPath);
    if (!vcamLock) vcamLock = [[NSObject alloc] init];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL exists = [fileManager fileExistsAtPath:kReplacementMediaPath];
    BOOL readable = [fileManager isReadableFileAtPath:kReplacementMediaPath];
    NSError *attributesError = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:kReplacementMediaPath error:&attributesError];
    VCamDebugLog(@"file exists=%d readable=%d bytes=%@ attributesError=%@",
                 exists, readable, attributes[NSFileSize], attributesError);
    if (!exists) {
        VCamDebugLog(@"abort: replacement file not visible to mediaserverd");
        return;
    }

    NSString *extension = [[kReplacementMediaPath pathExtension] lowercaseString];
    VCamDebugLog(@"extension=%@", extension);
    if ([extension isEqualToString:@"png"] || [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
        UIImage *image = [UIImage imageWithContentsOfFile:kReplacementMediaPath];
        if (image && image.CGImage) {
            replacementImage = CGImageRetain(image.CGImage);
            currentMode = VCamModeImage;
            VCamDebugLog(@"image loaded width=%zu height=%zu", CGImageGetWidth(replacementImage), CGImageGetHeight(replacementImage));
        } else {
            VCamDebugLog(@"abort: UIImage could not load image");
        }
    } else if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"]) {
        NSURL *videoURL = [NSURL fileURLWithPath:kReplacementMediaPath];
        AVAsset *asset = [AVAsset assetWithURL:videoURL];
        VCamDebugLog(@"asset created=%d duration=%.3f", asset != nil, CMTimeGetSeconds(asset.duration));

        NSError *error = nil;
        AVAssetReader *assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        VCamDebugLog(@"reader created=%d error=%@", assetReader != nil, error);
        if (!assetReader || error) {
            VCamDebugLog(@"abort: reader initialization failed");
            return;
        }

        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        VCamDebugLog(@"video track count=%lu", (unsigned long)videoTracks.count);
        if (videoTracks.count == 0) {
            VCamDebugLog(@"abort: no video track");
            return;
        }

        AVAssetTrack *videoTrack = videoTracks[0];
        VCamDebugLog(@"track size=%.0fx%.0f nominalFrameRate=%.2f", videoTrack.naturalSize.width,
                     videoTrack.naturalSize.height, videoTrack.nominalFrameRate);
        NSDictionary *outputSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        AVAssetReaderTrackOutput *videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
        videoOutput.alwaysCopiesSampleData = NO;

        BOOL canAdd = [assetReader canAddOutput:videoOutput];
        VCamDebugLog(@"canAddOutput=%d status=%ld error=%@", canAdd, (long)assetReader.status, assetReader.error);
        if (!canAdd) {
            VCamDebugLog(@"abort: cannot add reader output");
            return;
        }
        [assetReader addOutput:videoOutput];
        BOOL started = [assetReader startReading];
        VCamDebugLog(@"startReading=%d status=%ld error=%@", started, (long)assetReader.status, assetReader.error);
        if (!started) return;

        videoFrames = [[NSMutableArray alloc] init];
        int frameCount = 0;
        const int maxFrames = 60;
        while (assetReader.status == AVAssetReaderStatusReading && frameCount < maxFrames) {
            CMSampleBufferRef sampleBuffer = [videoOutput copyNextSampleBuffer];
            if (!sampleBuffer) {
                VCamDebugLog(@"copyNextSampleBuffer=NULL frameCount=%d status=%ld error=%@",
                             frameCount, (long)assetReader.status, assetReader.error);
                break;
            }
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                CVPixelBufferRetain(pixelBuffer);
                [videoFrames addObject:(__bridge id)pixelBuffer];
                CVPixelBufferRelease(pixelBuffer);
                frameCount++;
            } else {
                VCamDebugLog(@"sample has no pixel buffer at frame=%d", frameCount);
            }
            CFRelease(sampleBuffer);
        }
        VCamDebugLog(@"read complete frames=%d status=%ld error=%@", frameCount,
                     (long)assetReader.status, assetReader.error);
        if (frameCount > 0) {
            currentMode = VCamModeVideo;
            VCamDebugLog(@"video mode enabled frames=%lu", (unsigned long)videoFrames.count);
        } else {
            VCamDebugLog(@"video mode NOT enabled: zero decoded frames");
        }
        [assetReader cancelReading];
    } else {
        VCamDebugLog(@"abort: unsupported extension %@", extension);
    }

    if (!sharedCIContext) sharedCIContext = [CIContext context];
    VCamDebugLog(@"load finished mode=%d ciContext=%d", currentMode, sharedCIContext != nil);
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    @synchronized(vcamLock) {
        if (!didLogDraw) {
            didLogDraw = YES;
            VCamDebugLog(@"draw entered mode=%d target=%zux%zu frames=%lu", currentMode,
                         targetBuffer ? CVPixelBufferGetWidth(targetBuffer) : 0,
                         targetBuffer ? CVPixelBufferGetHeight(targetBuffer) : 0,
                         (unsigned long)videoFrames.count);
        }
        if (!targetBuffer) return;
        CIImage *replacementCIImage = nil;
        if (currentMode == VCamModeImage && replacementImage) {
            replacementCIImage = [CIImage imageWithCGImage:replacementImage];
        } else if (currentMode == VCamModeVideo && videoFrames.count > 0) {
            CVPixelBufferRef videoFrame = (__bridge CVPixelBufferRef)videoFrames[currentFrameIndex];
            currentFrameIndex = (currentFrameIndex + 1) % videoFrames.count;
            replacementCIImage = [CIImage imageWithCVPixelBuffer:videoFrame];
        }
        if (!replacementCIImage) return;

        CGFloat targetWidth = CVPixelBufferGetWidth(targetBuffer);
        CGFloat targetHeight = CVPixelBufferGetHeight(targetBuffer);
        CGRect replacementExtent = replacementCIImage.extent;
        CGFloat scale = MIN(targetWidth / replacementExtent.size.width, targetHeight / replacementExtent.size.height);
        CIImage *scaledImage = [replacementCIImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = scaledImage.extent;
        CGFloat offsetX = (targetWidth - scaledExtent.size.width) / 2.0;
        CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;
        CIImage *finalImage = [scaledImage imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];
        if (sharedCIContext) [sharedCIContext render:finalImage toCVPixelBuffer:targetBuffer];
    }
}
