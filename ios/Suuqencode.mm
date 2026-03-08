#import "Suuqencode.h"
#import "SuuqeHttpConnection.h"
#import <SuuqeDMABuf/DMABuf.h>

@interface Suuqencode ()

// Video encoding properties
@property(nonatomic) VTCompressionSessionRef compressionSession;
@property(nonatomic) dispatch_queue_t encodeQueue;
@property(nonatomic) int frameCount;

// Audio recording + FLAC encoding properties
@property(nonatomic, strong) AVAudioEngine *audioEngine;
@property(nonatomic, strong) AVAudioConverter *pcmConverter;
@property(nonatomic, strong) AVAudioConverter *flacConverter;
@property(nonatomic, strong) AVAudioFormat *targetPCMFormat;
@property(nonatomic, strong) AVAudioFormat *flacFormat;
@property(nonatomic) dispatch_queue_t audioEncodeQueue;
@property(nonatomic) BOOL isRecordingAudio;
@property(nonatomic) double audioSampleRate;
@property(nonatomic, strong) NSString *audioFormat; // "flac" or "pcm"

// HTTP streaming connections
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, SuuqeHttpConnection *> *httpConnections;

// PCM streaming playback (uses the shared audioEngine above)
@property(nonatomic, strong) AVAudioPlayerNode *playerNode;
@property(nonatomic, strong) AVAudioFormat *playbackFormat;
@property(nonatomic) BOOL isPlaybackActive;
@property(nonatomic) dispatch_queue_t playbackQueue;

- (void)sendEncodedData:(NSData *)data;

@end

@implementation Suuqencode

RCT_EXPORT_MODULE()

- (instancetype)init {
  self = [super init];
  if (self) {
    _encodeQueue = dispatch_queue_create("com.suuqencode.encodequeue",
                                         DISPATCH_QUEUE_SERIAL);
    _audioEncodeQueue = dispatch_queue_create("com.suuqencode.audioencodequeue",
                                              DISPATCH_QUEUE_SERIAL);
    _httpConnections = [NSMutableDictionary new];
    _playbackQueue = dispatch_queue_create("com.suuqencode.playbackqueue",
                                           DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

RCT_EXPORT_METHOD(startEncode) {
  [DMABuf setFrameChangeCallback:^{
    void *buf = [DMABuf buf];
    int width = [DMABuf width];
    int height = [DMABuf height];
    int bytesPerRow = [DMABuf bytesPerRow];

    if (!buf) {
      return;
    }

    size_t bufferSize = bytesPerRow * height;
    void *bufferCopy = malloc(bufferSize);
    if (!bufferCopy) {
      return;
    }
    memcpy(bufferCopy, buf, bufferSize);

    dispatch_async(self.encodeQueue, ^{
      if (!self.compressionSession) {
        [self setupCompressionSessionWithWidth:width height:height];
      }

      CVPixelBufferRef pixelBuffer = NULL;
      CVReturn status = CVPixelBufferCreateWithBytes(
          kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
          bufferCopy, bytesPerRow, releasePixelBufferCallback, NULL, NULL,
          &pixelBuffer);

      if (status != kCVReturnSuccess) {
        NSLog(@"Failed to create CVPixelBuffer");
        free(bufferCopy);
        return;
      }

      CMTime presentationTimeStamp = CMTimeMake(self.frameCount++, 30);
      VTEncodeInfoFlags flags;

      VTCompressionSessionEncodeFrame(self.compressionSession, pixelBuffer,
                                      presentationTimeStamp, kCMTimeInvalid,
                                      NULL, NULL, &flags);
      CVPixelBufferRelease(pixelBuffer);
    });
  }];
}

- (void)setupCompressionSessionWithWidth:(int)width height:(int)height {
  VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264, NULL,
                             NULL, NULL, compressionOutputCallback,
                             (__bridge void *)(self), &_compressionSession);

  VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime,
                       kCFBooleanTrue);
  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_ProfileLevel,
                       kVTProfileLevel_H264_Baseline_AutoLevel);
  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_AverageBitRate,
                       (__bridge CFTypeRef) @(width * height * 10));
  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_MaxKeyFrameInterval,
                       (__bridge CFTypeRef) @(20));

  VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
}

