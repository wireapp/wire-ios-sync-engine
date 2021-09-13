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


@import UIKit;
@import WireTransport;
@import OCMock;
@import WireSyncEngine;
@import WireDataModel;

#import "ObjectTranscoderTests.h"
#import "ZMConversationTranscoder.h"
#import "ZMConversationTranscoder+Internal.h"
#import "ZMSimpleListRequestPaginator.h"
#import "Tests-Swift.h"


static NSString *const CONVERSATIONS_PATH = @"/conversations";
static NSString *const CONVERSATION_ID_REQUEST_PREFIX = @"/conversations?ids=";


@interface ZMConversationTranscoderTests : ObjectTranscoderTests

- (ZMUpdateEvent *)conversationCreateEventForConversationID:(NSUUID *)conversationID selfID:(NSUUID *)selfID otherUserID:(NSUUID *)otherUserID;
- (ZMConversation *)setupConversation;
- (ZMTransportRequest *)requestToSyncConversation:(ZMConversation *)conversation andCompleteWithResponse:(ZMTransportResponse*)response;

@property (nonatomic) ZMConversationTranscoder<ZMUpstreamTranscoder, ZMDownstreamTranscoder> *sut;
@property (nonatomic) NSUUID *selfUserID;
@property (nonatomic) MockSyncStatus *mockSyncStatus;
@property (nonatomic) id syncStateDelegate;

@end



@implementation ZMConversationTranscoderTests

- (void)setUp
{
    [super setUp];
    self.selfUserID = NSUUID.createUUID;
    [self setupSelfConversation]; // when updating lastRead we are posting to the selfConversation

    self.syncStateDelegate = [OCMockObject niceMockForProtocol:@protocol(ZMSyncStateDelegate)];
    self.mockSyncStatus = [[MockSyncStatus alloc] initWithManagedObjectContext:self.syncMOC syncStateDelegate:self.syncStateDelegate];
    self.mockSyncStatus.mockPhase = SyncPhaseDone;
    self.mockApplicationStatus.mockSynchronizationState = ZMSynchronizationStateOnline;

    self.sut = (id) [[ZMConversationTranscoder alloc] initWithManagedObjectContext:self.syncMOC applicationStatus:self.mockApplicationStatus syncStatus:self.mockSyncStatus];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)setSut:(ZMConversationTranscoder<ZMUpstreamTranscoder,ZMDownstreamTranscoder> *)sut
{
    _sut = sut;
}

- (void)tearDown
{
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncStateDelegate stopMocking];
    self.syncStateDelegate = nil;
    self.sut = nil;
    self.mockSyncStatus = nil;
    
    [super tearDown];
}

- (void)setupSelfConversation
{
    ZMUser *selfUser = [ZMUser selfUserInContext:self.uiMOC];
    selfUser.remoteIdentifier = self.selfUserID;
    ZMConversation *selfConversation = [ZMConversation insertNewObjectInManagedObjectContext:self.uiMOC];
    selfConversation.remoteIdentifier = self.selfUserID;
    selfConversation.conversationType = ZMConversationTypeSelf;
    [self.uiMOC saveOrRollback];
}

- (ZMConversation *)setupConversation
{
    ZMConversation * conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.uiMOC];
    conversation.remoteIdentifier = [NSUUID createUUID];
    conversation.conversationType = ZMConversationTypeGroup;
    
    ZMMessage *msg = [[ZMTextMessage alloc] initWithNonce:NSUUID.createUUID managedObjectContext:self.uiMOC];
    msg.serverTimestamp = [NSDate date];
    [conversation.mutableMessages addObject:msg];
    conversation.lastServerTimeStamp = [msg.serverTimestamp dateByAddingTimeInterval:5];

    [self.uiMOC saveOrRollback];
    return conversation;
}

- (ZMTransportRequest *)requestToSyncConversation:(ZMConversation *)conversation andCompleteWithResponse:(ZMTransportResponse*)response
{
    __block ZMTransportRequest *request;
    [self.syncMOC performBlockAndWait:^{
        ZMConversation *syncConv = (id)[self.syncMOC objectWithID:conversation.objectID];
        
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:syncConv]];
        }
        
        request = [self.sut nextRequest];
        XCTAssertNotNil(request);
        
        // when
        [request completeWithResponse:response];
        [self.syncMOC saveOrRollback];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    return request;
}

- (BOOL)isConversation:(ZMConversation *)conversation matchingPayload:(NSDictionary *)payload serverTimeStamp:(NSDate *)serverTimeStamp
{
    const BOOL sameRemoteIdentifier = [NSObject isEqualOrBothNil:conversation.remoteIdentifier toObject:[payload uuidForKey:@"id"]];
    if (!sameRemoteIdentifier) {
        return NO;
    }
    const BOOL sameDomain = [NSObject isEqualOrBothNil:conversation.domain toObject:[[payload optionalDictionaryForKey:@"qualified_id"] optionalStringForKey:@"domain"]];
    const BOOL sameModifiedDate = nil == serverTimeStamp || [conversation.lastModifiedDate.transportString isEqualToString:serverTimeStamp.transportString];
    const BOOL sameCreator = [NSObject isEqualOrBothNil:conversation.creator.remoteIdentifier toObject:[payload uuidForKey:@"creator"]];
    const BOOL sameName = [NSObject isEqualOrBothNil:conversation.userDefinedName toObject:[payload optionalStringForKey:@"name"]];
    const BOOL sameType = conversation.conversationType == [self.class typeFromNumber:payload[@"type"]];

    NSMutableSet* activeParticipants = [NSMutableSet set];
    NSMutableSet* inactiveParticipants = [NSMutableSet set];
    for(NSDictionary *user in [[payload dictionaryForKey:@"members"] arrayForKey:@"others"]) {
        
        if([[user numberForKey:@"status"] intValue] == 0) {
            [activeParticipants addObject:[user uuidForKey:@"id"]];
        }
        else {
            [inactiveParticipants addObject:[user uuidForKey:@"id"]];
        }
    }
    
    BOOL sameActiveUsers = activeParticipants.count == conversation.localParticipantsExcludingSelf.count;
    for(ZMUser *user in conversation.localParticipantsExcludingSelf) {
        sameActiveUsers = sameActiveUsers && [activeParticipants containsObject:user.remoteIdentifier];
    }
    
    return (sameDomain
            && sameModifiedDate
            && sameCreator
            && sameName
            && sameType
            && sameActiveUsers);
}


- (NSDictionary *)conversationMetaDataForConversation:(NSUUID *)conversationID selfID:(NSUUID *)selfID otherUserID:(NSUUID *)otherUserID isArchived:(BOOL)isArchived
{
    return @{
             @"creator": selfID.transportString,
             @"id": conversationID.transportString,
             @"members" : @{
                     @"others" : @[
                             @{
                                 @"id": otherUserID.transportString
                                 },
                             ],
                     @"self" : @{
                             @"otr_archived" : @(isArchived),
                             @"otr_archived_ref" : (isArchived ? @"2014-06-30T09:09:14.738Z" : [NSNull null]),
                             @"id": selfID.transportString
                             }
                     },
             @"name" : [NSNull null],
             @"type": @3,
             };
}

- (ZMUpdateEvent *)conversationCreateEventForConversationID:(NSUUID *)conversationID selfID:(NSUUID *)selfID otherUserID:(NSUUID *)otherUserID isArchived:(BOOL)isArchived
{
    NSDictionary *payload = @{@"conversation": conversationID.transportString,
                              @"data" : [self conversationMetaDataForConversation:conversationID selfID:selfID otherUserID:otherUserID isArchived:isArchived],
                              @"from": selfID.transportString,
                              @"time": @"2013-06-30T09:09:14.752Z",
                              @"type": @"conversation.create"
                              };
    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
    return event;
}

- (ZMUpdateEvent *)conversationCreateEventForConversationID:(NSUUID *)conversationID selfID:(NSUUID *)selfID otherUserID:(NSUUID *)otherUserID
{
    return  [self conversationCreateEventForConversationID:conversationID selfID:selfID otherUserID:otherUserID isArchived:NO];
}


+ (ZMConversationType) typeFromNumber:(NSNumber *)number {
    const static int ZMConvTypeGroup = 0;
    const static int ZMConvOneToOne = 2;
    
    if([number intValue] == ZMConvTypeGroup) {
        return ZMConversationTypeGroup;
    }
    if([number intValue] == ZMConvOneToOne) {
        return ZMConversationTypeOneOnOne;
    }
    return ZMConversationTypeSelf;
}

- (NSMutableDictionary *)responsePayloadForUserEventInConversationID:(NSUUID *)conversationID userIDs:(NSArray *)userIDs eventType:(NSString *)eventType;
{
    return [self responsePayloadForUserEventInConversationID:conversationID lastTimeStamp:[NSDate date] userIDs:userIDs from:self.selfUserID eventType:eventType];
}

- (NSMutableDictionary *)responsePayloadForUserEventInConversationID:(NSUUID *)conversationID
                                                       lastTimeStamp:(NSDate *)lastServerTimeStamp
                                                             userIDs:(NSArray *)userIDs
                                                                from:(NSUUID *)fromUserID
                                                           eventType:(NSString *)eventType;
{
    NSArray *userIDStrings = [userIDs mapWithBlock:^id(NSUUID *userID) {
        Require([userID isKindOfClass:[NSUUID class]]);
        return userID.transportString;
    }];
    return [@{@"conversation": conversationID.transportString,
              @"data": @{@"user_ids": userIDStrings},
              @"from": fromUserID,
              @"time": [lastServerTimeStamp dateByAddingTimeInterval:5].transportString,
              @"type": eventType} mutableCopy];
}


- (NSMutableDictionary *)responsePayloadForRenameOfConversationID:(NSUUID *)conversationID name:(NSString *)name;
{
    return [@{@"conversation": conversationID.transportString,
              @"data": @{@"name": name},
              @"from": self.selfUserID.transportString,
              @"time": [NSDate date].transportString,
              @"type": @"conversation.rename"} mutableCopy];
}

- (void)testThatItProcessesListPaginatorRequestsBeforeRemoteIDRequestsDuringSlowSync
{
    // given
    self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
    
    // when
    NSArray *generators = self.sut.requestGenerators;
    
    // then
    XCTAssertEqual(generators.count, 2u);
    XCTAssertTrue([generators.firstObject isKindOfClass:ZMSimpleListRequestPaginator.class]);
    XCTAssertTrue([generators.lastObject isKindOfClass:ZMRemoteIdentifierObjectSync.class]);
}

- (void)testThatItProcessesDownstreamRequestsBeforeUpstreamWhenSlowSyncIsDone
{
    // given
    self.mockSyncStatus.mockPhase = SyncPhaseDone;
    
    // when
    NSArray *generators = self.sut.requestGenerators;
    
    // then
    XCTAssertEqual(generators.count, 3u);
    XCTAssertTrue([generators.firstObject isKindOfClass:ZMDownstreamObjectSync.class]);
    XCTAssertTrue([generators[1] isKindOfClass:ZMUpstreamInsertedObjectSync.class]);
    XCTAssertTrue([generators.lastObject isKindOfClass:ZMUpstreamModifiedObjectSync.class]);
}

- (void)testThatItReturnsTheContextChangeTrackers;
{
    // when
    NSArray *trackers = self.sut.contextChangeTrackers;
    
    // then
    XCTAssertEqual(trackers.count, 3u);
    NSArray *classes = [trackers mapWithBlock:^id(id<NSObject> obj) {
        return obj.class;
    }];
    NSArray *expected = @[ZMDownstreamObjectSync.class, ZMUpstreamInsertedObjectSync.class, ZMUpstreamModifiedObjectSync.class];
    XCTAssertEqualObjects(classes, expected);
}

- (void)testThatItDoesNotGenerateARequestIfSlowSyncIsDone {
    
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        // hard sync is done
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet set]];
        }
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        // then
        XCTAssertNil(request);
    }];
}

