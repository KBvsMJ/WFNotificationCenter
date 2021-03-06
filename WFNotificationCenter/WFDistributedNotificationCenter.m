//
//  WFDistributedNotificationCenter.m
//  WFNotificationCenter
//
//  Created by Conrad Kramer on 3/5/15.
//  Copyright (c) 2015 DeskConnect, Inc. All rights reserved.
//

#import "WFDistributedNotificationCenter.h"

#pragma mark - Serialization

static NSString * const WFNotificationArchiveNameKey = @"WFNotificationName";
static NSString * const WFNotificationArchiveObjectKey = @"WFNotificationObject";
static NSString * const WFNotificationArchiveUserInfoKey = @"WFNotificationUserInfo";

static NSData *WFArchivedDataFromNotification(NSNotification *notification) {
    NSCAssert(notification.object == nil || [notification.object isKindOfClass:[NSString class]], @"Notification object must be of class NSString");
    NSMutableData *data = [NSMutableData new];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    [archiver setOutputFormat:NSPropertyListBinaryFormat_v1_0];
    [archiver setRequiresSecureCoding:YES];
    [archiver encodeObject:notification.name forKey:WFNotificationArchiveNameKey];
    [archiver encodeObject:notification.object forKey:WFNotificationArchiveObjectKey];
    [archiver encodeObject:notification.userInfo forKey:WFNotificationArchiveUserInfoKey];
    [archiver finishEncoding];
    return [data copy];
}

static NSNotification *WFNotificationFromArchivedData(NSData *data, NSSet *allowedClasses) {
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
    [unarchiver setRequiresSecureCoding:YES];
    NSString *name = [unarchiver decodeObjectOfClass:[NSString class] forKey:WFNotificationArchiveNameKey];
    NSString *object = [unarchiver decodeObjectOfClass:[NSString class] forKey:WFNotificationArchiveObjectKey];
    NSDictionary *userInfo = nil;
    if (allowedClasses) {
        @try {
            userInfo = [unarchiver decodeObjectOfClasses:[allowedClasses setByAddingObject:[NSDictionary class]] forKey:WFNotificationArchiveUserInfoKey];
        }
        @catch (NSException *exception) {
            if ([exception.name isEqualToString:NSInvalidUnarchiveOperationException]) {
                NSLog(@"%@: Error: invalid set of allowed classes for \"%@\", dropping userInfo dictionary", NSStringFromClass([WFDistributedNotificationCenter class]), name);
            } else {
                @throw;
            }
        }
    }
    return [NSNotification notificationWithName:name object:object userInfo:userInfo];
}

#pragma mark - Server Callback

@interface WFDistributedNotificationCenter ()
- (void)receivedData:(NSData *)data withMessageId:(SInt32)messageId fromPort:(CFMessagePortRef)port;
@end

CFDataRef WFNotificationServerCallback(CFMessagePortRef local, SInt32 msgid, CFDataRef dataRef, void *info) {
    NSData *data = (dataRef ? [NSData dataWithBytes:CFDataGetBytePtr(dataRef) length:CFDataGetLength(dataRef)] : nil);
    for (WFDistributedNotificationCenter *center in (__bridge NSHashTable *)info)
        [center receivedData:data withMessageId:msgid fromPort:local];
    return NULL;
}

#pragma mark - Block Observer

@interface WFDNCBlockObserver : NSObject

@end

@implementation WFDNCBlockObserver {
    NSOperationQueue *_queue;
    void (^_block)(NSNotification *);
}

- (instancetype)initWithBlock:(void (^)(NSNotification *))block queue:(NSOperationQueue *)queue {
    NSParameterAssert(block);
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _block = [block copy];
    _queue = queue;
    
    return self;
}

- (void)send:(NSNotification *)notification {
    if (_queue) {
        [_queue addOperationWithBlock:^{
            _block(notification);
        }];
    } else {
        _block(notification);
    }
}

@end

static SInt32 const WFDistributedNotificationPostMessageId = 1;
static NSString * const WFDistributedNotificationCatchAllKey = @"*";

