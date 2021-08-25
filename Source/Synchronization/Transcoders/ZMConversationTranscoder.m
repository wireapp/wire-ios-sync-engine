// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
// 


@import WireSystem;
@import WireUtilities;
@import WireTransport;
@import WireDataModel;
@import WireRequestStrategy;

#import "ZMConversationTranscoder.h"
#import "ZMAuthenticationStatus.h"
#import "ZMSimpleListRequestPaginator.h"
#import <WireSyncEngine/WireSyncEngine-Swift.h>

static NSString* ZMLogTag ZM_UNUSED = @"event-processing";

NSString *const ConversationsPath = @"/conversations";
static NSString *const ConversationIDsPath = @"/conversations/ids";

NSUInteger ZMConversationTranscoderListPageSize = 100;
const NSUInteger ZMConversationTranscoderDefaultConversationPageSize = 32;

static NSString *const UserInfoTypeKey = @"type";
static NSString *const UserInfoUserKey = @"user";
static NSString *const UserInfoAddedValueKey = @"added";
static NSString *const UserInfoRemovedValueKey = @"removed";

static NSString *const ConversationTeamKey = @"team";
static NSString *const ConversationAccessKey = @"access";
static NSString *const ConversationAccessRoleKey = @"access_role";
static NSString *const ConversationTeamIdKey = @"teamid";
static NSString *const ConversationTeamManagedKey = @"managed";

@interface ZMConversationTranscoder () <ZMSimpleListRequestPaginatorSync>

@property (nonatomic) ZMUpstreamModifiedObjectSync *modifiedSync;
@property (nonatomic) ZMUpstreamInsertedObjectSync *insertedSync;

@property (nonatomic) ZMDownstreamObjectSync *downstreamSync;
@property (nonatomic) ZMRemoteIdentifierObjectSync *remoteIDSync;
@property (nonatomic) ZMSimpleListRequestPaginator *listPaginator;

@property (nonatomic, weak) SyncStatus *syncStatus;
@property (nonatomic) NSMutableOrderedSet<ZMConversation *> *lastSyncedActiveConversations;

@end


@interface ZMConversationTranscoder (DownstreamTranscoder) <ZMDownstreamTranscoder>
@end


@interface ZMConversationTranscoder (UpstreamTranscoder) <ZMUpstreamTranscoder>
@end


@interface ZMConversationTranscoder (PaginatedRequest) <ZMRemoteIdentifierObjectTranscoder>
@end


@implementation ZMConversationTranscoder

@synthesize useFederationEndpoint;

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)moc applicationStatus:(id<ZMApplicationStatus>)applicationStatus;
{
    Require(NO);
    self = [super initWithManagedObjectContext:moc applicationStatus:applicationStatus];
    NOT_USED(self);
    self = nil;
    return self;
}

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
                           applicationStatus:(id<ZMApplicationStatus>)applicationStatus
                                  syncStatus:(SyncStatus *)syncStatus;
{
    self = [super initWithManagedObjectContext:managedObjectContext applicationStatus:applicationStatus];
    if (self) {
        self.syncStatus = syncStatus;
        self.lastSyncedActiveConversations = [[NSMutableOrderedSet alloc] init];

        self.modifiedSync = [[ZMUpstreamModifiedObjectSync alloc] initWithTranscoder:self
                                                                          entityName:ZMConversation.entityName
                                                                     updatePredicate:nil
                                                                              filter:nil
                                                                          keysToSync:self.keysToSync managedObjectContext:self.managedObjectContext];

        self.insertedSync = [[ZMUpstreamInsertedObjectSync alloc] initWithTranscoder:self
                                                                          entityName:ZMConversation.entityName
                                                                managedObjectContext:self.managedObjectContext];

        self.downstreamSync = [[ZMDownstreamObjectSync alloc] initWithTranscoder:self
                                                                      entityName:ZMConversation.entityName
                                                   predicateForObjectsToDownload:ZMConversationTranscoder.predicateForDownstreamSync
                                                            managedObjectContext:self.managedObjectContext];

        self.listPaginator = [[ZMSimpleListRequestPaginator alloc] initWithBasePath:ConversationIDsPath
                                                                           startKey:@"start"
                                                                           pageSize:ZMConversationTranscoderListPageSize
                                                               managedObjectContext:self.managedObjectContext
                                                                    includeClientID:NO
                                                                         transcoder:self];
        self.conversationPageSize = ZMConversationTranscoderDefaultConversationPageSize;
        self.remoteIDSync = [[ZMRemoteIdentifierObjectSync alloc] initWithTranscoder:self managedObjectContext:self.managedObjectContext];
    }
    return self;
}