- (void)testThatItDownloadsConversationsThatNeedToBeSynchronizedFromTheBackendWithBlock:(void(^)(ZMConversation *conversation))block;
{
    // given
    __block NSUUID *remoteID;
    __block ZMConversation *conversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeOneOnOne;
        conversation.remoteIdentifier = [NSUUID createUUID];
        remoteID = conversation.remoteIdentifier;
        conversation.needsToBeUpdatedFromBackend = YES;
        XCTAssert([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    __block ZMTransportRequest *request;
    [self.syncMOC performGroupedBlockAndWait:^{
        block(conversation);
        request = [self.sut nextRequest];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertNotNil(request);
    NSString *path = [NSString pathWithComponents:@[@"/conversations", remoteID.transportString]];
    XCTAssertEqualObjects(request.path, path);
    XCTAssertEqual(request.method, ZMMethodGET);
}

- (void)testThatItDownloadsConversationsThatNeedToBeSynchronizedFromTheBackend_OnInitialization;
{
    [self testThatItDownloadsConversationsThatNeedToBeSynchronizedFromTheBackendWithBlock:^(ZMConversation *conversation) {
        NOT_USED(conversation);
        [ZMChangeTrackerBootstrap bootStrapChangeTrackers:self.sut.contextChangeTrackers onContext:self.syncMOC];
    }];
}

- (void)testThatItDownloadsConversationsThatNeedToBeSynchronizedFromTheBackend_OnObjectsDidChange;
{
    [self testThatItDownloadsConversationsThatNeedToBeSynchronizedFromTheBackendWithBlock:^(ZMConversation *conversation) {
        [self.sut.contextChangeTrackers[0] objectsDidChange:[NSSet setWithObject:conversation]];
    }];
}

- (void)checkThatItDowloadsConversationWithConnectionOfTipe:(ZMConnectionStatus)status shouldDownload:(BOOL)shouldDownload failureRecorder:(ZMTFailureRecorder *)recorder
{
    // given
    __block NSUUID *remoteID;
    __block ZMConversation *conversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeOneOnOne;
        conversation.remoteIdentifier = [NSUUID createUUID];
        remoteID = conversation.remoteIdentifier;
        conversation.needsToBeUpdatedFromBackend = YES;

        ZMConnection *connection = [ZMConnection insertNewObjectInManagedObjectContext:self.syncMOC];
        connection.status = status;
        connection.conversation = conversation;
        
        XCTAssert([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    [ZMChangeTrackerBootstrap bootStrapChangeTrackers:self.sut.contextChangeTrackers onContext:self.syncMOC];

    __block ZMTransportRequest *request;
    [self.syncMOC performGroupedBlockAndWait:^{
        request = [self.sut nextRequest];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    FHAssertEqual(recorder, request != nil, shouldDownload);
    
}

- (void)testThatItDoesNotDownloadConversationsThatHaveAPendingConnection;
{
    [self checkThatItDowloadsConversationWithConnectionOfTipe:ZMConnectionStatusPending shouldDownload:NO failureRecorder:NewFailureRecorder()];
}

- (void)testThatItDoesNotDownloadConversationsThatHaveAnIgnoredConnection;
{
    [self checkThatItDowloadsConversationWithConnectionOfTipe:ZMConnectionStatusIgnored shouldDownload:NO failureRecorder:NewFailureRecorder()];
}

- (void)testThatItDownloadsAConversationsThatHaveAnAcceptedConnection;
{
    [self checkThatItDowloadsConversationWithConnectionOfTipe:ZMConnectionStatusAccepted shouldDownload:YES failureRecorder:NewFailureRecorder()];
}

- (void)testThatItDownloadsAConversationsThatHaveABlockedConnection;
{
    [self checkThatItDowloadsConversationWithConnectionOfTipe:ZMConnectionStatusBlocked shouldDownload:YES failureRecorder:NewFailureRecorder()];
}

- (void)testThatItDownloadsAConversationsThatHaveAnInvalidConnection;
{
    [self checkThatItDowloadsConversationWithConnectionOfTipe:ZMConnectionStatusInvalid shouldDownload:YES failureRecorder:NewFailureRecorder()];
}

- (void)testThatItDownloadsAConversationsThatHaveASentConnection;
{
    [self checkThatItDowloadsConversationWithConnectionOfTipe:ZMConnectionStatusSent shouldDownload:YES failureRecorder:NewFailureRecorder()];
}

- (void)testThatItUpdatesAConversationFromDownstreamPayload;
{
    // given
    NSUUID *remoteID = [NSUUID createUUID];
    NSDictionary *payload = @{@"creator": @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                              @"members": @{
                                      @"self": @{
                                              @"id": @"08316f5e-3c0a-4847-a235-2b4d93f291a4"
                                              },
                                      @"others": @[]
                                      },
                              @"name": @"Jonathan",
                              @"id": remoteID.transportString,
                              @"type": @3};
    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeOneOnOne;
        conversation.remoteIdentifier = remoteID;
        conversation.needsToBeUpdatedFromBackend = YES;
        XCTAssert([self.syncMOC saveOrRollback]);
        
        // when
        
        id<ZMDownstreamTranscoder> t = (id) self.sut;
        [t updateObject:conversation withResponse:response downstreamSync:nil];
        
        // then
        XCTAssertEqual(conversation.conversationType, ZMConversationTypeConnection);
    }];
}



-(void)testThatItDoesNotFetchEventsForConversationWithoutRemoteIdentifier
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        (void)[ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2]];
        // when
        ZMTransportRequest *request;
        do {
            request = [self.sut nextRequest];
            if (request == nil) {
                break;
            }
            XCTAssertEqual([request.path rangeOfString:@"events"].location, (NSUInteger) NSNotFound);
        } while (YES);
    }];
}

- (void)testThatItReturnsTheConversationRemoteIdentifiersToPrefetchFromUpdateEvents;
{
    // given
    NSUUID *firstRemoteID = NSUUID.createUUID;
    NSUUID *secondRemoteID = NSUUID.createUUID;
    
    id <ZMTransportData> firstPayload = @{
                              @"conversation" : firstRemoteID,
                              @"data" : @{},
                              @"from": NSUUID.createUUID,
                              @"time" : NSDate.date.transportString,
                              @"type" : @"conversation.member-update"
                              };
    
    id <ZMTransportData> secondPayload = @{
                              @"conversation" : secondRemoteID,
                              @"data" : @{
                                      @"content" : @"www.wire.com",
                                      @"nonce" : NSUUID.createUUID,
                                      },
                              @"from": NSUUID.createUUID,
                              @"id" : @"6c9d.800122000a5911ba",
                              @"time" : NSDate.date.transportString,
                              @"type" : @"conversation.message-add"
                              };
    
    NSArray <ZMUpdateEvent *> *events = @[
                                          [ZMUpdateEvent eventFromEventStreamPayload:firstPayload uuid:nil],
                                          [ZMUpdateEvent eventFromEventStreamPayload:secondPayload uuid:nil]
                                          ];

    // when
    NSSet <NSUUID *>*identifiers = [self.sut conversationRemoteIdentifiersToPrefetchToProcessEvents:events];

    // then
    NSSet *expected = @[firstRemoteID, secondRemoteID].set;
    XCTAssertEqualObjects(identifiers, expected);
}

- (void)testThatNoRequestIsGeneratedForAConversationWithoutRemoteIdentifierEvenAfterTheyAreInserted
{
    // given
    __block NSUUID *remoteID;
    __block ZMConversation *conversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeOneOnOne;
        conversation.remoteIdentifier = [NSUUID createUUID];
        remoteID = conversation.remoteIdentifier;
        conversation.needsToBeUpdatedFromBackend = YES;
        XCTAssert([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    __block ZMTransportRequest *request;
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation.remoteIdentifier = nil;
        request = [self.sut nextRequest];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertNil(request);
}

- (void)testThatNoRequestIsGeneratedForAConversationIfAnyParticipantsNeedToBeUpdatedFromBackend
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = [NSUUID createUUID];
        conversation.needsToBeUpdatedFromBackend = YES;

        ZMUser *user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID];
        user.needsToBeUpdatedFromBackend = YES;

        ParticipantRole *role = [ParticipantRole insertNewObjectInManagedObjectContext:self.syncMOC];
        role.user = user;
        role.conversation = conversation;

        [self.syncMOC saveOrRollback];

        // Then
        ZMTransportRequest *request = [self.sut nextRequest];
        XCTAssertNil(request);
    }];
}



- (void)testThatItDoesNotCreateTheSelfConversationWhenReceivingAssetOrMessageEvents;
{
    // given
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:ZMConversation.entityName];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        NSUUID * const selfUserIdentifier = [NSUUID createUUID];
        [ZMUser selfUserInContext:self.syncMOC].remoteIdentifier = selfUserIdentifier;
        
        for(NSString* type in @[@"conversation.message-add", @"conversation.asset-add"]) {
            NSMutableDictionary *payload = [self responsePayloadForUserEventInConversationID:selfUserIdentifier userIDs:@[] eventType:type];
            ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
            
            // when
            NSUInteger const originalCount = [self.syncMOC countForFetchRequest:request error:nil];
            [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
            [self.syncMOC saveOrRollback];
            
            // then
            NSUInteger const count = [self.syncMOC countForFetchRequest:request error:nil];
            XCTAssertEqual(count, originalCount);
        }
    }];
}

- (ZMConversation *)createModifiedSyncMocConversationAndAddToTrackedObjectsWithID:(NSUUID *)conversationID name:(NSString *)name
{
    ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
    conversation.remoteIdentifier = conversationID; // Otherwise we'll try to insert it
    conversation.conversationType = ZMConversationTypeGroup; // We only don't update 'invalid' type
    conversation.userDefinedName = name;
    [conversation setLocallyModifiedKeys:[NSSet setWithObject:ZMConversationUserDefinedNameKey]];
    [self.syncMOC saveOrRollback];
    
    for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
        [tracker objectsDidChange:[NSSet setWithObject:conversation]];
    }
    return conversation;
}

- (void)testThatItCreatesARequestForUpdatingTheConversationName
{
    // given
    NSString *name = @"My Conversation Name";
    NSUUID *conversationID = NSUUID.createUUID;
    NSDictionary *responsePayload = [self responsePayloadForRenameOfConversationID:conversationID name:@"foo"];
    
    __block ZMConversation *conversation;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        
        conversation = [self createModifiedSyncMocConversationAndAddToTrackedObjectsWithID:conversationID name:name];
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        XCTAssertNotNil(request);
        
        // then
        NSString *expectedString = [NSString stringWithFormat:@"/conversations/%@", conversationID.transportString];
        XCTAssertEqualObjects(request.path, expectedString);
        XCTAssertEqual(request.method, ZMMethodPUT);
        XCTAssertEqualObjects(request.payload, @{@"name":name});
        XCTAssertNotNil(request.expirationDate);
        
        // and when
        ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:responsePayload HTTPStatus:200 transportSessionError:nil];
        [request completeWithResponse:response];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        XCTAssertFalse([conversation.keysThatHaveLocalModifications containsObject:ZMConversationUserDefinedNameKey]);
    }];
}

- (void)testThatItSetsTheLastReadToTheConversationNameChangeResponse;
{
    // given
    NSString *name = @"My Conversation Name";
    NSUUID *conversationID = [NSUUID createUUID];
    
    NSDate *oldEventTime = [NSDate date];
    NSDate *newEventTime = [oldEventTime dateByAddingTimeInterval:20];

    __block ZMConversation *conversation;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [self createModifiedSyncMocConversationAndAddToTrackedObjectsWithID:conversationID name:name];
        conversation.lastReadServerTimeStamp = oldEventTime;
        
        ZMTransportRequest *request = [[self.sut requestGenerators] nextRequest];
        XCTAssertNotNil(request);
        
        // when
        NSMutableDictionary *responsePayload = [self responsePayloadForRenameOfConversationID:conversation.remoteIdentifier name:@"foo"];
        responsePayload[@"time"] = newEventTime.transportString;
        
        ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:responsePayload HTTPStatus:200 transportSessionError:nil];
        [request completeWithResponse:response];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        XCTAssertEqualWithAccuracy([conversation.lastReadServerTimeStamp timeIntervalSince1970], [newEventTime timeIntervalSince1970], 0.1);
    }];
}

- (void)testThatItDoesNotSetTheLastReadToTheConversationNameChangeResponseIfItIsOlder;
{
    // given
    NSString *name = @"My Conversation Name";
    NSUUID *conversationID = [NSUUID createUUID];
    
    NSDate *oldEventTime = [[NSDate date] dateByAddingTimeInterval:-30];
    NSDate *newEventTime = [NSDate date];
    
    __block ZMConversation *conversation;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [self createModifiedSyncMocConversationAndAddToTrackedObjectsWithID:conversationID name:name];
        conversation.lastReadServerTimeStamp = newEventTime;
        
        ZMTransportRequest *request = [[self.sut requestGenerators] nextRequest];
        XCTAssertNotNil(request);
        
        // when
        NSMutableDictionary *responsePayload = [self responsePayloadForRenameOfConversationID:conversation.remoteIdentifier name:@"foo"];
        responsePayload[@"time"] = oldEventTime.transportString;
        
        ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:responsePayload HTTPStatus:200 transportSessionError:nil];
        [request completeWithResponse:response];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        XCTAssertEqualObjects(conversation.lastReadServerTimeStamp, newEventTime);
    }];
}

- (void)testThatItDoesNotCreateARequestIfThereIsNoUpdatedField
{
    // given
    NSString *name = @"My Conversation Name";
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = [NSUUID createUUID]; // Otherwise we'll try to insert it
        conversation.userDefinedName = name;
        [conversation setLocallyModifiedKeys:[NSSet set]];
        [self.syncMOC saveOrRollback];
        
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:conversation]];
        }
        
        ZMTransportRequest *request = [self.sut nextRequest];
        XCTAssertNil(request);
    }];
}



- (void)testThatItRevertsToTheOriginalNameWhenARequestForChangingItTimesOut
{
    
    // given
    NSString *oldName = @"Old conversation name";
    
    NSUUID *conversationID = [NSUUID createUUID];
    
    __block ZMConversation *conversation;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [self createModifiedSyncMocConversationAndAddToTrackedObjectsWithID:conversationID name:oldName];
        
        ZMUpstreamRequest *request = [self.sut requestForUpdatingObject:conversation forKeys:[NSSet setWithObject:@"userDefinedName"]];
        XCTAssertNotNil(request);
        
        // when
        [self.sut requestExpiredForObject:conversation forKeys:request.keys];
        
        
        // then
        XCTAssertTrue(conversation.needsToBeUpdatedFromBackend);
        XCTAssertFalse([conversation.keysThatHaveLocalModifications containsObject:@"userDefinedName"]);
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
}

