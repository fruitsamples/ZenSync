/*
 IMPORTANT: This Apple software is supplied to you by Apple Computer,
 Inc. ("Apple") in consideration of your agreement to the following terms,
 and your use, installation, modification or redistribution of this Apple
 software constitutes acceptance of these terms.  If you do not agree with
 these terms, please do not use, install, modify or redistribute this Apple
 software.
 
 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following text
 and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Computer,
 Inc. may be used to endorse or promote products derived from the Apple
 Software without specific prior written permission from Apple. Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES
 NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE
 IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A
 PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION
 ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR
 CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND
 WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT
 LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY
 OF SUCH DAMAGE.
 */
//
//  ZenCustomSyncClient.m
//  ZenSync
//
//  Copyright (c) 2004 Apple Computer, Inc. All rights reserved.
//

#import "ZenCustomSyncClient.h"
#import "strings.h"
#import "ZenSchemaStrings.h"
#import <SyncServices/SyncServices.h>

@interface ZenCustomSyncClient (PrivateMethods)

- (ISyncClient *)registerClient;
- (ISyncSession *)initializeSession:(ISyncClient *)syncClient;
- (void)pushDataForSession:(ISyncSession *)syncSession withClient:(ISyncClient *)syncClient;
- (BOOL)pullDataForSession:(ISyncSession *)syncSession withClient:(ISyncClient *)syncClient;
- (void)applyChanges;

@end

@implementation ZenCustomSyncClient

- (id)initWithFile:(NSString *)fileLoc isRefresh:(BOOL)isRefresh {
	self = [super init];
	if (!self)
		return nil;
	
	_fileLoc = [fileLoc retain];
	_records = [[NSMutableDictionary alloc] init];
	_changes = NULL;
	_fields = [[NSArray alloc] initWithObjects:@"RecordId", 
		ISyncAttribute_Com_MyCompany_SyncExamples_Zensync_Customentity_Name,
		ISyncAttribute_Com_MyCompany_SyncExamples_Zensync_Customentity_Team,
		ISyncAttribute_Com_MyCompany_SyncExamples_Zensync_Customentity_Time1,
		ISyncAttribute_Com_MyCompany_SyncExamples_Zensync_Customentity_Time2,
		nil];
	_lastSyncNumber = -1;
	_highestLocalId = 0;

	_isRefresh = isRefresh;
	if (_isRefresh || [self _readDataFromFile]) {
		// If there's a failure here, we're missing one of the pieces copied during build time
		// We'll warn about missing pieces as we notice their absence
		if (_plistLoc = [self createCustomPlist:
			[DEFAULT_CUSTOM_CLIENT_PLIST stringByExpandingTildeInPath]])
			return self;
	} else {
		NSLog(@"There was an error parsing the file at %@", fileLoc);
	}

	return nil;
}

- (void)dealloc {
	[_changes release];
	[_records release];
	[_fields release];
	[_fileLoc release];
	[super dealloc];
}

- (BOOL)sync {
	ISyncClient *syncClient;
	ISyncSession *syncSession;

	[self applyChanges];
	if ( ! (syncClient = [self registerClient]) )
		return NO;
	if ( ! (syncSession = [self initializeSession:syncClient]) )
		return NO;
	[self pushDataForSession:syncSession withClient:syncClient];
	return [self pullDataForSession:syncSession withClient:syncClient];	
}

- (void)applyChanges {
	// If we have any changes in our change store, we should apply them now.
	// We won't write them out unless we have a successful sync, and applying these changes now
	// let's us better handle the server's requests.
	if (_changes) {
		NSEnumerator *changeEnumerator = [_changes keyEnumerator];
		NSDictionary *currentChange;
		NSString *currentRecordNumber;
		
		while (( currentRecordNumber = (NSString *)[changeEnumerator nextObject] )) {
			currentChange = (NSDictionary *)[_changes objectForKey:currentRecordNumber];
			NSString *changeType = [currentChange objectForKey:@"ChangeType"];
			
			if ( [changeType isEqualToString:@"Add"] ) {
				[_changes removeObjectForKey:currentRecordNumber];
				currentRecordNumber = [NSString stringWithFormat:@"%05d", ++_highestLocalId];
				[_changes setObject:currentChange forKey:currentRecordNumber];
				[_records setObject:[self _mutDictFromChanges:(NSArray *)[currentChange objectForKey:@"ChangeSet"]
												 startingDict:nil] forKey:currentRecordNumber];
			} else if ( [changeType isEqualToString:@"Delete"] ) {
				[_records removeObjectForKey:currentRecordNumber];
			} else if ( [changeType isEqualToString:@"Modify"] ) {
				[_records setObject:[self _mutDictFromChanges:(NSArray *)[currentChange objectForKey:@"ChangeSet"]
												 startingDict:[_records objectForKey:currentRecordNumber]]
							 forKey:currentRecordNumber];
			} else { // This change was written as a series of changed fields
				NSMutableDictionary *newRecord = [(NSMutableDictionary *)[currentChange objectForKey:@"ChangeSet"]
					mutableCopy];
				[newRecord removeObjectForKey:ISyncRecordEntityNameKey];
				[_records setObject:newRecord forKey:currentRecordNumber];
			}
		}
	}
}