- (ZMStrategyConfigurationOption)configuration
{
    return ZMStrategyConfigurationOptionAllowsRequestsDuringSlowSync
         | ZMStrategyConfigurationOptionAllowsRequestsWhileOnline;
}

- (NSArray<NSString *> *)keysToSync
{
    NSArray *keysWithRef = @[
             ZMConversationArchivedChangedTimeStampKey,
             ZMConversationSilencedChangedTimeStampKey];
    NSArray *allKeys = [keysWithRef arrayByAddingObjectsFromArray:self.keysToSyncWithoutRef];
    return allKeys;
}

- (NSArray<NSString *>*)keysToSyncWithoutRef
{
    // Some keys don't have or are a time reference
    // These keys will always be over written when updating from the backend
    // They might be overwritten in a way that they don't create requests anymore whereas they previously did
    // To avoid crashes or unneccessary syncs, we should reset those when refetching the conversation from the backend
    
    return @[ZMConversationUserDefinedNameKey];
    
}

- (NSUUID *)nextUUIDFromResponse:(ZMTransportResponse *)response forListPaginator:(ZMSimpleListRequestPaginator *)paginator
{
    NOT_USED(paginator);
    
    NSDictionary *payload = [response.payload asDictionary];
    NSArray *conversationIDStrings = [payload arrayForKey:@"conversations"];
    NSArray *conversationUUIDs = [conversationIDStrings mapWithBlock:^id(NSString *obj) {
        return [obj UUID];
    }];
    NSSet *conversationUUIDSet = [NSSet setWithArray:conversationUUIDs];
    [self.remoteIDSync addRemoteIdentifiersThatNeedDownload:conversationUUIDSet];
    
    
    if (response.result == ZMTransportResponseStatusPermanentError && self.isSyncing) {
        [self.syncStatus failCurrentSyncPhaseWithPhase:self.expectedSyncPhase];
    }
    
    [self finishSyncIfCompleted];
    
    return conversationUUIDs.lastObject;
}

- (void)finishSyncIfCompleted
{
    if (!self.listPaginator.hasMoreToFetch && self.remoteIDSync.isDone && self.isSyncing) {
        [self updateInactiveConversations:self.lastSyncedActiveConversations];
        [self.lastSyncedActiveConversations removeAllObjects];
        [self.syncStatus finishCurrentSyncPhaseWithPhase:self.expectedSyncPhase];
    }
}

- (void)updateInactiveConversations:(NSOrderedSet<ZMConversation *> *)activeConversations
{
    NSMutableOrderedSet *inactiveConversations = [NSMutableOrderedSet orderedSetWithArray:[self.managedObjectContext executeFetchRequestOrAssert:[ZMConversation sortedFetchRequest]]];
    [inactiveConversations minusOrderedSet:activeConversations];
    
    for (ZMConversation *inactiveConversation in inactiveConversations) {
        if (inactiveConversation.conversationType == ZMConversationTypeGroup) {
            inactiveConversation.needsToBeUpdatedFromBackend = YES;
        }
    }
}

- (SyncPhase)expectedSyncPhase
{
    return SyncPhaseFetchingConversations;
}

- (BOOL)isSyncing
{
    return self.syncStatus.currentSyncPhase == self.expectedSyncPhase;
}

- (ZMTransportRequest *)nextRequestIfAllowed
{
    if (self.isSyncing && self.listPaginator.status != ZMSingleRequestInProgress && self.remoteIDSync.isDone) {
        [self.listPaginator resetFetching];
        [self.remoteIDSync setRemoteIdentifiersAsNeedingDownload:[NSSet set]];
    }
    
    return [self.requestGenerators nextRequest];
}

