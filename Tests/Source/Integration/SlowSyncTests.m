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
#import "ZMLoginTranscoder+Internal.h"
#import "ZMConversationTranscoder.h"
#import "ZMConversation+Testing.h"
#import "Tests-Swift.h"


@interface SlowSyncTests : IntegrationTest

@end

@implementation SlowSyncTests

- (void)setUp
{
    [super setUp];
    [self createSelfUserAndConversation];
    [self createExtraUsersAndConversations];
}

- (void)testThatWeCanGetConnections
{
    // when
    XCTAssertTrue([self login]);
    
    // then
    NSFetchRequest *fetchRequest = [ZMConnection sortedFetchRequest];
    
    __block NSString *user1Identifier;
    __block NSString *user2Identifier;
    [self.mockTransportSession.managedObjectContext performGroupedBlockAndWait:^{
        user1Identifier = self.user1.identifier;
        user2Identifier = self.user2.identifier;
    }];

    NSArray *connections = [self.userSession.managedObjectContext executeFetchRequestOrAssert:fetchRequest];
    XCTAssertNotNil(connections);
    XCTAssertEqual(connections.count, 2u);

    XCTAssertTrue([connections containsObjectMatchingWithBlock:^BOOL(ZMConnection *obj){
        return [obj.to.remoteIdentifier.transportString isEqual:user1Identifier];
    }]);
    
    XCTAssertTrue([connections containsObjectMatchingWithBlock:^BOOL(ZMConnection *obj){
        return [obj.to.remoteIdentifier.transportString isEqual:user2Identifier];
    }]);
}


- (void)testThatWeCanGetUsers
{
    // when
    XCTAssertTrue([self login]);
    
    // then
    NSFetchRequest *fetchRequest = [ZMUser sortedFetchRequest];
    NSArray *users = [self.userSession.managedObjectContext executeFetchRequestOrAssert:fetchRequest];
    ZMUser *fetchedSelfUser = [ZMUser selfUserInContext:self.userSession.managedObjectContext];
    
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
    // given
    __block NSString *selfConversationIdentifier;
    __block NSString *selfToUser1ConversationIdentifier;
    __block NSString *selfToUser2ConversationIdentifier;
    __block NSString *groupConversationIdentifier;
    
    [self.mockTransportSession.managedObjectContext performGroupedBlockAndWait:^{
        selfConversationIdentifier =  self.selfConversation.identifier;
        selfToUser1ConversationIdentifier = self.selfToUser1Conversation.identifier;
        selfToUser2ConversationIdentifier = self.selfToUser2Conversation.identifier;
        groupConversationIdentifier = self.groupConversation.identifier;
    }];
    
    // when
    XCTAssertTrue([self login]);
    
    // then
    NSFetchRequest *fetchRequest = [ZMConversation sortedFetchRequest];
    NSArray *conversations = [self.userSession.managedObjectContext executeFetchRequestOrAssert:fetchRequest];
    
    XCTAssertNotNil(conversations);
    XCTAssertEqual(conversations.count, 3u);
    


    ZMConversation *actualSelfConversation = [ZMConversation fetchWith:[NSUUID uuidWithTransportString:selfConversationIdentifier] in:self.userSession.managedObjectContext];
    [actualSelfConversation assertMatchesConversation:self.selfConversation failureRecorder:NewFailureRecorder()];
    
    ZMConversation *actualSelfToUser1Conversation = [self findConversationWithIdentifier:selfToUser1ConversationIdentifier inMoc:self.userSession.managedObjectContext];
    [actualSelfToUser1Conversation assertMatchesConversation:self.selfToUser1Conversation failureRecorder:NewFailureRecorder()];
    
    ZMConversation *actualSelfToUser2Conversation = [self findConversationWithIdentifier:selfToUser2ConversationIdentifier inMoc:self.userSession.managedObjectContext];
    [actualSelfToUser2Conversation assertMatchesConversation:self.selfToUser2Conversation failureRecorder:NewFailureRecorder()];
    
    ZMConversation *actualGroupConversation = [self findConversationWithIdentifier:groupConversationIdentifier inMoc:self.userSession.managedObjectContext];
    [actualGroupConversation assertMatchesConversation:self.groupConversation failureRecorder:NewFailureRecorder()];
}

