//
//  JITEnableContext.h
//  StikJIT
//
//  Created by s s on 2025/3/28.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "idevice.h"
#include "jit.h"
#include "mount.h"

typedef void (^LogFuncC)(const char* message, ...);
typedef void (^LogFunc)(NSString *message);
typedef void (^AfcProgressCallback)(uint64_t bytesSent, uint64_t totalBytes);

@interface JITEnableContext : NSObject {
    // tunnel
    @protected AdapterHandle *adapter;
    @protected RsdHandshakeHandle *handshake;

    // ideviceInfo
    @protected LockdowndClientHandle *   g_client;
}
@property (class, readonly)JITEnableContext* shared;
- (void)initLoggerWithLogPath:(NSString*)logPath loggingEnabled:(bool)loggingEnabled;
- (RpPairingFileHandle*)getPairingFileWithError:(NSError**)error;
- (BOOL)ensureTunnelWithError:(NSError**)err;
- (BOOL)startTunnel:(NSError**)err;

@end

@interface JITEnableContext(JIT)
- (BOOL)debugAppWithBundleID:(NSString*)bundleID logger:(LogFunc)logger jsCallback:(DebugAppCallback)jsCallback;
- (BOOL)debugAppWithPID:(int)pid logger:(LogFunc)logger jsCallback:(DebugAppCallback)jsCallback;
- (BOOL)launchAppWithoutDebug:(NSString*)bundleID logger:(LogFunc)logger;
@end

@interface JITEnableContext(DDI)
- (NSUInteger)getMountedDeviceCount:(NSError**)error __attribute__((swift_error(zero_result)));
- (NSInteger)mountPersonalDDIWithImagePath:(NSString*)imagePath trustcachePath:(NSString*)trustcachePath manifestPath:(NSString*)manifestPath error:(NSError**)error __attribute__((swift_error(nonzero_result)));
@end

@interface JITEnableContext(Profile)
- (NSArray<NSData*>*)fetchAllProfiles:(NSError **)error;
- (BOOL)removeProfileWithUUID:(NSString*)uuid error:(NSError **)error;
- (BOOL)addProfile:(NSData*)profile error:(NSError **)error;
@end

@interface JITEnableContext(App)
- (BOOL)installAppWithPackagePath:(NSString*)packagePath error:(NSError **)error;
- (BOOL)uninstallAppWithBundleID:(NSString*)bundleId error:(NSError **)error;
@end

@interface JITEnableContext(DeviceInfo)
- (NSObject*)ideviceInfoGetXMLWithKey:(NSString*)key error:(NSError**)error;
@end

@interface JITEnableContext(AFC)

- (BOOL)sendData:(NSData*)data
        toDevicePath:(NSString*)devicePath
             progress:(AfcProgressCallback)progress
                 error:(NSError**)error;

@end
