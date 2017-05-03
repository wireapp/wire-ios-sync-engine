//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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

@import Foundation;
@import WireRequestStrategy;
@import WireTransport;
@import WireMockTransport;
@import WireSyncEngine;
@import WireDataModel;

#import "MessagingTest.h"
#import "ZMUserSession+Internal.h"
#import "IntegrationTestBase.h"
#import "ZMUserSession+Internal.h"
#import "ZMLoginTranscoder+Internal.h"
#import "ZMConversationTranscoder.h"
#import "ZMConversation+Testing.h"
#import "WireSyncEngine_iOS_Tests-Swift.h"


@interface SlowSyncTests : IntegrationTestBase

@end



@implementation SlowSyncTests

- (void)testThatWeCanGetConnections
{
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    // then
    NSFetchRequest *fetchRequest = [ZMConnection sortedFetchRequest];


    NSArray *connections = [self.userSession.managedObjectContext executeFetchRequestOrAssert:fetchRequest];
    XCTAssertNotNil(connections);
    XCTAssertEqual(connections.count, 2u);

    XCTAssertTrue([connections containsObjectMatchingWithBlock:^BOOL(ZMConnection *obj){
        return [obj.to.remoteIdentifier isEqual:[self remoteIdentifierForMockObject:self.user1]];
    }]);
    
    XCTAssertTrue([connections containsObjectMatchingWithBlock:^BOOL(ZMConnection *obj){
        return [obj.to.remoteIdentifier isEqual:[self remoteIdentifierForMockObject:self.user2]];
    }]);
}


- (void)testThatWeCanGetUsers
{
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    // then
    NSFetchRequest *fetchRequest = [ZMUser sortedFetchRequest];

    
    NSArray *users = [self.uiMOC executeFetchRequestOrAssert:fetchRequest];
    ZMUser *fetchedSelfUser = [ZMUser selfUserInContext:self.uiMOC];
    
    XCTAssertNotNil(users);
    
    XCTAssertTrue(users.count >= 3u);

    XCTAssertTrue([self isActualUser:fetchedSelfUser equalToMockUser:self.selfUser failureRecorder:NewFailureRecorder()]);
    
    ZMUser *actualUser1 = [self userForMockUser:self.user1];
    XCTAssertTrue([self isActualUser:actualUser1 equalToMockUser:self.user1 failureRecorder:NewFailureRecorder()]);
    
    ZMUser *actualUser2 = [self userForMockUser:self.user2];
    XCTAssertTrue([self isActualUser:actualUser2 equalToMockUser:self.user2 failureRecorder:NewFailureRecorder()]);
}


- (void)testThatWeCanGetConversations
{
    
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // then
    NSFetchRequest *fetchRequest = [ZMConversation sortedFetchRequest];
    NSArray *conversations = [self.uiMOC executeFetchRequestOrAssert:fetchRequest];
    
    XCTAssertNotNil(conversations);
    XCTAssertEqual(conversations.count, 3u);
    
    
    ZMConversation *actualSelfConversation = [ZMConversation conversationWithRemoteID:[self remoteIdentifierForMockObject:self.selfConversation] createIfNeeded:NO inContext:self.uiMOC];
    [actualSelfConversation assertMatchesConversation:self.selfConversation failureRecorder:NewFailureRecorder()];
    
    ZMConversation *actualSelfToUser1Conversation = [self findConversationWithUUID:[self remoteIdentifierForMockObject:self.selfToUser1Conversation] inMoc:self.uiMOC];
    [actualSelfToUser1Conversation assertMatchesConversation:self.selfToUser1Conversation failureRecorder:NewFailureRecorder()];
    
    ZMConversation *actualSelfToUser2Conversation = [self findConversationWithUUID:[self remoteIdentifierForMockObject:self.selfToUser2Conversation] inMoc:self.uiMOC];
    [actualSelfToUser2Conversation assertMatchesConversation:self.selfToUser2Conversation failureRecorder:NewFailureRecorder()];
    
    ZMConversation *actualGroupConversation = [self findConversationWithUUID:[self remoteIdentifierForMockObject:self.groupConversation] inMoc:self.uiMOC];
    [actualGroupConversation assertMatchesConversation:self.groupConversation failureRecorder:NewFailureRecorder()];
}