@implementation WFDistributedNotificationCenter {
    NSURL *_registryURL;
    NSFileHandle *_registryHandle;
    NSString *_serverName;
    
    NSMutableDictionary *_observers;
    NSMutableSet *_blockObservers;
    
    CFMessagePortRef _server;
}

#pragma mark - Threading

+ (dispatch_queue_t)receiveNotificationQueue {
    static dispatch_queue_t receiveNotificationQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        receiveNotificationQueue = dispatch_queue_create("com.deskconnect.WFDistributedNotificationCenter.receive", DISPATCH_QUEUE_SERIAL);
    });
    return receiveNotificationQueue;
}

+ (void)postNotificationThreadEntryPoint:(id)__unused object {
    @autoreleasepool {
        [[NSThread currentThread] setName:NSStringFromClass(self)];
        
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [runLoop run];
    }
}

+ (NSThread *)postNotificationThread {
    static NSThread *postNotificationThread = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        postNotificationThread = [[NSThread alloc] initWithTarget:self selector:@selector(postNotificationThreadEntryPoint:) object:nil];
        [postNotificationThread start];
    });
    
    return postNotificationThread;
}

#pragma mark - Lifecycle

+ (NSHashTable *)activeCentersForServerName:(NSString *)serverName {
    static NSMutableDictionary *activeCentersByServerName = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activeCentersByServerName = [NSMutableDictionary new];
    });
    NSHashTable *activeCenters = ([activeCentersByServerName objectForKey:serverName] ?: [NSHashTable weakObjectsHashTable]);
    [activeCentersByServerName setObject:activeCenters forKey:serverName];
    return activeCenters;
}

- (instancetype)init {
    return [self initWithSecurityApplicationGroupIdentifier:nil];
}

- (instancetype)initWithSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSParameterAssert(groupIdentifier.length);
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _registryURL = [[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupIdentifier] URLByAppendingPathComponent:@".WFDNCRegistry"];
    if (!_registryURL) {
        NSLog(@"%@: Warning: Could not get container URL for group identifier \"%@\", falling back to temporary directory.", self, groupIdentifier);
        _registryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@".WFDNCRegistry"];
    }
    _serverName = [groupIdentifier stringByAppendingFormat:@".wfdnc.%i", getpid()];
    _observers = [NSMutableDictionary new];
    _blockObservers = [NSMutableSet new];
    
    int registryFd;
    if ((registryFd = open([_registryURL.path UTF8String], O_RDWR | O_CREAT, 0644)) == -1) {
        NSLog(@"%@: Error: Could not open registry file at path \"%@\": %@", self, _registryURL.path, [[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil] localizedFailureReason]);
        return nil;
    }
    
    _registryHandle = [[NSFileHandle alloc] initWithFileDescriptor:registryFd closeOnDealloc:YES];
    
    return self;
}

- (void)dealloc {
    if (_server) {
        if (![[WFDistributedNotificationCenter activeCentersForServerName:_serverName] anyObject])
            CFMessagePortInvalidate(_server);
        CFRelease(_server);
    }
}

#pragma mark - Port Registry

- (NSDictionary *)portRegistry {
    if (flock(_registryHandle.fileDescriptor, LOCK_SH) == -1) {
        NSLog(@"%@: Error: Failed to acquire registry lock: %@", self, [[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil] localizedFailureReason]);
        return nil;
    }
    
    [_registryHandle seekToFileOffset:0];
    NSDictionary *portRegistry = [NSPropertyListSerialization propertyListWithData:[_registryHandle readDataToEndOfFile] options:0 format:NULL error:nil];
    flock(_registryHandle.fileDescriptor, LOCK_UN);
    return portRegistry;
}