void releasePixelBufferCallback(void *releaseRefCon, const void *baseAddress) {
  free((void *)baseAddress);
}

void compressionOutputCallback(void *outputCallbackRefCon,
                               void *sourceFrameRefCon, OSStatus status,
                               VTEncodeInfoFlags infoFlags,
                               CMSampleBufferRef sampleBuffer) {
  if (status != noErr) {
    NSLog(@"Error encoding frame: %d", (int)status);
    return;
  }

  if (!CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }

  Suuqencode *encoder = (__bridge Suuqencode *)outputCallbackRefCon;
  const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
  size_t startCodeSize = sizeof(startCode);

  bool isKeyFrame = !CFDictionaryContainsKey(
      (CFDictionaryRef)CFArrayGetValueAtIndex(
          CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0),
      (const void *)kCMSampleAttachmentKey_NotSync);

  if (isKeyFrame) {
    CMFormatDescriptionRef format =
        CMSampleBufferGetFormatDescription(sampleBuffer);
    const uint8_t *sparameterSet;
    size_t sparameterSetSize, sparameterSetCount;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0);

    const uint8_t *pparameterSet;
    size_t pparameterSetSize, pparameterSetCount;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0);

    NSMutableData *spsData = [NSMutableData dataWithBytes:startCode
                                                   length:startCodeSize];
    [spsData appendBytes:sparameterSet length:sparameterSetSize];
    [encoder sendEncodedData:spsData];

    NSMutableData *ppsData = [NSMutableData dataWithBytes:startCode
                                                   length:startCodeSize];
    [ppsData appendBytes:pparameterSet length:pparameterSetSize];
    [encoder sendEncodedData:ppsData];
  }

  CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t length, totalLength;
  char *dataPointer;
  CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength,
                              &dataPointer);

  // Parse AVCC NAL units and convert to Annex B
  size_t bufferOffset = 0;
  static const int AVCCHeaderLength = 4;

  while (bufferOffset < totalLength - AVCCHeaderLength) {
    uint32_t NALUnitLength = 0;
    memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);

    // Convert big-endian length to host endianness
    NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);

    NSMutableData *naluData = [NSMutableData dataWithBytes:startCode
                                                    length:startCodeSize];
    [naluData appendBytes:(dataPointer + bufferOffset + AVCCHeaderLength)
                   length:NALUnitLength];

    [encoder sendEncodedData:naluData];

    bufferOffset += AVCCHeaderLength + NALUnitLength;
  }
}

- (void)sendEncodedData:(NSData *)data {
  NSString *base64Encoded = [data base64EncodedStringWithOptions:0];
  [self sendEventWithName:@"onEncodedData" body:base64Encoded];
}

#pragma mark - Audio Recording & FLAC Encoding

RCT_EXPORT_METHOD(startAudioEncode:(double)sampleRate
                  format:(NSString *)format
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  if (self.isRecordingAudio) {
    reject(@"ALREADY_RECORDING", @"Audio recording is already in progress", nil);
    return;
  }

  self.audioSampleRate = sampleRate > 0 ? sampleRate : 16000.0;
  self.audioFormat = ([format isEqualToString:@"pcm"]) ? @"pcm" : @"flac";

  AVAudioSession *session = [AVAudioSession sharedInstance];
  [session requestRecordPermission:^(BOOL granted) {
    if (!granted) {
      reject(@"PERMISSION_DENIED", @"Microphone permission was denied", nil);
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      NSError *setupError = nil;
      BOOL success = [self setupAudioCaptureWithError:&setupError];
      if (!success) {
        reject(@"SETUP_FAILED",
               setupError ? setupError.localizedDescription : @"Failed to set up audio capture",
               setupError);
        return;
      }

      // Emit format info so the receiver knows the audio parameters
      NSDictionary *formatInfo = @{
        @"sampleRate": @(self.audioSampleRate),
        @"channels": @(1),
        @"bitsPerSample": @(16),
        @"codec": self.audioFormat
      };
      [self sendEventWithName:@"onAudioFormatInfo" body:formatInfo];
      resolve(@(YES));
    });
  }];
}

