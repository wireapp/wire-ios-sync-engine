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


@import ZMTransport;
@import zmessaging;
@import ZMCDataModel;

#import "ObjectTranscoderTests.h"
#import "ZMUserTranscoder+Internal.h"
#import "ZMSyncStrategy.h"
#import "ZMUserSession.h"
#import <zmessaging/zmessaging-Swift.h>
#import "ZMUserSession+Internal.h"


static NSString *const USER_PATH_WITH_QUERY = @"/users?ids=";

@interface ZMUserTranscoderTests : ObjectTranscoderTests

@property (nonatomic) ZMUserTranscoder *sut;

@end



@implementation ZMUserTranscoderTests

- (void)setUp
{
    [super setUp];
    
    self.syncMOC.zm_userImageCache = [[UserImageLocalCache alloc] initWithLocation:nil];
    self.uiMOC.zm_userImageCache = self.syncMOC.zm_userImageCache;
    
    self.sut = [[ZMUserTranscoder alloc] initWithManagedObjectContext:self.syncMOC];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)tearDown
{
    [self.sut tearDown];
    self.sut = nil;
    
    [super tearDown];
}


- (NSMutableDictionary *)samplePayloadForUserID:(NSUUID *)userID
{
    return [@{
              @"type" : @"user.update",
              @"user" : [@{
                  @"name" : @"Lafontaine",
                  @"id" : userID.transportString,
                  @"email" : @"lafontaine@example.com",
                  @"phone" : @"555-986-45789",
                  @"accent_id" : @3,
                  @"picture" : @[]
                  } mutableCopy]
              } mutableCopy];
}

- (void)testThatItIsCreatedWithIsSlowSyncDoneTrue
{
    XCTAssertTrue(self.sut.isSlowSyncDone);
}

- (void)testThatItOnlyProcessesRemoteIDRequests
{
    // when
    NSArray *generators = self.sut.requestGenerators;
    
    // then
    XCTAssertEqual(generators.count, 1u);
    XCTAssertTrue([generators.firstObject isKindOfClass:ZMRemoteIdentifierObjectSync.class]);
}

- (void)testThatItReturnsTheContextChangeTrackers;
{
    // when
    NSArray *trackers = self.sut.contextChangeTrackers;
    
    // then
    XCTAssertEqual(trackers.count, 1u);
}

- (void)testThatItDoesNotRequestAUserWhileARequestForThatUserIsAlreadyInProgress
{
    
    // given
    [self.sut objectsDidChange:[NSSet setWithObject:[self insertUserWithRemoteID]]];
    
    ZMTransportRequest *firstRequest = [self.sut.requestGenerators nextRequest];
    XCTAssertNotNil(firstRequest);
    
    // when
    ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
    
    // then
    XCTAssertNil(request);
}

- (void)testThatItDoesNotRequestUsersWhileARequestForThoseUsersIsAlreadyInProgress
{
    // given
    NSUInteger const userCount = ZMUserTranscoderNumberOfUUIDsPerRequest * 2 + 10;
    NSMutableSet *users = [NSMutableSet set];
    for (NSUInteger i = 0; i < userCount; ++i) {
        [users addObject:[self insertUserWithRemoteID]];
    }
    [self.sut objectsDidChange:users];
    
    // For each request to /users we extract the IDs and put them into a set.
    // While doing so, we check that the ID is not in the set already, ie. that
    // it was not requested already.
    NSMutableSet *requestedIDs = [NSMutableSet set];
    for (size_t i = 0; i < (userCount / ZMUserTranscoderNumberOfUUIDsPerRequest) + 10UL; ++i) {
        ZMTransportRequest *req = [self.sut.requestGenerators nextRequest];

        if ([req.path hasPrefix:USER_PATH_WITH_QUERY]) {
            NSArray *ids = [[req.path substringFromIndex:USER_PATH_WITH_QUERY.length] componentsSeparatedByString:@","];
            for (NSString *identifier in ids) {
                XCTAssertFalse([requestedIDs containsObject:identifier]);
                [requestedIDs addObject:identifier];
            }
        }
    }
    // Finally we check that the number of IDs requested matches the number of users.
    // This makes sure that the test doesn't pass just because we didn't request any / enough users.
    XCTAssertEqual(requestedIDs.count, userCount);
}