- (NSArray *)commonRequestsOnLogin {
    return @[
             [[ZMTransportRequest alloc] initWithPath:ZMLoginURL method:ZMMethodPOST payload:@{@"email":[self.selfUser.email copy], @"password":[self.selfUser.password copy], @"label": self.userSession.authenticationStatus.cookieLabel} authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken],
             [ZMTransportRequest requestGetFromPath:@"/self"],
             [ZMTransportRequest requestGetFromPath:@"/clients"],
             [ZMTransportRequest requestGetFromPath:[NSString stringWithFormat:@"/notifications/last?client=%@",  [ZMUser selfUserInContext:self.syncMOC].selfClient.remoteIdentifier]],
             [ZMTransportRequest requestGetFromPath:@"/connections?size=90"],
             [ZMTransportRequest requestGetFromPath:@"/conversations/ids?size=100"],
             [ZMTransportRequest requestGetFromPath:[NSString stringWithFormat:@"/conversations?ids=%@,%@,%@,%@", self.selfConversation.identifier,self.selfToUser1Conversation.identifier,self.selfToUser2Conversation.identifier,self.groupConversation.identifier]],
             [ZMTransportRequest requestGetFromPath:[NSString stringWithFormat:@"/users?ids=%@,%@,%@", self.selfUser.identifier, self.user1.identifier, self.user2.identifier]],
             [ZMTransportRequest requestGetFromPath:[NSString stringWithFormat:@"/users?ids=%@", self.user3.identifier]],
             [ZMTransportRequest requestWithPath:@"/onboarding/v3" method:ZMMethodPOST payload:@{
                                                                                                                @"cards" : @[],
                                                                                                                @"self" : @[@"r6E0oILa7PsAlgL+tap6ZEYhOm2y3SVfKJe1eDTVKcw="]
                                                                                                                      }]
             ];

}

- (void)testThatItGeneratesOnlyTheExpectedRequestsForUserWithoutV3ProfilePicture
{
    // when
    [[self mockTransportSession] performRemoteChanges:^(id<MockTransportSessionObjectCreation> session) {
        NOT_USED(session);
        self.selfUser.completeProfileAssetIdentifier = nil;
        self.selfUser.previewProfileAssetIdentifier = nil;
    }];
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    [NSThread sleepForTimeInterval:0.2]; // sleep to wait for spurious calls
    
    NSDictionary *assetsUpdatePayload = @{
                                          @"assets":
                                              @[
                                                  @{@"key" : self.selfUser.previewProfileAssetIdentifier, @"type" : @"image", @"size" : @"preview"},
                                                  @{@"key" : self.selfUser.completeProfileAssetIdentifier, @"type" : @"image", @"size" : @"complete"},
                                                  ]
                                          };
    
    ZMUser *localUser = [ZMUser selfUserInContext:self.syncMOC];
    AssetRequestFactory *factory = [[AssetRequestFactory alloc] init];

    // given
    NSArray *expectedRequests = [[self commonRequestsOnLogin] arrayByAddingObjectsFromArray: @[
                                  [factory profileImageAssetRequestWithData:localUser.imageMediumData],
                                  [factory profileImageAssetRequestWithData:localUser.imageSmallProfileData],
                                  [ZMTransportRequest requestWithPath:@"/self" method:ZMMethodPUT payload:assetsUpdatePayload],
                                  [ZMTransportRequest imageGetRequestFromPath:[NSString stringWithFormat:@"/assets/%@?conv_id=%@",self.selfUser.smallProfileImageIdentifier,self.selfUser.identifier]],
                                  [ZMTransportRequest imageGetRequestFromPath:[NSString stringWithFormat:@"/assets/%@?conv_id=%@",self.selfUser.mediumImageIdentifier, self.selfUser.identifier]]
                                  ]];
    
    // then
    NSMutableArray *mutableRequests = [self.mockTransportSession.receivedRequests mutableCopy];
    __block NSUInteger clientRegistrationCallCount = 0;
    __block NSUInteger notificationStreamCallCount = 0;
    [self.mockTransportSession.receivedRequests enumerateObjectsUsingBlock:^(ZMTransportRequest *request, NSUInteger idx, BOOL *stop) {
        NOT_USED(stop);
        NOT_USED(idx);
        if ([request.path containsString:@"clients"] && request.method == ZMMethodPOST) {
            [mutableRequests removeObject:request];
            clientRegistrationCallCount++;
        }
        if ([request.path hasPrefix:@"/notifications?size=500"]) {
            [mutableRequests removeObject:request];
            notificationStreamCallCount++;
        }
    }];
    XCTAssertEqual(clientRegistrationCallCount, 1u);
    XCTAssertEqual(notificationStreamCallCount, 1u);
    
    AssertArraysContainsSameObjects(expectedRequests, mutableRequests);
}