- (void)createConversation:(ZMConversation **)conversationPointer
                 withUser1:(ZMUser **)user1Pointer
                     user2:(ZMUser **)user2Pointer
                  selfUser:(ZMUser **)selfUserPointer {
    // given
    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    selfUser.remoteIdentifier = [NSUUID createUUID];
    
    ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
    user1.remoteIdentifier = [NSUUID createUUID];
    
    ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
    user2.remoteIdentifier = [NSUUID createUUID];
    
    ZMConversation *conversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                                  withParticipants:@[user1, user2]];
    conversation.remoteIdentifier = [NSUUID createUUID];
    
    
    [conversation
     addParticipantsAndUpdateConversationStateWithUsers:[NSSet setWithArray:@[selfUser, user1, user2]] role: nil];

    *conversationPointer = conversation;
    *user1Pointer = user1;
    *user2Pointer = user2;
    *selfUserPointer = selfUser;
}

- (void)checkConversation:(ZMConversation *)conversation
  forExpectedParticipants:(NSArray *)expectedParticipants
   unexpectedParticipants:(NSArray *)unexpectedParticipants
          failureRecorder:(ZMTFailureRecorder *)failureRecorder
{
    
    for (ZMUser *expectedUser in expectedParticipants) {
        FHAssertTrue(failureRecorder, [conversation.localParticipants containsObject:expectedUser]);
    }
    for (ZMUser *unexpectedUser in unexpectedParticipants) {
        FHAssertTrue(failureRecorder, ![conversation.localParticipants containsObject:unexpectedUser]);
    }
    XCTAssertEqual(conversation.localParticipants.count, expectedParticipants.count);
}

#pragma mark - Single request sync

- (NSDictionary *)createConversationDataWithRemoteIDString:(NSString *)remoteIDString
                                          selfUserID:(NSUUID *)selfUserID
{
    return @{
             @"name" : [NSNull null],
             @"creator" : @"3bc5750a-b965-40f8-aff2-831e9b5ac2e9",
             @"members" : @{
                     @"self" : @{
                             @"id" : selfUserID.transportString,
                             @"otr_archived_ref" : [NSNull null],
                             @"otr_archived" : [NSNull null],
                             @"otr_muted_ref" : [NSNull null],
                             @"otr_muted" : [NSNull null],
                             },
                     @"others" : @[]
                     },
             @"type" : @0,
             @"id" : remoteIDString
             };
}


- (void)setUpSyncWithConversationIDs:(NSArray *)conversationIDs
{
    ZMTransportResponse *idResponse = [ZMTransportResponse responseWithPayload:@{@"conversations" : conversationIDs } HTTPStatus:200 transportSessionError:nil];
    [self generateRequestAndCompleteWithResponse:idResponse];
}


- (void)generateRequestAndCompleteWithResponse:(ZMTransportResponse *)response
{
    [self generateRequestAndCompleteWithResponse:response checkRequest:nil];
}


- (void)generateRequestAndCompleteWithResponse:(ZMTransportResponse *)response checkRequest:(void(^)(ZMTransportRequest *))block {
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMTransportRequest *request = [self.sut nextRequest];
        XCTAssertNotNil(request);
        if (block) {
            block(request);
        }
        [request completeWithResponse:response];
    }];
}


- (NSArray *)createConversationIDArrayOfSize:(NSUInteger)size {
    NSMutableArray *conversationIDs = [NSMutableArray array];
    for (NSUInteger i=0; i < size; ++i) {
        [conversationIDs addObject:[NSUUID createUUID].transportString];
    }
    return conversationIDs;
}


- (void)checkThatThereAreConversationsForAllRawConversations:(NSArray *)rawConversations failureRecorder:(ZMTFailureRecorder *)failureRecorder
{
    [self.syncMOC performGroupedBlockAndWait:^{
        
        NSFetchRequest *conversationFetchRequest = [NSFetchRequest fetchRequestWithEntityName:ZMConversation.entityName];
        NSArray *conversations = [self.syncMOC executeFetchRequestOrAssert:conversationFetchRequest];
        
        for (NSDictionary *payload in rawConversations) {
            FHAssertTrue(failureRecorder, [conversations indexOfObjectPassingTest:^BOOL(ZMConversation *obj, NSUInteger idx ZM_UNUSED, BOOL *stop ZM_UNUSED) {
                return [self isConversation:obj matchingPayload:payload serverTimeStamp:nil];
            }] != NSNotFound);
        }
    }];
}


- (ZMTransportResponse *)createConversationResponseForRawConversations:(NSArray *)rawConversations
{
    NSDictionary *responsePayload = @{@"conversations" : rawConversations};
    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:responsePayload HTTPStatus:200 transportSessionError:nil];
    return response;
}


- (void)checkThatRequest:(ZMTransportRequest *)request isGetRequestForConversationIDs:(NSArray *)expectedConversationIDs failureRecorder:(ZMTFailureRecorder *)failureRecorder
{
    FHAssertNotNil(failureRecorder, request);
    FHAssertNotNil(failureRecorder, expectedConversationIDs);
    
    NSString *requestPath = request.path;
    NSString *expectedPrefix = CONVERSATION_ID_REQUEST_PREFIX;
    
    FHAssertTrue(failureRecorder, [request.path hasPrefix:expectedPrefix]);
    
    NSString *requestedIdentifiersString = [requestPath substringFromIndex:expectedPrefix.length];
    NSArray *requestedIdentifiers = [requestedIdentifiersString componentsSeparatedByString:@","];
    
    FHAssertEqualObjects(failureRecorder, [NSSet setWithArray:expectedConversationIDs], [NSSet setWithArray:requestedIdentifiers]);
    FHAssertEqual(failureRecorder, ZMMethodGET, request.method);
}

- (NSArray *)createRawConversationsForIds:(NSArray *)conversationIDs {
    return [conversationIDs mapWithBlock:^id(id obj) {
        return [self createConversationDataWithRemoteIDString:obj selfUserID:[self selfUserID]];
    }];
}


- (void)testThatItRequestsAllIDsWhenStartingSlowSync
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];

        // then
        NSString *expectedPath = [NSString stringWithFormat:@"/conversations/ids?size=100"];
        XCTAssertNotNil(request);
        XCTAssertTrue([request.path isEqualToString:expectedPath]);
        XCTAssertEqual(ZMMethodGET, request.method);
    }];
}


- (void)testThatItFetchesAllConversationsById
{
    __block NSArray *conversationIDs;
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        conversationIDs = [self createConversationIDArrayOfSize:20];
        [self setUpSyncWithConversationIDs:conversationIDs];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        // then
        [self checkThatRequest:request isGetRequestForConversationIDs:conversationIDs failureRecorder:NewFailureRecorder()];
    }];
}


- (void)testThatItAddsConversationsFromAResponse
{
    __block NSArray *rawConversations;
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        NSArray *conversationIDs = [self createConversationIDArrayOfSize:3];
        rawConversations = [self createRawConversationsForIds:conversationIDs];
        [self setUpSyncWithConversationIDs:conversationIDs];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
     
        // when
        ZMTransportResponse *response = [self createConversationResponseForRawConversations:rawConversations];
        [self generateRequestAndCompleteWithResponse:response];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        [self checkThatThereAreConversationsForAllRawConversations:rawConversations failureRecorder:NewFailureRecorder()];
        XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase);
    }];
}


- (void)testThatIsResets_NeedsToUpdateFromBackend_OnExistingConversationsInAResponse
{
    __block NSArray *rawConversations;
    __block NSArray *conversationIDs;
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        conversationIDs = [self createConversationIDArrayOfSize:3];
        rawConversations = [self createRawConversationsForIds:conversationIDs];
        [self setUpSyncWithConversationIDs:conversationIDs];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        ZMTransportResponse *response = [self createConversationResponseForRawConversations:rawConversations];
        [self generateRequestAndCompleteWithResponse:response checkRequest:^(ZMTransportRequest *req __unused) {
            // Artificially set the needsToUpdateFromBackend to true
            for(NSString *remoteID in conversationIDs) {
                ZMConversation * conversation = [ZMConversation fetchOrCreateWith:[NSUUID uuidWithTransportString:remoteID] domain:nil in:self.sut.managedObjectContext];
                conversation.needsToBeUpdatedFromBackend = YES;
            }
        }];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        for(NSString *remoteID in conversationIDs) {
            ZMConversation * conversation = [ZMConversation fetchOrCreateWith:[NSUUID uuidWithTransportString:remoteID] domain:nil in:self.sut.managedObjectContext];
            XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        }
    }];
}

- (void)testThatItPaginatesConversationRequests
{
    __block NSArray *allConversationIDs;
    __block ZMTransportResponse *response1;
    NSMutableArray *requestedIDs = [NSMutableArray array];
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        NSUInteger pageSize = 13;
        self.sut.conversationPageSize = pageSize;
        
        NSArray *conversationIDPage1 = [self createConversationIDArrayOfSize:pageSize];
        NSArray *rawConversations1 = [self createRawConversationsForIds:conversationIDPage1];
        response1 = [self createConversationResponseForRawConversations:rawConversations1];
        
        NSArray *conversationIDPage2 = [self createConversationIDArrayOfSize:5];
        
        allConversationIDs = [conversationIDPage1 arrayByAddingObjectsFromArray:conversationIDPage2];
        
        [self setUpSyncWithConversationIDs:allConversationIDs];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        [self generateRequestAndCompleteWithResponse:response1 checkRequest:^(ZMTransportRequest *request) {
            [self addIDsFromRequest:request toArray:requestedIDs];
        }];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        __block ZMTransportRequest *page2Request;
        [self.syncMOC performGroupedBlockAndWait:^{
            page2Request = [self.sut nextRequest];
        }];
        
        [self addIDsFromRequest:page2Request toArray:requestedIDs];
        
        // then
        XCTAssertEqual(allConversationIDs.count, requestedIDs.count);
        XCTAssertEqualObjects([NSSet setWithArray:allConversationIDs], [NSSet setWithArray:requestedIDs]);
    }];
}


- (void)addIDsFromRequest:(ZMTransportRequest *)request toArray:(NSMutableArray *)array {
    
    NSString *requestedIDs = [request.path substringFromIndex:CONVERSATION_ID_REQUEST_PREFIX.length];
    NSArray *justIDArray = [requestedIDs componentsSeparatedByString:@","];
    [array addObjectsFromArray:justIDArray];
}

- (void)testThatItDoeNotSendAnotherRequestIfItReceivedAllPages
{
    __block ZMTransportResponse *response1;
    __block ZMTransportResponse *response2;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        NSUInteger pageSize = 13;
        self.sut.conversationPageSize = pageSize;
        
        NSArray *conversationIDPage1 = [self createConversationIDArrayOfSize:pageSize];
        NSArray *rawConversations1 = [self createRawConversationsForIds:conversationIDPage1];
        response1 = [self createConversationResponseForRawConversations:rawConversations1];
        
        NSArray *conversationIDPage2 = [self createConversationIDArrayOfSize:5];
        NSArray *rawConversations2 = [self createRawConversationsForIds:conversationIDPage2];
        response2 = [self createConversationResponseForRawConversations:rawConversations2];
        
        
        NSArray *allConversationIDs = [conversationIDPage1 arrayByAddingObjectsFromArray:conversationIDPage2];
        
        [self setUpSyncWithConversationIDs:allConversationIDs];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        [self generateRequestAndCompleteWithResponse:response1];
    }];
    WaitForAllGroupsToBeEmpty(0.15);
    [self.syncMOC performGroupedBlockAndWait:^{
        [self generateRequestAndCompleteWithResponse:response2];
    }];
    WaitForAllGroupsToBeEmpty(0.15);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        ZMTransportRequest *request = [self.sut nextRequest];
        XCTAssertNil(request);
    }];
}

- (void)testThatPageSizeIsSetToDefault
{
    // then
    XCTAssertEqual(self.sut.conversationPageSize, ZMConversationTranscoderDefaultConversationPageSize);
}

- (void)testThatIsSlowSyncDoneIsTrueWhenAllConversationsAreFetched
{
    __block NSArray *rawConversations;
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        NSArray *conversationIDs = [self createConversationIDArrayOfSize:3];
        rawConversations = [self createRawConversationsForIds:conversationIDs];
        [self setUpSyncWithConversationIDs:conversationIDs];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        ZMTransportResponse *response = [self createConversationResponseForRawConversations:rawConversations];
        [self generateRequestAndCompleteWithResponse:response];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase);
    }];
}


- (void)testThatItDoesNotCreateANewRequestWhileARequestIsAlreadyInProgress
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        ZMTransportRequest *firstRequest = [self.sut nextRequest];
        XCTAssertNotNil(firstRequest);
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        // then
        XCTAssertNil(request);
    }];
}


- (void)testThatItDoesNotFetchConversationsIfThereIsNothingToFetch
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        [self setUpSyncWithConversationIDs:@[]];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        // then
        XCTAssertNil(request);
        XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase);
    }];
}


- (void)testThatItDoesNotGenerateConversationsDuringSlowSync
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMConversation *insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                                              withParticipants:@[user1, user2]];
        NOT_USED(insertedConversation);
        
        
        // - this is the hard sync request
        ZMTransportRequest *request1 = [self.sut nextRequest];
        XCTAssertNotNil(request1);
        NSString *expectedPath = @"/conversations/ids?size=100";
        XCTAssertEqualObjects(expectedPath, request1.path);
        XCTAssertEqual(ZMMethodGET, request1.method);
        
        // when
        ZMTransportRequest *request2 = [self.sut nextRequest];
        
        // then
        XCTAssertNil(request2);
    }];
}