- (void)testThatItReturnsSelfUserInContext
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *selfUser1 = [ZMUser selfUserInContext:self.syncMOC];
        
        // when
        ZMUser *selfUser2 = [ZMUser selfUserInContext:self.syncMOC];
        
        // then
        XCTAssertNotNil(selfUser1);
        XCTAssertEqual(selfUser1, selfUser2);
        XCTAssertTrue([selfUser1 isSelfUser]);
    }];
}

- (void)testThatItReturnsSelfUserInUserSession
{
    [self.syncMOC performGroupedBlockAndWait:^{
        id session = [OCMockObject mockForClass:ZMUserSession.class];
        [[[session stub] andReturn:self.syncMOC] managedObjectContext];
        // given
        ZMUser *selfUser1 = [ZMUser selfUserInContext:self.syncMOC];
        
        // when
        ZMUser *selfUser2 = [ZMUser selfUserInUserSession:session];
        
        // then
        XCTAssertNotNil(selfUser1);
        XCTAssertEqual(selfUser1, selfUser2);
        XCTAssertTrue([selfUser1 isSelfUser]);
    }];
}

- (void)testThatItRequestsUsersAgainIfTheFirstRequestFailedBecauseOfANetworkError;
{
    // given
    NSUInteger const batchCount = 5;
    NSUInteger const userCount = ZMUserTranscoderNumberOfUUIDsPerRequest * (batchCount - 1) + 10;
    NSMutableArray *allUsers = [NSMutableArray array];
    for (NSUInteger i = 0; i < userCount; ++i) {
        [allUsers addObject:[self insertUserWithRemoteID]];
    }
    [self.sut objectsDidChange:[NSSet setWithArray:allUsers]];

    ZMTransportResponse *failingResponse = [ZMTransportResponse responseWithTransportSessionError:
        [NSError errorWithDomain:ZMTransportSessionErrorDomain code:ZMTransportSessionErrorCodeTryAgainLater userInfo:nil]];
    
    // 1st request:
    __block ZMTransportRequest *req1;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        req1 = [self.sut.requestGenerators nextRequest];
    }];
    
    XCTAssertTrue([req1.path hasPrefix:USER_PATH_WITH_QUERY]);
    [req1 completeWithResponse:[self successResponseForUsersRequest:req1]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // 2nd request:
    __block ZMTransportRequest *req2;
    [self.syncMOC performGroupedBlockAndWait:^{
        req2 = [self.sut.requestGenerators nextRequest];
    }];
    XCTAssertTrue([req2.path hasPrefix:USER_PATH_WITH_QUERY]);
    [req2 completeWithResponse:failingResponse];
    WaitForAllGroupsToBeEmpty(0.5);
    XCTAssertNotEqualObjects(req2.path, req1.path);

    // 3rd request:
    __block ZMTransportRequest *req3;
    [self.syncMOC performGroupedBlockAndWait:^{
        req3 = [self.sut.requestGenerators nextRequest];
    }];
    XCTAssertEqualObjects(req3.path, req2.path);
}

- (void)testThatItRequestsUsersAgainIfTheFirstRequestFailedBecauseOfAnInvalidHTTPStatus;
{
    // given
    NSUInteger const batchCount = 5;
    NSUInteger const userCount = ZMUserTranscoderNumberOfUUIDsPerRequest * (batchCount - 1) + 10;
    NSMutableArray *allUsers = [NSMutableArray array];
    for (NSUInteger i = 0; i < userCount; ++i) {
        [allUsers addObject:[self insertUserWithRemoteID]];
    }
    [self.sut objectsDidChange:[NSSet setWithArray:allUsers]];
    
    ZMTransportResponse *failingResponse = [ZMTransportResponse responseWithPayload:nil HTTPStatus:500 transportSessionError:nil];

    // 1st request:
    ZMTransportRequest *req1 = [self.sut.requestGenerators nextRequest];
    XCTAssertTrue([req1.path hasPrefix:USER_PATH_WITH_QUERY]);
    [req1 completeWithResponse:[self successResponseForUsersRequest:req1]];
    WaitForAllGroupsToBeEmpty(0.5);

    // 2nd request:
    ZMTransportRequest *req2 = [self.sut.requestGenerators nextRequest];
    XCTAssertTrue([req2.path hasPrefix:USER_PATH_WITH_QUERY]);
    [req2 completeWithResponse:failingResponse];
    WaitForAllGroupsToBeEmpty(0.5);
    XCTAssertNotEqualObjects(req2.path, req1.path);

    // 3rd request:
    ZMTransportRequest *req3 = [self.sut.requestGenerators nextRequest];
    XCTAssertEqualObjects(req3.path, req2.path);
}