- (NSArray *)commonRequestsOnLogin
{
    __block NSString *selfConversationIdentifier;
    __block NSString *selfToUser1ConversationIdentifier;
    __block NSString *selfToUser2ConversationIdentifier;
    __block NSString *groupConversationIdentifier;
    __block NSString *user1Identifier;
    __block NSString *user2Identifier;
    __block NSString *user3Identifier;
    
    [self.mockTransportSession.managedObjectContext performGroupedBlockAndWait:^{
        selfConversationIdentifier =  self.selfConversation.identifier;
        selfToUser1ConversationIdentifier = self.selfToUser1Conversation.identifier;
        selfToUser2ConversationIdentifier = self.selfToUser2Conversation.identifier;
        groupConversationIdentifier = self.groupConversation.identifier;
        user1Identifier = self.user1.identifier;
        user2Identifier = self.user2.identifier;
        user3Identifier = self.user3.identifier;
    }];
    
    return @[
             [[ZMTransportRequest alloc] initWithPath:ZMLoginURL method:ZMMethodPOST payload:@{@"email":[IntegrationTest.SelfUserEmail copy], @"password":[IntegrationTest.SelfUserPassword copy], @"label": CookieLabel.current.value} authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken],
             [ZMTransportRequest requestGetFromPath:@"/self"],
             [ZMTransportRequest requestGetFromPath:@"/self"], // second request during slow sync
             [ZMTransportRequest requestGetFromPath:@"/clients"],
             [ZMTransportRequest requestGetFromPath:[NSString stringWithFormat:@"/notifications/last?client=%@",  [ZMUser selfUserInContext:self.userSession.managedObjectContext].selfClient.remoteIdentifier]],
             [ZMTransportRequest requestGetFromPath:@"/connections?size=90"],
             [ZMTransportRequest requestGetFromPath:@"/conversations/ids?size=100"],
             [ZMTransportRequest requestGetFromPath:[NSString stringWithFormat:@"/conversations?ids=%@,%@,%@,%@", selfConversationIdentifier, selfToUser1ConversationIdentifier, selfToUser2ConversationIdentifier, groupConversationIdentifier]],
             [ZMTransportRequest requestGetFromPath:@"/teams"],
             [ZMTransportRequest requestGetFromPath:@"/properties/labels"]
             ];

}