- (NSArray *)contextChangeTrackers
{
    return @[self.downstreamSync, self.insertedSync, self.modifiedSync];
}

- (NSArray *)requestGenerators;
{
    if (self.isSyncing) {
        return  @[self.listPaginator, self.remoteIDSync];
    } else {
        return  @[self.downstreamSync, self.insertedSync, self.modifiedSync];
    }
}

- (ZMConversation *)createOneOnOneConversationFromTransportData:(NSDictionary *)transportData
                                                           type:(ZMConversationType const)type
                                                serverTimeStamp:(NSDate *)serverTimeStamp;
{
    NSUUID * const convRemoteID = [transportData uuidForKey:@"id"];
    if(convRemoteID == nil) {
        ZMLogError(@"Missing ID in conversation payload");
        return nil;
    }
    
    // Get the 'other' user:
    NSDictionary *members = [transportData dictionaryForKey:@"members"];
    
    NSArray *others = [members arrayForKey:@"others"];

    if ((type == ZMConversationTypeConnection) && (others.count == 0)) {
        // But be sure to update the conversation if it already exists:

        ZMConversation *conversation = [ZMConversation fetchWith:convRemoteID domain:nil in:self.managedObjectContext];
        if ((conversation.conversationType != ZMConversationTypeOneOnOne) &&
            (conversation.conversationType != ZMConversationTypeConnection))
        {
            conversation.conversationType = type;
        }
        
        // Ignore everything else since we can't find out which connection it belongs to.
        return conversation;
    }
    
    VerifyReturnNil(others.count != 0); // No other users? Self conversation?
    VerifyReturnNil(others.count < 2); // More than 1 other user in a conversation that's not a group conversation?
    
    NSUUID *otherUserRemoteID = [[others[0] asDictionary] uuidForKey:@"id"];
    VerifyReturnNil(otherUserRemoteID != nil); // No remote ID for other user?

    ZMUser *user = [ZMUser fetchOrCreateWith:otherUserRemoteID domain:nil in:self.managedObjectContext];
    ZMConversation *conversation = user.connection.conversation;
    
    if (conversation == nil) {
        // if the conversation already exist, it will pick it up here and hook it up to the connection
        conversation = [ZMConversation fetchOrCreateWith:convRemoteID domain:nil in:self.managedObjectContext];
        RequireString(conversation.conversationType != ZMConversationTypeGroup,
                      "Conversation for connection is a group conversation: %s",
                      convRemoteID.transportString.UTF8String);
        user.connection.conversation = conversation;
    } else {
        // check if a conversation already exists with that ID
        [conversation mergeWithExistingConversationWithRemoteID:convRemoteID];
    }
    
    conversation.remoteIdentifier = convRemoteID;
    [conversation updateWithTransportData:transportData serverTimeStamp:serverTimeStamp];
    return conversation;
}


- (BOOL)shouldProcessUpdateEvent:(ZMUpdateEvent *)event
{
    switch (event.type) {
        case ZMUpdateEventTypeConversationMessageAdd:
        case ZMUpdateEventTypeConversationClientMessageAdd:
        case ZMUpdateEventTypeConversationOtrMessageAdd:
        case ZMUpdateEventTypeConversationOtrAssetAdd:
        case ZMUpdateEventTypeConversationKnock:
        case ZMUpdateEventTypeConversationAssetAdd:
        case ZMUpdateEventTypeConversationMemberJoin:
        case ZMUpdateEventTypeConversationMemberLeave:
        case ZMUpdateEventTypeConversationRename:
        case ZMUpdateEventTypeConversationMemberUpdate:
        case ZMUpdateEventTypeConversationCreate:
        case ZMUpdateEventTypeConversationDelete:
        case ZMUpdateEventTypeConversationConnectRequest:
        case ZMUpdateEventTypeConversationAccessModeUpdate:
        case ZMUpdateEventTypeConversationMessageTimerUpdate:
        case ZMUpdateEventTypeConversationReceiptModeUpdate:
            return YES;
        default:
            return NO;
    }
}