- (void)testThatItRequestsAnIncompleteUserAgainAfterRequestWasCompleted
{
    // given
    __block ZMUser *user;
    __block BOOL needsToBeUpdated;
    [self.syncMOC performGroupedBlockAndWait:^{
        user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID]; // this user is now incomplete
        needsToBeUpdated = user.needsToBeUpdatedFromBackend;
        [self.sut objectsDidChange:[NSSet setWithObject:user]];
    }];
    XCTAssertTrue(needsToBeUpdated);
    NSDictionary *payload = @{
                                  @"id" : [user.remoteIdentifier transportString],
                                  @"name" : @"Roger",
                              };

    __block ZMTransportRequest *userRequest;
    [self.syncMOC performGroupedBlockAndWait:^{
        userRequest = [self.sut.requestGenerators nextRequest];
    }];
    XCTAssertEqualObjects(userRequest.path, [USER_PATH_WITH_QUERY stringByAppendingString:[user.remoteIdentifier transportString]]);
    [userRequest completeWithResponse:[ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        user.needsToBeUpdatedFromBackend = YES;
        [self.sut objectsDidChange:[NSSet setWithObject:user]];
    }];
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        userRequest = [self.sut.requestGenerators nextRequest];
    }];
    XCTAssertNotNil(userRequest);
    XCTAssertEqualObjects(userRequest.path, [USER_PATH_WITH_QUERY stringByAppendingString:[user.remoteIdentifier transportString]]);
}

