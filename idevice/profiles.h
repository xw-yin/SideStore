//
//  profiles.h
//  StikDebug
//
//  Created by s s on 2025/11/29.
//

#ifndef PROFILES_H
#define PROFILES_H
#include "idevice.h"
#include <Foundation/Foundation.h>
NSArray<NSData*>* _Nullable fetchAppProfiles(AdapterHandle* _Nonnull adapter, RsdHandshakeHandle* _Nonnull handshake, NSError* _Nullable * _Nullable error);
bool removeProfile(AdapterHandle* _Nonnull adapter, RsdHandshakeHandle* _Nonnull handshake, NSString* _Nonnull uuid, NSError* _Nullable * _Nullable error);
bool addProfile(AdapterHandle* _Nonnull adapter, RsdHandshakeHandle* _Nonnull handshake, NSData* _Nonnull profile, NSError* _Nullable * _Nullable error);

#endif
