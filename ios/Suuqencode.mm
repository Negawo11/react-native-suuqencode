#import "Suuqencode.h"

@interface Suuqencode()

@property (nonatomic) VTCompressionSessionRef compressionSession;
@property (nonatomic) dispatch_queue_t encodeQueue;
@property (nonatomic) int frameCount;

@end

@implementation Suuqencode

RCT_EXPORT_MODULE()

- (instancetype)init
{
    self = [super init];
    if (self) {
        _encodeQueue = dispatch_queue_create("com.suuqencode.encodequeue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#import <SuuqeDMABuf/DMABuf.h>

RCT_EXPORT_METHOD(startEncode)
{
    [DMABuf setFrameChangeCallback:^{
        void *buf = [DMABuf buf];
        int width = [DMABuf width];
        int height = [DMABuf height];
        
        if (!buf) {
            return;
        }
        
        dispatch_async(self.encodeQueue, ^{
            if (!self.compressionSession) {
                [self setupCompressionSessionWithWidth:width height:height];
            }
            
            CVPixelBufferRef pixelBuffer = NULL;
            CVReturn status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, buf, width * 4, NULL, NULL, NULL, &pixelBuffer);
            
            if (status != kCVReturnSuccess) {
                NSLog(@"Failed to create CVPixelBuffer");
                return;
            }
            
            CMTime presentationTimeStamp = CMTimeMake(self.frameCount++, 30);
            VTEncodeInfoFlags flags;
            
            VTCompressionSessionEncodeFrame(self.compressionSession, pixelBuffer, presentationTimeStamp, kCMTimeInvalid, NULL, NULL, &flags);
            CVPixelBufferRelease(pixelBuffer);
        });
    }];
}

- (void)setupCompressionSessionWithWidth:(int)width height:(int)height {
    VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264, NULL, NULL, NULL, compressionOutputCallback, (__bridge void *)(self), &_compressionSession);

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(width * height * 10));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(20));

    VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
}

void compressionOutputCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    if (status != noErr) {
        NSLog(@"Error encoding frame: %d", (int)status);
        return;
    }

    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }

    Suuqencode *encoder = (__bridge Suuqencode *)outputCallbackRefCon;

    bool isKeyFrame = !CFDictionaryContainsKey( (CFDictionaryRef)CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0), (const void *)kCMSampleAttachmentKey_NotSync);

    if (isKeyFrame)
    {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        const uint8_t *sparameterSet;
        size_t sparameterSetSize, sparameterSetCount;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0 );

        const uint8_t *pparameterSet;
        size_t pparameterSetSize, pparameterSetCount;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0 );

        NSData *sps = [NSData dataWithBytes:sparameterSet length:sparameterSetSize];
        NSData *pps = [NSData dataWithBytes:pparameterSet length:pparameterSetSize];

        [encoder sendEncodedData:sps];
        [encoder sendEncodedData:pps];
    }

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);

    NSData *naluData = [NSData dataWithBytes:dataPointer length:length];
    [encoder sendEncodedData:naluData];
}

- (void)sendEncodedData:(NSData *)data {
    NSString *base64Encoded = [data base64EncodedStringWithOptions:0];
    [self sendEventWithName:@"onEncodedData" body:base64Encoded];
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"onEncodedData"];
}

+ (BOOL)requiresMainQueueSetup
{
    return NO;
}

@end