- (ZMConversation *)conversationFromEventPayload:(ZMUpdateEvent *)event conversationMap:(ZMConversationMapping *)prefetchedMapping
{
    NSUUID * const conversationID = [event.payload optionalUuidForKey:@"conversation"];
    NSString * const domain = [[event.payload optionalDictionaryForKey:@"qualified_conversation"] optionalStringForKey:@"domain"];
    
    if (nil == conversationID) {
        return nil;
    }

    ZMConversation *conversation = prefetchedMapping[conversationID];
    if (conversation != nil && [domain isEqual:conversation.domain]) {
        return conversation;
    }

    BOOL created = NO;
    conversation = [ZMConversation fetchOrCreateWith:conversationID
                                              domain:domain
                                                  in:self.managedObjectContext
                                             created:&created];

    if (created) {
        // if we did not have this conversation before, refetch it
        conversation.needsToBeUpdatedFromBackend = YES;
    }

    return conversation;
}

- (BOOL)isSelfConversationEvent:(ZMUpdateEvent *)event;
{
    NSUUID * const conversationID = event.conversationUUID;
    return [conversationID isSelfConversationRemoteIdentifierInContext:self.managedObjectContext];
}

- (void)deleteConversationFromEvent:(ZMUpdateEvent *)event
{
    NSUUID *conversationId = event.conversationUUID;
    
    if (conversationId == nil) {
        ZMLogError(@"Missing conversation payload in ZMupdateEventConversatinDelete");
        return;
    }

    ZMConversation *conversation = [ZMConversation fetchWith:conversationId domain:nil in:self.managedObjectContext];
    
    if (conversation != nil) {
        [self.managedObjectContext deleteObject:conversation];
    }
}

- (void)processEvents:(NSArray<ZMUpdateEvent *> *)events
           liveEvents:(BOOL)liveEvents
       prefetchResult:(ZMFetchRequestBatchResult *)prefetchResult;
{
    for (ZMUpdateEvent *event in events) {
        
        if (event.type == ZMUpdateEventTypeConversationCreate) {
            [self createConversationFromEvent:event];
            continue;
        }
        
        if (event.type == ZMUpdateEventTypeConversationDelete) {
            [self deleteConversationFromEvent:event];
            continue;
        }
        
        if ([self isSelfConversationEvent:event]) {
            continue;
        }
        
        ZMConversation *conversation = [self conversationFromEventPayload:event
                                                          conversationMap:prefetchResult.conversationsByRemoteIdentifier];
        if (conversation == nil) {
            continue;
        }
        [self markConversationForDownloadIfNeeded:conversation afterEvent:event];
        
        if (![self shouldProcessUpdateEvent:event]) {
            continue;
        }
        
        NSDate * const currentLastTimestamp = conversation.lastServerTimeStamp;
        [conversation updateWithUpdateEvent:event];
        
        if (liveEvents) {
            [self processUpdateEvent:event forConversation:conversation previousLastServerTimestamp:currentLastTimestamp];
        }
    }
}

- (NSSet<NSUUID *> *)conversationRemoteIdentifiersToPrefetchToProcessEvents:(NSArray<ZMUpdateEvent *> *)events
{
    return [NSSet setWithArray:[events mapWithBlock:^NSUUID *(ZMUpdateEvent *event) {
        return [event.payload optionalUuidForKey:@"conversation"];
    }]];
}


- (void)markConversationForDownloadIfNeeded:(ZMConversation *)conversation afterEvent:(ZMUpdateEvent *)event {
    
    switch(event.type) {
        case ZMUpdateEventTypeConversationOtrAssetAdd:
        case ZMUpdateEventTypeConversationOtrMessageAdd:
        case ZMUpdateEventTypeConversationRename:
        case ZMUpdateEventTypeConversationMemberLeave:
        case ZMUpdateEventTypeConversationKnock:
        case ZMUpdateEventTypeConversationMessageAdd:
        case ZMUpdateEventTypeConversationTyping:
        case ZMUpdateEventTypeConversationAssetAdd:
        case ZMUpdateEventTypeConversationClientMessageAdd:
            break;
        default:
            return;
    }
    
    BOOL isConnection = conversation.connection.status == ZMConnectionStatusPending
        || conversation.connection.status == ZMConnectionStatusSent
        || conversation.conversationType == ZMConversationTypeConnection; // the last OR should be covered by the
                                                                      // previous cases already, but just in case..
    if (isConnection || conversation.conversationType == ZMConversationTypeInvalid) {
        conversation.needsToBeUpdatedFromBackend = YES;
        conversation.connection.needsToBeUpdatedFromBackend = YES;
    }
}

