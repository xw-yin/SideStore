//
//  afc.m
//  AltStore
//
//  Created by s s on 2026/3/28.
//
#include "idevice.h"
#import "JITEnableContext.h"
#import "JITEnableContextInternal.h"
#import <Foundation/Foundation.h>

static const size_t kAfcChunkSize = 10 * 1024 * 1024; // 10 MiB chunks as required

@implementation JITEnableContext(AFC)

- (BOOL)sendData:(NSData*)data
	toDevicePath:(NSString*)devicePath
	   progress:(AfcProgressCallback)progress
		 error:(NSError**)error {
	[self ensureTunnelWithError:error];
	if (error && *error) { return NO; }

	if (!data) {
		if (error) { *error = [self errorWithStr:@"Data must not be nil" code:-2]; }
		return NO;
	}

	uint64_t totalBytes = (uint64_t)data.length;
	uint64_t sentBytes = 0;

	AfcClientHandle *client = NULL;
	AfcFileHandle *fileHandle = NULL;
	IdeviceFfiError *ffiErr = afc_client_connect_rsd(adapter, handshake, &client);
	if (ffiErr) {
		if (error) { *error = [self errorWithStr:@(ffiErr->message ?: "Failed to connect to AFC") code:ffiErr->code]; }
		idevice_error_free(ffiErr);
		return NO;
	}

	NSString *parent = [devicePath stringByDeletingLastPathComponent];
	if (parent.length > 0 && ![parent isEqualToString:@"/"] && ![parent isEqualToString:@"."]) {
		IdeviceFfiError *dirErr = afc_make_directory(client, parent.UTF8String);
		if (dirErr) { idevice_error_free(dirErr); }
	}

	ffiErr = afc_file_open(client, devicePath.UTF8String, AfcWr, &fileHandle);
	if (ffiErr) {
		if (error) { *error = [self errorWithStr:@(ffiErr->message ?: "Failed to open remote file") code:ffiErr->code]; }
		idevice_error_free(ffiErr);
		afc_client_free(client);
		return NO;
	}

	BOOL success = NO;
	const uint8_t *bytes = data.bytes;
	while (sentBytes < totalBytes) {
		size_t chunkLength = (size_t)MIN((uint64_t)kAfcChunkSize, totalBytes - sentBytes);
		ffiErr = afc_file_write(fileHandle, bytes + sentBytes, chunkLength);
		if (ffiErr) {
			if (error) { *error = [self errorWithStr:@(ffiErr->message ?: "Failed to write to device") code:ffiErr->code]; }
			idevice_error_free(ffiErr);
			break;
		}

		sentBytes += (uint64_t)chunkLength;
		if (progress) { progress(sentBytes, totalBytes); }
	}

	if (totalBytes == 0) {
		success = YES;
	} else if (sentBytes == totalBytes) {
		success = YES;
	}

	if (progress && success && sentBytes < totalBytes) { progress(totalBytes, totalBytes); }

	afc_file_close(fileHandle);
	afc_client_free(client);
	return success;
}

@end

