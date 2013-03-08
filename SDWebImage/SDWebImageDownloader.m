/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import <ImageIO/ImageIO.h>

NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";

static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

@interface SDWebImageDownloader ()

@property (strong, nonatomic) NSOperationQueue *downloadQueue;
@property (weak, nonatomic) NSOperation *lastAddedOperation;
@property (strong, nonatomic) NSMutableDictionary *URLCallbacks;
@property (strong, nonatomic) NSMutableDictionary *HTTPHeaders;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t workingQueue;
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t barrierQueue;

@end

@implementation SDWebImageDownloader

+ (void)initialize
{
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator"))
    {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (SDWebImageDownloader *)sharedDownloader
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    if ((self = [super init]))
    {
        NSLog(@"init SDWebImageDownloader");
        _queueMode = SDWebImageDownloaderFILOQueueMode;
        _downloadQueue = NSOperationQueue.new;
        _downloadQueue.maxConcurrentOperationCount = 2;
        _URLCallbacks = NSMutableDictionary.new;
        _HTTPHeaders = [NSMutableDictionary dictionaryWithObject:@"image/*" forKey:@"Accept"];
        _workingQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloader", DISPATCH_QUEUE_SERIAL);
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc
{
    [self.downloadQueue cancelAllOperations];
    SDDispatchQueueRelease(_workingQueue);
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    if (value)
    {
        self.HTTPHeaders[field] = value;
    }
    else
    {
        [self.HTTPHeaders removeObjectForKey:field];
    }
}

- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    return self.HTTPHeaders[field];
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads
{
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSInteger)maxConcurrentDownloads
{
    return _downloadQueue.maxConcurrentOperationCount;
}

- (id<SDWebImageOperation>)downloadImageWithURL:(NSURL *)url options:(SDWebImageDownloaderOptions)options progress:(void (^)(NSUInteger, long long))progressBlock completed:(void (^)(UIImage *, NSData *, NSError *, BOOL))completedBlock
{
    __block SDWebImageDownloaderOperation *operation;
    __weak SDWebImageDownloader *wself = self;
    
    NSLog(@"SDWebImage init 001");

    [self addProgressCallback:progressBlock andCompletedBlock:completedBlock forURL:url createCallback:^
    {
        NSLog(@"break005");

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests
        NSMutableURLRequest *request = [NSMutableURLRequest.alloc initWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
        request.HTTPShouldHandleCookies = NO;
        request.HTTPShouldUsePipelining = YES;
        request.allHTTPHeaderFields = wself.HTTPHeaders;
        operation = [SDWebImageDownloaderOperation.alloc initWithRequest:request queue:wself.workingQueue options:options progress:^(NSUInteger receivedSize, long long expectedSize)
        {
            NSLog(@"operation start");
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            NSArray *callbacksForURL = [sself callbacksForURL:url];
            NSLog(@"callback loop");
            for (NSDictionary *callbacks in callbacksForURL)
            {
                NSLog(@"break 010");
                SDWebImageDownloaderProgressBlock callback = [callbacks objectForKey:kProgressCallbackKey];
                if (callback) callback(receivedSize, expectedSize);
                NSLog(@"break 011");
            }
        }
        completed:^(UIImage *image, NSData *data, NSError *error, BOOL finished)
        {
            NSLog(@"completed");
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            NSArray *callbacksForURL = [sself callbacksForURL:url];
            if (finished)
            {
                [sself removeCallbacksForURL:url];
            }
            for (NSDictionary *callbacks in callbacksForURL)
            {
                SDWebImageDownloaderCompletedBlock callback = [callbacks objectForKey:kCompletedCallbackKey];
                if (callback) callback(image, data, error, finished);
            }
        }
        cancelled:^
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            [sself callbacksForURL:url];
            [sself removeCallbacksForURL:url];
        }];
        [wself.downloadQueue addOperation:operation];
        if (wself.queueMode == SDWebImageDownloaderLIFOQueueMode)
        {
            // Emulate LIFO queue mode by systematically adding new operations as last operation's dependency
            [wself.lastAddedOperation addDependency:operation];
            wself.lastAddedOperation = operation;
        }
    }];

    return operation;
}

- (void)addProgressCallback:(void (^)(NSUInteger, long long))progressBlock andCompletedBlock:(void (^)(UIImage *, NSData *data, NSError *, BOOL))completedBlock forURL:(NSURL *)url createCallback:(void (^)())createCallback
{
    NSLog(@"break 007");
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    if(url == nil)
    {
        if (completedBlock != nil)
        {
            completedBlock(nil, nil, nil, NO);
        }
        return;
    }
    
    NSLog(@"break 008");
    
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        NSLog(@"break 009");
        NSLog( @"%@", self.URLCallbacks.description );
        NSLog(@"break 010-1");
        NSLog(@"url : %@", url.description);
        
        BOOL first = NO;
        
        
        @try {
            NSLog(@"break 010-2");
            if ([self.URLCallbacks objectForKey:url] == FALSE )
            {
                NSLog(@"break 011");

                //self.URLCallbacks[url] = [NSMutableArray new];
                [self.URLCallbacks setObject:[NSMutableArray new] forKey:url];
                
                NSLog( @"%@", self.URLCallbacks.description );
                first = YES;
            }
        }
        @catch (NSException * e) {
            NSLog(@"Exception: %@", e);
            NSLog(@"break 011-1");
            self.URLCallbacks[url] = NSMutableArray.new;
            first = YES;
            NSLog(@"break 011-2");
        }
        
        NSLog(@"break 001");
        // Handle single download of simultaneous download request for the same URL
        //arqNSMutableArray *callbacksForURL = self.URLCallbacks[url];
        NSMutableArray *callbacksForURL = [self.URLCallbacks objectForKey:url];
        NSLog(@"break 002");
        NSMutableDictionary *callbacks = NSMutableDictionary.new;
        NSLog(@"break 003");
        //if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
        if (progressBlock) [callbacks setObject:[progressBlock copy] forKey:kProgressCallbackKey];
        NSLog(@"break 004");
        //if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
        if (progressBlock) [callbacks setObject:[completedBlock copy] forKey:kCompletedCallbackKey];
        [callbacksForURL addObject:callbacks];
        //self.URLCallbacks[url] = callbacksForURL;
        [self.URLCallbacks setObject:callbacksForURL forKey:url];
        
        if (first)
        {
            createCallback();
        }
        
        NSLog(@"break 004-1");
        NSLog( @"%@", self.URLCallbacks.description );
    });
}

- (NSArray *)callbacksForURL:(NSURL *)url
{
    __block NSArray *callbacksForURL;
    dispatch_sync(self.barrierQueue, ^
    {
        //callbacksForURL = self.URLCallbacks[url];
        callbacksForURL = [self.URLCallbacks objectForKey:url];
    });
    return callbacksForURL;
}

- (void)removeCallbacksForURL:(NSURL *)url
{
    dispatch_barrier_async(self.barrierQueue, ^
    {
        [self.URLCallbacks removeObjectForKey:url];
    });
}

@end
