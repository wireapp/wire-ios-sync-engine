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

@import ZMCDataModel;

#import "IntegrationTestBase.h"
#import "ZMUserSession.h"
#import "ZMUserSession+Internal.h"
#import "ZMUserSession+Background+Testing.h"
#import "zmessaging_iOS_Tests-Swift.h"


@interface APNSTests : IntegrationTestBase

@end

@implementation APNSTests

- (NSDictionary *)APNSPayloadForNotificationPayload:(NSDictionary *)notificationPayload identifier:(NSUUID *)identifier {
    
    return @{ @"aps" :
                  @{
                      @"content-available" : @(1)
                      },
              @"data" :
                  @{
                      @"data": @{
                              @"id" : identifier ? identifier.transportString : @"bf96c4ce-c7d1-11e4-8001-22000a5a00c8",
                              @"payload" : @[notificationPayload],
                              @"transient" : @(0)
                              }
                      }
              };
    
}


- (NSDictionary *)APNSPayloadForNotificationPayload:(NSDictionary *)notificationPayload {
    
    return [self APNSPayloadForNotificationPayload:notificationPayload identifier:nil];
    
}


- (void)testThatAConversationIsCreatedFromAnAPNS
{
    // given
    BOOL const useAPNS = YES;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    NSString *conversationName = @"MYCONVO";
    __block NSString *conversationID;
    WaitForAllGroupsToBeEmpty(0.2);
    __block NSDictionary *conversationTransportData;
    
    ZMConversationList *conversationsList = [ZMConversationList conversationsInUserSession:self.userSession];
    NSUInteger oldCount = conversationsList.count;
    
    if(useAPNS) {
        [self.mockTransportSession closePushChannelAndRemoveConsumer]; // do not use websocket
    }
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        MockConversation *conversation = [session insertGroupConversationWithSelfUser:self.selfUser otherUsers:@[self.user1]];
        [conversation changeNameByUser:self.selfUser name:conversationName];
        conversationID = conversation.identifier;
        conversationTransportData = (NSDictionary *)conversation.transportData;
    }];
    WaitForAllGroupsToBeEmpty(0.2);
    
    NSDictionary *payload = @{
                              @"conversation" : conversationID,
                              @"data" : conversationTransportData,
                              
                              @"from" : self.user1.identifier,
                              @"time" : @"2015-03-11T09:34:00.436Z",
                              @"type" : @"conversation.create"
                              };
    
    [self.application setBackground];
    
    // when
    if(useAPNS) {
        [self.userSession receivedPushNotificationWithPayload:[self APNSPayloadForNotificationPayload:payload] completionHandler:nil source:ZMPushNotficationTypeVoIP];
    }
    WaitForEverythingToBeDone();
    
    // then
    ZMConversationList *convs = [ZMConversationList conversationsInUserSession:self.userSession];
    XCTAssertEqual(convs.count, oldCount+1);
    NSUInteger index = [conversationsList indexOfObjectPassingTest:^BOOL(ZMConversation *conversation, NSUInteger idx, BOOL *stop) {
        NOT_USED(idx);
        NOT_USED(stop);
        return [conversation.displayName isEqualToString:conversationName];
    }];
    XCTAssertNotEqual(index, (NSUInteger) NSNotFound);
    
}


- (BOOL)registerForNotifications:(NSData*)token
{
    [self.mockTransportSession resetReceivedRequests];
    [self.userSession performChanges:^{
        [self.userSession setPushToken:token];
        [self.userSession setPushKitToken:token];
        [self.uiMOC forceSaveOrRollback];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    return [self lastRequestsContainedTokenRequests];
}


- (BOOL)lastRequestsContainedTokenRequests
{
    BOOL didContainVOIPRequest = NO;
    BOOL didContainRemoteRequest = NO;
    for (ZMTransportRequest *aRequest in self.mockTransportSession.receivedRequests) {
        if (![aRequest.path isEqualToString: @"/push/tokens"]) {
            continue;
        }
        NSString *transportType = aRequest.payload[@"transport"];
        if ([transportType isEqualToString:@"APNS_VOIP"]) {
            didContainVOIPRequest = YES;
        }
        if ([transportType isEqualToString:@"APNS"]) {
            didContainRemoteRequest = YES;
        }
    }
    return (didContainRemoteRequest && didContainVOIPRequest);
}

- (void)testThatItUpdatesNewTokensIfNeeded
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    [self.mockTransportSession resetReceivedRequests];

    // given
    NSData *token = [NSData dataWithBytes:@"abc" length:3];
    NSData *newToken = [NSData dataWithBytes:@"def" length:6];
    
    XCTAssertTrue([self registerForNotifications:token]);
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    [self recreateUserSessionAndWipeCache:NO];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // expect
    id mockPushRegistrant = [OCMockObject partialMockForObject:self.userSession.pushRegistrant];
    [(ZMPushRegistrant *)[[mockPushRegistrant expect] andReturn:newToken] pushToken];
    self.application.registerForRemoteNotificationsCallback = ^{
        [self.userSession performChanges:^{
            [self.userSession application:self.application didRegisterForRemoteNotificationsWithDeviceToken:newToken];
        }];
    };
    
    // when
    [self.userSession start];

    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session simulatePushChannelOpened];
    }];
    WaitForEverythingToBeDone();

    // then
    XCTAssertTrue([self lastRequestsContainedTokenRequests], @"Did receive: %@", self.mockTransportSession.receivedRequests);
    XCTAssertEqual(self.application.registerForRemoteNotificationCount, 1u);
}

