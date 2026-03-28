//
//  applist.c
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

#import "idevice.h"
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#import "applist.h"
#import "JITEnableContext.h"
#import "JITEnableContextInternal.h"

NSError* makeError(int code, NSString* msg);

bool installApp(AdapterHandle* adapter, RsdHandshakeHandle* handshake, NSString* packagePath, NSError** error) {
    InstallationProxyClientHandle *instProxyHandle = NULL;
    IdeviceFfiError * err = installation_proxy_connect_rsd(adapter, handshake, &instProxyHandle);
    
    if (err) {
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        return false;
    }
    
    err = installation_proxy_install(instProxyHandle, [packagePath UTF8String], nil);
    if (err) {
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        installation_proxy_client_free(instProxyHandle);
        return false;
    }
    
    return true;
}

bool uninstallApp(AdapterHandle* adapter, RsdHandshakeHandle* handshake, NSString* bundleId, NSError** error) {
    InstallationProxyClientHandle *instProxyHandle = NULL;
    IdeviceFfiError * err = installation_proxy_connect_rsd(adapter, handshake, &instProxyHandle);
    
    if (err) {
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        return false;
    }
    
    err = installation_proxy_uninstall(instProxyHandle, [bundleId UTF8String], nil);
    if (err) {
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        installation_proxy_client_free(instProxyHandle);
        return false;
    }
    
    return true;
}


@implementation JITEnableContext(App)
- (BOOL)installAppWithPackagePath:(NSString*)packagePath error:(NSError **)error {
    [self ensureTunnelWithError:error];
    if(*error) {
        return NO;
    }
    
    return installApp(adapter, handshake, packagePath, error);
}

- (BOOL)uninstallAppWithBundleID:(NSString*)bundleId error:(NSError **)error {
    [self ensureTunnelWithError:error];
    if(*error) {
        return NO;
    }
    
    return uninstallApp(adapter, handshake, bundleId, error);
}

@end