- (void)testThatItClearsNeedsToBeUpdatedFromBackendAfterSuccessfulRequest
{
    // given
    ZMUser *user = [self insertUserWithRemoteID];
    [self.sut objectsDidChange:[NSSet setWithObject:user]];
    XCTAssertTrue(user.needsToBeUpdatedFromBackend);
    NSArray *payload = @[ [self samplePayloadForUserID:user.remoteIdentifier][@"user"] ];
    
    ZMTransportRequest *userRequest = [self.sut.requestGenerators nextRequest];
    
    // when
    [userRequest completeWithResponse:[ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertFalse(user.needsToBeUpdatedFromBackend);
}

- (void)testThatItClearsNeedsToBeUpdatedFromBackendAfterAPermanentFailedRequest
{
    // given
    ZMUser *user = [self insertUserWithRemoteID];
    [self.sut objectsDidChange:[NSSet setWithObject:user]];
    XCTAssertTrue(user.needsToBeUpdatedFromBackend);
    NSArray *payload = @[ [self samplePayloadForUserID:user.remoteIdentifier][@"user"] ];
    
    ZMTransportRequest *userRequest = [self.sut.requestGenerators nextRequest];
    
    // when
    [userRequest completeWithResponse:[ZMTransportResponse responseWithPayload:payload HTTPStatus:400 transportSessionError:nil]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertFalse(user.needsToBeUpdatedFromBackend);
}

- (void)testThatItDoesNotClearNeedsToBeUpdatedFromBackendAfterATemporarilyFailedRequest
{
    // given
    ZMUser *user = [self insertUserWithRemoteID];
    XCTAssertTrue(user.needsToBeUpdatedFromBackend);
    ZMTransportRequest *userRequest = [self.sut.requestGenerators nextRequest];
    
    // when
    [userRequest completeWithResponse:[ZMTransportResponse responseWithPayload:@{} HTTPStatus:500 transportSessionError:nil]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertTrue(user.needsToBeUpdatedFromBackend);
}

- (void)testThatItRequestsAllConnectedUsersAndSelfAndAnyPreviousUserBeingFetchedWhenSlowSyncIsReset
{
    // given
    __block NSArray *connectedUsers;
    __block NSArray *nonConnectedUsers;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        connectedUsers = @[
                           [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                           [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                           [ZMUser selfUserInContext:self.syncMOC],
                           ];
        for (ZMUser *user in connectedUsers) {
            user.remoteIdentifier = [NSUUID createUUID];
            user.needsToBeUpdatedFromBackend = YES;
            ZMConnection *connection = [ZMConnection insertNewObjectInManagedObjectContext:self.syncMOC];
            connection.to = user;
        }
        
        nonConnectedUsers = @[
                              [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                              [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC]
                              ];
        
        for (ZMUser *user in nonConnectedUsers) {
            user.remoteIdentifier = [NSUUID createUUID];
            user.needsToBeUpdatedFromBackend = YES;
        }
        [self.syncMOC saveOrRollback];
        [self.sut objectsDidChange:[NSSet setWithArray:nonConnectedUsers]];
        
        // when
        [self.sut setNeedsSlowSync];
    }];
    
    // then
    ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
    XCTAssertNotNil(request);
    XCTAssertTrue([request.path hasPrefix:USER_PATH_WITH_QUERY]);
    XCTAssertEqual(ZMMethodGET, request.method);
    
    NSString *queryString = [request.path substringFromIndex:USER_PATH_WITH_QUERY.length];
    NSArray *UUIDs = [queryString componentsSeparatedByString:@","];
    
    for(ZMUser *user in nonConnectedUsers) {
        XCTAssertTrue([UUIDs containsObject:[user.remoteIdentifier transportString]]);
    }
}

- (void)testThatItRequestsAllConnectedUsersAndSelfWhenSlowSyncIsReset
{
    // given
    __block NSArray *connectedUsers;
    __block NSArray *nonConnectedUsers;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        connectedUsers = @[
                           [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                           [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                           [ZMUser selfUserInContext:self.syncMOC],
                           ];
        for (ZMUser *user in connectedUsers) {
            user.remoteIdentifier = [NSUUID createUUID];
            user.needsToBeUpdatedFromBackend = YES;
            ZMConnection *connection = [ZMConnection insertNewObjectInManagedObjectContext:self.syncMOC];
            connection.to = user;
        }
        
        nonConnectedUsers = @[
                              [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                              [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                              ];
        
        for (ZMUser *user in nonConnectedUsers) {
            user.remoteIdentifier = [NSUUID createUUID];
            user.needsToBeUpdatedFromBackend = YES;
        }
        
        // when
        [self.sut setNeedsSlowSync];
    }];
    
    // then
    ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
    XCTAssertNotNil(request);
    XCTAssertTrue([request.path hasPrefix:USER_PATH_WITH_QUERY]);
    XCTAssertEqual(ZMMethodGET, request.method);
    
    NSString *queryString = [request.path substringFromIndex:USER_PATH_WITH_QUERY.length];
    NSArray *UUIDs = [queryString componentsSeparatedByString:@","];
    
    XCTAssertEqual(connectedUsers.count, UUIDs.count);
    for(ZMUser *user in connectedUsers) {
        XCTAssertTrue([UUIDs containsObject:[user.remoteIdentifier transportString]]);
    }
}

- (void)testThatIsSlowSyncDoneIsTrueWhenAllConnectedUsersAndSelfAreFetched
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
    
        NSArray *connectedUsers = @[
                                    [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                                    [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                                    [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
                                    [ZMUser selfUserInContext:self.syncMOC],
                                    ];
        for (ZMUser *user in connectedUsers) {
            user.remoteIdentifier = [NSUUID createUUID];
            user.needsToBeUpdatedFromBackend = YES;
            ZMConnection *connection = [ZMConnection insertNewObjectInManagedObjectContext:self.syncMOC];
            connection.to = user;
        }
        
        [self.sut setNeedsSlowSync];
    }];
    ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
    XCTAssertNotNil(request);
    ZMTransportResponse *response =[self successResponseForUsersRequest:request];
    
    // when
    [request completeWithResponse:response];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertTrue(self.sut.isSlowSyncDone);
    
}

- (void)testThatIsSlowSyncDoneIsTrueWhenAllConnectedUsersAreFetchedWithMultipleRequests
{
    // given
    NSUInteger numRequests = 3;
    
    NSUInteger const userCount = ZMUserTranscoderNumberOfUUIDsPerRequest * numRequests + 10;
    [self.syncMOC performGroupedBlockAndWait:^{
        for (NSUInteger i = 0; i < userCount; ++i) {
            ZMUser *user = [self insertUserWithRemoteID];
            user.needsToBeUpdatedFromBackend = YES;
            ZMConnection *connection = [ZMConnection insertNewObjectInManagedObjectContext:self.syncMOC];
            connection.to = user;
        }
    }];
    
    [self.sut setNeedsSlowSync];
    
    // when
    for(size_t i = 0; i < numRequests+1; ++i) {
        ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
        if(request == nil) {
            break;
        }
        ZMTransportResponse *response =[self successResponseForUsersRequest:request];
        [request completeWithResponse:response];
        WaitForAllGroupsToBeEmpty(0.5);
    }
    
    // then
    XCTAssertTrue(self.sut.isSlowSyncDone);
}

- (void)testThatIsSlowSyncDoneIsFalseWhenOnlySomeConnectedUsersAreFetched
{
    // given
    NSUInteger const userCount = ZMUserTranscoderNumberOfUUIDsPerRequest * 2 + 10;
    
    [self.syncMOC performGroupedBlockAndWait:^{
        for (NSUInteger i = 0; i < userCount; ++i) {
            ZMUser *user = [self insertUserWithRemoteID];
            user.needsToBeUpdatedFromBackend = YES;
            ZMConnection *connection = [ZMConnection insertNewObjectInManagedObjectContext:self.syncMOC];
            connection.to = user;
        }
    }];
    
    [self.sut setNeedsSlowSync];
    ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
    XCTAssertNotNil(request);
    ZMTransportResponse *response =[self successResponseForUsersRequest:request];
    
    // when
    [request completeWithResponse:response];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertFalse(self.sut.isSlowSyncDone);
}

- (void)testThatItDoesNotClearNeedsToBeUpdatedFromBackendWhenItIsUpdatedFromPushChannelData
{
    // given
    ZMUser *user = [self insertUserWithRemoteID];
    XCTAssertTrue(user.needsToBeUpdatedFromBackend);
    NSDictionary *payload = [self samplePayloadForUserID:user.remoteIdentifier];
    
    ZMUpdateEvent *event = [OCMockObject mockForClass:[ZMUpdateEvent class]];
    (void)[(ZMUpdateEvent *)[[(id)event stub] andReturnValue:OCMOCK_VALUE(ZMUpdateEventUserUpdate)] type];
    (void)[(ZMUpdateEvent *)[[(id)event stub] andReturn:payload] payload];
    
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }];
    // then
    XCTAssertTrue(user.needsToBeUpdatedFromBackend);
}

- (void)testThatItProcessEventOfTypeZMUpdateEventUserUpdate
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        NSString *finalName = @"Mario";
        NSString *finalEmail = @"mario@mario.example.com";
        ZMUser *user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.name = @"Lucky Luke";
        user.emailAddress = @"lucky@luke.example.com";
        user.remoteIdentifier = [NSUUID createUUID];
        
        
        NSMutableDictionary *payload = [self samplePayloadForUserID:user.remoteIdentifier];
        payload[@"user"][@"name"] = finalName;
        payload[@"user"][@"email"] = finalEmail;
        
        ZMUpdateEvent *event = [OCMockObject mockForClass:[ZMUpdateEvent class]];
        (void)[(ZMUpdateEvent *)[[(id)event stub] andReturnValue:OCMOCK_VALUE(ZMUpdateEventUserUpdate)] type];
        (void)[(ZMUpdateEvent *)[[(id)event stub] andReturn:payload] payload];
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertEqualObjects(finalName, user.name);
        XCTAssertEqualObjects(finalEmail, user.emailAddress);
    }];
}

- (void)testThatItUpdatesTheMediumImageRemoteIdentifierFromAnUpdateEvent;
{
    // given
    NSUUID *remoteID = [NSUUID createUUID];
    ZMUser *user = [self insertUserWithRemoteID:remoteID];
    NSUUID *mediumImageRemoteID = [NSUUID createUUID];
    
    NSMutableDictionary *payload = [self samplePayloadForUserID:remoteID];
    payload[@"user"][@"picture"] = @[
                                    @{
                                        @"content_length" : @51128,
                                        @"data" : @"",
                                        @"content_type" : @"image/webp",
                                        @"id" : mediumImageRemoteID.transportString,
                                        @"info" : @{
                                                @"height" : @774,
                                                @"tag" : @"medium",
                                                @"original_width" : @600,
                                                @"width" : @600,
                                                @"correlation_id" : @"e6810025c-1bef-ee0f-8605e1ca-9511317",
                                                @"original_height" : @774,
                                                @"nonce" : @"8202b5ee6-04a3-8bb8-c83ce7a7-7fa8d79",
                                                @"public" : @true
                                                }
                                        },
                                    ];
    
    ZMUpdateEvent *event = [OCMockObject mockForClass:[ZMUpdateEvent class]];
    (void)[(ZMUpdateEvent *)[[(id)event stub] andReturnValue:OCMOCK_VALUE(ZMUpdateEventUserUpdate)] type];
    (void)[(ZMUpdateEvent *)[[(id)event stub] andReturn:payload] payload];
    
    // when
    [self.syncMOC performGroupedBlockAndWait:^{
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [self.syncMOC performGroupedBlockAndWait:^{
        XCTAssertEqualObjects(user.mediumRemoteIdentifier, mediumImageRemoteID);
    }];
}

- (void)testThatItDoesNotCrashWithUpdateEventWithInvalidUserData
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        NSDictionary *payload = @{
                                  @"type" : @"user.update",
                                  @"user" : @"baz"
                                  };
        
        ZMUpdateEvent *event = [OCMockObject mockForClass:[ZMUpdateEvent class]];
        (void)[(ZMUpdateEvent *)[[(id)event stub] andReturnValue:OCMOCK_VALUE(ZMUpdateEventUserUpdate)] type];
        (void)[(ZMUpdateEvent *)[[(id)event stub] andReturn:payload] payload];
        
        // when
        [self performIgnoringZMLogError:^{
            [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        }];
    }];
}

- (void)testThatItDoesNotProcessUpdateEventWrongType
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        NSString *initialName = @"Mario";
        NSString *initialEmail = @"mario@mario.example.com";
        ZMUser *user = [ZMUser insertNewObjectInManagedObjectContext:self.uiMOC];
        user.name = initialName;
        user.emailAddress = initialEmail;
        user.remoteIdentifier = [NSUUID createUUID];
        
        NSMutableDictionary *payload = [self samplePayloadForUserID:user.remoteIdentifier];
        payload[@"type"] = @"user.foobarx";
        
        ZMUpdateEvent *event = [OCMockObject mockForClass:[ZMUpdateEvent class]];
        (void)[(ZMUpdateEvent *)[[(id)event stub] andReturnValue:OCMOCK_VALUE(ZMUpdateEventUserUpdate)] type];
        (void)[(ZMUpdateEvent *)[[(id)event stub] andReturn:payload] payload];
        
        // when
        [self.sut processEvents:@[event] liveEvents:YES prefetchResult:nil];
        
        // then
        XCTAssertEqualObjects(initialName, user.name);
        XCTAssertEqualObjects(initialEmail, user.emailAddress);
    }];
}