- (void)testThatItReregistersPushTokensOnDemand
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);

    // given
    NSData *token = [NSData dataWithBytes:@"abc" length:3];
    NSData *newToken = [NSData dataWithBytes:@"def" length:6];

    // when
    XCTAssertTrue([self registerForNotifications:token]);
    
    // then
    ZMTransportRequest *request = self.mockTransportSession.receivedRequests.lastObject;
    XCTAssertEqualObjects(request.path, @"/push/tokens");
    [self.mockTransportSession resetReceivedRequests];
    
    // expect
    id mockPushRegistrant = [OCMockObject partialMockForObject:self.userSession.pushRegistrant];
    [(ZMPushRegistrant *)[[mockPushRegistrant expect] andReturn:newToken] pushToken];
    self.application.registerForRemoteNotificationsCallback = ^{
        [self.userSession performChanges:^{
            [self.userSession application:self.userSession.application didRegisterForRemoteNotificationsWithDeviceToken:newToken];
        }];
    };
    
    // when
    [self.userSession resetPushTokens];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    BOOL didContainSignalingKeyRequest = NO;
    XCTAssertEqual(self.mockTransportSession.receivedRequests.count, 3u);
    for (ZMTransportRequest *aRequest in self.mockTransportSession.receivedRequests) {
        if ([aRequest.path containsString:@"/clients/"] && [aRequest.payload asDictionary][@"sigkeys"] != nil) {
            didContainSignalingKeyRequest = YES;
        }
    }
    XCTAssertTrue(didContainSignalingKeyRequest);
    XCTAssertTrue([self lastRequestsContainedTokenRequests]);
    XCTAssertEqual(self.application.registerForRemoteNotificationCount, 1u);
    [mockPushRegistrant verify];
}

- (void)testThatItReregistersPushTokensOnDemandEvenIfItDidNotChange
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);

    // given
    NSData *token = [NSData dataWithBytes:@"abc" length:3];
    
    [self registerForNotifications:token];
    XCTAssertTrue([self lastRequestsContainedTokenRequests]);
    [self.mockTransportSession resetReceivedRequests];
    
    // expect
    id mockPushRegistrant = [OCMockObject partialMockForObject:self.userSession.pushRegistrant];
    [(ZMPushRegistrant *)[[mockPushRegistrant expect] andReturn:token] pushToken];
    self.application.registerForRemoteNotificationsCallback = ^{
        [self.userSession performChanges:^{
            [self.userSession application:self.userSession.application didRegisterForRemoteNotificationsWithDeviceToken:token];
        }];
    };
    
    // when
    [self.userSession performChanges:^{
        [self.userSession resetPushTokens];
    }];
    WaitForAllGroupsToBeEmpty(1.0);
    
    // then
    BOOL didContainSignalingKeyRequest = NO;
    XCTAssertEqual(self.mockTransportSession.receivedRequests.count, 3u);
    for (ZMTransportRequest *aRequest in self.mockTransportSession.receivedRequests) {
        if ([aRequest.path containsString:@"/clients/"] && [aRequest.payload asDictionary][@"sigkeys"] != nil) {
            didContainSignalingKeyRequest = YES;
        }
    }
    XCTAssertTrue(didContainSignalingKeyRequest);
    XCTAssertTrue([self lastRequestsContainedTokenRequests]);
    XCTAssertEqual(self.application.registerForRemoteNotificationCount, 1u);
    [mockPushRegistrant verify];
}