- (void)testThatItGeneratesRequestsAfterSlowSyncIsDone
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMConversation *insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                                              withParticipants:@[user1, user2]];
        [self.syncMOC saveOrRollback];
        // expect
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        // - this is the hard sync request
        ZMTransportRequest *request1 = [self.sut nextRequest];
        XCTAssertNotNil(request1);
        NSString *expectedPath = @"/conversations/ids?size=100";
        XCTAssertEqualObjects(expectedPath, request1.path);
        XCTAssertEqual(ZMMethodGET, request1.method);
        
        
        [request1 completeWithResponse:[ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil]];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        self.mockSyncStatus.mockPhase = SyncPhaseDone;
        ZMTransportRequest *request2 = [self.sut nextRequest];
        
        // then
        XCTAssertNotNil(request2);
        
        XCTAssertEqualObjects(@"/conversations", request2.path);
        XCTAssertEqual(ZMMethodPOST, request2.method);
    }];
}

- (void)testThatItMarksInactiveConversationsToBeUpdatedFromBackend_WhenSlowSyncIsDone
{
    __block ZMConversation *conversation1;
    __block ZMConversation *conversation2;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        conversation1 = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2]];
        conversation1.remoteIdentifier = [NSUUID createUUID];
        
        conversation2 = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2]];
        conversation2.remoteIdentifier = [NSUUID createUUID];
        
        [self.syncMOC saveOrRollback];
        
        [self setUpSyncWithConversationIDs:@[conversation1.remoteIdentifier.transportString]];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        NSArray *rawConversations = [self createRawConversationsForIds:@[conversation1.remoteIdentifier.transportString]];
        ZMTransportResponse *response = [self createConversationResponseForRawConversations:rawConversations];
        [request completeWithResponse:response];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertFalse(conversation1.needsToBeUpdatedFromBackend);
    XCTAssertTrue(conversation2.needsToBeUpdatedFromBackend);
}

#pragma mark -  InsertNewConversation)

- (void)testThatItGeneratesARequestToGenerateAConversation
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user3 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user3.remoteIdentifier = [NSUUID createUUID];
        
        ZMConversation *insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[
                                                                                                                                             user1, user2, user3
                                                                                                                                             ]];
        XCTAssertTrue([self.syncMOC saveOrRollback]);
        
        
        // expect
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        
        // then
        XCTAssertEqualObjects(@"/conversations", request.path);
        XCTAssertEqual(ZMMethodPOST, request.method);
        
        NSSet *expectedUsers = [NSSet setWithArray:@[
                                                     [user1.remoteIdentifier transportString],
                                                     [user2.remoteIdentifier transportString],
                                                     [user3.remoteIdentifier transportString]
                                                     ]];
        XCTAssertEqualObjects([NSSet setWithArray:request.payload.asDictionary[@"users"]], expectedUsers);
        XCTAssertEqualObjects(request.payload.asDictionary[@"conversation_role"], ZMConversation.defaultMemberRoleName);
    }];
}

- (void)testThatItGeneratesARequestToGenerateAConversationWithAName
{
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        NSString *name = @"Foo foo conversation";
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user3 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user3.remoteIdentifier = [NSUUID createUUID];

        NSArray <ZMUser *> *users = @[user1, user2, user3];
        
        ZMConversation *insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:users];
        insertedConversation.userDefinedName = name;
        XCTAssertTrue([self.syncMOC saveOrRollback]);
        
        // expect
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        
        // then
        XCTAssertEqualObjects(@"/conversations", request.path);
        XCTAssertEqual(ZMMethodPOST, request.method);

        NSSet *expectedUsers = [users mapWithBlock:^NSString *(ZMUser *user) { return user.remoteIdentifier.transportString; }].set;
        XCTAssertEqualObjects([NSSet setWithArray:request.payload.asDictionary[@"users"]], expectedUsers);
        XCTAssertEqualObjects(request.payload.asDictionary[@"name"], name);
    }];
}

- (void)testThatItGeneratesARequestToGenerateAConversationWithATeam
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];

        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];

        NSArray <ZMUser *> *users = @[user1, user2];

        // when
        ZMTransportRequest *request = [self requestForConversationCreationWithTeamAndUsers:users modifier:nil];

        // then
        XCTAssertEqualObjects(@"/conversations", request.path);
        XCTAssertEqual(ZMMethodPOST, request.method);

        NSSet *expected = [users mapWithBlock:^NSString *(ZMUser *user) { return user.remoteIdentifier.transportString; }].set;
        XCTAssertEqualObjects([NSSet setWithArray:request.payload.asDictionary[@"users"]], expected);
        NSDictionary *teamPayload = request.payload.asDictionary[@"team"];
        Team *team = [ZMUser selfUserInContext:self.syncMOC].team;
        XCTAssertNotNil(team);
        XCTAssertEqualObjects(teamPayload[@"teamid"], team.remoteIdentifier.transportString);
        XCTAssertEqualObjects(teamPayload[@"managed"], @NO);
    }];
}

- (void)testThatItGeneratesARequestToGenerateAConversationWithATeamAndName
{
    // given
    NSString *name = @"Wire";
    ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
    user1.remoteIdentifier = [NSUUID createUUID];
    ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
    user2.remoteIdentifier = [NSUUID createUUID];
    NSArray <ZMUser *> *users = @[user1, user2];

    // when
    ZMTransportRequest *request =  [self requestForConversationCreationWithTeamAndUsers:users modifier:^(ZMConversation *conversation) {
        conversation.userDefinedName = name;
    }];

    // then
    XCTAssertEqualObjects(@"/conversations", request.path);
    XCTAssertEqual(ZMMethodPOST, request.method);

    NSSet *expected = [users mapWithBlock:^NSString *(ZMUser *user) { return user.remoteIdentifier.transportString; }].set;
    XCTAssertEqualObjects([NSSet setWithArray:request.payload.asDictionary[@"users"]], expected);
    XCTAssertEqualObjects(request.payload.asDictionary[@"name"], name);
    NSDictionary *teamPayload = request.payload.asDictionary[@"team"];
    Team *team = [ZMUser selfUserInContext:self.syncMOC].team;
    XCTAssertNotNil(team);

    XCTAssertEqualObjects(teamPayload[@"teamid"], team.remoteIdentifier.transportString);
    XCTAssertEqualObjects(teamPayload[@"managed"], @NO);
}

- (ZMTransportRequest *)requestForConversationCreationWithTeamAndUsers:(NSArray <ZMUser *> *)users modifier:(void (^)(ZMConversation *conversation))modifier
{
    __block ZMTransportRequest *request;

    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        Team *team = [Team insertNewObjectInManagedObjectContext:self.syncMOC];
        team.remoteIdentifier = NSUUID.createUUID;
        Member *member = [Member getOrCreateMemberForUser:[ZMUser selfUserInContext:self.syncMOC] inTeam:team context:self.syncMOC];
        [member setTeamRole:TeamRoleMember];
        NOT_USED(member);
        ZMConversation *insertedConversation =
            [ZMConversation insertGroupConversationWithMoc:self.syncMOC
                                              participants:users
                                                      name:nil
                                                      team:team
                                               allowGuests:YES
                                              readReceipts:NO
                                          participantsRole:nil];
        if (modifier) {
            modifier(insertedConversation);
        }

        XCTAssertTrue([self.syncMOC saveOrRollback]);

        // expect
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }

        // then
        request = [self.sut nextRequest];
    }];
    
    return request;
}

- (void)testThatModifedSyncIsUpdatedWhenConversationTranscoderShouldNotCreateRequest;
{
    __block ZMConversation *conversation = nil;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        conversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2]];
        conversation.userDefinedName = nil;
        [conversation setLocallyModifiedKeys:[NSSet setWithObject:ZMConversationUserDefinedNameKey]];
        XCTAssertTrue([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMUpstreamModifiedObjectSync *mockUpstream = [OCMockObject niceMockForClass:ZMUpstreamModifiedObjectSync.class];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        XCTAssertTrue([conversation.keysThatHaveLocalModifications containsObject:ZMConversationUserDefinedNameKey]);

        [self.sut shouldCreateRequestToSyncObject:conversation forKeys:[NSSet set] withSync:mockUpstream];
        
        XCTAssertFalse([conversation.keysThatHaveLocalModifications containsObject:ZMConversationUserDefinedNameKey]);
    }];
}

- (void)checkThatItResetsLocallyModifiedKeysIfNeededBeforeCreatingRequestForKey:(NSString *)key shouldCreateRequest:(BOOL)shouldCreateRequest withBlock:(void(^)(ZMConversation *conversation, NSArray<ZMUser *> *users))block
{
    __block ZMConversation *conversation = nil;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        conversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2]];

        block(conversation, @[user1, user2]);
        XCTAssertTrue([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMUpstreamModifiedObjectSync *mockUpstream = [OCMockObject niceMockForClass:ZMUpstreamModifiedObjectSync.class];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        [conversation setLocallyModifiedKeys:[NSSet setWithObject:key]];
        XCTAssertTrue([conversation.keysThatHaveLocalModifications containsObject:key]);
        
        BOOL willCreate = [self.sut shouldCreateRequestToSyncObject:conversation forKeys:[NSSet setWithObject:key] withSync:mockUpstream];
        if (!shouldCreateRequest) {
            XCTAssertFalse([conversation.keysThatHaveLocalModifications containsObject:key]);
            XCTAssertFalse(willCreate);

        } else {
            XCTAssertTrue([conversation.keysThatHaveLocalModifications containsObject:key]);
            XCTAssertTrue(willCreate);
        }
    }];
}

- (void)testThatItResetsUserDefinedNameKeyIfTranscoderShould_Not_CreateRequest;
{
    [self checkThatItResetsLocallyModifiedKeysIfNeededBeforeCreatingRequestForKey:ZMConversationUserDefinedNameKey shouldCreateRequest:NO withBlock:^(ZMConversation *conversation, id ZM_UNUSED users){
        conversation.userDefinedName = nil;
    }];
}

- (void)testThatItOnlyResetsTheKeysItNeedsToReset
{
    NSSet *keys = [NSSet setWithObjects:ZMConversationUserDefinedNameKey, ZMConversationArchivedChangedTimeStampKey, nil];
    __block ZMConversation *conversation = nil;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        conversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2, selfUser]];
        conversation.userDefinedName = nil;
        conversation.isArchived = YES;
        XCTAssertTrue([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMUpstreamModifiedObjectSync *mockUpstream = [OCMockObject niceMockForClass:ZMUpstreamModifiedObjectSync.class];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        [conversation setLocallyModifiedKeys:keys];
        XCTAssertTrue([conversation.keysThatHaveLocalModifications isEqualToSet:keys]);
        BOOL shouldCreate = [self.sut shouldCreateRequestToSyncObject:conversation forKeys:keys withSync:mockUpstream];
        
        // then
        XCTAssertFalse([conversation.keysThatHaveLocalModifications containsObject:ZMConversationUserDefinedNameKey]);
        XCTAssertTrue([conversation.keysThatHaveLocalModifications containsObject:ZMConversationArchivedChangedTimeStampKey]);
        XCTAssertTrue(shouldCreate);
    }];
}


- (void)testThatItDoesNotGeneratesTheSameConversationTwice
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMConversation *insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                                              withParticipants:@[user1, user2]];
        insertedConversation.userDefinedName = @"Test conversation 1";
        
        [self.syncMOC saveOrRollback];
        // expect
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        // when
        ZMTransportRequest *request1 = [self.sut nextRequest];
        XCTAssertNotNil(request1);
        ZMTransportRequest *request2 = [self.sut nextRequest];
        
        // then
        XCTAssertNil(request2);
    }];
}


- (void)testThatItUpdatesANewlyInsertedConversationWithTheResponsePayload
{
    // given
    
    __block ZMConversation *insertedConversation;
    __block ZMTransportRequest *request;
    
    NSUUID *convUUID =[NSUUID createUUID];
    NSString *name = @"Procrastination";
    
    
    [self.syncMOC performGroupedBlockThenWaitForReasonableTimeout:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        NSUUID *user1ID = user1.remoteIdentifier;
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        NSUUID *user2ID = user2.remoteIdentifier;
        
        insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                              withParticipants:@[user1, user2]];
        
        
        
        NSDictionary *payload =  @{
                                   @"creator" : user1ID.transportString,
                                   @"id" : convUUID.transportString,
                                   @"members" : @{
                                           @"others" : @[
                                                   @{
                                                       @"id" : user1ID.transportString
                                                       },
                                                   @{
                                                       @"id" : user2ID.transportString
                                                       },
                                                   ],
                                           @"self" : @{
                                                   @"id" : @"90c74fe0-cef7-446a-affb-6cba0e75d5da"
                                                   },
                                           },
                                   @"name" : name,
                                   @"type" : @0
                                   };
        
        [self.syncMOC saveOrRollback];
        
        // when
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        
        request = [self.sut nextRequest];
        [request completeWithResponse:[ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil]];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqualObjects(convUUID, insertedConversation.remoteIdentifier);
        XCTAssertEqualObjects(name, insertedConversation.userDefinedName);
        XCTAssert([insertedConversation needsToDownloadRoles]);
    }];
}