- (ISyncClient *)registerClient {
	ISyncManager *manager = [ISyncManager sharedManager];
	ISyncClient *syncClient;

	// Register the schema.
	[manager registerSchemaWithBundlePath:
		[DEFAULT_CUSTOM_SCHEMA stringByExpandingTildeInPath]];
	
	// See if our client has already registered
	if (!(syncClient = [manager clientWithIdentifier:[NSString stringWithFormat:@"com.mycompany.syncexamples.ZenSync%@", [_fileLoc lastPathComponent]]])) {
		// and if it hasn't, register the client.
		// We use the filename as part of the identifier, so that each file represents a separate sync client
		syncClient = [manager registerClientWithIdentifier:[NSString stringWithFormat:@"com.mycompany.syncexamples.ZenSync%@",
			[_fileLoc lastPathComponent]] descriptionFilePath:_plistLoc];
	}
	
	return syncClient;
}

- (ISyncSession *)initializeSession:(ISyncClient *)syncClient {
	ISyncSession *syncSession;

	// Open a session with the sync server
	syncSession = [ISyncSession beginSessionWithClient:syncClient
		/* (NSArray *) of (NSString *) */ entityNames:[NSArray arrayWithObject:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]
        /* How long I'm willing to wait - pretty much forever */ beforeDate:[NSDate distantFuture]];

	// If we failed to get a sync session, we either timed out, or syncing isn't enabled.
	if (!syncSession) {
		if (![[ISyncManager sharedManager] isEnabled])
			NSLog(@"Syncing is currently disabled");
		else
			NSLog(@"Zen Sync timed out in beginSession");
		return nil;
	}

	// If we're refreshing our data, it's okay to overwrite previous client ids.
	if ( !_isRefresh ) {
		// Using our custom data, determine the highest record Id the server should know about
		NSNumber *highestServerId = (NSNumber *)[syncClient objectForKey:@"HighestId"];
		//   If we've got a higher recordId in our local document, update our info on the server
		if ([highestServerId integerValue] < _highestLocalId) {
			[syncClient setObject:[NSNumber numberWithInteger:_highestLocalId] forKey:@"HighestId"];
		} else {
			_highestLocalId = [highestServerId integerValue];
		}
	}

	// Using the custom data, get the number of the last sync, so we can bump it and store it
	NSInteger serverLastSync = [(NSNumber *)[syncClient objectForKey:@"LastSyncNumber"] integerValue];
	_lastSyncNumber = (_lastSyncNumber > serverLastSync) ? _lastSyncNumber + 1 : serverLastSync + 1;

	// If we've been asked to do a refresh sync, inform the server, and skip the push phase altogether
	if ( _isRefresh ) {
		[syncSession clientDidResetEntityNames:[NSArray arrayWithObject:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]];
	} else if ( ! _changes ) {
		// If there were no change lines (not even blanks), we're pushing everything (slow sync).
		// Tell the server our request, and let it determine if we can.
		[syncSession clientWantsToPushAllRecordsForEntityNames:
			[NSArray arrayWithObject:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]];
	}
	return syncSession;
}