- (void)testThatItPingsBackToTheBackendWhenReceivingAVoIPNotificationToCancelTheAPNSNotification
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.2);
    
    [self.mockTransportSession closePushChannelAndRemoveConsumer]; // do not use websocket
    
    NSUUID *identifier = NSUUID.createUUID;
    __block NSDictionary *conversationTransportData;

    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        MockConversation *conversation = [session insertGroupConversationWithSelfUser:self.selfUser otherUsers:@[self.user1]];
        conversationTransportData = (NSDictionary *)conversation.transportData;
    }];
    WaitForAllGroupsToBeEmpty(0.2);
    
    NSDictionary *payload = @{
                              @"conversation" : NSUUID.createUUID,
                              @"data" : conversationTransportData,
                              @"from" : self.user1.identifier,
                              @"time" : @"2015-03-11T09:34:00.436Z",
                              @"type" : @"conversation.create"
                              };
    [self.application setBackground];
    
    // when
    [self.mockTransportSession resetReceivedRequests];
    NSDictionary *apnsPayload = [self APNSPayloadForNotificationPayload:payload identifier:identifier];
    NSUUID *lastNotificationId = self.syncMOC.zm_lastNotificationID;
    [self.userSession receivedPushNotificationWithPayload:apnsPayload completionHandler:nil source:ZMPushNotficationTypeVoIP];
    WaitForAllGroupsToBeEmpty(0.2);
    
    // then
    NSArray <ZMTransportRequest *> *requests = self.mockTransportSession.receivedRequests;
    ZMTransportRequest *firstRequest = requests.firstObject;
    XCTAssertNotNil(firstRequest);
    XCTAssertEqual(firstRequest.method, ZMMethodGET);
    XCTAssertEqual(requests.count, 3lu); // Notification stream fetch (with fallback cancelation), GET call state, GET conversation metadata

    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    NSString *expectedPath = [NSString stringWithFormat:@"/notifications?size=500&since=%@&client=%@&cancel_fallback=%@", lastNotificationId.transportString, selfUser.selfClient.remoteIdentifier, identifier.transportString];
    XCTAssertTrue([firstRequest.path containsString:expectedPath]);
}

- (void)testThatItPingsBackToTheBackendWhenReceivingAVoIPNotificationToCancelTheAPNSNotificationAndRetiresAfter_401
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.2);
    
    [self.mockTransportSession closePushChannelAndRemoveConsumer]; // do not use websocket
    
    NSUUID *identifier = NSUUID.createUUID;

    __block NSDictionary *conversationTransportData;
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        MockConversation *conversation = [session insertGroupConversationWithSelfUser:self.selfUser otherUsers:@[self.user1]];
        conversationTransportData = (NSDictionary *)conversation.transportData;
    }];
    WaitForAllGroupsToBeEmpty(0.2);
    
    NSDictionary *payload = @{
                              @"conversation" : NSUUID.createUUID,
                              @"data" : conversationTransportData,
                              @"from" : self.user1.identifier,
                              @"time" : @"2015-03-11T09:34:00.436Z",
                              @"type" : @"conversation.create"
                              };
    
    [self.application setBackground];

    // expect
    XCTestExpectation *fetchingExpectation = [self expectationWithDescription:@"fetching notification"];
    
    __block NSUInteger callCount = 0;

    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    NSUUID *lastNotificationId = self.syncMOC.zm_lastNotificationID;
    NSString *expectedPath = [NSString stringWithFormat:@"/notifications?size=500&since=%@&client=%@&cancel_fallback=%@", lastNotificationId.transportString, selfUser.selfClient.remoteIdentifier, identifier.transportString];

    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        if ([request.path isEqualToString:expectedPath] && request.method == ZMMethodGET) {
            if (++callCount == 1) {
                return [ZMTransportResponse responseWithTransportSessionError:NSError.tryAgainLaterError];
            } else {
                [fetchingExpectation fulfill];
                return [ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil];
            }
        };
        return nil;
    };
    
    // when
    [self.mockTransportSession resetReceivedRequests];
    NSDictionary *apnsPayload = [self APNSPayloadForNotificationPayload:payload identifier:identifier];
    [self.userSession receivedPushNotificationWithPayload:apnsPayload completionHandler:nil source:ZMPushNotficationTypeVoIP];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForEverythingToBeDone();

    // then
    NSArray <ZMTransportRequest *> *requests = self.mockTransportSession.receivedRequests;
    ZMTransportRequest *lastRequest = requests.lastObject;
    XCTAssertNotNil(lastRequest);
    XCTAssertEqual(lastRequest.method, ZMMethodGET);
    XCTAssertEqual(requests.count, 2lu);
    XCTAssertEqual(callCount, 2lu);
    XCTAssertTrue([lastRequest.path containsString:expectedPath]);
    
}