- (void)testThatItDoesNotUpdateLastModifiedDateIfItsPriorCurrentValue
{
    __block ZMConversation *insertedConversation;
    __block ZMTransportRequest *request;

    NSUUID *convUUID =[NSUUID createUUID];
    NSString *name = @"Procrastination";
    
    __block NSDate *currentLastModified;
    
    [self.syncMOC performGroupedBlockThenWaitForReasonableTimeout:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        NSUUID *user1ID = user1.remoteIdentifier;
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        NSUUID *user2ID = user2.remoteIdentifier;
        
        insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                              withParticipants:@[user1, user2]];
        
        currentLastModified = insertedConversation.lastModifiedDate;
        
        NSDictionary *payload =  @{
                                   @"creator" : user1ID.transportString,
                                   @"id" : convUUID.transportString,
                                   @"members" : @{
                                           @"others" : @[
                                                   @{
                                                       @"id" : user1ID.transportString
                                                       },
                                                   @{
                                                       @"id" : user2ID.transportString
                                                       },
                                                   ],
                                           @"self" : @{
                                                   @"id" : @"90c74fe0-cef7-446a-affb-6cba0e75d5da"
                                                   },
                                           },
                                   @"name" : name,
                                   @"type" : @0
                                   };
        
        [self.syncMOC saveOrRollback];
        
        // when
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        
        request = [self.sut nextRequest];
        [request completeWithResponse:[ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil]];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqualObjects(currentLastModified, insertedConversation.lastModifiedDate);
    }];

}

- (void)testThatANewConversationIsDeletedOnBackendError
{
    // given
    __block ZMTransportRequest *request;
    [self.syncMOC performGroupedBlockThenWaitForReasonableTimeout:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMConversation *insertedConversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC
                                                                                              withParticipants:@[user1, user2]];
        [self.syncMOC saveOrRollback];
        
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:insertedConversation]];
        }
        
        request = [self.sut nextRequest];
    }];
    
    // when
    [request completeWithResponse:[ZMTransportResponse responseWithPayload:nil HTTPStatus:430 transportSessionError:nil]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockThenWaitForReasonableTimeout:^{
        [self.syncMOC saveOrRollback];
    }];
    
    // then
    NSFetchRequest *convFetchRequest = [ZMConversation sortedFetchRequest];
    NSArray *conversations = [self.uiMOC executeFetchRequestOrAssert:convFetchRequest];
    XCTAssertEqual(0u, conversations.count);
}


- (void)testThatWhenCreatedItGeneratesRequestForConversationMissingRemoteIdentifier
{
    // given
    
    __block ZMUser *user1;
    __block ZMUser *user2;
    [self.syncMOC performGroupedBlockAndWait:^{
        user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        (void)[ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2]];
        XCTAssertTrue([self.syncMOC saveOrRollback]);
    }];
    
    self.sut = (id) [[ZMConversationTranscoder alloc] initWithManagedObjectContext:self.syncMOC applicationStatus:self.mockApplicationStatus syncStatus:self.mockSyncStatus];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [ZMChangeTrackerBootstrap bootStrapChangeTrackers:self.sut.contextChangeTrackers onContext:self.syncMOC];
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        ZMTransportRequest *request = [self.sut nextRequest];
        
        // then
        XCTAssertEqualObjects(@"/conversations", request.path);
        XCTAssertEqual(ZMMethodPOST, request.method);
        
        NSSet *expectedUsers = [NSSet setWithArray:@[
                                                     [user1.remoteIdentifier transportString],
                                                     [user2.remoteIdentifier transportString],
                                                     ]];
        XCTAssertEqualObjects([NSSet setWithArray:request.payload.asDictionary[@"users"]], expectedUsers);
    }];
}


- (void)testThatItWhenTheCreationRequestReturnsAnyAlreadyExistingConversationIsDeletedAndTheNewOneIsMarkedToDownload
{
    // this can happen if we received a push event notification before we received the conversation creation roundtrip
    
    // given
    NSUUID *remoteID = [NSUUID createUUID];
    __block ZMConversation *createdConversation;
    __block ZMConversation *existingConversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        
        existingConversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        existingConversation.remoteIdentifier = remoteID;
        existingConversation.conversationType = ZMConversationTypeGroup;
        createdConversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        createdConversation.conversationType = ZMConversationTypeGroup;
        [self.syncMOC saveOrRollback];
        
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:createdConversation]];
        }
        
        
        NSDictionary *responsePayload = @{
                                          @"creator" : @"39562cc3-717d-4395-979c-5387ae17f5c3",
                                          @"id" : remoteID.transportString,
                                          @"members" : @{
                                                  @"others" : @[],
                                                  @"self" : @{}
                                                  },
                                          @"name" : [NSNull null],
                                          @"type" : @(ZMConversationTypeGroup)
                                          };
        
        // when
        
        
        ZMTransportRequest *request = [self.sut nextRequest];
        XCTAssertNotNil(request);
        
        ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:responsePayload HTTPStatus:200 transportSessionError:nil];
        [request completeWithResponse:response];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        
        NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:[ZMConversation entityName]];
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"remoteIdentifier_data == %@", remoteID.data];
        NSArray *result = [self.syncMOC executeFetchRequestOrAssert:fetchRequest];
        
        XCTAssertEqual(result.count, 1u);
        
        XCTAssertEqual(createdConversation, result[0]);
        XCTAssertTrue(existingConversation.isDeleted || existingConversation.managedObjectContext == nil);
        XCTAssertTrue(createdConversation.needsToBeUpdatedFromBackend);
        
    }];
}

- (void)testThatItDoesNotAppendsYouStartedUsingANewDeviceIfRegisteredDevice {
    
    // given

    UserClient *selfClient = [self createSelfClient];
    
    __block NSDictionary *rawConversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        NSArray *conversationIDs = [self createConversationIDArrayOfSize:1];
        rawConversation = [self createRawConversationsForIds:conversationIDs][0];
        [self setUpSyncWithConversationIDs:conversationIDs];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        ZMTransportResponse *response = [self createConversationResponseForRawConversations:@[rawConversation]];
        [self generateRequestAndCompleteWithResponse:response];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then

    ZMConversation *conv = [ZMConversation fetchWith:[NSUUID uuidWithTransportString:rawConversation[@"id"]] in:self.syncMOC];
    
    NSArray *messages = [[conv lastMessagesWithLimit:50] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ZMMessage * _Nonnull evaluatedObject, NSDictionary<NSString *,id> * _Nullable ZM_UNUSED bindings) {
        return [evaluatedObject isKindOfClass:[ZMSystemMessage class]] && [(ZMSystemMessage *)evaluatedObject systemMessageType] == ZMSystemMessageTypeNewClient && [[(ZMSystemMessage *)evaluatedObject clients] containsObject:(id<UserClientType>)selfClient];
    }]];
    
    XCTAssertEqual(messages.count, 0u);
}

- (void)testThatItDoesAppendsNewConversationSystemMessage
{
    // given
    self.sut = (id) [[ZMConversationTranscoder alloc] initWithManagedObjectContext:self.syncMOC applicationStatus:self.mockApplicationStatus syncStatus:self.mockSyncStatus];
    
    __block NSDictionary *rawConversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        self.mockSyncStatus.mockPhase = SyncPhaseFetchingConversations;
        
        NSArray *conversationIDs = [self createConversationIDArrayOfSize:1];
        rawConversation = [self createRawConversationsForIds:conversationIDs][0];
        [self setUpSyncWithConversationIDs:conversationIDs];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        ZMTransportResponse *response = [self createConversationResponseForRawConversations:@[rawConversation]];
        [self generateRequestAndCompleteWithResponse:response];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    ZMConversation *conv = [ZMConversation fetchWith:[NSUUID uuidWithTransportString:rawConversation[@"id"]] in:self.syncMOC];
    
    NSArray *messages = [[conv lastMessagesWithLimit:50] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ZMMessage * _Nonnull evaluatedObject, NSDictionary<NSString *,id> * _Nullable ZM_UNUSED bindings) {
        return [evaluatedObject isKindOfClass:[ZMSystemMessage class]] && [(ZMSystemMessage *)evaluatedObject systemMessageType] == ZMSystemMessageTypeNewConversation;
    }]];
    
    XCTAssertEqual(messages.count, 1u);
}

#pragma mark -  Participants

- (void)testThatItRemovesUsersFromAConversationAfterAPushEvent
{
    // given
    NSUUID* conversationID = [NSUUID createUUID];
    
    __block ZMConversation *conversation;
    __block NSUUID* userID;
    __block ZMUser *nonRemovedUser;
    __block ZMUser *removedUser;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        removedUser = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        removedUser.remoteIdentifier = [NSUUID createUUID];
        userID = removedUser.remoteIdentifier;
        
        nonRemovedUser = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        nonRemovedUser.remoteIdentifier = [NSUUID createUUID];
        
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeGroup;
        conversation.remoteIdentifier = conversationID;
        [conversation addParticipantsAndUpdateConversationStateWithUsers:[NSSet setWithArray:@[removedUser, nonRemovedUser]] role:nil];
        
        XCTAssertEqual(conversation.localParticipants.count, 2u);
    }];
    
    NSDictionary *payload = [self responsePayloadForUserEventInConversationID:conversationID userIDs:@[userID] eventType:@"conversation.member-leave"];
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.sut processEvents:@[[ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil]] liveEvents:YES prefetchResult:nil];
    }];
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqual(conversation.localParticipants.count, 1u);
        XCTAssertEqualObjects(conversation.localParticipants.anyObject, nonRemovedUser);
        
    }];
}


- (void)testThatItDoesNotArchiveAConversationAfterAPushEventWhenTheSelfUserIsRemovedByAnotherUser
{
    // given
    NSUUID* conversationID = [NSUUID createUUID];
    NSDate *lastModifiedDate = [NSDate dateWithTimeIntervalSinceNow:-1000];
    
    __block ZMConversation *conversation;
    __block NSUUID* otherUserID;
    __block ZMUser *otherUser;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        otherUserID = [NSUUID createUUID];
        otherUser = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        otherUser.remoteIdentifier = otherUserID;
        
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        [conversation addParticipantAndUpdateConversationStateWithUser:[ZMUser selfUserInContext:self.syncMOC] role:nil];
        conversation.conversationType = ZMConversationTypeGroup;
        conversation.remoteIdentifier = conversationID;
        conversation.lastModifiedDate = lastModifiedDate;
        [self.syncMOC saveOrRollback];
        
        XCTAssertTrue(conversation.isSelfAnActiveMember);
        XCTAssertFalse(conversation.isArchived);
    }];
    
    NSDictionary *payload = [self responsePayloadForUserEventInConversationID:conversationID lastTimeStamp:[NSDate date] userIDs:@[self.selfUserID] from:otherUserID eventType:@"conversation.member-leave"];
    
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.sut processEvents:@[[ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil]] liveEvents:YES prefetchResult:nil];
    }];
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertFalse(conversation.isSelfAnActiveMember);
        XCTAssertFalse(conversation.isArchived);
    }];
}

- (void)testThatItAddsUsersToAConversationAfterAPushEvent
{
    // given
    __block ZMConversation *conversation;
    NSUUID* conversationID = [NSUUID createUUID];
    NSUUID* userID = [NSUUID createUUID];
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeGroup;
        conversation.remoteIdentifier = conversationID;
        [conversation addParticipantsAndUpdateConversationStateWithUsers:[NSSet setWithArray:@[user1, user2]] role:nil];
        
        XCTAssertEqual(conversation.localParticipants.count, 2u);
        
        NSDictionary *payload = [self responsePayloadForUserEventInConversationID:conversationID userIDs:@[userID] eventType:@"conversation.member-join"];
        
        // when
        [self.sut processEvents:@[[ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil]] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertEqual(conversation.localParticipants.count, 3u);
    }];
}

- (void)testThatItMarksTheConversationAsNeedingToBeUpdatedWhenTheSelfUserIsAdded
{
    [self.syncMOC performBlockAndWait:^{
        // given
        
        // A conversation that we were previously in:
        NSUUID *conversationID = [NSUUID createUUID];
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        selfUser.remoteIdentifier = self.selfUserID;
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        
        ZMUser *user3 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user3.remoteIdentifier = [NSUUID createUUID];
        
        ZMConversation *conversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2, user3]];
        conversation.remoteIdentifier = conversationID;
        [conversation removeParticipantAndUpdateConversationStateWithUser:selfUser initiatingUser:selfUser];
        
        [conversation resetLocallyModifiedKeys:conversation.keysThatHaveLocalModifications];
        XCTAssert([self.syncMOC save:nil]);
        
        // when
        for (id<ZMContextChangeTracker> t in self.sut.contextChangeTrackers) {
            [t objectsDidChange:[NSSet setWithObject:conversation]];
        }
        ZMTransportRequest *request = [self.sut nextRequest];
        
        // then
        XCTAssertNil(request);
        
        // and when (2)
        
        NSDictionary *payload = [self responsePayloadForUserEventInConversationID:conversationID userIDs:@[self.selfUserID] eventType:@"conversation.member-join"];
        NSDictionary *joinPayload = @{@"id": NSUUID.createUUID.transportString,
                                      @"payload": @[payload]};
        NSArray *events = [ZMUpdateEvent eventsArrayFromPushChannelData:joinPayload];
        for (ZMUpdateEvent *e in events) {
            [self.sut processEvents:@[e] liveEvents:YES prefetchResult:nil];
        }
        
        // then
        XCTAssertTrue(conversation.isSelfAnActiveMember);
        XCTAssertTrue(conversation.needsToBeUpdatedFromBackend);
        ZMTransportRequest *request2 = [self.sut nextRequest];
        XCTAssertNil(request2);
    }];
}