RCT_EXPORT_METHOD(stopAudioEncode) {
  if (!self.isRecordingAudio) {
    return;
  }

  self.isRecordingAudio = NO;

  if (self.audioEngine) {
    [self.audioEngine.inputNode removeTapOnBus:0];

    // Only tear down the shared engine if playback isn't using it
    if (!self.isPlaybackActive) {
      [self.audioEngine stop];
      self.audioEngine = nil;
    }
  }

  self.pcmConverter = nil;
  self.flacConverter = nil;
  self.targetPCMFormat = nil;
  self.flacFormat = nil;
  self.audioFormat = nil;
}

- (BOOL)setupAudioCaptureWithError:(NSError **)outError {
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *error = nil;

  [session setCategory:AVAudioSessionCategoryPlayAndRecord
           withOptions:(AVAudioSessionCategoryOptionDefaultToSpeaker |
                        AVAudioSessionCategoryOptionAllowBluetooth)
                 error:&error];
  if (error) {
    if (outError) *outError = error;
    return NO;
  }

  // NOTE: We intentionally do NOT set AVAudioSessionModeVoiceChat here.
  // That mode routes audio to the earpiece, overriding DefaultToSpeaker.
  // Instead we rely on setVoiceProcessingEnabled:YES on the AVAudioInputNode
  // (below) which directly activates the VPIO audio unit for AEC without
  // changing the output routing.

  [session setActive:YES error:&error];
  if (error) {
    if (outError) *outError = error;
    return NO;
  }

  // Reuse the shared engine if playback already started one, else create new.
  // We must use a SINGLE AVAudioEngine for both recording and playback so
  // that the Voice Processing IO unit (AEC) can reference the output signal.
  BOOL playbackWasActive = (self.audioEngine != nil && self.isPlaybackActive);
  AVAudioFormat *savedPlaybackFormat = self.playbackFormat;

  if (self.audioEngine.isRunning) {
    // Must stop before enabling voice processing
    [self.audioEngine stop];
  }
  if (!self.audioEngine) {
    self.audioEngine = [[AVAudioEngine alloc] init];
  }

  AVAudioInputNode *inputNode = self.audioEngine.inputNode;

  // Explicitly enable Voice Processing on the input node (iOS 13+).
  // This activates the hardware AEC / noise-suppression unit so the mic
  // signal has the speaker output (Gemini's voice) subtracted from it.
  // Enabling VPIO swaps the underlying audio unit, which can invalidate
  // existing node connections — we reconnect the player node below.
  if (@available(iOS 13.0, *)) {
    NSError *vpError = nil;
    if (![inputNode setVoiceProcessingEnabled:YES error:&vpError]) {
      NSLog(@"[Suuqencode] Warning: could not enable voice processing: %@", vpError);
    }
  }

  // Reconnect the player node if it was attached, because enabling VPIO
  // changes the audio unit topology and can invalidate prior connections.
  if (playbackWasActive && self.playerNode && savedPlaybackFormat) {
    [self.audioEngine disconnectNodeOutput:self.playerNode];
    [self.audioEngine connect:self.playerNode
                           to:self.audioEngine.mainMixerNode
                       format:savedPlaybackFormat];
  }

  AVAudioFormat *hardwareFormat = [inputNode outputFormatForBus:0];

  if (!hardwareFormat || hardwareFormat.sampleRate == 0) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"SuuqencodeAudio"
                                      code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: @"Could not get hardware audio format"}];
    }
    return NO;
  }

  // Target PCM format: 16-bit signed integer, mono, at requested sample rate
  AudioStreamBasicDescription pcmASBD = {};
  pcmASBD.mFormatID = kAudioFormatLinearPCM;
  pcmASBD.mSampleRate = self.audioSampleRate;
  pcmASBD.mChannelsPerFrame = 1;
  pcmASBD.mBitsPerChannel = 16;
  pcmASBD.mBytesPerFrame = 2;
  pcmASBD.mBytesPerPacket = 2;
  pcmASBD.mFramesPerPacket = 1;
  pcmASBD.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;

  self.targetPCMFormat = [[AVAudioFormat alloc] initWithStreamDescription:&pcmASBD];
  if (!self.targetPCMFormat) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"SuuqencodeAudio"
                                      code:-2
                                  userInfo:@{NSLocalizedDescriptionKey: @"Could not create target PCM format"}];
    }
    return NO;
  }

  // FLAC output format (only if FLAC mode is selected)
  if ([self.audioFormat isEqualToString:@"flac"]) {
    AudioStreamBasicDescription flacASBD = {};
    flacASBD.mFormatID = kAudioFormatFLAC;
    flacASBD.mSampleRate = self.audioSampleRate;
    flacASBD.mChannelsPerFrame = 1;
    flacASBD.mBitsPerChannel = 16;
    flacASBD.mFramesPerPacket = 0;
    flacASBD.mBytesPerPacket = 0;
    flacASBD.mBytesPerFrame = 0;
    flacASBD.mFormatFlags = 0;

    self.flacFormat = [[AVAudioFormat alloc] initWithStreamDescription:&flacASBD];
    if (!self.flacFormat) {
      if (outError) {
        *outError = [NSError errorWithDomain:@"SuuqencodeAudio"
                                        code:-3
                                    userInfo:@{NSLocalizedDescriptionKey: @"FLAC audio format not available on this device"}];
      }
      return NO;
    }
  }

  // PCM resampler: hardware format → target PCM
  self.pcmConverter = [[AVAudioConverter alloc] initFromFormat:hardwareFormat
                                                     toFormat:self.targetPCMFormat];
  if (!self.pcmConverter) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"SuuqencodeAudio"
                                      code:-4
                                  userInfo:@{NSLocalizedDescriptionKey: @"Could not create PCM resampler"}];
    }
    return NO;
  }

  // FLAC encoder: target PCM → FLAC (only if FLAC mode is selected)
  if ([self.audioFormat isEqualToString:@"flac"]) {
    self.flacConverter = [[AVAudioConverter alloc] initFromFormat:self.targetPCMFormat
                                                        toFormat:self.flacFormat];
    if (!self.flacConverter) {
      if (outError) {
        *outError = [NSError errorWithDomain:@"SuuqencodeAudio"
                                        code:-5
                                    userInfo:@{NSLocalizedDescriptionKey: @"Could not create FLAC encoder — FLAC encoding may not be supported on this OS version"}];
      }
      return NO;
    }
  }

  // Install tap on the input node using the hardware's native format
  __weak Suuqencode *weakSelf = self;
  [inputNode installTapOnBus:0
                  bufferSize:4096
                      format:hardwareFormat
                       block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
    __strong Suuqencode *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.isRecordingAudio) return;

    // Copy the buffer so we can safely dispatch off the realtime audio thread
    AVAudioPCMBuffer *bufferCopy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:buffer.format
                                                                 frameCapacity:buffer.frameLength];
    bufferCopy.frameLength = buffer.frameLength;

    if (hardwareFormat.commonFormat == AVAudioPCMFormatFloat32) {
      for (AVAudioChannelCount ch = 0; ch < hardwareFormat.channelCount; ch++) {
        memcpy(bufferCopy.floatChannelData[ch],
               buffer.floatChannelData[ch],
               buffer.frameLength * sizeof(float));
      }
    } else if (hardwareFormat.commonFormat == AVAudioPCMFormatInt16) {
      for (AVAudioChannelCount ch = 0; ch < hardwareFormat.channelCount; ch++) {
        memcpy(bufferCopy.int16ChannelData[ch],
               buffer.int16ChannelData[ch],
               buffer.frameLength * sizeof(int16_t));
      }
    } else if (hardwareFormat.commonFormat == AVAudioPCMFormatInt32) {
      for (AVAudioChannelCount ch = 0; ch < hardwareFormat.channelCount; ch++) {
        memcpy(bufferCopy.int32ChannelData[ch],
               buffer.int32ChannelData[ch],
               buffer.frameLength * sizeof(int32_t));
      }
    } else {
      // Float64 or other — fallback to raw bytes
      size_t byteCount = buffer.frameLength * hardwareFormat.streamDescription->mBytesPerFrame;
      for (AVAudioChannelCount ch = 0; ch < hardwareFormat.channelCount; ch++) {
        memcpy(bufferCopy.floatChannelData[ch],
               buffer.floatChannelData[ch],
               byteCount);
      }
    }

    dispatch_async(strongSelf.audioEncodeQueue, ^{
      [strongSelf processAudioBuffer:bufferCopy];
    });
  }];

  // Start (or restart) the engine
  [self.audioEngine startAndReturnError:&error];
  if (error) {
    if (outError) *outError = error;
    [inputNode removeTapOnBus:0];
    if (!self.isPlaybackActive) {
      self.audioEngine = nil;
    }
    return NO;
  }

  // If a player node was active before we stopped the engine to enable
  // voice processing, resume it now that the engine is running again.
  if (playbackWasActive && self.playerNode) {
    [self.playerNode play];
  }

  self.isRecordingAudio = YES;
  return YES;
}

