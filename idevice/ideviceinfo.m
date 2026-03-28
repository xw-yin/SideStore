//
//  ideviceinfo.c
//  StikDebug
//
//  Created by Stephen on 8/2/25.
//

#include <stdlib.h>
#include <arpa/inet.h>
#include "ideviceinfo.h"
#include "idevice.h"
#import "JITEnableContext.h"
#import "JITEnableContextInternal.h"
@import Foundation;

NSError* makeError(int code, NSString* msg);


NSObject* ideviceinfo_c_get_xml(AdapterHandle* adapter, RsdHandshakeHandle* handshake, NSString* key, NSError** error) {
    LockdowndClientHandle *g_client = NULL;
    IdeviceFfiError *err = lockdownd_connect_rsd(adapter, handshake, &g_client);
    if (err) {
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        return NULL;
    }

    void *plist_obj = NULL;
    err = lockdownd_get_value(g_client, [key UTF8String], NULL, &plist_obj);
    if (err) {
        lockdownd_client_free(g_client);
        *error = makeError(err->code, @(err->message));
        idevice_error_free(err);
        return NULL;
    }

    char *plistBin = NULL;
    uint32_t xml_len = 0;
    if (plist_to_bin(plist_obj, &plistBin, &xml_len) != 0 || !plistBin) {
        lockdownd_client_free(g_client);
        plist_free(plist_obj);
        return NULL;
    }
    NSDictionary* ans = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:plistBin length:xml_len] options:0 format:0 error:nil];
    lockdownd_client_free(g_client);
    plist_free(plist_obj);
    return ans;
}

@implementation JITEnableContext(DeviceInfo)

- (NSObject*)ideviceInfoGetXMLWithKey:(NSString*)key error:(NSError**)error {
    [self ensureTunnelWithError:error];
    if (*error) { return NULL; }
    return ideviceinfo_c_get_xml(adapter, handshake, key, error);
}
@end