- (void)processUpdateEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation previousLastServerTimestamp:(NSDate *)previousLastServerTimestamp
{
    switch (event.type) {
        case ZMUpdateEventTypeConversationRename:
            [self processConversationRenameEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationMemberJoin:
            [self processMemberJoinEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationMemberLeave:
            [self processMemberLeaveEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationMemberUpdate:
            [self processMemberUpdateEvent:event forConversation:conversation previousLastServerTimeStamp:previousLastServerTimestamp];
            break;
        case ZMUpdateEventTypeConversationConnectRequest:
            [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationAccessModeUpdate:
            [self processAccessModeUpdateEvent:event inConversation:conversation];
            break;       
        case ZMUpdateEventTypeConversationMessageTimerUpdate:
            [self processDestructionTimerUpdateEvent:event inConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationReceiptModeUpdate:
            [self processReceiptModeUpdate:event inConversation:conversation lastServerTimestamp:previousLastServerTimestamp];
        default:
            break;
    }
}

- (void)processConversationRenameEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    NSString *newName = [data stringForKey:@"name"];
    
    if (![conversation.userDefinedName isEqualToString:newName] || [conversation.modifiedKeys containsObject:ZMConversationUserDefinedNameKey]) {
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    conversation.userDefinedName = newName;
}

- (void)processMemberLeaveEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSUUID *senderUUID = event.senderUUID;
    ZMUser *sender = [ZMUser fetchOrCreateWith:senderUUID domain:nil in:self.managedObjectContext];
    NSSet *removedUsers = [event usersFromUserIDsInManagedObjectContext:self.managedObjectContext createIfNeeded:YES];
    
    ZMLogDebug(@"processMemberLeaveEvent (%@) leaving users.count = %lu", conversation.remoteIdentifier.transportString, (unsigned long)removedUsers.count);
    
    if ([removedUsers intersectsSet:conversation.localParticipants]) {
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    [conversation removeParticipantsAndUpdateConversationStateWithUsers:removedUsers initiatingUser:sender];
}

@end

@implementation ZMConversationTranscoder (UpstreamTranscoder)

- (BOOL)shouldProcessUpdatesBeforeInserts;
{
    return NO;
}

- (ZMUpstreamRequest *)requestForUpdatingObject:(ZMConversation *)updatedConversation forKeys:(NSSet *)keys;
{
    ZMUpstreamRequest *request = nil;
    if([keys containsObject:ZMConversationUserDefinedNameKey]) {
        request = [self requestForUpdatingUserDefinedNameInConversation:updatedConversation];
    }
    if (request == nil && (   [keys containsObject:ZMConversationArchivedChangedTimeStampKey]
                           || [keys containsObject:ZMConversationSilencedChangedTimeStampKey])) {
        request = [updatedConversation requestForUpdatingSelfInfo];
    }
    if (request == nil) {
        ZMTrapUnableToGenerateRequest(keys, self);
    }
    return request;
}

- (ZMUpstreamRequest *)requestForUpdatingUserDefinedNameInConversation:(ZMConversation *)conversation
{
    NSDictionary *payload = @{ @"name" : conversation.userDefinedName };
    NSString *lastComponent = conversation.remoteIdentifier.transportString;
    Require(lastComponent != nil);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, lastComponent]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];

    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationUserDefinedNameKey] transportRequest:request userInfo:nil];
}

- (ZMCompletionHandler *)rejectedConversationCompletionHandler
{
    ZM_WEAK(self);

    return [ZMCompletionHandler handlerOnGroupQueue:self.managedObjectContext block:^(ZMTransportResponse *response) {
        ZM_STRONG(self);

        if (response.HTTPStatus == 412 && [[response payloadLabel] isEqualToString:@"missing-legalhold-consent"])
        {
            [self.managedObjectContext.zm_userInterfaceContext performGroupedBlock:^{
                [ZMConversation notifyMissingLegalHoldConsentInContext:self.managedObjectContext];
            }];
        }
    }];
}

- (ZMUpstreamRequest *)requestForInsertingObject:(ZMManagedObject *)managedObject forKeys:(NSSet *)keys;
{
    NOT_USED(keys);
    
    ZMTransportRequest *request = nil;
    ZMConversation *insertedConversation = (ZMConversation *) managedObject;
    NSMutableDictionary *payload = [NSMutableDictionary new];

    BOOL hasQualifiedUsers = [insertedConversation.localParticipantsExcludingSelf.allObjects filterWithBlock:^BOOL(ZMUser *user) {
        return user.domain != nil;
    }].count == insertedConversation.localParticipantsExcludingSelf.count;

    if (hasQualifiedUsers && self.useFederationEndpoint) {
        NSArray *qualifiedParticipantUUIDs = [[insertedConversation.localParticipantsExcludingSelf allObjects] mapWithBlock:^id(ZMUser *user) {
            return @{
                @"id": user.remoteIdentifier.transportString,
                @"domain": user.domain
            };
        }];

        payload[@"qualified_users"] = qualifiedParticipantUUIDs;
        payload[@"users"] = @[];
    } else {
        NSArray *participantUUIDs = [[insertedConversation.localParticipantsExcludingSelf allObjects] mapWithBlock:^id(ZMUser *user) {
            return [user.remoteIdentifier transportString];
        }];

        payload[@"users"] = participantUUIDs;
    }

    payload[@"conversation_role"] = ZMConversation.defaultMemberRoleName;

    if (insertedConversation.userDefinedName != nil) {
        payload[@"name"] = insertedConversation.userDefinedName;
    }
    
    if (insertedConversation.hasReadReceiptsEnabled) {
        payload[@"receipt_mode"] = @(1);
    }

    if (insertedConversation.team.remoteIdentifier != nil) {
        payload[ConversationTeamKey] = @{
                             ConversationTeamIdKey: insertedConversation.team.remoteIdentifier.transportString,
                             ConversationTeamManagedKey: @NO // FIXME:
                             };
    }

    NSArray <NSString *> *accessPayload = insertedConversation.accessPayload;
    if (nil != accessPayload) {
        payload[ConversationAccessKey] = accessPayload;
    }

    NSString *accessRolePayload = insertedConversation.accessRolePayload;
    if (nil != accessRolePayload) {
        payload[ConversationAccessRoleKey] = accessRolePayload;
    }
    
    request = [ZMTransportRequest requestWithPath:ConversationsPath method:ZMMethodPOST payload:payload];
    [request addCompletionHandler:[self rejectedConversationCompletionHandler]];

    return [[ZMUpstreamRequest alloc] initWithTransportRequest:request];
}


- (void)updateInsertedObject:(ZMManagedObject *)managedObject request:(ZMUpstreamRequest *__unused)upstreamRequest response:(ZMTransportResponse *)response
{
    ZMConversation *insertedConversation = (ZMConversation *)managedObject;
    NSUUID *remoteID = [response.payload.asDictionary uuidForKey:@"id"];
    
    // check if there is another with the same conversation ID
    if (remoteID != nil) {
        ZMConversation *existingConversation = [ZMConversation fetchWith:remoteID domain:nil in:self.managedObjectContext];
        
        if (existingConversation != nil) {
            [self.managedObjectContext deleteObject:existingConversation];
            insertedConversation.needsToBeUpdatedFromBackend = YES;
        }
    }
    insertedConversation.remoteIdentifier = remoteID;
    [insertedConversation updateWithTransportData:response.payload.asDictionary serverTimeStamp:nil];
    
    if (insertedConversation.team == nil) {
        insertedConversation.needsToDownloadRoles = YES;
    }
}

- (ZMUpdateEvent *)conversationEventWithKeys:(NSSet *)keys responsePayload:(id<ZMTransportData>)payload;
{
    NSSet *keysThatGenerateEvents = [NSSet setWithObjects:ZMConversationUserDefinedNameKey, nil];
    
    if (! [keys intersectsSet:keysThatGenerateEvents]) {
        return nil;
        
    }

    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
    return event;
}


- (BOOL)updateUpdatedObject:(ZMConversation *)conversation
            requestUserInfo:(NSDictionary *)userInfo
                   response:(ZMTransportResponse *)response
                keysToParse:(NSSet *)keysToParse
{
    NOT_USED(conversation);
    
    ZMUpdateEvent *event = [self conversationEventWithKeys:keysToParse responsePayload:response.payload];
    if (event != nil) {
        [self processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }
        
    if ([keysToParse isEqualToSet:[NSSet setWithObject:ZMConversationUserDefinedNameKey]]) {
        return NO;
    }
    
    if( keysToParse == nil ||
       [keysToParse isEmpty] ||
       [keysToParse containsObject:ZMConversationSilencedChangedTimeStampKey] ||
       [keysToParse containsObject:ZMConversationArchivedChangedTimeStampKey])
    {
        return NO;
    }
    ZMLogError(@"Unknown changed keys in request. keys: %@  payload: %@  userInfo: %@", keysToParse, response.payload, userInfo);
    return NO;
}

- (ZMManagedObject *)objectToRefetchForFailedUpdateOfObject:(ZMManagedObject *)managedObject;
{
    if([managedObject isKindOfClass:ZMConversation.class]) {
        return managedObject;
    }
    return nil;
}

- (void)requestExpiredForObject:(ZMConversation *)conversation forKeys:(NSSet *)keys
{
    NOT_USED(keys);
    conversation.needsToBeUpdatedFromBackend = YES;
    [self resetModifiedKeysWithoutReferenceInConversation:conversation];
}

- (BOOL)shouldCreateRequestToSyncObject:(ZMManagedObject *)managedObject forKeys:(NSSet<NSString *> * __unused)keys  withSync:(id)sync;
{
    if (sync == self.downstreamSync || sync == self.insertedSync) {
        return YES;
    }
    // This is our chance to reset keys that should not be set - instead of crashing when we create a request.
    ZMConversation *conversation = (ZMConversation *)managedObject;
    NSMutableSet *remainingKeys = [NSMutableSet setWithSet:keys];
    
    if ([conversation hasLocalModificationsForKey:ZMConversationUserDefinedNameKey] && !conversation.userDefinedName) {
        [conversation resetLocallyModifiedKeys:[NSSet setWithObject:ZMConversationUserDefinedNameKey]];
        [remainingKeys removeObject:ZMConversationUserDefinedNameKey];
    }
    if (remainingKeys.count < keys.count) {
        [(id<ZMContextChangeTracker>)sync objectsDidChange:[NSSet setWithObject:conversation]];
        [self.managedObjectContext enqueueDelayedSave];
    }
    return (remainingKeys.count > 0);
}

- (BOOL)shouldRetryToSyncAfterFailedToUpdateObject:(ZMConversation *)conversation request:(ZMUpstreamRequest *__unused)upstreamRequest response:(ZMTransportResponse *__unused)response keysToParse:(NSSet * __unused)keys
{
    if (conversation.remoteIdentifier) {
        conversation.needsToBeUpdatedFromBackend = YES;
        [self resetModifiedKeysWithoutReferenceInConversation:conversation];
        [self.downstreamSync objectsDidChange:[NSSet setWithObject:conversation]];
    }
    
    return NO;
}

/// Resets all keys that don't have a time reference and would possibly be changed with refetching of the conversation from the BE
- (void)resetModifiedKeysWithoutReferenceInConversation:(ZMConversation*)conversation
{
    [conversation resetLocallyModifiedKeys:[NSSet setWithArray:self.keysToSyncWithoutRef]];
    
    // since we reset all keys, we should make sure to remove the object from the modifiedSync
    // it might otherwise try to sync remaining keys
    [self.modifiedSync objectsDidChange:[NSSet setWithObject:conversation]];
}

@end



@implementation ZMConversationTranscoder (DownstreamTranscoder)

- (ZMTransportRequest *)requestForFetchingObject:(ZMConversation *)conversation downstreamSync:(id<ZMObjectSync>)downstreamSync;
{
    NOT_USED(downstreamSync);
    if (conversation.remoteIdentifier == nil) {
        return nil;
    }

    if (conversation.domain != nil) {
        NSString *path = [NSString pathWithComponents:@[ConversationsPath,
                                                        conversation.domain,
                                                        conversation.remoteIdentifier.transportString]];
        ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil];
        return request;
    } else {
        NSString *path = [NSString pathWithComponents:@[ConversationsPath,
                                                        conversation.remoteIdentifier.transportString]];
        ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil];
        return request;
    }

}