- (void)testThatItGeneratesOnlyTheExpectedRequestsForUserWithV3ProfilePicture
{
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    [NSThread sleepForTimeInterval:0.2]; // sleep to wait for spurious calls
    
    // given
    NSArray *expectedRequests = [[self commonRequestsOnLogin] arrayByAddingObjectsFromArray: @[
                                  [ZMTransportRequest requestGetFromPath:@"/self"],
                                  [ZMTransportRequest imageGetRequestFromPath:[NSString stringWithFormat:@"/assets/v3/%@",self.selfUser.previewProfileAssetIdentifier]],
                                  [ZMTransportRequest imageGetRequestFromPath:[NSString stringWithFormat:@"/assets/v3/%@",self.selfUser.completeProfileAssetIdentifier]]
                                  ]];
    
    // then
    NSMutableArray *mutableRequests = [self.mockTransportSession.receivedRequests mutableCopy];
    __block NSUInteger clientRegistrationCallCount = 0;
    __block NSUInteger notificationStreamCallCount = 0;
    [self.mockTransportSession.receivedRequests enumerateObjectsUsingBlock:^(ZMTransportRequest *request, NSUInteger idx, BOOL *stop) {
        NOT_USED(stop);
        NOT_USED(idx);
        if ([request.path containsString:@"clients"] && request.method == ZMMethodPOST) {
            [mutableRequests removeObject:request];
            clientRegistrationCallCount++;
        }
        
        if ([request.path hasPrefix:@"/notifications?size=500"]) {
            [mutableRequests removeObject:request];
            notificationStreamCallCount++;
        }
    }];
    XCTAssertEqual(clientRegistrationCallCount, 1u);
    XCTAssertEqual(notificationStreamCallCount, 1u);
    
    AssertArraysContainsSameObjects(expectedRequests, mutableRequests);
}

- (void)testThatItDoesAQuickSyncOnStartupIfAfterARestartWithoutAnyPushNotification
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    [self recreateUserSessionAndWipeCache:NO];
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // then
    BOOL hasNotificationsRequest = NO;
    for (ZMTransportRequest *request in self.mockTransportSession.receivedRequests) {
        
        if ([request.path hasPrefix:@"/notifications"]) {
            hasNotificationsRequest = YES;
        }
        
        XCTAssertFalse([request.path hasPrefix:@"/conversations"]);
        XCTAssertFalse([request.path hasPrefix:@"/connections"]);
    }
    
    XCTAssertTrue(hasNotificationsRequest);
}



- (void)testThatItDoesAQuickSyncOnStartupIfItHasReceivedNotificationsEarlier
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);

    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        ZMGenericMessage *message = [ZMGenericMessage messageWithText:@"Hello, Test!" nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        [self.groupConversation encryptAndInsertDataFromClient:self.user1.clients.anyObject toClient:self.selfUser.clients.anyObject data:message.data];
    }];
    WaitForEverythingToBeDone();
    
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    [self recreateUserSessionAndWipeCache:NO];
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // then
    BOOL hasNotificationsRequest = NO;
    for (ZMTransportRequest *request in self.mockTransportSession.receivedRequests) {
        
        if ([request.path hasPrefix:@"/notifications"]) {
            hasNotificationsRequest = YES;
        }
        
        XCTAssertFalse([request.path hasPrefix:@"/conversations"]);
        XCTAssertFalse([request.path hasPrefix:@"/connections"]);
    }
    
    XCTAssertTrue(hasNotificationsRequest);
}

- (void)testThatItDoesAQuickSyncAfterTheWebSocketWentDown
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        ZMGenericMessage *message = [ZMGenericMessage messageWithText:@"Hello, Test!" nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        [self.groupConversation encryptAndInsertDataFromClient:self.user1.clients.anyObject toClient:self.selfUser.clients.anyObject data:message.data];
    }];
    WaitForEverythingToBeDone();
    
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session simulatePushChannelClosed];
        [session simulatePushChannelOpened];
    }];
    WaitForEverythingToBeDone();
    
    // then
    BOOL hasNotificationsRequest = NO;
    for (ZMTransportRequest *request in self.mockTransportSession.receivedRequests) {
        
        if ([request.path hasPrefix:@"/notifications"]) {
            hasNotificationsRequest = YES;
        }
        
        XCTAssertFalse([request.path hasPrefix:@"/conversations"]);
        XCTAssertFalse([request.path hasPrefix:@"/connections"]);
    }
    
    XCTAssertTrue(hasNotificationsRequest);
}