- (void)testThatDonwloadedUsersAreMarkAsCompletedEvenIfThePayloadDoesNotContainThem
{

    __block ZMUser *user;
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // given
        user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID];
        user.needsToBeUpdatedFromBackend = YES;
        [self.sut objectsDidChange:[NSSet setWithObject:user]];
        ZMTransportResponse *dummyResponse = [ZMTransportResponse responseWithPayload:@[] HTTPStatus:200 transportSessionError:nil];
        
        // when
        ZMTransportRequest *request = [self.sut.requestGenerators nextRequest];
        [request completeWithResponse:dummyResponse];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.syncMOC performGroupedBlockAndWait:^{
        
        // then
        XCTAssertFalse(user.needsToBeUpdatedFromBackend);
        
    }];
}

- (void)testThatNextRequestReturnsNilIfAllUsersAreComplete
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMUser *otherUser = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        [self completeUserWithRandomData:otherUser];
        
        // when
        ZMTransportRequest *req = [self.sut.requestGenerators nextRequest];
        
        // then
        XCTAssertNil(req);
    }];
}

- (void)testThatItRequestsUsersIfTheyAreIncomplete
{
    // given
    [self.syncMOC performGroupedBlockAndWait:^{
        NSArray *users = @[
            [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
            [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC],
            [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC]
        ];
        
        for (ZMUser *user in users) {
            user.remoteIdentifier = [NSUUID createUUID];
        }
        [self.sut objectsDidChange:[NSSet setWithArray:users]];
        
        // when
        ZMTransportRequest *req = [self.sut.requestGenerators nextRequest];
        
        // then
        XCTAssertNotNil(req);
        XCTAssertTrue([req.path hasPrefix:USER_PATH_WITH_QUERY]);
        
        NSString *ids = [req.path substringFromIndex:USER_PATH_WITH_QUERY.length];
        NSArray *tokenizedIds = [ids componentsSeparatedByString:@","];
        tokenizedIds = [tokenizedIds mapWithBlock:^(NSString *s) {
            return [NSUUID uuidWithTransportString:s];
        }];
        NSSet *tokenizedIdsSet = [NSSet setWithArray:tokenizedIds];
        
        XCTAssertEqual(tokenizedIdsSet.count, tokenizedIds.count);
        XCTAssertEqual(users.count, tokenizedIdsSet.count);
        for(ZMUser *user in users) {
            XCTAssertTrue([tokenizedIdsSet containsObject:user.remoteIdentifier]);
        }
        
        XCTAssertEqual(req.method,ZMMethodGET);
        XCTAssertNil(req.payload);
    }];
}

- (void)completeUserWithRandomData:(ZMUser *)user;
{
    user.name = @"Foo";
    user.accentColorValue = ZMAccentColorVividRed;
    user.emailAddress = @"foo@example.com";
    user.mediumRemoteIdentifier =  [NSUUID createUUID];
    user.localMediumRemoteIdentifier = user.mediumRemoteIdentifier;
    user.localSmallProfileRemoteIdentifier = user.mediumRemoteIdentifier;
    user.imageMediumData = [NSData dataWithBytes:(const char[]){'a'} length:1];
    user.imageSmallProfileData = [NSData dataWithBytes:(const char[]){'b'} length:1];
    user.phoneNumber = @"123";
    user.remoteIdentifier = [NSUUID createUUID];
    user.needsToBeUpdatedFromBackend = NO;
}

- (ZMUser *)insertUserWithRemoteID
{
    __block ZMUser *user;
    [self.syncMOC performGroupedBlockAndWait:^{
        user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = [NSUUID createUUID];
    }];
    return user;
}

- (ZMUser *)insertUserWithRemoteID:(NSUUID *)remoteID;
{
    __block ZMUser *user;
    [self.syncMOC performGroupedBlockAndWait:^{
        user = [ZMUser insertNewObjectInManagedObjectContext:self.syncMOC];
        user.remoteIdentifier = remoteID;
    }];
    return user;
}

- (ZMTransportResponse *)successResponseForUsersRequest:(ZMTransportRequest *)request;
{
    NSMutableArray *payload = [NSMutableArray array];
    
    XCTAssertTrue([request.path hasPrefix:USER_PATH_WITH_QUERY]);
    NSArray *idStrings = [[request.path substringFromIndex:USER_PATH_WITH_QUERY.length] componentsSeparatedByString:@","];
    for (NSString *identifier in idStrings) {
        NSDictionary *userData = @{@"id": identifier,
                                   @"accent_id": @0,
                                   @"email": @"john@example.com",
                                   @"name": @"John",
                                   @"phone": @"+49 123 456789",
                                   @"picture": @[
                                           @{
                                               @"content_length": @55,
                                               @"content_type": @"image/jpeg",
                                               @"data": @"amtoYWRmc2hqa2Fkc2Zoa2phZGZzaGtqZGFmc2toamRmYXNraGpkZnNoa2poa2pkYWZzaAo=",
                                               @"id": @"87e36dfd-1292-525b-aab1-4c8b8ca3a458",
                                               @"info": @{
                                                       @"correlation_id": @"10da31151-918a-7afb-4497e8fe-ea68e07",
                                                       @"height": @144,
                                                       @"nonce": @"1f2e0c699-b787-8ecf-7b511329-e323737",
                                                       @"original_height": @1280,
                                                       @"original_width": @960,
                                                       @"public": @YES,
                                                       @"tag": @"preview",
                                                       @"width": @108
                                                       }
                                               },
                                           @{
                                               @"content_length": @44092,
                                               @"content_type": @"image/jpeg",
                                               @"data": @"",
                                               @"id": @"1fc2a77f-b674-5575-8bd0-197ddd478a99",
                                               @"info": @{
                                                       @"correlation_id": @"10da31151-918a-7afb-4497e8fe-ea68e07",
                                                       @"height": @1280,
                                                       @"nonce": @"fac5fba55-9674-7129-73c2337d-37694ae",
                                                       @"original_height": @1280,
                                                       @"original_width": @960,
                                                       @"public": @YES,
                                                       @"tag": @"medium",
                                                       @"width": @960
                                                       }
                                               }
                                           ]
                                   };
        [payload addObject:userData];
    }
    return [ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil];
}

@end