- (void)updateObject:(ZMConversation *)conversation withResponse:(ZMTransportResponse *)response downstreamSync:(id<ZMObjectSync>)downstreamSync;
{
    NOT_USED(downstreamSync);
    conversation.needsToBeUpdatedFromBackend = NO;
    [self resetModifiedKeysWithoutReferenceInConversation:conversation];
    
    NSDictionary *dictionaryPayload = [response.payload asDictionary];
    VerifyReturn(dictionaryPayload != nil);
    [conversation updateWithTransportData:dictionaryPayload serverTimeStamp:nil];
}

- (void)deleteObject:(ZMConversation *)conversation withResponse:(ZMTransportResponse *)response downstreamSync:(id<ZMObjectSync>)downstreamSync;
{
    // Self user has been removed from the group conversation but missed the conversation.member-leave event.
    if (response.HTTPStatus == 403 && conversation.conversationType == ZMConversationTypeGroup && conversation.isSelfAnActiveMember) {
        ZMUser *selfUser = [ZMUser selfUserInContext:self.managedObjectContext];
        [conversation removeParticipantAndUpdateConversationStateWithUser:selfUser initiatingUser:selfUser];
    }
    
    // Conversation has been permanently deleted
    if (response.HTTPStatus == 404 && conversation.conversationType == ZMConversationTypeGroup) {
        [self.managedObjectContext deleteObject:conversation];
    }
    
    if (response.isPermanentylUnavailableError) {
        conversation.needsToBeUpdatedFromBackend = NO;
    }
    
    NOT_USED(downstreamSync);
}