- (void)testThatAConversationIsMarkedAsNeedToBeUpdatedIfItFailedToUpload
{
    [self.syncMOC performBlockAndWait:^{
        // given
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
       
        // when
        ZMManagedObject *object = [self.sut objectToRefetchForFailedUpdateOfObject:conversation];
        
        // then
        XCTAssertEqual(object, conversation);
    }];
}

- (void)testThatItProcessesMemberJoinEventForSelfUser
{
    self.sut = (id) [[ZMConversationTranscoder alloc] initWithManagedObjectContext:self.syncMOC applicationStatus:self.mockApplicationStatus syncStatus:self.mockSyncStatus];
    
    NSUUID *conversationID = [NSUUID createUUID];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        [ZMUser selfUserInContext:self.syncMOC].remoteIdentifier = self.selfUserID;
        [ZMUser selfUserInContext:self.syncMOC].name = @"Me, myself";
    
        // when
        NSDictionary *eventPayload = [self responsePayloadForUserEventInConversationID:conversationID userIDs:@[self.selfUserID] eventType:@"conversation.member-join"];
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        ZMConversation *createdConversation = [ZMConversation fetchWith:conversationID in:self.syncMOC];
        XCTAssertNotNil(createdConversation);
        XCTAssertTrue(createdConversation.isSelfAnActiveMember);
        
        // this is the member join system message
        XCTAssertEqual(createdConversation.allMessages.count, 1u);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
}

#pragma mark - SilencedAndArchived

- (void)testThatItSendsARequestWhenConversationIsSilenced
{
    [self checkThatItSendsARequestForIsSilenced:YES];
}

- (void)testThatItSendsARequestWhenConversationIsUnsilenced
{
    [self checkThatItSendsARequestForIsSilenced:NO];
}

- (void)checkThatItSendsARequestForIsSilenced:(BOOL)isSilenced
{
    // given
    NSString *modifiedKey = ZMConversationSilencedChangedTimeStampKey;
    NSSet *keys = [NSSet setWithObject:modifiedKey];

    ZMConversation *conversation =  [self setupConversation];
    conversation.isFullyMuted = isSilenced;
    [self.uiMOC saveOrRollback];
    XCTAssertEqualObjects(conversation.keysThatHaveLocalModifications, keys);

    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:@{} HTTPStatus:200 transportSessionError:nil];
    ZMTransportRequest *request = [self requestToSyncConversation:conversation andCompleteWithResponse:response];

    [self.syncMOC performGroupedBlockAndWait:^{
        [self.syncMOC saveOrRollback];

        ZMConversation *syncConv = (id)[self.syncMOC objectWithID:conversation.objectID];

        // then
        XCTAssertEqual(request.method, ZMMethodPUT);
        NSString *expectedPath = [NSString pathWithComponents:@[ @"/", @"conversations", conversation.remoteIdentifier.transportString, @"self" ]];
        XCTAssertEqualObjects(request.path, expectedPath);
        NSDictionary *expected = @{ @"otr_muted": @(isSilenced),
                                    @"otr_muted_status": @(isSilenced ? 3 : 0),
                                    @"otr_muted_ref": syncConv.silencedChangedTimestamp.transportString
                                    };
        XCTAssertEqualObjects(request.payload, expected);

        XCTAssertFalse([syncConv.keysThatHaveLocalModifications containsObject:modifiedKey]);
    }];
}

- (void)testThatItSendsARequestWhenConversationIsArchived
{
    [self checkThatItSendsARequestForIsArchived:YES];
}

- (void)testThatItSendsARequestWhenConversationIsUnarchived
{
    [self checkThatItSendsARequestForIsArchived:NO];
}

- (void)checkThatItSendsARequestForIsArchived:(BOOL)isArchived
{
    // given
    NSString *modifiedKey = ZMConversationArchivedChangedTimeStampKey;
    NSSet *keys = [NSSet setWithObject:modifiedKey];
    
    ZMConversation *conversation = [self setupConversation];

    // when
    conversation.isArchived = isArchived;
    [self.uiMOC saveOrRollback];
    
    XCTAssertEqualObjects(conversation.keysThatHaveLocalModifications, keys);
    
    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil];
    ZMTransportRequest *request = [self requestToSyncConversation:conversation andCompleteWithResponse:response];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.syncMOC saveOrRollback];
        
        ZMConversation *syncConv = [(id)self.syncMOC objectWithID:conversation.objectID];
        // then
        XCTAssertEqual(request.method, ZMMethodPUT);
        NSString *expectedPath = [NSString pathWithComponents:@[ @"/", @"conversations", conversation.remoteIdentifier.transportString, @"self" ]];
        XCTAssertEqualObjects(request.path, expectedPath);
        
        NSDictionary *expected = @{ @"otr_archived_ref": syncConv.lastServerTimeStamp.transportString,
                                    @"otr_archived" : @(isArchived)};
        XCTAssertEqualObjects(request.payload, expected);
        
        XCTAssertFalse([syncConv.keysThatHaveLocalModifications containsObject:modifiedKey]);
    }];
}

- (void)testThatItCombinesUpdatesForMuteAndArchive
{
    // given
    NSString *modifiedKey1 = ZMConversationArchivedChangedTimeStampKey;
    NSString *modifiedKey2 = ZMConversationSilencedChangedTimeStampKey;
    __block ZMConversation *syncConv;
    __block ZMTransportResponse *response;
    __block ZMTransportRequest *request;
    __block ZMTransportRequest *request2;


    ZMConversation *conversation = [self setupConversation];
    conversation.isArchived = YES;
    conversation.isFullyMuted = YES;
    [self.uiMOC saveOrRollback];

    [self.syncMOC performBlockAndWait:^{
        syncConv = (id)[self.syncMOC objectWithID:conversation.objectID];
        XCTAssertTrue([syncConv.keysThatHaveLocalModifications containsObject:modifiedKey1]);
        XCTAssertTrue([syncConv.keysThatHaveLocalModifications containsObject:modifiedKey2]);

        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:syncConv]];
        }

        request = [self.sut nextRequest];
        XCTAssertNotNil(request);

        request2 = [self.sut nextRequest];

        // when
        response = [ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil];
        [request completeWithResponse:response];
    }];

    WaitForAllGroupsToBeEmpty(0.5);
    [self.syncMOC performGroupedBlockAndWait:^{

        // then
        XCTAssertEqual(request.method, ZMMethodPUT);
        NSString *expectedPath = [NSString pathWithComponents:@[ @"/", @"conversations", conversation.remoteIdentifier.transportString, @"self" ]];
        XCTAssertEqualObjects(request.path, expectedPath);
        XCTAssertEqualObjects(request.payload, (@{
                                                  @"otr_archived_ref": [conversation.lastServerTimeStamp transportString],
                                                  @"otr_archived": @YES,
                                                  @"otr_muted_status": @(3),
                                                  @"otr_muted_ref": [conversation.lastServerTimeStamp transportString],
                                                  @"otr_muted": @YES,
                                                  }));

        XCTAssertFalse([syncConv.keysThatHaveLocalModifications containsObject:modifiedKey1]);
        XCTAssertFalse([syncConv.keysThatHaveLocalModifications containsObject:modifiedKey2]);

        XCTAssertNil(request2);
    }];
}

- (void)checkThatItProcessesUpdateEventForIsSilencedBefore:(BOOL)isSilencedBefore
                                           isSilencedAfter:(BOOL)isSilencedAfter
                                                      data:(NSDictionary *)data
{
    // given
    __block ZMConversation *conversation;
    NSUUID* conversationID = [NSUUID createUUID];

    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = conversationID;
        conversation.isFullyMuted = isSilencedBefore;
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        NSMutableDictionary *dataWithSelf = [data mutableCopy];
        dataWithSelf[@"target"] = selfUser.remoteIdentifier.transportString;
        NSDictionary *payload = @{
                                  @"conversation" : conversation.remoteIdentifier.transportString,
                                  @"data" : dataWithSelf,
                                  @"from" : @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                                  @"time" : @"2014-08-07T13:19:42.394Z",
                                  @"type" : @"conversation.member-update",
                                  };

        ZMUpdateEvent *updateEvent = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
        XCTAssertNotNil(updateEvent);

        // when
        [self.sut processEvents:@[updateEvent] liveEvents:YES prefetchResult:nil];

        // then
        XCTAssertEqual(conversation.isFullyMuted, isSilencedAfter);
    }];
}

- (void)testThatItDoesNotSetIsSilencedFromNonOTRPayload
{
    [self checkThatItProcessesUpdateEventForIsSilencedBefore:NO isSilencedAfter:NO data:@{
                                                                                           @"muted" : @YES
                                                                                           }];
}

- (void)testThatItDoesNotUpdateIsSilencedIfItIsNotInThePayload
{
    [self checkThatItProcessesUpdateEventForIsSilencedBefore:YES isSilencedAfter:YES data:@{}];
}

- (ZMConversation *)checkThatItProcessesUpdateEventForIsArchivedBefore:(BOOL)isArchivedBefore
                                                       isArchivedAfter:(BOOL)isArchivedAfter
                                                                  data:(NSDictionary *)data
{
    // given
    __block ZMConversation *conversation;
    NSUUID* conversationID = [NSUUID createUUID];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        NSMutableDictionary *dataWithSelf = [data mutableCopy];
        dataWithSelf[@"target"] = selfUser.remoteIdentifier.transportString;
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        [conversation addParticipantAndUpdateConversationStateWithUser:selfUser role:nil];
        conversation.remoteIdentifier = conversationID;
        conversation.isArchived = isArchivedBefore;
        
        NSDictionary *payload = @{
                                  @"conversation" : conversation.remoteIdentifier.transportString,
                                  @"data" : dataWithSelf,
                                  @"from" : @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                                  @"time" : @"2014-08-07T13:19:42.394Z",
                                  @"type" : @"conversation.member-update",
                                  };
        
        ZMUpdateEvent *updateEvent = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
        XCTAssertNotNil(updateEvent);
        
        // when
        [self.sut processEvents:@[updateEvent] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertEqual(conversation.isArchived, isArchivedAfter);
    }];
    
    return conversation;
}


- (void)testThatItSetsIsArchivedAndArchivedChangedTimestampFromPayload
{
    NSDate *archivedDate = [NSDate date];
    ZMConversation *conversation = [self checkThatItProcessesUpdateEventForIsArchivedBefore:NO
                                                                            isArchivedAfter:YES
                                                                                       data:@{ @"otr_archived" : @1,
                                                                                               @"otr_archived_ref" : archivedDate.transportString}];
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqualWithAccuracy([archivedDate timeIntervalSince1970], [conversation.archivedChangedTimestamp timeIntervalSince1970], 1.0);
    }];
}


- (void)testThatItResetsIsArchivedFromNullPayload
{
    NSDate *unarchivedDate = [NSDate date];
    ZMConversation *conversation = [self checkThatItProcessesUpdateEventForIsArchivedBefore:YES
                                             isArchivedAfter:NO
                                                        data:@{@"otr_archived" : @0,
                                                               @"otr_archived_ref" : unarchivedDate.transportString}];
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqualWithAccuracy([unarchivedDate timeIntervalSince1970], [conversation.archivedChangedTimestamp timeIntervalSince1970], 1.0);
    }];
    
}

- (void)testThatItResetsIsArchivedFromFalsePayload
{
    [self checkThatItProcessesUpdateEventForIsArchivedBefore:YES isArchivedAfter:YES data:@{
                                                                                           @"archived" : @"false"
                                                                                           }];
}

- (void)testThatItDoesNotUpdateIsArchivedIfItIsNotInThePayload
{
    [self checkThatItProcessesUpdateEventForIsArchivedBefore:YES isArchivedAfter:YES data:@{}];
}

#pragma mark - UpdateEvents

- (void)testThatItProcessesConversationCreateEvents
{
    // given
    NSUUID *selfUserID = [ZMUser selfUserInContext:self.uiMOC].remoteIdentifier;
    NSUUID *remoteID = [NSUUID createUUID];
    NSDictionary *innerPayload = @{
                                   @"name" : @"foobarz",
                                   @"creator" : @"3bc5750a-b965-40f8-aff2-831e9b5ac2e9",
                                   @"members" : @{
                                           @"self" : @{
                                                   @"id" : selfUserID.transportString,
                                                   },
                                           @"others" : @[]
                                           },
                                   @"type" : @0,
                                   @"id" : remoteID.transportString,
                                   };
    
    NSDate *serverTime = NSDate.date;
    NSDictionary *payload = @{
                              @"type" : @"conversation.create",
                              @"data" : innerPayload,
                              @"time" : serverTime.transportString
                              };
    
    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:[NSUUID createUUID]];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        ZMConversation *conversation = [ZMConversation fetchWith:remoteID in:self.syncMOC];
        XCTAssertNotNil(conversation);
        XCTAssertTrue([self isConversation:conversation matchingPayload:innerPayload serverTimeStamp:serverTime]);
    }];
}