- (void)testThatItDoesASlowSyncAfterTheWebSocketWentDownAndNotificationsReturnsAnError
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        ZMGenericMessage *message = [ZMGenericMessage messageWithText:@"Hello, Test!" nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        [self.groupConversation encryptAndInsertDataFromClient:self.user1.clients.anyObject toClient:self.selfUser.clients.anyObject data:message.data];
    }];
    WaitForEverythingToBeDone();
    
    [self.mockTransportSession resetReceivedRequests];

    // make /notifications fail
    __block BOOL hasNotificationsRequest = NO;
    __block BOOL hasConversationsRequest = NO;
    __block BOOL hasConnectionsRequest = NO;
    __block BOOL hasUserRequest = NO;

    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        if([request.path hasPrefix:@"/notifications"]) {
            if (!(hasConnectionsRequest && hasConversationsRequest && hasUserRequest)) {
                return [ZMTransportResponse responseWithPayload:nil HTTPStatus:404 transportSessionError:nil];
            }
            hasNotificationsRequest = YES;
        }
        if ([request.path hasPrefix:@"/users"]) {
            hasUserRequest = YES;
        }
        if ([request.path hasPrefix:@"/conversations?ids="]) {
            hasConversationsRequest = YES;
        }
        if ([request.path hasPrefix:@"/connections?size="]) {
            hasConnectionsRequest = YES;
        }
        return nil;
    };

    
    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session simulatePushChannelClosed];
        [session simulatePushChannelOpened];
    }];
    WaitForEverythingToBeDone();
    
    // then

    XCTAssertTrue(hasNotificationsRequest);
    XCTAssertTrue(hasUserRequest);
    XCTAssertTrue(hasConversationsRequest);
    XCTAssertTrue(hasConnectionsRequest);
}

- (void)testThatTheUIIsNotifiedWhenTheSyncIsComplete
{
    // given
    id observer = [OCMockObject mockForProtocol:@protocol(ZMNetworkAvailabilityObserver)];
    [ZMNetworkAvailabilityChangeNotification addNetworkAvailabilityObserver:observer userSession:self.userSession];
    
    // expect
    NSMutableArray *receivedNotes = [NSMutableArray array];
    [[observer stub] didChangeAvailability:[OCMArg checkWithBlock:^BOOL(ZMNetworkAvailabilityChangeNotification *note) {
        [receivedNotes addObject:note];
        return YES;
    }]];
    
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    // then
    [observer verify];
    [ZMNetworkAvailabilityChangeNotification removeNetworkAvailabilityObserver:observer];
    
    XCTAssertEqual(receivedNotes.count, 1u);
    ZMNetworkAvailabilityChangeNotification *note1 = receivedNotes[0];

    XCTAssertNotNil(note1);

    XCTAssertEqual(note1.networkState, ZMNetworkStateOnline);
    
    XCTAssertEqual(self.userSession.networkState, ZMNetworkStateOnline);
}

- (ZMUser *)findUserWithUUID:(NSString *)UUIDString inMoc:(NSManagedObjectContext *)moc {
    ZMUser *user = [ZMUser userWithRemoteID:[UUIDString UUID] createIfNeeded:NO inContext:moc];
    XCTAssertNotNil(user);
    return user;
}


- (BOOL)isActualUser:(ZMUser *)user equalToMockUser:(MockUser *)mockUser failureRecorder:(ZMTFailureRecorder *)failureRecorder;
{
    __block NSDictionary *values;
    [mockUser.managedObjectContext performBlockAndWait:^{
        values = [[mockUser committedValuesForKeys:nil] copy];
    }];
    
    BOOL emailAndPhoneMatches = YES;
    if (user.isSelfUser) {
        FHAssertEqualObjects(failureRecorder, user.emailAddress, values[@"email"]);
        FHAssertEqualObjects(failureRecorder, user.phoneNumber, values[@"phone"]);
        emailAndPhoneMatches = (user.emailAddress == values[@"email"] || [user.emailAddress isEqualToString:values[@"email"]]) &&
                               (user.phoneNumber == values[@"phone"] || [user.phoneNumber isEqualToString:values[@"phone"]]);
    }
    FHAssertEqualObjects(failureRecorder, user.name, values[@"name"]);
    FHAssertEqual(failureRecorder, user.accentColorValue, (ZMAccentColor) [values[@"accentID"] intValue]);
    
    return ((user.name == values[@"name"] || [user.name isEqualToString:values[@"name"]])
            && emailAndPhoneMatches
            && (user.accentColorValue == (ZMAccentColor) [values[@"accentID"] intValue]));
}

- (ZMConversation *)findConversationWithUUID:(NSUUID *)UUID inMoc:(NSManagedObjectContext *)moc
{
    ZMConversation *conversation = [ZMConversation conversationWithRemoteID:UUID createIfNeeded:NO inContext:moc];
    XCTAssertNotNil(conversation);
    return conversation;
}

@end


@implementation SlowSyncTests (BackgroundFetch)

- (void)testThatItFetchesTheNotificationStreamDuringBackgroundFetch
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.application setBackground];
    [self.application simulateApplicationDidEnterBackground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    XCTestExpectation *expectation = [self expectationWithDescription:@"fetchCompleted"];
    [self.userSession application:self.application performFetchWithCompletionHandler:^(UIBackgroundFetchResult result) {
        NOT_USED(result);
        ZMTransportRequest *request = self.mockTransportSession.receivedRequests.lastObject;
        XCTAssertNotNil(request);
        XCTAssertTrue([request.path containsString:@"notifications"]);
        [expectation fulfill];
    }];
    
    // then
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
}

@end
