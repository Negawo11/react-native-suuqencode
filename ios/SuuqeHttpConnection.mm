#import "SuuqeHttpConnection.h"

@interface SuuqeHttpConnection () <NSURLSessionDataDelegate, NSStreamDelegate>

@property (nonatomic, strong, readwrite) NSString *connectionId;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSString *method;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic) NSInteger bufferSize;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;

// For streaming POST/PUT/PATCH body
@property (nonatomic, strong) NSInputStream *bodyInputStream;
@property (nonatomic, strong) NSOutputStream *bodyOutputStream;
@property (nonatomic, strong) NSThread *streamThread;

@property (nonatomic, strong) NSMutableArray<NSData *> *pendingWrites;
@property (nonatomic) NSUInteger currentWriteOffset;
@property (nonatomic) BOOL streamHasSpace;
@property (nonatomic) BOOL doneWriting;
@property (nonatomic) BOOL closed;

@property (nonatomic) NSInteger totalBytesQueued;

@end

@implementation SuuqeHttpConnection

- (instancetype)initWithConnectionId:(NSString *)connectionId
                                 url:(NSURL *)url
                              method:(NSString *)method
                             headers:(NSDictionary<NSString *, NSString *> *)headers
                          bufferSize:(NSInteger)bufferSize {
  self = [super init];
  if (self) {
    _connectionId = connectionId;
    _url = url;
    _method = method;
    _requestHeaders = headers ?: @{};
    _bufferSize = bufferSize > 0 ? bufferSize : 65536;
    _pendingWrites = [NSMutableArray new];
    _currentWriteOffset = 0;
    _streamHasSpace = NO;
    _doneWriting = NO;
    _closed = NO;
    _totalBytesQueued = 0;
  }
  return self;
}

- (void)start {
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:self.url];
  request.HTTPMethod = self.method;

  for (NSString *key in self.requestHeaders) {
    [request setValue:self.requestHeaders[key] forHTTPHeaderField:key];
  }

  BOOL needsBody = [self.method isEqualToString:@"POST"] ||
                   [self.method isEqualToString:@"PUT"] ||
                   [self.method isEqualToString:@"PATCH"];

  if (needsBody) {
    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    CFStreamCreateBoundPair(kCFAllocatorDefault, &readStream, &writeStream,
                            (CFIndex)self.bufferSize);

    self.bodyInputStream = (__bridge_transfer NSInputStream *)readStream;
    self.bodyOutputStream = (__bridge_transfer NSOutputStream *)writeStream;

    self.bodyOutputStream.delegate = self;

    // Start a dedicated thread for the output stream run loop
    self.streamThread = [[NSThread alloc] initWithTarget:self
                                                selector:@selector(streamThreadMain)
                                                  object:nil];
    self.streamThread.name =
        [NSString stringWithFormat:@"SuuqeHttp-%@", self.connectionId];
    [self.streamThread start];

    request.HTTPBodyStream = self.bodyInputStream;
  }

  NSURLSessionConfiguration *config =
      [NSURLSessionConfiguration defaultSessionConfiguration];
  NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
  delegateQueue.maxConcurrentOperationCount = 1;
  delegateQueue.name =
      [NSString stringWithFormat:@"SuuqeHttp-delegate-%@", self.connectionId];

  self.session = [NSURLSession sessionWithConfiguration:config
                                               delegate:self
                                          delegateQueue:delegateQueue];

  self.task = [self.session dataTaskWithRequest:request];
  [self.task resume];
}

#pragma mark - Stream Thread

- (void)streamThreadMain {
  @autoreleasepool {
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];

    [self.bodyOutputStream scheduleInRunLoop:runLoop
                                    forMode:NSDefaultRunLoopMode];
    [self.bodyOutputStream open];

    // Add a port to prevent the run loop from exiting immediately
    [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];

    while (!self.closed && !(self.doneWriting && self.pendingWrites.count == 0)) {
      @autoreleasepool {
        [runLoop runMode:NSDefaultRunLoopMode
              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
      }
    }

    // Close the output stream when done
    if (self.bodyOutputStream) {
      [self.bodyOutputStream close];
      [self.bodyOutputStream removeFromRunLoop:runLoop
                                       forMode:NSDefaultRunLoopMode];
    }
  }
}

#pragma mark - Write API

- (void)writeData:(NSData *)data {
  if (self.closed || self.doneWriting) return;

  if (self.streamThread && self.streamThread.isExecuting) {
    [self performSelector:@selector(_enqueueData:)
                 onThread:self.streamThread
               withObject:data
            waitUntilDone:NO];
  }
}

- (void)_enqueueData:(NSData *)data {
  [self.pendingWrites addObject:data];
  self.totalBytesQueued += data.length;
  [self _drainWriteBuffer];
}

- (void)finishWriting {
  if (self.closed) return;

  if (self.streamThread && self.streamThread.isExecuting) {
    [self performSelector:@selector(_markDoneWriting)
                 onThread:self.streamThread
               withObject:nil
            waitUntilDone:NO];
  } else {
    self.doneWriting = YES;
  }
}