@end


@implementation ZMConversationTranscoder (PaginatedRequest)

- (NSUInteger)maximumRemoteIdentifiersPerRequestForObjectSync:(ZMRemoteIdentifierObjectSync *)sync;
{
    NOT_USED(sync);
    return self.conversationPageSize;
}


- (ZMTransportRequest *)requestForObjectSync:(ZMRemoteIdentifierObjectSync *)sync remoteIdentifiers:(NSSet *)identifiers;
{
    NOT_USED(sync);
    
    NSArray *currentBatchOfConversationIDs = [[identifiers allObjects] mapWithBlock:^id(NSUUID *obj) {
        return obj.transportString;
    }];
    NSString *path = [NSString stringWithFormat:@"%@?ids=%@", ConversationsPath, [currentBatchOfConversationIDs componentsJoinedByString:@","]];

    return [[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil];
}


- (void)didReceiveResponse:(ZMTransportResponse *)response remoteIdentifierObjectSync:(ZMRemoteIdentifierObjectSync *)sync forRemoteIdentifiers:(NSSet *)remoteIdentifiers;
{
    NOT_USED(sync);
    NOT_USED(remoteIdentifiers);
    NSDictionary *payload = [response.payload asDictionary];
    NSArray *conversations = [payload arrayForKey:@"conversations"];
    
    for (NSDictionary *rawConversation in [conversations asDictionaries]) {
        ZMConversation *conversation = [self createConversationFromTransportData:rawConversation serverTimeStamp:[NSDate date] source:ZMConversationSourceSlowSync];
        conversation.needsToBeUpdatedFromBackend = NO;
        
        if (conversation != nil) {
            [self.lastSyncedActiveConversations addObject:conversation];
        }
    }
    
    if (response.result == ZMTransportResponseStatusPermanentError && self.isSyncing) {
        [self.syncStatus failCurrentSyncPhaseWithPhase:self.expectedSyncPhase];
    }
    
    [self finishSyncIfCompleted];
}

@end