- (void)processAudioBuffer:(AVAudioPCMBuffer *)inputBuffer {
  if (!self.isRecordingAudio) return;

  // Step 1: Resample hardware PCM → target PCM (16kHz mono int16)
  double sampleRateRatio = self.targetPCMFormat.sampleRate / inputBuffer.format.sampleRate;
  AVAudioFrameCount outputFrameCapacity = (AVAudioFrameCount)ceil(inputBuffer.frameLength * sampleRateRatio) + 16;

  AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.targetPCMFormat
                                                              frameCapacity:outputFrameCapacity];
  NSError *error = nil;
  __block BOOL pcmInputProvided = NO;

  AVAudioConverterOutputStatus pcmStatus = [self.pcmConverter
      convertToBuffer:pcmBuffer
                error:&error
    withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets,
                                                   AVAudioConverterInputStatus *outStatus) {
      if (pcmInputProvided) {
        *outStatus = AVAudioConverterInputStatus_NoDataNow;
        return nil;
      }
      pcmInputProvided = YES;
      *outStatus = AVAudioConverterInputStatus_HaveData;
      return inputBuffer;
    }];

  if (error) {
    NSLog(@"[Suuqencode] PCM resampling error: %@", error);
    return;
  }
  if (pcmBuffer.frameLength == 0) {
    return;
  }

  // Step 2: Encode PCM → FLAC, or emit raw PCM
  if ([self.audioFormat isEqualToString:@"pcm"]) {
    // PCM mode: emit the resampled 16-bit PCM data directly
    NSData *pcmData = [NSData dataWithBytes:pcmBuffer.int16ChannelData[0]
                                     length:pcmBuffer.frameLength * sizeof(int16_t)];
    NSString *base64 = [pcmData base64EncodedStringWithOptions:0];
    [self sendEventWithName:@"onAudioEncodedData" body:base64];
    return;
  }

  // FLAC mode
  AVAudioCompressedBuffer *flacBuffer =
      [[AVAudioCompressedBuffer alloc] initWithFormat:self.flacFormat
                                       packetCapacity:8
                                    maximumPacketSize:65536];

  __block BOOL flacInputProvided = NO;
  AVAudioConverterOutputStatus flacStatus = [self.flacConverter
      convertToBuffer:flacBuffer
                error:&error
    withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets,
                                                   AVAudioConverterInputStatus *outStatus) {
      if (flacInputProvided) {
        *outStatus = AVAudioConverterInputStatus_NoDataNow;
        return nil;
      }
      flacInputProvided = YES;
      *outStatus = AVAudioConverterInputStatus_HaveData;
      return pcmBuffer;
    }];

  if (error) {
    NSLog(@"[Suuqencode] FLAC encoding error: %@", error);
    return;
  }

  if ((flacStatus == AVAudioConverterOutputStatus_HaveData ||
       flacStatus == AVAudioConverterOutputStatus_InputRanDry) &&
      flacBuffer.byteLength > 0) {
    NSData *flacData = [NSData dataWithBytes:flacBuffer.data length:flacBuffer.byteLength];
    NSString *base64 = [flacData base64EncodedStringWithOptions:0];
    [self sendEventWithName:@"onAudioEncodedData" body:base64];
  }
}