- (void)testThatItGeneratesOnlyTheExpectedRequestsForSelfUserProfilePicture
{
    // when
    XCTAssertTrue([self login]);

    __block NSString *previewProfileAssetIdentifier = nil;
    __block NSString *completeProfileAssetIdentifier = nil;
    [self.mockTransportSession.managedObjectContext performGroupedBlockAndWait:^{
        previewProfileAssetIdentifier = self.selfUser.previewProfileAssetIdentifier;
        completeProfileAssetIdentifier = self.selfUser.completeProfileAssetIdentifier;
    }];
    
    // given
    NSArray *expectedRequests = [[self commonRequestsOnLogin] arrayByAddingObjectsFromArray: @[
                                  [ZMTransportRequest imageGetRequestFromPath:[NSString stringWithFormat:@"/assets/v3/%@", previewProfileAssetIdentifier]],
                                  [ZMTransportRequest imageGetRequestFromPath:[NSString stringWithFormat:@"/assets/v3/%@", completeProfileAssetIdentifier]],
                                  [ZMTransportRequest requestWithPath:@"properties/WIRE_RECEIPT_MODE" method:ZMMethodGET payload:nil],
                                  [ZMTransportRequest requestWithPath:@"/conversations/96961d01-df3e-42f0-a9a8-ba8fb6b00035/roles" method:ZMMethodGET payload:nil]
                                  ]];
    
    // then
    NSMutableArray *mutableRequests = [self.mockTransportSession.receivedRequests mutableCopy];
    __block NSUInteger usersFetchCallCount = 0;
    __block NSUInteger clientRegistrationCallCount = 0;
    __block NSUInteger notificationStreamCallCount = 0;
    [self.mockTransportSession.receivedRequests enumerateObjectsUsingBlock:^(ZMTransportRequest *request, NSUInteger idx, BOOL *stop) {
        NOT_USED(stop);
        NOT_USED(idx);

        if ([request.path hasPrefix:@"/users?ids="] && request.method == ZMMethodGET) {
            [mutableRequests removeObject:request];
            usersFetchCallCount++;
        }

        if ([request.path containsString:@"clients"] && request.method == ZMMethodPOST) {
            [mutableRequests removeObject:request];
            clientRegistrationCallCount++;
        }

        if ([request.path containsString:@"clients"] && request.method == ZMMethodPUT) {
            [mutableRequests removeObject:request];
            clientRegistrationCallCount++;
        }

        if ([request.path hasPrefix:@"/notifications?size=500"]) {
            [mutableRequests removeObject:request];
            notificationStreamCallCount++;
        }
    }];
    XCTAssertEqual(usersFetchCallCount, 2u);
    XCTAssertEqual(clientRegistrationCallCount, 2u);
    XCTAssertEqual(notificationStreamCallCount, 1u);
    
    AssertArraysContainsSameObjects(expectedRequests, mutableRequests);
}

- (void)testThatItDoesAQuickSyncOnStartupIfAfterARestartWithoutAnyPushNotification
{
    // given
    XCTAssertTrue([self login]);
    
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    [self recreateSessionManager];
    
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

- (void)testThatTheUIIsNotifiedWhenTheSyncIsComplete
{
    // given
    NetworkStateRecorder *stateRecoder = [[NetworkStateRecorder alloc] init];
    id token = [ZMNetworkAvailabilityChangeNotification addNetworkAvailabilityObserver:stateRecoder userSession:self.userSession];
    
    // when
    XCTAssertTrue([self login]);
    
    // then
    XCTAssertEqual(stateRecoder.stateChanges_objc.count, 2u);
    ZMNetworkState state1 = (ZMNetworkState)[stateRecoder.stateChanges_objc.firstObject intValue];
    ZMNetworkState state2 = (ZMNetworkState)[stateRecoder.stateChanges_objc.lastObject intValue];

    XCTAssertEqual(state1, ZMNetworkStateOnlineSynchronizing);
    XCTAssertEqual(state2, ZMNetworkStateOnline);
    XCTAssertEqual(self.userSession.networkState, ZMNetworkStateOnline);
    
    token = nil;
}

- (void)testThatItHasTheSelfUserEmailAfterTheSlowSync
{
    // given
    XCTAssertTrue([self login]);
    
    // then
    XCTAssertNotNil([[ZMUser selfUserInUserSession:self.userSession] emailAddress]);
}

- (ZMUser *)findUserWithUUID:(NSString *)UUIDString inMoc:(NSManagedObjectContext *)moc {
    ZMUser *user = [ZMUser fetchWith:[UUIDString UUID] in:moc];
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

- (ZMConversation *)findConversationWithIdentifier:(NSString *)identifier inMoc:(NSManagedObjectContext *)moc
{

    ZMConversation *conversation = [ZMConversation fetchWith:[NSUUID uuidWithTransportString:identifier] in:moc];
    XCTAssertNotNil(conversation);
    return conversation;
}

@end


@implementation SlowSyncTests (BackgroundFetch)

- (void)testThatItFetchesTheNotificationStreamDuringBackgroundFetch
{
    // given
    XCTAssertTrue([self login]);
    
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
    WaitForAllGroupsToBeEmpty(0.5);
}

@end