- (void)removePortsFromRegistry:(NSSet *)portNames forNotificationName:(NSString *)aName object:(NSString *)anObject {
    if (flock(_registryHandle.fileDescriptor, LOCK_EX) == -1) {
        NSLog(@"%@: Error: Failed to acquire registry lock: %@", self, [[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil] localizedFailureReason]);
        return;
    }
    
    [_registryHandle seekToFileOffset:0];
    NSMutableDictionary *portRegistry = [NSPropertyListSerialization propertyListWithData:[_registryHandle readDataToEndOfFile] options:NSPropertyListMutableContainers format:NULL error:nil];
    for (NSString *observerName in [portRegistry allKeys]) {
        if (!aName || [observerName isEqualToString:aName]) {
            NSMutableDictionary *portsByObject = [portRegistry objectForKey:observerName];
            for (NSString *observerObject in [portsByObject allKeys]) {
                NSMutableSet *ports = [portsByObject objectForKey:observerObject];
                if (!anObject || [observerObject isEqualToString:anObject]) {
                    for (NSString *portName in portNames)
                        [ports removeObject:portName];
                }
                if (!ports.count)
                    [portsByObject removeObjectForKey:observerObject];
            }
            if (!portsByObject.count)
                [portRegistry removeObjectForKey:observerName];
        }
    }
    
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:portRegistry format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [_registryHandle truncateFileAtOffset:data.length];
    [_registryHandle seekToFileOffset:0];
    [_registryHandle writeData:data];
    flock(_registryHandle.fileDescriptor, LOCK_UN);
}

- (void)addPortsToRegistry:(NSSet *)portNames forNotificationName:(NSString *)aName object:(NSString *)anObject {
    if (flock(_registryHandle.fileDescriptor, LOCK_EX) == -1) {
        NSLog(@"%@: Error: Failed to acquire registry lock: %@", self, [[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil] localizedFailureReason]);
        return;
    }
    
    [_registryHandle seekToFileOffset:0];
    NSMutableDictionary *portRegistry = ([NSPropertyListSerialization propertyListWithData:[_registryHandle readDataToEndOfFile] options:NSPropertyListMutableContainers format:NULL error:nil] ?: [NSMutableDictionary new]);
    NSMutableDictionary *portsByObject = ([portRegistry objectForKey:(aName ?: WFDistributedNotificationCatchAllKey)] ?: [NSMutableDictionary new]);
    NSMutableSet *ports = ([NSMutableSet setWithArray:[portsByObject objectForKey:(anObject ?: WFDistributedNotificationCatchAllKey)]] ?: [NSMutableSet new]);
    [ports addObject:_serverName];
    [portsByObject setObject:[ports allObjects] forKey:(anObject ?: WFDistributedNotificationCatchAllKey)];
    [portRegistry setObject:portsByObject forKey:(aName ?: WFDistributedNotificationCatchAllKey)];
    
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:portRegistry format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [_registryHandle truncateFileAtOffset:data.length];
    [_registryHandle seekToFileOffset:0];
    [_registryHandle writeData:data];
    flock(_registryHandle.fileDescriptor, LOCK_UN);
}

#pragma mark - Registration

- (void)removeObserver:(id)observer {
    [self removeObserver:observer name:nil object:nil];
}

- (void)removeObserver:(id)observer name:(NSString *)aName object:(NSString *)anObject {
    if (!observer)
        return;
    
    if ([_blockObservers containsObject:observer]) {
        aName = nil;
        anObject = nil;
        [_blockObservers removeObject:observer];
    }
    
    for (NSString *notificationName in [_observers allKeys]) {
        NSMutableDictionary *targetsByObject = [_observers objectForKey:notificationName];
        if (!aName || [notificationName isEqualToString:aName]) {
            for (NSString *notificationObject in [targetsByObject allKeys]) {
                NSMapTable *selectorsByTarget = [targetsByObject objectForKey:notificationObject];
                if (!anObject || [anObject isEqualToString:notificationObject]) {
                    [selectorsByTarget removeObjectForKey:observer];
                }
                if (!selectorsByTarget.count) {
                    [targetsByObject removeObjectForKey:notificationObject];
                }
            }
        }
        if (!targetsByObject.count) {
            [_observers removeObjectForKey:notificationName];
        }
    }
    
    if (!_observers.count && _server) {
        NSHashTable *activeCenters = [WFDistributedNotificationCenter activeCentersForServerName:_serverName];
        if ([activeCenters containsObject:self] && activeCenters.count == 1) {
            CFMessagePortInvalidate(_server);
            [self removePortsFromRegistry:[NSSet setWithObject:_serverName] forNotificationName:nil object:nil];
        }
        CFRelease(_server);
        _server = NULL;
        [activeCenters removeObject:self];
    }
}