#pragma mark - PCM Streaming Playback

RCT_EXPORT_METHOD(startPcmPlayer:(double)sampleRate
                  channels:(double)channels
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  if (self.isPlaybackActive) {
    // Already running — just resolve
    resolve(@(YES));
    return;
  }

  double rate = sampleRate > 0 ? sampleRate : 24000.0;
  int ch = channels > 0 ? (int)channels : 1;

  // 16-bit signed integer PCM at the given sample rate
  AudioStreamBasicDescription asbd = {};
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mSampleRate = rate;
  asbd.mChannelsPerFrame = (UInt32)ch;
  asbd.mBitsPerChannel = 16;
  asbd.mBytesPerFrame = 2 * (UInt32)ch;
  asbd.mBytesPerPacket = 2 * (UInt32)ch;
  asbd.mFramesPerPacket = 1;
  asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;

  self.playbackFormat = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
  if (!self.playbackFormat) {
    reject(@"FORMAT_ERROR", @"Could not create playback format", nil);
    return;
  }

  // Use the shared audioEngine for playback.  When recording starts
  // later, voice processing (AEC) will reference this engine's output
  // to cancel speaker audio from the mic signal.
  BOOL needsStart = NO;
  if (!self.audioEngine) {
    self.audioEngine = [[AVAudioEngine alloc] init];
    needsStart = YES;
  } else if (!self.audioEngine.isRunning) {
    needsStart = YES;
  }

  self.playerNode = [[AVAudioPlayerNode alloc] init];

  [self.audioEngine attachNode:self.playerNode];
  [self.audioEngine connect:self.playerNode
                            to:self.audioEngine.mainMixerNode
                        format:self.playbackFormat];

  if (needsStart) {
    NSError *error = nil;
    [self.audioEngine startAndReturnError:&error];
    if (error) {
      reject(@"ENGINE_ERROR", error.localizedDescription, error);
      [self.audioEngine detachNode:self.playerNode];
      self.playerNode = nil;
      if (!self.isRecordingAudio) {
        self.audioEngine = nil;
      }
      return;
    }
  }

  [self.playerNode play];
  self.isPlaybackActive = YES;
  resolve(@(YES));
}