- (void)testThatItFetchesTheNotificationAndPingsBackToTheBackendWhenReceivingAVoIPNotificationOfTypeNotice
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.2);
    
    [self.mockTransportSession closePushChannelAndRemoveConsumer]; // do not use websocket
    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    XCTAssertEqual(selfUser.clients.count, 1u);

    __block NSDictionary *conversationTransportData;
    
    __block NSString *convIdentifier;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        MockConversation *conversation = [session insertGroupConversationWithSelfUser:self.selfUser otherUsers:@[self.user1]];
        conversationTransportData = (NSDictionary *)conversation.transportData;
        convIdentifier = conversation.identifier;
    }];
    WaitForAllGroupsToBeEmpty(0.2);
    NSUUID *notificationID = NSUUID.createUUID;
    NSUUID *conversationID = [NSUUID uuidWithTransportString:convIdentifier];
    
    NSDictionary *eventPayload = [self conversationCreatePayloadWithNotificationID:notificationID
                                                                    conversationID:convIdentifier
                                                                     transportData:conversationTransportData
                                                                          senderID:self.user1.identifier];
    NSDictionary *notificationStreamPayload = [self notificationStreamPayloadWithNotifications:@[eventPayload]];
    NSDictionary *noticePayload = [self noticePayloadWithIdentifier:notificationID];

    [self.application setBackground];
    
    // when
    XCTestExpectation *fetchingExpectation = [self expectationWithDescription:@"fetching notification"];
    NSUUID *lastNotificationId = self.syncMOC.zm_lastNotificationID;

    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        NSString *path = [NSString stringWithFormat:@"/notifications?size=500&since=%@&client=%@&cancel_fallback=%@", lastNotificationId.transportString ,selfUser.selfClient.remoteIdentifier, notificationID.transportString];
        if ([request.path isEqualToString:path] && request.method == ZMMethodGET) {
            [fetchingExpectation fulfill];
            return [ZMTransportResponse responseWithPayload:notificationStreamPayload HTTPStatus:200 transportSessionError:nil];
        };
        return nil;
    };
    
    [self.mockTransportSession resetReceivedRequests];
    NSDictionary *apnsPayload = noticePayload;
    [self.userSession receivedPushNotificationWithPayload:apnsPayload completionHandler:nil source:ZMPushNotficationTypeVoIP];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForEverythingToBeDone();
    
    // then
    ZMConversation *conversation = [ZMConversation fetchObjectWithRemoteIdentifier:conversationID inManagedObjectContext:self.uiMOC];
    XCTAssertNotNil(conversation);
}

- (void)testThatItFetchesTheNotificationAndPingsBackToTheBackendWhenReceivingAVoIPNotificationOfTypeNotice_TriesAgainWhenReceiving_401
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.2);
    
    [self.mockTransportSession closePushChannelAndRemoveConsumer]; // do not use websocket
    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    XCTAssertEqual(selfUser.clients.count, 1u);
    
    __block NSDictionary *conversationTransportData;
    
    __block NSString *convIdentifier;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        MockConversation *conversation = [session insertGroupConversationWithSelfUser:self.selfUser otherUsers:@[self.user1]];
        conversationTransportData = (NSDictionary *)conversation.transportData;
        convIdentifier = conversation.identifier;
    }];
    WaitForAllGroupsToBeEmpty(0.2);
    NSUUID *notificationID = NSUUID.createUUID;
    NSUUID *conversationID = [NSUUID uuidWithTransportString:convIdentifier];
    
    NSDictionary *eventPayload = [self conversationCreatePayloadWithNotificationID:notificationID
                                                                    conversationID:convIdentifier
                                                                     transportData:conversationTransportData
                                                                          senderID:self.user1.identifier];
    NSDictionary *notificationStreamPayload = [self notificationStreamPayloadWithNotifications:@[eventPayload]];
    NSDictionary *noticePayload = [self noticePayloadWithIdentifier:notificationID];

    [self.application setBackground];
    
    // when
    XCTestExpectation *fetchingExpectation = [self expectationWithDescription:@"fetching notification"];
    
    __block NSUInteger requestCount = 0;
    NSUUID *lastNotificationId = self.syncMOC.zm_lastNotificationID;
    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        NSString *path = [NSString stringWithFormat:@"/notifications?size=500&since=%@&client=%@&cancel_fallback=%@", lastNotificationId.transportString, selfUser.selfClient.remoteIdentifier, notificationID.transportString];
        if ([request.path isEqualToString:path] && request.method == ZMMethodGET) {
            if (++requestCount == 2) {
                [fetchingExpectation fulfill];
                return [ZMTransportResponse responseWithPayload:notificationStreamPayload HTTPStatus:200 transportSessionError:nil];
            } else {
                return [ZMTransportResponse responseWithTransportSessionError:NSError.tryAgainLaterError];
            }
        };
        return nil;
    };
    
    [self.mockTransportSession resetReceivedRequests];
    NSDictionary *apnsPayload = noticePayload;
    [self.userSession receivedPushNotificationWithPayload:apnsPayload completionHandler:nil source:ZMPushNotficationTypeVoIP];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForEverythingToBeDone();
    
    // then
    XCTAssertEqual(requestCount, 2lu);
    ZMConversation *conversation = [ZMConversation fetchObjectWithRemoteIdentifier:conversationID inManagedObjectContext:self.uiMOC];
    XCTAssertNotNil(conversation);
}

