#import "TMPettyCache.h"

#define TMPettyCacheError(error) if (error) { NSLog(@"%@ (%d) ERROR: %@", \
            [[NSString stringWithUTF8String:__FILE__] lastPathComponent], \
            __LINE__, [error localizedDescription]); }

NSString * const TMPettyCacheDirectory = @"TMPettyCacheDirectory";
NSString * const TMPettyCacheSharedName = @"TMPettyCacheShared";
NSUInteger const TMPettyCacheDefaultMemoryLimit = 0xA00000; // 10 MB

@interface TMPettyCache ()
#if OS_OBJECT_USE_OBJC
@property (strong) dispatch_queue_t queue;
#else
@property (assign) dispatch_queue_t queue;
#endif
@property (copy) NSString *name;
@property (strong) NSMutableDictionary *dataKeys;
@property (strong) NSCache *cache;
@property (strong) NSString *cachePath;
@property (assign) NSUInteger currentMemoryBytes;
@property (assign) NSUInteger currentMemoryCount;
@property (assign) NSUInteger currentDiskBytes;
@property (assign) NSUInteger currentDiskCount;
@end

@implementation TMPettyCache

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    self.cache.delegate = nil;

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(_queue);
    _queue = NULL;
    #endif
}

- (instancetype)initWithName:(NSString *)name
{
    if (![name length])
        return nil;

    if (self = [super init]) {
        self.name = name;
        
        self.cache = [[NSCache alloc] init];
        self.cache.name = [[NSString alloc] initWithFormat:@"%@.%@.%p", NSStringFromClass([self class]), self.name, self];
        self.cache.delegate = self;
        
        self.queue = dispatch_queue_create([self.cache.name UTF8String], DISPATCH_QUEUE_SERIAL);
        self.dataKeys = [[NSMutableDictionary alloc] init];

        self.memoryCacheByteLimit = TMPettyCacheDefaultMemoryLimit;
        self.memoryCacheCountLimit = 0;
        self.willEvictDataFromMemoryBlock = nil;
        
        #warning make this do something
        self.diskCacheByteLimit = 0;
        #warning make this do something
        self.diskCacheMaxAge = 0.0;
        
        self.willEvictDataFromDiskBlock = nil;
        
        self.currentMemoryBytes = 0;
        self.currentMemoryCount = 0;

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *dirPath = [[paths objectAtIndex:0] stringByAppendingPathComponent:TMPettyCacheDirectory];
        self.cachePath = [dirPath stringByAppendingPathComponent:self.name];
        
        [self createCacheDirectory];
        [self updateDiskBytesAndCount];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:[UIApplication sharedApplication]];
    }

    return self;
}

+ (instancetype)withName:(NSString *)name
{
    return [[TMPettyCache alloc] initWithName:name];
}

+ (instancetype)sharedCache
{
    static TMPettyCache *cache = nil;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        cache = [[self alloc] initWithName:TMPettyCacheSharedName];
    });

    return cache;
}

#pragma mark - Private Methods

- (void)didReceiveMemoryWarning:(NSNotification *)notification
{
    [self clearMemoryCache];
}

- (NSURL *)fileURLForKey:(NSString *)key
{
    if (![self.cachePath length] || ![key length])
        return nil;

    return [NSURL fileURLWithPath:[self.cachePath stringByAppendingPathComponent:key]];
}

#pragma mark - <NSCacheDelegate>

- (void)cache:(NSCache *)cache willEvictObject:(id)object
{
    __weak __typeof(self) weakSelf = self;

    void (^evictionBlock)() = ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSData *data = (NSData *)object;
        NSUInteger dataLength = [data length];
        NSValue *dataValue = [NSValue valueWithNonretainedObject:data];
        NSString *key = [strongSelf.dataKeys objectForKey:dataValue];
        NSURL *fileURL = [strongSelf fileURLForKey:key];
        BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]];

        if (strongSelf.willEvictDataFromMemoryBlock)
            strongSelf.willEvictDataFromMemoryBlock(self, key, data, fileExists ? fileURL : nil);

        strongSelf.currentMemoryBytes -= dataLength;
        strongSelf.currentMemoryCount -= 1;

        [strongSelf.dataKeys removeObjectForKey:dataValue];
    };

    /**
     When `TMPettyCache` is performing the eviction (via `removeDataForKey`, `clearMemoryCache`,
     or `clearAllCachesSynchronously`) this method will always be called on `self.queue`.
     
     When the system does evictions (e.g. when the app goes to background) this method will be
     called on the main thread and should be sync'd with `self.queue` for seriality.
     */

    if ([NSThread isMainThread]) {
        dispatch_sync(self.queue, evictionBlock);
    } else {
        evictionBlock();
    }
}

#pragma mark - Private Queue Methods 