- (void)testThatItProcessesConversationCreateEventsWithQualifiedID
{
    // given
    NSUUID *selfUserID = [ZMUser selfUserInContext:self.uiMOC].remoteIdentifier;
    NSUUID *remoteID = [NSUUID createUUID];
    NSString *domain = @"example.com";
    NSDictionary *innerPayload = @{
                                   @"name" : @"foobarz",
                                   @"creator" : @"3bc5750a-b965-40f8-aff2-831e9b5ac2e9",
                                   @"members" : @{
                                           @"self" : @{
                                                   @"id" : selfUserID.transportString,
                                                   },
                                           @"others" : @[]
                                           },
                                   @"type" : @0,
                                   @"id" : remoteID.transportString,
                                   @"qualified_id" : @{
                                           @"id" : remoteID.transportString,
                                           @"domain" : domain
                                   },
                                   };

    NSDate *serverTime = NSDate.date;
    NSDictionary *payload = @{
                              @"type" : @"conversation.create",
                              @"data" : innerPayload,
                              @"time" : serverTime.transportString
                              };

    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:[NSUUID createUUID]];

    [self.syncMOC performGroupedBlockAndWait:^{


        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];

        // then
        ZMConversation *conversation = [ZMConversation fetchWith:remoteID in:self.syncMOC];
        XCTAssertNotNil(conversation);
        XCTAssertTrue([self isConversation:conversation matchingPayload:innerPayload serverTimeStamp:serverTime]);
    }];
}

- (void)testThatItUpdatesTheConversationTypeWhenProcessingConversationCreateEventForConnection;
{
    // When a one-on-one is create on the server (due to auto-connect) we 1st receive a "conversation.connect-request"
    // which triggers the conversation to get created locally with needsToBeUpdatedFromBackend set
    // We _must_ reset this to the type in the payload once we receive the "conversation.create".
    
    // given
    NSUUID *remoteID = NSUUID.createUUID;
    __block NSManagedObjectID *localID;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *conversation = [ZMConversation fetchOrCreateWith:remoteID domain:nil in:self.syncMOC];
        XCTAssert([self.syncMOC saveOrRollback]);
        localID = conversation.objectID;
        // This should not be set, yet.
        XCTAssertNotEqual(conversation.conversationType, ZMConversationTypeOneOnOne);
    }];
    
    NSUUID *selfID = NSUUID.createUUID;
    NSDictionary *innerPayload = @{
                                   @"creator": selfID.transportString,
                                   @"members": @{
                                       @"self": @{
                                           @"id": selfID.transportString
                                       },
                                       @"others": @[]
                                   },
                                   @"name": [NSNull null],
                                   @"id": remoteID.transportString,
                                   @"type": @3, //  <-------------------------------- "Connection"
                                   };
    
    
    NSDictionary *payload = @{@"conversation": remoteID.transportString,
                              @"time": @"2015-05-06T12:15:00.104Z",
                              @"from": selfID.transportString,
                              @"type" : @"conversation.create",
                              @"data" : innerPayload
                              };
    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:[NSUUID createUUID]];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        ZMConversation *conversation = (id) [self.syncMOC objectWithID:localID];
        XCTAssertEqual(conversation.conversationType, ZMConversationTypeConnection);
    }];
}

- (void)testThatItProcessesConversationCreateEventForPendingConnectionConversation
{
    // When the other end hasn't accepted, yet, they're not in the 'others' array.
    // We can not (safely) match this conversation with the connection, since we have
    // no way of looking up the user / connection.
    
    // given
    NSUUID *remoteID = [NSUUID createUUID];
    NSDictionary *innerPayload = @{@"creator": @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                                   @"id": remoteID.transportString,
                                   @"members": @{
                                           @"others": @[],
                                           @"self": @{
                                                   @"id": @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                                                   },
                                           },
                                   @"name": @"Jonathan",
                                   @"type": @3,};
    
    
    NSDictionary *payload = @{
                              @"type" : @"conversation.create",
                              @"data" : innerPayload,
                              @"time": @"2014-07-02T14:52:45.211Z"
                              };
    
    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:[NSUUID createUUID]];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        ZMConversation *conversation = [ZMConversation fetchWith:remoteID in:self.syncMOC];
        XCTAssertNil(conversation);
    }];
}

- (void)testThatItProcessesConversationRenameEvents
{
    // given
    __block ZMUser *user3;
    __block ZMConversation *conversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *user1 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user1.remoteIdentifier = [NSUUID createUUID];
        ZMUser *user2 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user2.remoteIdentifier = [NSUUID createUUID];
        user3 = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user3.remoteIdentifier = [NSUUID createUUID];
        conversation = [ZMConversation insertGroupConversationIntoManagedObjectContext:self.syncMOC withParticipants:@[user1, user2, user3]];
        conversation.userDefinedName = @"Some old name";
        conversation.remoteIdentifier = [NSUUID createUUID];
        XCTAssertTrue([self.syncMOC saveOrRollback]);
    }];
    
    NSString *newName = @"My New Name";
    NSDate *time = [NSDate date];
    NSDictionary *payload = @{@"type" : @"conversation.rename",
                              @"from": user3.remoteIdentifier.transportString,
                              @"time": time.transportString,
                              @"conversation" : conversation.remoteIdentifier.transportString,
                              @"data": @{@"name": newName}
                              };
    
    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:[NSUUID createUUID]];

    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqualObjects(conversation.userDefinedName, newName);
    }];
}

- (void)testThatItDoesNotProcessUpdateEventWrongType
{
    // given
    NSUUID *remoteID = [NSUUID createUUID];
    NSDictionary *payload = @{
                              @"id" : [remoteID transportString],
                              @"type" : @"user.update",
                              @"connection" : @{}
                              };
    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:[NSUUID createUUID]];
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        ZMConversation *conversation = [ZMConversation fetchWith:remoteID in:self.syncMOC];
        XCTAssertNil(conversation);
    }];
}

- (void)testThatItDoesNotCreateANewConversationWhenItProcessesAConversationCreateEventForAOneOnOneConversation;
{
    // given
    NSUUID *otherUserID = [NSUUID createUUID];
    __block ZMUser *otherUser;
    __block ZMConnection *existingConnection;
    [self.syncMOC performGroupedBlockAndWait:^{
        [ZMUser selfUserInContext:self.syncMOC].remoteIdentifier = self.selfUserID;
        [ZMUser selfUserInContext:self.syncMOC].name = @"Me, myself";
        otherUser = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        otherUser.name = @"Other";
        otherUser.remoteIdentifier = otherUserID;
        existingConnection = [ZMConnection insertNewSentConnectionToUser:otherUser];
        XCTAssertNotNil(existingConnection.conversation);
        XCTAssertNil(existingConnection.conversation.remoteIdentifier);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    NSUUID *conversationID = [NSUUID createUUID];
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUpdateEvent *event = [self conversationCreateEventForConversationID:conversationID selfID:self.selfUserID otherUserID:otherUserID];
        XCTAssertNotNil(event);
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[ZMConversation entityName]];
        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"conversationType" ascending:YES]];
        NSArray *allConversations = [self.syncMOC executeFetchRequestOrAssert:request];
        XCTAssertEqual(allConversations.count, 2u);
        
        ZMConversation *selfConversation = allConversations.firstObject;
        XCTAssertNotNil(selfConversation);
        XCTAssertEqual(selfConversation.conversationType, ZMConversationTypeSelf);
        XCTAssertEqualObjects(selfConversation.remoteIdentifier, self.selfUserID);
        
        ZMConversation *conversation = allConversations.lastObject;
        XCTAssertNotNil(conversation);
        XCTAssertEqual(conversation, existingConnection.conversation);
        XCTAssertEqualObjects(conversation.remoteIdentifier, conversationID);
        XCTAssertEqual(conversation.conversationType, ZMConversationTypeConnection);
        
        
        // also check that the existing connection is not altered
        XCTAssertNotNil(existingConnection.to);
        XCTAssertEqual(existingConnection.to, otherUser);
        XCTAssertEqualObjects(existingConnection.to.remoteIdentifier, otherUserID);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatItMergesConversationsWhenItProcessesAConversationCreateEventForAOneOnOneConversationAndTheConnectionAlreadyHasAConversation
{
    // given
    self.sut = (id) [[ZMConversationTranscoder alloc] initWithManagedObjectContext:self.syncMOC applicationStatus:self.mockApplicationStatus syncStatus:self.mockSyncStatus];
    
    NSUUID *otherUserID = [NSUUID createUUID];
    NSUUID *conversationID = [NSUUID createUUID];
    
    __block ZMUser *otherUser;
    __block ZMConnection *existingConnection;
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // create connection + connection-conversation
        [ZMUser selfUserInContext:self.syncMOC].remoteIdentifier = self.selfUserID;
        [ZMUser selfUserInContext:self.syncMOC].name = @"Me, myself";
        otherUser = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        otherUser.name = @"Other";
        otherUser.remoteIdentifier = otherUserID;
        existingConnection = [ZMConnection insertNewSentConnectionToUser:otherUser];
        XCTAssertNotNil(existingConnection.conversation);
        XCTAssertNil(existingConnection.conversation.remoteIdentifier);
        
        // process a member-join event on that connection-conversation, before I know that it is a connection-conversation
        NSDictionary *eventPayload = [self responsePayloadForUserEventInConversationID:conversationID userIDs:@[otherUserID] eventType:@"conversation.member-join"];
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // forcing an event here - in real code it will be created in another syncObject, not tested here
        ZMSystemMessage *memberJoinEvent = [[ZMSystemMessage alloc] initWithNonce:NSUUID.createUUID managedObjectContext:self.syncMOC];
        memberJoinEvent.systemMessageType = ZMSystemMessageTypeParticipantsAdded;
        [existingConnection.conversation.mutableMessages addObject:memberJoinEvent];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // SANITY CHECK - now I should have two conversations
        ZMConversation *createdConversation = [ZMConversation fetchWith:conversationID in:self.syncMOC];
        XCTAssertNotNil(createdConversation);
        XCTAssertNotEqual(createdConversation, existingConnection.conversation);
        
        // this is the member join system message
        XCTAssertEqual(createdConversation.allMessages.count, 1u);
        
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[ZMConversation entityName]];
        NSArray *allConversations = [self.syncMOC executeFetchRequestOrAssert:request];
        
        XCTAssertEqual(allConversations.count, 3u);
    }];
    
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        
        ZMUpdateEvent *event = [self conversationCreateEventForConversationID:conversationID selfID:self.selfUserID otherUserID:otherUserID];
        XCTAssertNotNil(event);
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[ZMConversation entityName]];
        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"conversationType" ascending:YES]];
        NSArray *allConversations = [self.syncMOC executeFetchRequestOrAssert:request];
        XCTAssertEqual(allConversations.count, 2u);
        
        ZMConversation *conversation = allConversations.lastObject;
        XCTAssertNotNil(conversation);
        XCTAssertEqual(conversation, existingConnection.conversation);
        XCTAssertEqualObjects(conversation.remoteIdentifier, conversationID);
        XCTAssertEqual(conversation.conversationType, ZMConversationTypeConnection);
        
        // also check that the existing connection is not altered
        XCTAssertNotNil(existingConnection.to);
        XCTAssertEqual(existingConnection.to, otherUser);
        XCTAssertEqualObjects(existingConnection.to.remoteIdentifier, otherUserID);
        
        // check that the conversation has both events
        XCTAssertEqual(conversation.allMessages.count, 2u);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatItDoesNotSetLastModifiedDateFromPushPayloadIfForIgnoredEvents
{
    // given
    __block ZMConversation *conversation;
    NSUUID* conversationID = [NSUUID createUUID];
    NSDate *lastModifiedDate = [NSDate dateWithTimeIntervalSinceReferenceDate:417002300];
    NSDate *newerLastModifiedDate = [lastModifiedDate dateByAddingTimeInterval:10];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = conversationID;
        conversation.lastModifiedDate = lastModifiedDate;
    
        NSArray<NSNumber *> *ignoredEventTypes = @[
                                                   @(ZMUpdateEventTypeConversationAccessModeUpdate),
                                                   @(ZMUpdateEventTypeConversationMessageTimerUpdate),
                                                   @(ZMUpdateEventTypeTeamMemberUpdate),
                                                   @(ZMUpdateEventTypeTeamMemberLeave),
                                                   @(ZMUpdateEventTypeConversationRename)
                                                   ];
        NSMutableArray<ZMUpdateEvent *> *events = @[].mutableCopy;
        
        for (NSNumber *eventType in ignoredEventTypes) {
            NSDictionary *payload = @{@"conversation": conversation.remoteIdentifier.transportString,
                                      @"data": @{},
                                      @"from": @"6185dc93-aabd-4ece-bf75-372a6dd3592b",
                                      @"time": newerLastModifiedDate.transportString,
                                      @"type": [ZMUpdateEvent eventTypeStringForUpdateEventType:eventType.unsignedIntegerValue]};
            
            [events addObject:[ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil]];
        }
        
        // when
        [self performIgnoringZMLogError:^{ // ignore errors from that we are sending incomplete payloads
            [self.sut processEvents:events liveEvents:YES prefetchResult:nil];
        }];
        
        // then
        XCTAssertEqualWithAccuracy(conversation.lastModifiedDate.timeIntervalSinceReferenceDate, lastModifiedDate.timeIntervalSinceReferenceDate, 0.2);
    }];
}

- (void)testThatItDoesNotSetLastModifiedDateFromPushPayloadWhenItIsAlreadyNewer
{
    // given
    __block ZMConversation *conversation;
    NSUUID* conversationID = [NSUUID createUUID];
    NSDate *lastModifiedDate = [NSDate dateWithTimeIntervalSinceReferenceDate:417002300];
    NSDate *newerLastModifiedDate = [lastModifiedDate dateByAddingTimeInterval:10];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = conversationID;
        conversation.lastModifiedDate = newerLastModifiedDate;
        
        NSDictionary *payload = @{@"conversation": conversation.remoteIdentifier.transportString,
                                  @"data": @{
                                          @"content": @"http://www.youtube.com/watch?v=CRbWeUN1n7k#t=544",
                                          @"nonce": [NSUUID createUUID].transportString,
                                          },
                                  @"from": @"6185dc93-aabd-4ece-bf75-372a6dd3592b",
                                  @"time": lastModifiedDate.transportString,
                                  @"type": @"conversation.message-add"};
        
        ZMUpdateEvent *updateEvent = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
        XCTAssertNotNil(updateEvent);
        
        // when
        [self.sut processEvents:@[updateEvent] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertEqualWithAccuracy(conversation.lastModifiedDate.timeIntervalSinceReferenceDate, newerLastModifiedDate.timeIntervalSinceReferenceDate, 0.1);
    }];
}