- (void)_markDoneWriting {
  self.doneWriting = YES;
  // If buffer is already empty, the run loop exit condition handles closing
}

- (void)_drainWriteBuffer {
  while (self.pendingWrites.count > 0 && self.streamHasSpace && !self.closed) {
    NSData *data = self.pendingWrites.firstObject;
    const uint8_t *bytes =
        (const uint8_t *)data.bytes + self.currentWriteOffset;
    NSInteger remaining = (NSInteger)data.length - (NSInteger)self.currentWriteOffset;

    NSInteger written =
        [self.bodyOutputStream write:bytes maxLength:(NSUInteger)remaining];

    if (written > 0) {
      self.currentWriteOffset += (NSUInteger)written;
      if (self.currentWriteOffset >= data.length) {
        NSInteger chunkSize = (NSInteger)data.length;
        [self.pendingWrites removeObjectAtIndex:0];
        self.currentWriteOffset = 0;

        // Notify delegate (switch to main thread for event emission)
        __weak SuuqeHttpConnection *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          __strong SuuqeHttpConnection *strongSelf = weakSelf;
          if (strongSelf && strongSelf.delegate) {
            [strongSelf.delegate httpConnection:strongSelf.connectionId
                                  didWriteBytes:chunkSize
                               totalBytesQueued:strongSelf.totalBytesQueued];
          }
        });
      }
    } else if (written == 0) {
      // Stream buffer full, wait for space
      self.streamHasSpace = NO;
      break;
    } else {
      // Error writing to stream
      self.streamHasSpace = NO;
      NSLog(@"[SuuqeHttp] Error writing to output stream: %@",
            self.bodyOutputStream.streamError);
      break;
    }
  }
}

#pragma mark - Close

- (void)close {
  if (self.closed) return;
  self.closed = YES;

  // Cancel the URL task immediately
  [self.task cancel];

  // Close the output stream if we have one
  if (self.bodyOutputStream) {
    // If the stream thread is running, close from there
    if (self.streamThread && self.streamThread.isExecuting) {
      [self performSelector:@selector(_closeOutputStream)
                   onThread:self.streamThread
                 withObject:nil
              waitUntilDone:NO];
    } else {
      [self.bodyOutputStream close];
    }
  }

  // Invalidate the session (cancels all tasks and releases delegate)
  [self.session invalidateAndCancel];

  [self.pendingWrites removeAllObjects];
}

- (void)_closeOutputStream {
  if (self.bodyOutputStream) {
    [self.bodyOutputStream close];
  }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
  if (aStream != self.bodyOutputStream) return;

  switch (eventCode) {
  case NSStreamEventHasSpaceAvailable:
    self.streamHasSpace = YES;
    [self _drainWriteBuffer];
    break;
  case NSStreamEventErrorOccurred:
    NSLog(@"[SuuqeHttp] Output stream error: %@", aStream.streamError);
    break;
  case NSStreamEventEndEncountered:
    break;
  default:
    break;
  }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:
         (void (^)(NSURLSessionResponseDisposition))completionHandler {
  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
  NSInteger statusCode = httpResponse.statusCode;

  // Convert header keys/values to strings
  NSMutableDictionary *headers = [NSMutableDictionary new];
  for (NSString *key in httpResponse.allHeaderFields) {
    headers[key] =
        [NSString stringWithFormat:@"%@", httpResponse.allHeaderFields[key]];
  }

  __weak SuuqeHttpConnection *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong SuuqeHttpConnection *strongSelf = weakSelf;
    if (strongSelf && strongSelf.delegate) {
      [strongSelf.delegate httpConnection:strongSelf.connectionId
                       didReceiveResponse:statusCode
                                  headers:headers];
    }
  });

  completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  __weak SuuqeHttpConnection *weakSelf = self;
  // Copy data so it's safe across dispatch
  NSData *dataCopy = [data copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong SuuqeHttpConnection *strongSelf = weakSelf;
    if (strongSelf && strongSelf.delegate) {
      [strongSelf.delegate httpConnection:strongSelf.connectionId
                           didReceiveData:dataCopy];
    }
  });
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  __weak SuuqeHttpConnection *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong SuuqeHttpConnection *strongSelf = weakSelf;
    if (strongSelf && strongSelf.delegate) {
      // Don't report cancellation errors as failures if we closed intentionally
      if (strongSelf.closed && error &&
          error.code == NSURLErrorCancelled) {
        [strongSelf.delegate httpConnection:strongSelf.connectionId
                       didCompleteWithError:nil];
      } else {
        [strongSelf.delegate httpConnection:strongSelf.connectionId
                       didCompleteWithError:error];
      }
    }
  });
}

#pragma mark - Cleanup

- (void)dealloc {
  if (!_closed) {
    _closed = YES;
    [_task cancel];
    [_bodyOutputStream close];
    [_session invalidateAndCancel];
    [_pendingWrites removeAllObjects];
  }
}

@end