RCT_EXPORT_METHOD(writePcmData:(NSString *)base64Data) {
  if (!self.isPlaybackActive || !self.playerNode) return;

  NSData *pcmData = [[NSData alloc] initWithBase64EncodedString:base64Data
                                                        options:0];
  if (!pcmData || pcmData.length == 0) return;

  AVAudioFormat *fmt = self.playbackFormat;
  UInt32 bytesPerFrame = fmt.streamDescription->mBytesPerFrame;
  AVAudioFrameCount frameCount = (AVAudioFrameCount)(pcmData.length / bytesPerFrame);
  if (frameCount == 0) return;

  AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                          frameCapacity:frameCount];
  buffer.frameLength = frameCount;
  memcpy(buffer.int16ChannelData[0], pcmData.bytes, frameCount * bytesPerFrame);

  // Schedule on the player node.  AVAudioPlayerNode internally queues
  // buffers and plays them back-to-back with sample-accurate timing
  // — zero gap between consecutive scheduleBuffer calls.
  [self.playerNode scheduleBuffer:buffer completionHandler:nil];
}

RCT_EXPORT_METHOD(stopPcmPlayer) {
  if (!self.isPlaybackActive) return;
  self.isPlaybackActive = NO;

  if (self.playerNode) {
    [self.playerNode stop];
    if (self.audioEngine) {
      [self.audioEngine detachNode:self.playerNode];
    }
  }
  self.playerNode = nil;
  self.playbackFormat = nil;

  // Only tear down the shared engine if recording isn't using it
  if (!self.isRecordingAudio && self.audioEngine) {
    [self.audioEngine stop];
    self.audioEngine = nil;
  }

  [self sendEventWithName:@"onPcmPlayerStopped" body:@{}];
}

#pragma mark - HTTP Streaming

RCT_EXPORT_METHOD(httpCreate:(NSString *)connectionId
                  url:(NSString *)urlString
                  method:(NSString *)method
                  headers:(NSDictionary *)headers
                  bufferSize:(double)bufferSize) {
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) {
    [self sendEventWithName:@"onHttpError"
                       body:@{
                         @"connectionId" : connectionId,
                         @"error" : @"Invalid URL"
                       }];
    return;
  }

  SuuqeHttpConnection *connection =
      [[SuuqeHttpConnection alloc] initWithConnectionId:connectionId
                                                    url:url
                                                 method:method
                                                headers:headers
                                             bufferSize:(NSInteger)bufferSize];
  connection.delegate = self;

  @synchronized(self.httpConnections) {
    self.httpConnections[connectionId] = connection;
  }

  [connection start];
}