- (void)addObserver:(id)observer selector:(SEL)aSelector name:(NSString *)aName object:(NSString *)anObject {
    [self addObserver:observer selector:aSelector name:aName object:anObject allowedClasses:nil];
}

- (void)addObserver:(id)observer selector:(SEL)aSelector name:(NSString *)aName object:(NSString *)anObject allowedClasses:(NSSet *)allowedClasses {
    NSParameterAssert(observer);
    NSParameterAssert(aSelector);
    
    if (!allowedClasses.count) {
        allowedClasses = [NSSet setWithObjects:[NSArray class], [NSDictionary class], [NSString class], [NSData class], [NSDate class], [NSNumber class], nil];
    }
    
    NSMutableDictionary *targetsByObject = ([_observers objectForKey:(aName ?: WFDistributedNotificationCatchAllKey)] ?: [NSMutableDictionary new]);
    NSMapTable *selectorsByTarget = ([targetsByObject objectForKey:(anObject ?: WFDistributedNotificationCatchAllKey)] ?: [NSMapTable weakToStrongObjectsMapTable]);
    NSMutableSet *selectors = ([selectorsByTarget objectForKey:observer] ?: [NSMutableSet new]);
    [selectors addObject:@[NSStringFromSelector(aSelector), allowedClasses]];
    [selectorsByTarget setObject:selectors forKey:observer];
    [targetsByObject setObject:selectorsByTarget forKey:(anObject ?: WFDistributedNotificationCatchAllKey)];
    [_observers setObject:targetsByObject forKey:(aName ?: WFDistributedNotificationCatchAllKey)];
    
    if (!_server) {
        NSHashTable *activeCenters = [WFDistributedNotificationCenter activeCentersForServerName:_serverName];
        [activeCenters addObject:self];
        CFMessagePortContext context = {0, (__bridge void *)activeCenters, NULL, NULL, NULL};
        _server = CFMessagePortCreateLocal(NULL, (__bridge CFStringRef)_serverName, &WFNotificationServerCallback, &context, NULL);
        NSAssert(_server != NULL, @"%@: Error: The notification server could not be established, is the app group identifier set correctly?", self);
        CFMessagePortSetDispatchQueue(_server, [WFDistributedNotificationCenter receiveNotificationQueue]);
    }
    
    [self addPortsToRegistry:[NSSet setWithObject:_serverName] forNotificationName:aName object:anObject];
}

- (id<NSObject>)addObserverForName:(NSString *)name object:(id)obj queue:(NSOperationQueue *)queue usingBlock:(void (^)(NSNotification *note))block {
    return [self addObserverForName:name object:obj allowedClasses:nil queue:queue usingBlock:block];
}

- (id<NSObject>)addObserverForName:(NSString *)name object:(id)obj allowedClasses:(NSSet *)allowedClasses queue:(NSOperationQueue *)queue usingBlock:(void (^)(NSNotification *note))block {
    NSParameterAssert(block);
    WFDNCBlockObserver *observer = [[WFDNCBlockObserver alloc] initWithBlock:block queue:queue];
    [_blockObservers addObject:observer];
    [self addObserver:observer selector:@selector(send:) name:name object:obj allowedClasses:allowedClasses];
    return observer;
}

#pragma mark - Posting

- (void)postNotificationName:(NSString *)aName object:(NSString *)anObject {
    [self postNotification:[NSNotification notificationWithName:aName object:anObject]];
}

- (void)postNotificationName:(NSString *)aName object:(NSString *)anObject userInfo:(NSDictionary *)aUserInfo {
    [self postNotification:[NSNotification notificationWithName:aName object:anObject userInfo:aUserInfo]];
}

