#import <Foundation/Foundation.h>

@protocol SuuqeHttpConnectionDelegate <NSObject>
- (void)httpConnection:(NSString *)connectionId
    didReceiveResponse:(NSInteger)statusCode
               headers:(NSDictionary *)headers;
- (void)httpConnection:(NSString *)connectionId
        didReceiveData:(NSData *)data;
- (void)httpConnection:(NSString *)connectionId
         didWriteBytes:(NSInteger)bytesWritten
      totalBytesQueued:(NSInteger)totalQueued;
- (void)httpConnection:(NSString *)connectionId
  didCompleteWithError:(NSError *_Nullable)error;
@end

@interface SuuqeHttpConnection : NSObject

@property(nonatomic, strong, readonly) NSString *connectionId;
@property(nonatomic, weak) id<SuuqeHttpConnectionDelegate> delegate;

- (instancetype)initWithConnectionId:(NSString *)connectionId
                                 url:(NSURL *)url
                              method:(NSString *)method
                             headers:
                                 (NSDictionary<NSString *, NSString *> *_Nullable)
                                     headers
                          bufferSize:(NSInteger)bufferSize;

- (void)start;
- (void)writeData:(NSData *)data;
- (void)finishWriting;
- (void)close;

@end