RCT_EXPORT_METHOD(httpWrite:(NSString *)connectionId
                  base64Data:(NSString *)base64Data) {
  SuuqeHttpConnection *connection;
  @synchronized(self.httpConnections) {
    connection = self.httpConnections[connectionId];
  }
  if (!connection) return;

  NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Data
                                                     options:0];
  if (data) {
    [connection writeData:data];
  }
}

RCT_EXPORT_METHOD(httpFinishWriting:(NSString *)connectionId) {
  SuuqeHttpConnection *connection;
  @synchronized(self.httpConnections) {
    connection = self.httpConnections[connectionId];
  }
  if (connection) {
    [connection finishWriting];
  }
}

RCT_EXPORT_METHOD(httpClose:(NSString *)connectionId) {
  SuuqeHttpConnection *connection;
  @synchronized(self.httpConnections) {
    connection = self.httpConnections[connectionId];
    [self.httpConnections removeObjectForKey:connectionId];
  }
  if (connection) {
    [connection close];
  }
}

#pragma mark - SuuqeHttpConnectionDelegate

- (void)httpConnection:(NSString *)connectionId
    didReceiveResponse:(NSInteger)statusCode
               headers:(NSDictionary *)headers {
  [self sendEventWithName:@"onHttpResponse"
                     body:@{
                       @"connectionId" : connectionId,
                       @"statusCode" : @(statusCode),
                       @"headers" : headers ?: @{}
                     }];
}

- (void)httpConnection:(NSString *)connectionId
        didReceiveData:(NSData *)data {
  NSString *base64 = [data base64EncodedStringWithOptions:0];
  [self sendEventWithName:@"onHttpData"
                     body:@{
                       @"connectionId" : connectionId,
                       @"data" : base64
                     }];
}

- (void)httpConnection:(NSString *)connectionId
         didWriteBytes:(NSInteger)bytesWritten
      totalBytesQueued:(NSInteger)totalQueued {
  [self sendEventWithName:@"onHttpWriteComplete"
                     body:@{
                       @"connectionId" : connectionId,
                       @"bytesWritten" : @(bytesWritten),
                       @"totalBytesQueued" : @(totalQueued)
                     }];
}

- (void)httpConnection:(NSString *)connectionId
  didCompleteWithError:(NSError *)error {
  if (error) {
    [self sendEventWithName:@"onHttpError"
                       body:@{
                         @"connectionId" : connectionId,
                         @"error" : error.localizedDescription ?: @"Unknown error"
                       }];
  } else {
    [self sendEventWithName:@"onHttpComplete"
                       body:@{@"connectionId" : connectionId}];
  }

  // Remove completed connection from tracking
  @synchronized(self.httpConnections) {
    [self.httpConnections removeObjectForKey:connectionId];
  }
}

#pragma mark - Events

- (NSArray<NSString *> *)supportedEvents {
  return @[
    @"onEncodedData",
    @"onAudioEncodedData",
    @"onAudioFormatInfo",
    @"onHttpResponse",
    @"onHttpData",
    @"onHttpWriteComplete",
    @"onHttpError",
    @"onHttpComplete",
    @"onPcmPlayerStopped"
  ];
}

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (void)invalidate {
  // Clean up PCM player
  if (self.isPlaybackActive) {
    self.isPlaybackActive = NO;
    [self.playerNode stop];
    self.playerNode = nil;
    self.playbackFormat = nil;
  }
  // Clean up shared audio engine
  if (self.isRecordingAudio) {
    self.isRecordingAudio = NO;
    if (self.audioEngine) {
      [self.audioEngine.inputNode removeTapOnBus:0];
    }
  }
  if (self.audioEngine) {
    [self.audioEngine stop];
    self.audioEngine = nil;
  }

  // Clean up all HTTP connections when the module is invalidated
  @synchronized(self.httpConnections) {
    for (SuuqeHttpConnection *conn in self.httpConnections.allValues) {
      [conn close];
    }
    [self.httpConnections removeAllObjects];
  }
}

@end