- (void)postNotification:(NSNotification *)notification {
    NSParameterAssert(notification);
    NSAssert(notification.object == nil || [notification.object isKindOfClass:[NSString class]], @"%@: Notification object must be of class NSString", self);
    NSData *data = WFArchivedDataFromNotification(notification);
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(distributeNotification:data:)]];
    [invocation setSelector:@selector(distributeNotification:data:)];
    [invocation setArgument:&notification atIndex:2];
    [invocation setArgument:&data atIndex:3];
    [invocation retainArguments];
    [invocation performSelector:@selector(invokeWithTarget:) onThread:[WFDistributedNotificationCenter postNotificationThread] withObject:self waitUntilDone:NO];
}

- (void)distributeNotification:(NSNotification *)notification data:(NSData *)data {
    NSMutableSet *portNames = [NSMutableSet new];
    NSDictionary *portRegistry = self.portRegistry;
    for (NSString *portNotificationName in portRegistry) {
        if ([portNotificationName isEqualToString:notification.name] || [portNotificationName isEqualToString:WFDistributedNotificationCatchAllKey]) {
            NSDictionary *portsByObject = [portRegistry objectForKey:portNotificationName];
            for (NSString *portObject in portsByObject) {
                if ([portObject isEqualToString:notification.object] || [portObject isEqualToString:WFDistributedNotificationCatchAllKey]) {
                    [portNames addObjectsFromArray:[portsByObject objectForKey:portObject]];
                }
            }
        }
    }
    
    if (!portNames.count)
        return;
    
    NSMutableSet *invalidPortNames = [NSMutableSet new];
    
    for (NSString *portName in portNames) {
        CFMessagePortRef port = CFMessagePortCreateRemote(NULL, (__bridge CFStringRef)portName);
        if (!port || !CFMessagePortIsValid(port)) {
            [invalidPortNames addObject:portName];
            if (port)
                CFRelease(port);
            continue;
        }
        
        SInt32 status = CFMessagePortSendRequest(port, WFDistributedNotificationPostMessageId, (__bridge CFDataRef)data, 1000, 0, NULL, NULL);
        if (status != kCFMessagePortSuccess) {
            NSLog(@"%@: Error: could not post notification to port \"%@\" with error code %i", self, portName, (int)status);
        }
        
        CFMessagePortInvalidate(port);
        CFRelease(port);
    }
    
    [self removePortsFromRegistry:invalidPortNames forNotificationName:nil object:nil];
}

#pragma mark - Receiving

- (void)receivedData:(NSData *)data withMessageId:(SInt32)messageId fromPort:(CFMessagePortRef)port {
    if (messageId == WFDistributedNotificationPostMessageId) {
        [self receivedNotificationData:data];
    }
}

- (void)receivedNotificationData:(NSData *)data {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSNotification *notification = WFNotificationFromArchivedData(data, nil);
    for (NSString *observerNotificationName in _observers) {
        if ([observerNotificationName isEqualToString:notification.name] || [observerNotificationName isEqualToString:WFDistributedNotificationCatchAllKey]) {
            NSMutableDictionary *observerTargetsByObject = [_observers objectForKey:observerNotificationName];
            for (NSString *observerObject in observerTargetsByObject) {
                if ([notification.object isEqualToString:observerObject] || [observerObject isEqualToString:WFDistributedNotificationCatchAllKey]) {
                    NSMapTable *selectorsByTarget = [observerTargetsByObject objectForKey:observerObject];
                    for (id target in selectorsByTarget) {
                        for (NSArray *selectorPair in [selectorsByTarget objectForKey:target]) {
                            notification = WFNotificationFromArchivedData(data, [selectorPair objectAtIndex:1]);
                            [target performSelector:NSSelectorFromString([selectorPair objectAtIndex:0]) withObject:notification];
                        }
                    }
                }
            }
        }
    }
#pragma clang diagnostic pop
}

@end