- (void)testThatWhenReceivingEventsForAnUnknownConversationAndThenItIsDownloadedAsOneToOneItSetsTheTypeAsOneToOne
{
    // given
    __block ZMConversation *conversation;
    NSUUID* conversationID = [NSUUID createUUID];
    NSUUID* userID = [NSUUID createUUID];
    NSDictionary *payload = @{@"conversation": conversationID.transportString,
                              @"data": @{
                                      @"content": @"http://www.youtube.com/watch?v=CRbWeUN1n7k#t=544",
                                      @"nonce": [NSUUID createUUID].transportString,
                                      },
                              @"from": @"6185dc93-aabd-4ece-bf75-372a6dd3592b",
                              @"time": [NSDate date].transportString,
                              @"type": @"conversation.message-add"};
    
    ZMUpdateEvent *updateEvent = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
    XCTAssertNotNil(updateEvent);
    
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.sut processEvents:@[updateEvent] liveEvents:YES prefetchResult:nil];
        
        // then
        conversation = [ZMConversation fetchWith:conversationID in:self.syncMOC];
        XCTAssertNotNil(conversation);
        
        // given
        NSDictionary *conversationPayload = @{
                                              @"creator": userID.transportString,
                                              @"members": @{
                                                      @"self": @{
                                                              @"id": @"39562cc3-717d-4395-979c-5387ae17f5c3",
                                                              },
                                                      @"others": @[
                                                              @{
                                                                  @"id": userID.transportString,
                                                                  }
                                                              ]
                                                      },
                                              @"name": @"Marco1",
                                              @"id": conversationID.transportString,
                                              @"type": @2
                                              };
        ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:conversationPayload HTTPStatus:200 transportSessionError:nil];
        
        // when
        [self.sut updateObject:conversation withResponse:response downstreamSync:nil];
        
        // then
        XCTAssertEqual(conversation.conversationType, ZMConversationTypeOneOnOne);
    }];
    
}

- (void)testThatItDoesNotUnArchiveAConversations_WhenTheConversationsArchivedChangeTimeStampIsNewer
{
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        NSDate *oldArchived = [NSDate date];
        NSDate *newArchived = [oldArchived dateByAddingTimeInterval:100];
        
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = NSUUID.createUUID;
        conversation.lastServerTimeStamp = newArchived;
        conversation.isArchived = YES;
        [conversation resetLocallyModifiedKeys:[NSSet setWithObject:ZMConversationArchivedChangedTimeStampKey]];
        
        XCTAssertNotNil(conversation);
        XCTAssertTrue(conversation.isArchived);
        XCTAssertEqualObjects(conversation.archivedChangedTimestamp, newArchived);
        
        NSDictionary *payload = @{
                                  @"conversation" : conversation.remoteIdentifier.transportString,
                                  @"data" : @{},
                                  @"from" : @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                                  @"time" : [oldArchived transportString],
                                  @"type" : @"conversation.member-join",
                                  };
        
        ZMUpdateEvent *updateEvent = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
        XCTAssertNotNil(updateEvent);
        
        // when
        [self.sut processEvents:@[updateEvent] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertTrue(conversation.isArchived);
        XCTAssertFalse([conversation.keysThatHaveLocalModifications containsObject:ZMConversationArchivedChangedTimeStampKey]);
    }];
}

@end



@implementation ZMConversationTranscoderTests (LastRead)

- (void)testThatItSetsLastReadWhenTheVisibleWindowChanges;
{
    // given
    size_t const MessageCount = 300;
    __block ZMConversation *syncConversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        syncConversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        syncConversation.remoteIdentifier = [NSUUID createUUID];
        
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:417005700];
        for (size_t i = 0; i < MessageCount; ++i) {
            ZMTextMessage *message = [[ZMTextMessage alloc] initWithNonce:NSUUID.createUUID managedObjectContext:self.syncMOC];
            message.text = [NSString stringWithFormat:@"%llu", (long long unsigned) i];
            message.serverTimestamp = [date dateByAddingTimeInterval:(NSTimeInterval) i];
            [syncConversation.mutableMessages addObject:message];
        }
        XCTAssert([self.syncMOC saveOrRollback]);
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    ZMConversation *conversation = (id) [self.uiMOC objectWithID:syncConversation.objectID];
    conversation.lastReadTimestampSaveDelay = 0.2;
    ZMMessage *toMessage = [conversation lastMessagesWithLimit:50][42];
    [conversation markMessagesAsReadUntil:toMessage];
    XCTAssert([self.uiMOC saveOrRollback]);
    WaitForAllGroupsToBeEmpty(conversation.lastReadTimestampSaveDelay + 0.2);
    
    // then
    [self.uiMOC refreshObject:conversation mergeChanges:NO];
    XCTAssertEqual(conversation.lastReadServerTimeStamp, toMessage.serverTimestamp);
    XCTAssertTrue([conversation.keysThatHaveLocalModifications containsObject:@"lastReadServerTimeStamp"],
                  @"{%@}", [conversation.keysThatHaveLocalModifications.allObjects componentsJoinedByString:@", "]);
}

- (void)testThatWhenReceivingAVisibleEventAfterTheLastReadTheLastReadIsNotIncreased
{
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = [NSUUID createUUID];
        conversation.lastReadServerTimeStamp = [NSDate date];
        conversation.lastServerTimeStamp = [NSDate date];
        
        NSDate *lastReadTimeStamp = conversation.lastReadServerTimeStamp;
        NSDate *newDate = [NSDate date];
        
        NSDictionary *payload = @{
                                  @"conversation" : conversation.remoteIdentifier.transportString,
                                  @"data" : @{
                                          @"nonce" : [NSUUID createUUID].transportString,
                                          @"content" : @"this should not increase the last read"
                                          },
                                  @"from" : @"08316f5e-3c0a-4847-a235-2b4d93f291a4",
                                  @"time" : newDate.transportString,
                                  @"type" : @"conversation.message-add",
                                  };
        
        ZMUpdateEvent *updateEvent = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
        XCTAssertNotNil(updateEvent);
        
        // when
        [self.sut processEvents:@[updateEvent] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertEqualObjects(conversation.lastReadServerTimeStamp, lastReadTimeStamp);

    }];
}

#pragma mark -  EventsInConnectionConversations

- (void)testThatWhenProcessingConversationUpdateEventsItDoesNotRefetchThatConversationIfItWasAnAcceptedConnection
{
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        ZMUser *user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID];
        NSUUID *uuid = [NSUUID createUUID];
        NSDictionary *eventPayload = @{
                                       @"conversation" : [uuid transportString],
                                       @"type": @"conversation.otr-message-add",
                                       @"time" : [NSDate dateWithTimeIntervalSince1970:1233253].transportString
                                       };
        
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        XCTAssertNotNil(event);
        
        ZMConnection *connection = [ZMConnection insertNewSentConnectionToUser:user];
        ZMConversation *conversation = connection.conversation;
        conversation.remoteIdentifier = uuid;
        conversation.conversationType = ZMConversationTypeOneOnOne;
        connection.status = ZMConnectionStatusAccepted;
        XCTAssertNotNil(conversation);
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        XCTAssertFalse(connection.needsToBeUpdatedFromBackend);
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        XCTAssertFalse(connection.needsToBeUpdatedFromBackend);
        
    }];
}

- (void)testThatWhenProcessingConversationUpdateEventsItRefetchesThatConversationIfItWasAConnection
{
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        ZMUser *user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID];
        NSUUID *uuid = [NSUUID createUUID];
        NSDictionary *eventPayload = @{
                                       @"conversation" : [uuid transportString],
                                       @"type": @"conversation.otr-message-add",
                                       @"time" : [NSDate dateWithTimeIntervalSince1970:1233253].transportString
                                       };
        
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        XCTAssertNotNil(event);
        
        ZMConnection *connection = [ZMConnection insertNewSentConnectionToUser:user];
        ZMConversation *conversation = connection.conversation;
        conversation.remoteIdentifier = uuid;
        XCTAssertNotNil(conversation);
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        XCTAssertFalse(connection.needsToBeUpdatedFromBackend);
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertTrue(conversation.needsToBeUpdatedFromBackend);
        XCTAssertTrue(connection.needsToBeUpdatedFromBackend);
        
    }];
}

- (void)testThatWhenProcessingConversationUpdateEventsItDoesNotRefetchThatConversationIfItWasAGroupConversation
{
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        ZMUser *user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID];
        NSUUID *uuid = [NSUUID createUUID];
        NSDictionary *eventPayload = @{
                                       @"conversation" : [uuid transportString],
                                       @"type": @"conversation.otr-message-add",
                                       @"time" : [NSDate dateWithTimeIntervalSince1970:1233253].transportString
                                       };
        
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        XCTAssertNotNil(event);
        
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = uuid;
        conversation.conversationType = ZMConversationTypeGroup;
        XCTAssertNotNil(conversation);
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        
    }];
}

- (void)testThatWhenProcessingConversationUpdateEventsItDoesNotRefetchThatConversationIfItWasNotInvalid
{
    [self.syncMOC performGroupedBlockAndWait:^{

        // given
        NSUUID *uuid = [NSUUID createUUID];
        NSDictionary *eventPayload = @{
                                       @"conversation" : [uuid transportString],
                                       @"type": @"conversation.otr-message-add",
                                       @"time" : [NSDate dateWithTimeIntervalSince1970:1233253].transportString
                                       };
        
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        XCTAssertNotNil(event);
        
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = uuid;
        conversation.conversationType = ZMConversationTypeOneOnOne;
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
    }];
}

- (void)testThatWhenProcessingConversationUpdateEventsItDoesNotRefetchThatConversationIfItWasInvalid
{
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        NSUUID *uuid = [NSUUID createUUID];
        NSDictionary *eventPayload = @{
                                       @"conversation" : [uuid transportString],
                                       @"type": @"conversation.otr-message-add",
                                       @"time" : [NSDate dateWithTimeIntervalSince1970:1233253].transportString
                                       };
        
        ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:eventPayload uuid:nil];
        XCTAssertNotNil(event);
        
        ZMConversation *conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.remoteIdentifier = uuid;
        conversation.conversationType = ZMConversationTypeInvalid;
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertTrue(conversation.needsToBeUpdatedFromBackend);
    }];
}

- (void)testThatItRemovesSelfUserAndMarkAsSynced_OnPermissionError
{
    __block ZMConversation *conversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        selfUser.remoteIdentifier = [NSUUID createUUID];
        selfUser.needsToBeUpdatedFromBackend = NO;
        
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeGroup;
        conversation.remoteIdentifier = [NSUUID createUUID];
        conversation.needsToBeUpdatedFromBackend = YES;
        [conversation addParticipantAndUpdateConversationStateWithUser:selfUser role: nil];
        [self.syncMOC saveOrRollback];
        
        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:conversation]];
        }
        
        // when
        ZM_ALLOW_MISSING_SELECTOR(ZMTransportRequest *request = [self.sut.requestGenerators firstNonNilReturnedFromSelector:@selector(nextRequest)];)
        XCTAssertNotNil(request);
        [request completeWithResponse:[ZMTransportResponse responseWithPayload:@{} HTTPStatus:403 transportSessionError:nil]];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        XCTAssertFalse(conversation.isFault);
        XCTAssertFalse(conversation.needsToBeUpdatedFromBackend);
        XCTAssertFalse(conversation.isSelfAnActiveMember);
        XCTAssertFalse([conversation hasLocalModificationsForKey:ZMConversationParticipantRolesKey]);
    }];
}

- (void)testThatItDeletesTheConversation_OnMissingResourceError
{
    __block ZMConversation *conversation;
    [self.syncMOC performGroupedBlockAndWait:^{
        // given
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        selfUser.remoteIdentifier = [NSUUID createUUID];
        selfUser.needsToBeUpdatedFromBackend = NO;
        
        conversation = [ZMConversation insertNewObjectInManagedObjectContext:self.syncMOC];
        conversation.conversationType = ZMConversationTypeGroup;
        conversation.remoteIdentifier = [NSUUID createUUID];
        conversation.needsToBeUpdatedFromBackend = YES;
        [conversation addParticipantAndUpdateConversationStateWithUser:[ZMUser selfUserInContext:self.syncMOC] role: nil];
        [self.syncMOC saveOrRollback];

        for (id<ZMContextChangeTracker> tracker in self.sut.contextChangeTrackers) {
            [tracker objectsDidChange:[NSSet setWithObject:conversation]];
        }
        
        // when
        ZM_ALLOW_MISSING_SELECTOR(ZMTransportRequest *request = [self.sut.requestGenerators firstNonNilReturnedFromSelector:@selector(nextRequest)];)
        XCTAssertNotNil(request);
        [request completeWithResponse:[ZMTransportResponse responseWithPayload:@{} HTTPStatus:404 transportSessionError:nil]];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        // then
        XCTAssertTrue(conversation.isFault);
    }];
}

@end