- (NSDictionary *)cacheFilePathsWithAttributes
{
    /// @warning Should only be called internally on `self.queue` or `init`
    
    NSError *error = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.cachePath error:&error];
    TMPettyCacheError(error);
    
    if (![contents count])
        return nil;
    
    NSMutableDictionary *filePathsWithAttributes = [[NSMutableDictionary alloc] initWithCapacity:[contents count]];
    
    for (NSString *fileName in contents) {
        NSString *filePath = [self.cachePath stringByAppendingPathComponent:fileName];
        
        error = nil;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
        TMPettyCacheError(error);
        
        if (!attributes)
            continue;
        
        [filePathsWithAttributes setObject:attributes forKey:filePath];
    }
    
    return [[NSDictionary alloc] initWithDictionary:filePathsWithAttributes];
}

- (void)setDataInMemoryCache:(NSData *)data forKey:(NSString *)key
{
    /// @warning Should only be called internally on `self.queue` or `init`
    
    NSUInteger dataLength = [data length];
    
    [self.dataKeys setObject:key forKey:[NSValue valueWithNonretainedObject:data]];
    [self.cache setObject:data forKey:key cost:dataLength];
    
    self.currentMemoryBytes += dataLength;
    self.currentMemoryCount += 1;
}

- (void)setFileModificationDate:(NSDate *)date fileURL:(NSURL *)url
{
    /// @warning Should only be called internally on `self.queue` or `init`
    
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:NO];
    if (!fileExists)
        return;

    NSError *error = nil;
    [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date }
                                     ofItemAtPath:[url path]
                                            error:&error];
    TMPettyCacheError(error);
}

- (void)createCacheDirectory
{
    /// @warning Should only be called internally on `self.queue` or `init`

    if (![self.cachePath length] || [[NSFileManager defaultManager] fileExistsAtPath:self.cachePath isDirectory:nil])
        return;

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.cachePath withIntermediateDirectories:YES attributes:nil error:&error];
    TMPettyCacheError(error);

    self.currentDiskBytes = 0;
    self.currentDiskCount = 0;
}

- (void)updateDiskBytesAndCount
{
    /// @warning Should only be called internally on `self.queue` or `init`

    NSUInteger diskBytes = 0;

    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:self.cachePath error:&error];
    TMPettyCacheError(error);

    for (NSString *fileName in files) {
        NSString *filePath = [self.cachePath stringByAppendingPathComponent:fileName];

        error = nil;
        NSDictionary *butes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
        TMPettyCacheError(error);

        diskBytes += [butes fileSize];
    }

    self.currentDiskBytes = diskBytes;
    self.currentDiskCount = [files count];
}

- (void)removeFileAtURL:(NSURL *)fileURL
{
    /// @warning Should only be called internally on `self.queue` or `init`

    NSString *filePath = [fileURL path];

    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (self.willEvictDataFromDiskBlock) {
            NSString *key = [filePath lastPathComponent];
            NSURL *url = [NSURL fileURLWithPath:filePath isDirectory:NO];
            self.willEvictDataFromDiskBlock(self, key, nil, url);
        }
        
        NSError *error = nil;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
        TMPettyCacheError(error);

        error = nil;
        BOOL removed = [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error];
        TMPettyCacheError(error);

        if (removed) {
            self.currentDiskBytes -= [attributes fileSize];
            self.currentDiskCount -= 1;
        }
    }
}

#pragma mark - Public Methods