- (void)testThatItSendsAConfirmationMessageWhenReceivingATextMessage
{
    if (BackgroundAPNSConfirmationStatus.sendDeliveryReceipts) {
        // given
        XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
        WaitForAllGroupsToBeEmpty(0.2);
        

        ZMGenericMessage *textMessage = [ZMGenericMessage messageWithText:@"Hello" nonce:[NSUUID createUUID].transportString expiresAfter:nil];
        
        [self.mockTransportSession closePushChannelAndRemoveConsumer]; // do not use websocket
        __block MockEvent *event;
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            NOT_USED(session);
            // insert message on "backend"
            event = [self.selfToUser1Conversation encryptAndInsertDataFromClient:self.user1.clients.anyObject toClient:self.selfUser.clients.anyObject data:textMessage.data];
            
            // register new client
            [session registerClientForUser:self.user1 label:@"foobar" type:@"permanent"];
        }];
        WaitForAllGroupsToBeEmpty(0.2);
        
        NSDictionary *payload = [event.transportData asDictionary];
        
        [self.application setBackground];
        [self.application simulateApplicationDidEnterBackground];
        WaitForAllGroupsToBeEmpty(0.2);
        
        XCTestExpectation *confirmationExpectation = [self expectationWithDescription:@"Did send confirmation"];
        XCTestExpectation *missingClientsExpectation = [self expectationWithDescription:@"Did fetch missing client"];
        __block NSUInteger requestCount = 0;
        self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
            NSString *confirmationPath = [NSString stringWithFormat:@"/conversations/%@/otr/messages?report_missing=", self.selfToUser1Conversation.identifier];
            if ([request.path hasPrefix:confirmationPath] && request.method == ZMMethodPOST) {
                XCTAssertTrue(request.shouldUseVoipSession);
                requestCount++;
                if (requestCount == 2) {
                    [confirmationExpectation fulfill];
                }
            }
            NSString *clientsPath = [NSString stringWithFormat:@"/users/prekeys"];
            if ([request.path isEqualToString:clientsPath]) {
                XCTAssertTrue(request.shouldUseVoipSession);
                XCTAssertEqual(requestCount, 1u);
                [missingClientsExpectation fulfill];
            }
            return nil;
        };
        
        // when
        [self.userSession receivedPushNotificationWithPayload:[self APNSPayloadForNotificationPayload:payload] completionHandler:nil source:ZMPushNotficationTypeVoIP];
        XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
        WaitForAllGroupsToBeEmpty(0.2);
    }
}


#pragma mark - Helper

- (NSDictionary *)conversationCreatePayloadWithNotificationID:(NSUUID *)notificationID
                                               conversationID:(NSString *)conversationID
                                                transportData:(NSDictionary *)transportData
                                                     senderID:(NSString *)senderID
{
    return @{
             @"id" :notificationID.transportString,
             @"payload" : @[
                     @{
                         @"conversation" : conversationID,
                         @"data" : transportData,
                         @"from" : senderID,
                         @"time" : @"2015-03-11T09:34:00.436Z",
                         @"type" : @"conversation.create"
                         }
                     ]
             };
}

- (NSDictionary *)notificationStreamPayloadWithNotifications:(NSArray <NSDictionary *>*)notifications
{
    return @{
             @"notifications": notifications,
             @"hasMore": @NO
             };
}

- (NSDictionary *)noticePayloadWithIdentifier:(NSUUID *)uuid
{
    return @{
             @"aps" : @{},
             @"data" : @{
                     @"data" : @{ @"id" : uuid.transportString },
                     @"type" : @"notice"
                     }
             };
}


@end