- (void)pushDataForSession:(ISyncSession *)syncSession withClient:(ISyncClient *)syncClient {
	NSString *currentRecordNumber;

	// Since we may have upped our highest seen local id due to an add being applied locally, reset the
	// datum on the server
	[syncClient setObject:[NSNumber numberWithInteger:_highestLocalId] forKey:@"HighestId"];		

	// Ask the server how it wants us to sync
	if ([syncSession shouldPushAllRecordsForEntityName:
		ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]) {
		// If the server wants us to push all of our records, we simply read them from our data store, and push them
		NSEnumerator *recordEnumerator = [_records keyEnumerator];
		while (( currentRecordNumber = (NSString *)[recordEnumerator nextObject] )) {
			[(NSMutableDictionary *)[_records objectForKey:currentRecordNumber] setObject:
				ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity forKey:ISyncRecordEntityNameKey];
			[syncSession pushChangesFromRecord:[_records objectForKey:currentRecordNumber]
								withIdentifier:currentRecordNumber];
		}
	} else if ([syncSession shouldPushChangesForEntityName:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]) {
		// If the server would rather have us push up our changes, pull any changes from our change store, and push them
		//    Those that were specified with add / delete / modify, push as ISyncChange s
		//    All others, push as modified records
		NSEnumerator *changeEnumerator = [_changes keyEnumerator];
		NSDictionary *currentChange;
		
		while (( currentRecordNumber = (NSString *)[changeEnumerator nextObject] )) {
			currentChange = (NSDictionary *)[_changes objectForKey:currentRecordNumber];
			NSString *changeType = [currentChange objectForKey:@"ChangeType"];
				
			if ( [changeType isEqualToString:@"Add"] ) {
				[syncSession pushChange:[ISyncChange changeWithType:ISyncChangeTypeAdd
												  recordIdentifier:currentRecordNumber
														   changes:(NSArray *)[currentChange objectForKey:@"ChangeSet"]]];
			} else if ( [changeType isEqualToString:@"Delete"] ) {
				[syncSession pushChange:[ISyncChange changeWithType:ISyncChangeTypeDelete
												   recordIdentifier:currentRecordNumber
															changes:nil]];
			} else if ( [changeType isEqualToString:@"Modify"] ) {
				[syncSession pushChange:[ISyncChange changeWithType:ISyncChangeTypeModify
												   recordIdentifier:currentRecordNumber
															changes:(NSArray *)[currentChange objectForKey:@"ChangeSet"]]];
			} else { // This change was written as a series of changed fields
				NSLog(@"Pushing a change that looks like :%@", [currentChange objectForKey:@"ChangeSet"]);
				[syncSession pushChangesFromRecord:(NSDictionary *)[currentChange objectForKey:@"ChangeSet"]
									withIdentifier:currentRecordNumber];
			}
		}
	}
	// If the server wouldn't let us push anything, do nothing
}
	
- (BOOL)pullDataForSession:(ISyncSession *)syncSession withClient:(ISyncClient *)syncClient {
	// See if the engine will let us pull our changes for our entity
	BOOL shouldPull = [syncSession shouldPullChangesForEntityName:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity];

	// If we're allowed to pull changes, tell the engine to prepare them.  If not, we're still okay
	// (one example is when we're supposed to push the truth.  We won't be asked to pull changes in that case)
	if (shouldPull) {
		BOOL serverResponse = [syncSession prepareToPullChangesForEntityNames:[NSArray arrayWithObject:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]
		  /* How long I'm willing to wait - pretty much forever */ beforeDate:[NSDate distantFuture]];

		// If the server tells us the mingling didn't go okay, bail out of this methood
		if ( ! serverResponse ) {
			[syncSession cancelSyncing];
			return NO;
		}
	
		// Determine if the server will push everything
		if ([syncSession shouldReplaceAllRecordsOnClientForEntityName:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity])
			// And if so, whack our data
			[_records removeAllObjects];
		
		// Enumerate over the available changes
		NSEnumerator *changeEnumerator = [syncSession changeEnumeratorForEntityNames:
			[NSArray arrayWithObject:ISyncEntity_Com_MyCompany_SyncExamples_Zensync_Customentity]];
		
		ISyncChange *currentChange;
		
		// Apply each change to the data store, and report success or failure back to the sync server
		while (( currentChange = (ISyncChange *)[changeEnumerator nextObject] )) {
			switch ( [currentChange type] ) {
				case ISyncChangeTypeDelete:
					[_records removeObjectForKey:[currentChange recordIdentifier]];
					[syncSession clientAcceptedChangesForRecordWithIdentifier:[currentChange recordIdentifier]
															  formattedRecord:nil
														  newRecordIdentifier:nil];
					break;
				case ISyncChangeTypeAdd:
				{
					NSString *newRecordId = [NSString stringWithFormat:@"%05d", ++_highestLocalId];
					[syncSession clientAcceptedChangesForRecordWithIdentifier:[currentChange recordIdentifier]
															  formattedRecord:nil
														  newRecordIdentifier:newRecordId];
					[_records setObject:[currentChange record] forKey:newRecordId];
					break;
				}
				case ISyncChangeTypeModify:
					[_records setObject:[currentChange record] forKey:[currentChange recordIdentifier]];
					[syncSession clientAcceptedChangesForRecordWithIdentifier:[currentChange recordIdentifier]
															  formattedRecord:nil
														  newRecordIdentifier:nil];
					break;
			}
		}
		// If we were asked to pull something from the server, we got changes.
		// Once all have been applied, tell the server we're done modifying our data, for better or worse
		[syncSession clientCommittedAcceptedChanges];
	}	
	// Update our HighestId info (we might have incremented it while applying an add from the server)
	[syncClient setObject:[NSNumber numberWithInteger:_highestLocalId] forKey:@"HighestId"];
	
	// Update our LastSyncNumber info, now that we know the sync was successful
	[syncClient setObject:[NSNumber numberWithInteger:_lastSyncNumber] forKey:@"LastSyncNumber"];
	
	// tell the sync server we're done with this session
	[syncSession finishSyncing];
	
	return YES;
}

@end