- (void)dataForKey:(NSString *)key block:(TMPettyCacheBlock)block
{
    NSDate *now = [[NSDate alloc] init];

    if (!block || ![key length])
        return;

    __weak __typeof(self) weakSelf = self;
    
    dispatch_async(self.queue, ^{
        __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSData *data = [strongSelf.cache objectForKey:key];
        NSURL *fileURL = [strongSelf fileURLForKey:key];
        
        if (!data && [[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [strongSelf setFileModificationDate:now fileURL:fileURL];

            NSError *error = nil;
            data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:&error];
            TMPettyCacheError(error);
            
            if (data)
                [strongSelf setDataInMemoryCache:data forKey:key];
        }

        block(strongSelf, key, data, fileURL);
    });
}

- (void)fileURLForKey:(NSString *)key block:(TMPettyCacheBlock)block
{
    if (!block || ![key length])
        return;

    __weak __typeof(self) weakSelf = self;

    dispatch_async(self.queue, ^{
        NSURL *fileURL = [weakSelf fileURLForKey:key];
        block(weakSelf, key, nil, [[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]] ? fileURL : nil);
    });
}

- (void)setData:(NSData *)data forKey:(NSString *)key block:(TMPettyCacheBlock)completionBlock
{
    if (![key length])
        return;
    
    if (!data) {
        [self removeDataForKey:key block:nil];
        return;
    }

    __weak __typeof(self) weakSelf = self;
    
    dispatch_async(self.queue, ^{
        __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        [strongSelf setDataInMemoryCache:data forKey:key];
        
        NSURL *fileURL = [strongSelf fileURLForKey:key];
        
        NSError *error = nil;
        BOOL written = [data writeToURL:fileURL options:0 error:&error];
        TMPettyCacheError(error);
        
        if (written) {
            strongSelf.currentDiskBytes += [data length];
            strongSelf.currentDiskCount += 1;
        }
        
        if (completionBlock)
            completionBlock(strongSelf, key, data, fileURL);
    });
}

- (void)removeDataForKey:(NSString *)key block:(TMPettyCacheBlock)completionBlock
{
    if (![key length])
        return;

    __weak __typeof(self) weakSelf = self;

    dispatch_async(self.queue, ^{
        __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSData *data = [strongSelf.cache objectForKey:key];
        NSURL *fileURL = [strongSelf fileURLForKey:key];
        
        if (data)
            [strongSelf.cache removeObjectForKey:key];
        
        [strongSelf removeFileAtURL:fileURL];
        
        if (completionBlock)
            completionBlock(strongSelf, key, nil, fileURL);
    });
}

- (void)clearMemoryCache
{
    __weak __typeof(self) weakSelf = self;

    dispatch_async(self.queue, ^{
        [weakSelf.cache removeAllObjects];
        [weakSelf.dataKeys removeAllObjects];
    });
}

- (void)clearDiskCache
{
    __weak __typeof(self) weakSelf = self;
    
    dispatch_async(self.queue, ^{
        __typeof(weakSelf) strongSelf = weakSelf;

        if (![[NSFileManager defaultManager] fileExistsAtPath:strongSelf.cachePath])
            return;
        
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:strongSelf.cachePath error:&error];
        TMPettyCacheError(error);
        
        [strongSelf createCacheDirectory];
    });
}

- (void)clearAllCachesSynchronously
{
    dispatch_sync(self.queue, ^{
        [self.cache removeAllObjects];
        [self.dataKeys removeAllObjects];

        if ([[NSFileManager defaultManager] fileExistsAtPath:self.cachePath]) {
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtPath:self.cachePath error:&error];
            TMPettyCacheError(error);
        }
        
        [self createCacheDirectory];
    });
}

- (void)trimDiskCacheToSize:(NSUInteger)byteLimit
{
    if (byteLimit <= 0) {
        [self clearDiskCache];
        return;
    }
    
    __weak __typeof(self) weakSelf = self;

    dispatch_async(self.queue, ^{
        __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSDictionary *filePathsWithAttributes = [strongSelf cacheFilePathsWithAttributes];
        if (!filePathsWithAttributes)
            return;

        NSArray *filePathsSortedByDate = [filePathsWithAttributes keysSortedByValueUsingComparator:^(id file0, id file1) {
            return [[file0 fileModificationDate] compare:[file1 fileModificationDate]];
        }];

        for (NSString *filePath in filePathsSortedByDate) {
            [self removeFileAtURL:[NSURL fileURLWithPath:filePath isDirectory:NO]];

            if (self.currentDiskBytes <= byteLimit)
                break;
        }
    });
}

- (void)trimDiskCacheToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self clearDiskCache];
        return;
    }

    __weak __typeof(self) weakSelf = self;

    dispatch_async(self.queue, ^{
        __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSDictionary *filePathsWithAttributes = [strongSelf cacheFilePathsWithAttributes];
        if (!filePathsWithAttributes)
            return;
        
        NSArray *filePathsSortedByDate = [filePathsWithAttributes keysSortedByValueUsingComparator:^(id file0, id file1) {
            return [[file0 fileModificationDate] compare:[file1 fileModificationDate]];
        }];

        for (NSString *filePath in filePathsSortedByDate) {
            NSDictionary *attributes = [filePathsWithAttributes objectForKey:filePath];
            if (!attributes)
                continue;

            if ([[attributes fileModificationDate] compare:trimDate] != NSOrderedDescending) {
                [self removeFileAtURL:[NSURL fileURLWithPath:filePath isDirectory:NO]];
            } else {
                break;
            }
        }
    });
}

#pragma mark - Accessors

- (NSUInteger)memoryCacheByteLimit
{
    __block NSUInteger limit = 0;
    
    dispatch_sync(self.queue, ^{
        limit = self.cache.totalCostLimit;
    });
    
    return limit;
}

- (void)setMemoryCacheByteLimit:(NSUInteger)limit
{
    __weak __typeof(self) weakSelf = self;
    
    dispatch_async(self.queue, ^{
        weakSelf.cache.totalCostLimit = limit;
    });
}

- (NSUInteger)memoryCacheCountLimit
{
    __block NSUInteger limit = 0;
    
    dispatch_sync(self.queue, ^{
        limit = self.cache.countLimit;
    });
    
    return limit;
}

- (void)setMemoryCacheCountLimit:(NSUInteger)limit
{
    __weak __typeof(self) weakSelf = self;
    
    dispatch_async(self.queue, ^{
        weakSelf.cache.countLimit = limit;
    });
}

@end