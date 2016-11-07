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


#import "IntegrationTestBase.h"
#import "ConversationTestsBase.h"
#import "NotificationObservers.h"

@import ZMCDataModel;
@import ZMUtilities;

@interface ConversationTestsOTR : ConversationTestsBase

- (ZMGenericMessage*)sessionMessage:(NSDictionary *)eventPayload fromClient:(MockUserClient *)fromClient toClient:(MockUserClient *)toClient;

@end

@implementation ConversationTestsOTR

- (ZMGenericMessage*)sessionMessage:(NSDictionary *)eventPayload fromClient:(MockUserClient *)fromClient toClient:(MockUserClient *)toClient
{
    NSString *encryptedDataString = eventPayload[@"data"][@"text"];
    XCTAssertNotNil(encryptedDataString);
    
    NSData *encryptedData = [[NSData alloc] initWithBase64EncodedString:encryptedDataString options:0];
    NSData *decryptedData = [MockUserClient sessionMessageDataForEncryptedDataFromClient:fromClient toClient:toClient data:encryptedData];
    
    XCTAssertNotNil(decryptedData);
    if (decryptedData == nil) {
        return nil;
    }
    ZMGenericMessage *genericMessage = (ZMGenericMessage *)[[[ZMGenericMessage builder] mergeFromData:decryptedData] build];
    return genericMessage;
}

- (void)testThatItAppendsOTRMessages
{
    self.registeredOnThisDevice = YES;
    
    NSString *expectedText1 = @"The sky above the port was the color of ";
    NSString *expectedText2 = @"television, tuned to a dead channel.";
    
    NSUUID *nonce1 = [NSUUID createUUID];
    NSUUID *nonce2 = [NSUUID createUUID];
    
    ZMGenericMessage *genericMessage1 = [ZMGenericMessage messageWithText:expectedText1 nonce:nonce1.transportString expiresAfter:nil];
    ZMGenericMessage *genericMessage2 = [ZMGenericMessage messageWithText:expectedText2 nonce:nonce2.transportString expiresAfter:nil];
    
    [self testThatItAppendsMessageToConversation:self.groupConversation withBlock:^NSArray *(MockTransportSession<MockTransportSessionObjectCreation> * session){
        
        EncryptionContext *box = self.userSession.syncManagedObjectContext.zm_cryptKeyStore.encryptionContext;
        __block NSArray *selfPreKeys;
        __block NSError *error;
        [box perform:^(EncryptionSessionsDirectory * _Nonnull sessionsDirectory) {
            NSString *preKey1 = [sessionsDirectory generatePrekey:0 error:&error];
            NSString *preKey2 = [sessionsDirectory generatePrekey:1 error:&error];
            selfPreKeys = @[preKey1, preKey2];
        }];
        
        //1. remotely register self client
        MockUserClient *selfClient = self.selfUser.clients.anyObject;
        
        [self inserOTRMessage:genericMessage1 inConversation:self.groupConversation fromUser:self.user2 toClient:selfClient usingKey:selfPreKeys[0] session:session];
        [self inserOTRMessage:genericMessage2 inConversation:self.groupConversation fromUser:self.user3 toClient:selfClient usingKey:selfPreKeys[1] session:session];
        
        return @[nonce1, nonce2];
    } verify:^(ZMConversation *conversation) {
        //check that we successfully decrypted messages
        XCTAssert(conversation.messages.count > 0);
        if (conversation.messages.count < 2) {
            XCTFail(@"message count is too low");
        } else {
            ZMClientMessage *msg1 = conversation.messages[conversation.messages.count - 2];
            XCTAssertEqualObjects(msg1.nonce, nonce1);
            XCTAssertEqualObjects(msg1.genericMessage.text.content, expectedText1);
            
            ZMClientMessage *msg2 = conversation.messages[conversation.messages.count - 1];
            XCTAssertEqualObjects(msg2.nonce, nonce2);
            XCTAssertEqualObjects(msg2.genericMessage.text.content, expectedText2);
        }
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatOtrMessageIsDelivered:(BOOL)shouldBeDelivered
   shouldEstablishSessionBetweenUsers:(BOOL)shouldEstablishSessionBetweenUsers
                        createMessage:(ZMMessage *(^)(ZMConversation *conversation))createMessage
                 withReadMessageBlock:(void(^)(MockPushEvent *lastEvent, EncryptionContext *user1Box))readMessage
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);

    //register other users clients
    EncryptionContext *user1Box = [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:shouldEstablishSessionBetweenUsers];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    // when
    [self.userSession performChanges:^{
        message = createMessage(conversation);
    }];
    
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    // then
    if (shouldBeDelivered) {
        MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;

        //check that recipient can read this message
        if (readMessage) {
            readMessage(lastEvent, user1Box);
        }
    }
    else {
        // then
        MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
        NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
        ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
        
        XCTAssertNotEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
        XCTAssertEqual(message.deliveryState, ZMDeliveryStatePending);
    }
}

- (void)testThatItDeliveresOTRMessageIfNoMissingClients
{
    //given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSString *messageText = @"Hey!";
    __block ZMClientMessage *message;
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    //this fetch the missing client
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:@"Bonsoir, je voudrais un croissant" nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:messageText nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    // then
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    //check that recipient can read this message
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    MockUserClient *user1Client = [self.user1.clients anyObject];
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    
    ZMGenericMessage *genericMessage = [self sessionMessage:lastEventPayload fromClient:selfClient toClient:user1Client];
    XCTAssertEqualObjects(genericMessage.text.content, messageText);

}

- (void)testThatItDeliveresOTRAssetIfNoMissingClients
{
    __block ZMAssetClientMessage *message;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];

    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDone();
    
    // then
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    
    
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertEqual(lastEventType, ZMTUpdateEventConversationOTRAssetAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    UserClient *selfClient = selfUser.selfClient;
    XCTAssertEqual(selfClient.missingClients.count, 0u);
    XCTAssertFalse([message hasLocalModificationsForKey:ZMAssetClientMessageUploadedStateKey]);
    XCTAssertEqual(message.uploadState, ZMAssetUploadStateDone);
}

- (void)testThatItAsksForMissingClientsKeysWhenDeliveringOtrMessage
{
    NSString *messageText = @"Hey!";

    __block BOOL askedForPreKeys = NO;
    [self.mockTransportSession setResponseGeneratorBlock:^ ZMTransportResponse *(ZMTransportRequest *__unused request) {
        if ([request.path.pathComponents containsObject:@"prekeys"]) {
            askedForPreKeys = YES;
            return ResponseGenerator.ResponseNotCompleted;
        }
        return nil;
    }];

    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:messageText nonce:[NSUUID createUUID]];
    }];
    
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertNotEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStatePending);
    
    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    UserClient *selfClient = selfUser.selfClient;
    
    XCTAssertTrue(selfClient.missingClients.count > 0);
    XCTAssertTrue(askedForPreKeys);
}

- (void)testThatItSendsFailedOTRMessageAfterMissingClientsAreFetchedButSessionIsNotCreated
{
    // GIVEN
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    //register other users clients
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    [self.mockTransportSession setResponseGeneratorBlock:^ ZMTransportResponse *(ZMTransportRequest *__unused request) {
        if ([request.path.pathComponents containsObject:@"prekeys"]) {
            return [ZMTransportResponse responseWithPayload:@{
                                                              self.user1.identifier: @{
                                                                      [(MockUserClient *)self.user1.clients.anyObject identifier]: @{
                                                                              @"id": @0,
                                                                              @"key": [@"invalid key" dataUsingEncoding:NSUTF8StringEncoding].base64String
                                                                              }
                                                                      }
                                                              } HTTPStatus:201 transportSessionError:nil];
        }
        return nil;
    }];
    
    // WHEN
    __block id <ZMConversationMessage> message;
    [self.mockTransportSession resetReceivedRequests];

    [self performIgnoringZMLogError:^{
        [self.userSession performChanges:^{
            message = [conversation appendMessageWithText:@"Hello World"];
        }];
        WaitForEverythingToBeDoneWithTimeout(5);

    }];

    // THEN
    NSString *expectedPath = [NSString stringWithFormat:@"/conversations/%@/otr", conversation.remoteIdentifier.transportString];
    
    // then we expect it to receive a bomb message
    // when resending after fetching the (faulty) prekeys
    NSUInteger messagesReceived = 0;
    
    for (ZMTransportRequest *req in self.mockTransportSession.receivedRequests) {
        
        if (! [req.path hasPrefix:expectedPath]) {
            continue;
        }
        
        ZMNewOtrMessage *otrMessage = [ZMNewOtrMessage parseFromData:req.binaryData];
        XCTAssertNotNil(otrMessage);
        
        NSArray <ZMUserEntry *>* userEntries = otrMessage.recipients;
        ZMClientEntry *clientEntry = [userEntries.firstObject.clients firstObject];
        
        if ([clientEntry.text isEqualToData:[@"💣" dataUsingEncoding:NSUTF8StringEncoding]]) {
            messagesReceived++;
        }
    }
    
    XCTAssertEqual(messagesReceived, 1lu);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
}

- (void)testThatItDeliveresOTRMessageAfterMissingClientsAreFetched
{
    NSString *messageText = @"Hey!";
    __block ZMClientMessage *message;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:messageText nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    // then
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    //check that recipient can read this message
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    MockUserClient *user1Client = [self.user1.clients anyObject];
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    
    ZMGenericMessage *genericMessage = [self sessionMessage:lastEventPayload fromClient:selfClient toClient:user1Client];
    XCTAssertEqualObjects(genericMessage.text.content, messageText);
}

- (void)testThatItDeliveresOTRAssetAfterMissingClientsAreFetched
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    __block ZMAssetClientMessage *message;

    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
    }];
    
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    // then
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    //check that recipient can read this message
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertEqual(lastEventType, ZMTUpdateEventConversationOTRAssetAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    UserClient *selfClient = selfUser.selfClient;
    XCTAssertEqual(selfClient.missingClients.count, 0u);
}


- (void)testThatItResetsKeysIfClientUnknown
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    self.mockTransportSession.responseGeneratorBlock = ^ ZMTransportResponse *(ZMTransportRequest *__unused request) {
        if ([request.path.pathComponents containsObject:@"assets"]) {
            return [ZMTransportResponse responseWithPayload:@{ @"label" : @"unknown-client"} HTTPStatus:403 transportSessionError:nil];
        }
        return nil;
    };
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMAssetClientMessage *message;
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    // then
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertNotEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStatePending);
    
    XCTAssertFalse([message hasLocalModificationsForKey:ZMAssetClientMessageUploadedStateKey]);
    XCTAssertEqual(message.uploadState, ZMAssetUploadStateUploadingFailed);
    
}

- (void)testThatItNotifiesIfThereAreNewRemoteClients
{
    ZMUser *selfUser = [ZMUser selfUserInContext:self.uiMOC];
    UserChangeObserver *observer = [[UserChangeObserver alloc] initWithUser:selfUser];

    [self testThatOtrMessageIsDelivered:YES
     shouldEstablishSessionBetweenUsers:YES
                          createMessage:^ ZMMessage *(ZMConversation *conversation){
                              return [conversation appendOTRMessageWithText:@"Hey!" nonce:[NSUUID createUUID]];
                          }
                   withReadMessageBlock:^(__unused MockPushEvent *lastEvent,__unused EncryptionContext *user1Box) {
                       XCTAssertTrue([observer.notifications.firstObject clientsChanged]);
                   }];

    // after
    [observer tearDown];
}

- (void)testThatItDeliversTwoOTRAssetMessages
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    //register other users clients
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        for(int i = 0; i < 7; ++i) {
            MockUser *user = [session insertUserWithName:[NSString stringWithFormat:@"TestUser %d", i+1]];
            user.email = [NSString stringWithFormat:@"user%d@example.com", i+1];
            user.accentID = 4;
            [self storeRemoteIDForObject:user];
            [self setupOTREnvironmentForUser:user isSelfClient:NO numberOfKeys:10 establishSessionWithSelfUser:NO];
            [self.groupConversation addUsersByUser:user addedUsers:@[user]];
        }
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversation];
    
    __block ZMMessage *imageMessage1;
    // when
    [self.userSession performChanges:^{
        imageMessage1 = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
    }];
    
    __block ZMMessage *textMessage;
    [self.userSession performChanges:^{
        textMessage = [conversation appendOTRMessageWithText:@"foobar" nonce:[NSUUID createUUID]];
    }];
    
    __block ZMMessage *imageMessage2;
    // and when
    [self.userSession performChanges:^{
        imageMessage2 = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
        
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertEqual(imageMessage1.deliveryState, ZMDeliveryStateSent);
    XCTAssertEqual(textMessage.deliveryState, ZMDeliveryStateSent);
    XCTAssertEqual(imageMessage2.deliveryState, ZMDeliveryStateSent);
}

- (void)testThatItSendsFailedSessionOTRAssetMessageAfterMissingClientsAreFetchedButSessionIsNotCreated
{
    // GIVEN
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    //register other users clients
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMAssetClientMessage *message;
    
    [self.mockTransportSession setResponseGeneratorBlock:^ ZMTransportResponse *(ZMTransportRequest *__unused request) {
        if ([request.path.pathComponents containsObject:@"prekeys"]) {
            return [ZMTransportResponse responseWithPayload:@{
                                                              self.user1.identifier: @{
                                                                      [(MockUserClient *)self.user1.clients.anyObject identifier]: @{
                                                                              @"id": @0,
                                                                              @"key": [@"invalid key" dataUsingEncoding:NSUTF8StringEncoding].base64String
                                                                              }
                                                                      }
                                                              } HTTPStatus:201 transportSessionError:nil];
        }
        return nil;
    }];

    // WHEN
    [self.mockTransportSession resetReceivedRequests];
    [self performIgnoringZMLogError:^{
        [self.userSession performChanges:^{
            message = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
        }];
        WaitForEverythingToBeDoneWithTimeout(5);
    }];

    // THEN
    NSString *expectedPath = [NSString stringWithFormat:@"/conversations/%@/otr/assets", conversation.remoteIdentifier.transportString];
    
    // then we expect it to receive a bomb preview and medium
    // when resending after fetching the (faulty) prekeys
    NSUInteger previewReceived = 0;
    NSUInteger mediumReceived = 0;
    
    for (ZMTransportRequest *req in self.mockTransportSession.receivedRequests) {

        if (! [req.path hasPrefix:expectedPath]) {
            continue;
        }

        ZMMultipartBodyItem *metaData = req.multipartBodyItems.firstObject;
        ZMMultipartBodyItem *imageData = req.multipartBodyItems.lastObject;
        
        ZMOtrAssetMeta *otrMessage = [ZMOtrAssetMeta parseFromData:metaData.data];
        XCTAssertNotNil(otrMessage);
        
        NSArray <ZMUserEntry *>* userEntries = otrMessage.recipients;
        ZMClientEntry *clientEntry = [userEntries.firstObject.clients firstObject];
        
        if ([clientEntry.text isEqualToData:[@"💣" dataUsingEncoding:NSUTF8StringEncoding]]) {
            if (imageData.data.length > 1000) {
                mediumReceived++;
            } else {
                previewReceived++;
            }
        }
    }
    
    XCTAssertEqual(previewReceived, 1lu);
    XCTAssertEqual(mediumReceived, 1lu);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
}

- (void)testThatItOTRMessagesCanExpire
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSTimeInterval defaultExpirationTime = [ZMMessage defaultExpirationTime];
    [ZMMessage setDefaultExpirationTime:0.3];

    //register other users clients
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    
    self.mockTransportSession.doNotRespondToRequests = YES;
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMClientMessage *message;
    
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:@"I can't hear you, Claudy" nonce:[NSUUID createUUID]];
    }];
    
    XCTAssertTrue([self waitOnMainLoopUntilBlock:^BOOL{
        return message.isExpired;
    } timeout:0.5]);
    
    // then
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateFailedToSend);
    XCTAssertEqual(conversation.conversationListIndicator, ZMConversationListIndicatorExpiredMessage);

    [ZMMessage setDefaultExpirationTime:defaultExpirationTime];

}

- (void)testThatItOTRAssetCantExpire
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSTimeInterval defaultExpirationTime = [ZMMessage defaultExpirationTime];
    [ZMMessage setDefaultExpirationTime:0.3];
    
    //register other users clients
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    
    self.mockTransportSession.doNotRespondToRequests = YES;
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMAssetClientMessage *message;
    
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithImageData:[self verySmallJPEGData] nonce:[NSUUID createUUID]];
    }];
    
    [self spinMainQueueWithTimeout:0.5];
    
    // then
    XCTAssertFalse(message.isExpired);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStatePending);

    [ZMMessage setDefaultExpirationTime:defaultExpirationTime];
}

- (void)testThatItOTRMessagesCanBeResentAndItIsMovedToTheEndOfTheConversation
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSTimeInterval defaultExpirationTime = [ZMMessage defaultExpirationTime];
    [ZMMessage setDefaultExpirationTime:0.3];

    self.mockTransportSession.doNotRespondToRequests = YES;
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMClientMessage *message;
    
    // fail to send
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:@"Where's everyone?" nonce:[NSUUID createUUID]];
    }];
    
    XCTAssertTrue([self waitOnMainLoopUntilBlock:^BOOL{
        return message.isExpired;
    } timeout:0.5]);
    
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateFailedToSend);
    [ZMMessage setDefaultExpirationTime:defaultExpirationTime];
    self.mockTransportSession.doNotRespondToRequests = NO;
    [NSThread sleepForTimeInterval:0.1]; // advance timestamp
    
    // when receiving a new message
    NSString *otherUserMessageText = @"Are you still there?";
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> __unused *session) {
        ZMGenericMessage *genericMessage = [ZMGenericMessage messageWithText:otherUserMessageText nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        [self.selfToUser1Conversation encryptAndInsertDataFromClient:self.user1.clients.anyObject toClient:self.selfUser.clients.anyObject data:genericMessage.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    id<ZMConversationMessage> lastMessage = conversation.messages.lastObject;
    XCTAssertEqualObjects(lastMessage.textMessageData.messageText, otherUserMessageText);
    
    // and when resending
    [self.userSession performChanges:^{
        [message resend];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(conversation.messages.lastObject, message);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
}

- (void)testThatItSendsANotificationWhenRecievingAOtrMessageThroughThePushChannel
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    NSString *expectedText = @"The sky above the port was the color of ";
    ZMGenericMessage *message = [ZMGenericMessage messageWithText:expectedText nonce:[NSUUID createUUID].transportString expiresAfter:nil];
    

    MockConversation *mockConversation = self.groupConversation;
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    NSUInteger initialMessagesCount = conversation.messages.count;
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    //    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    MockUserClient *senderClient = [self.user1.clients anyObject];
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *__unused session) {
        NSData *encryptedData = [MockUserClient encryptedDataFromClient:senderClient toClient:selfClient data:message.data];
        [mockConversation insertOTRMessageFromClient:senderClient toClient:selfClient data:encryptedData];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);
    
    ConversationChangeInfo *note = observer.notifications.firstObject;
    XCTAssertNotNil(note);
    XCTAssertTrue(note.messagesChanged);
    XCTAssertFalse(note.participantsChanged);
    XCTAssertFalse(note.nameChanged);
    XCTAssertTrue(note.lastModifiedDateChanged);
    XCTAssertFalse(note.connectionStateChanged);
    
    ZMClientMessage *msg = conversation.messages[initialMessagesCount];
    XCTAssertEqualObjects(msg.genericMessage.text.content, expectedText);
    [observer tearDown];    
}

- (ZMGenericMessage *)remotelyInsertOTRImageIntoConversation:(MockConversation *)mockConversation imageFormat:(ZMImageFormat)format
{
    NSData *encryptedImageData;
    NSData *imageData = [self verySmallJPEGData];
    ZMGenericMessage *message = [self otrAssetGenericMessage:format imageData:imageData encryptedData:&encryptedImageData];
    
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    MockUserClient *senderClient = [self.user1.clients anyObject];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NSData *messageData = [MockUserClient encryptedDataFromClient:senderClient toClient:selfClient data:message.data];
        NSUUID *assetId = [NSUUID createUUID];
        [session createAssetWithData:encryptedImageData identifier:assetId.transportString contentType:@"" forConversation:mockConversation.identifier];
        [mockConversation insertOTRAssetFromClient:senderClient toClient:selfClient metaData:messageData imageData:encryptedImageData assetId:assetId isInline:format == ZMImageFormatPreview];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    return message;
}

- (void)testThatItSendsANotificationWhenRecievingAOtrAssetMessageThroughThePushChannel:(ZMImageFormat)format
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    MockConversation *mockConversation = self.groupConversation;
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    NSUInteger initialMessagesCount = conversation.messages.count;
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    ZMGenericMessage *assetMessage = [self remotelyInsertOTRImageIntoConversation:mockConversation imageFormat:format];
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);
    
    ConversationChangeInfo *note = observer.notifications.firstObject;
    XCTAssertNotNil(note);
    XCTAssertTrue(note.messagesChanged);
    XCTAssertFalse(note.participantsChanged);
    XCTAssertFalse(note.nameChanged);
    XCTAssertTrue(note.lastModifiedDateChanged);
    XCTAssertFalse(note.connectionStateChanged);
    
    ZMAssetClientMessage *msg = conversation.messages[initialMessagesCount];
    XCTAssertEqualObjects([msg.imageAssetStorage genericMessageForFormat:format], assetMessage);
    [observer tearDown];

}

- (void)testThatItSendsANotificationWhenRecievingAOtrMediumAssetMessageThroughThePushChannel
{
    [self testThatItSendsANotificationWhenRecievingAOtrAssetMessageThroughThePushChannel:ZMImageFormatMedium];
}

- (void)testThatItSendsANotificationWhenRecievingAOtrPreviewAssetMessageThroughThePushChannel
{
    [self testThatItSendsANotificationWhenRecievingAOtrAssetMessageThroughThePushChannel:ZMImageFormatPreview];
}

- (ZMGenericMessage *)otrAssetGenericMessage:(ZMImageFormat)format imageData:(NSData *)imageData encryptedData:(NSData **)encryptedData
{
    ZMIImageProperties *properties = [ZMIImageProperties imagePropertiesWithSize:[ZMImagePreprocessor sizeOfPrerotatedImageWithData:imageData] length:imageData.length mimeType:@"image/jpeg"];
    
    NSData *otrKey = [NSData randomEncryptionKey];
    *encryptedData = [imageData zmEncryptPrefixingPlainTextIVWithKey:otrKey];
    
    NSData *sha = [*encryptedData zmSHA256Digest];
    
    ZMImageAssetEncryptionKeys *keys = [[ZMImageAssetEncryptionKeys alloc] initWithOtrKey:otrKey sha256:sha];
    ZMGenericMessage *message = [ZMGenericMessage genericMessageWithMediumImageProperties:properties processedImageProperties:properties encryptionKeys:keys nonce:[NSUUID createUUID].transportString format:format expiresAfter:nil];

    return message;
}

- (void)testThatItUnarchivesAnArchivedConversationWhenReceivingAnEncryptedMessage {
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversation];
    [self.userSession performChanges:^{
        conversation.isArchived = YES;
    }];
    WaitForEverythingToBeDone();
    XCTAssertTrue(conversation.isArchived);
    
    // when
    
    ZMGenericMessage *message = [ZMGenericMessage messageWithText:@"Foo bar" nonce:[NSUUID createUUID].transportString expiresAfter:nil];
    
    [self createClientsAndEncryptMessageData:message appendMessageBlock:^(MockUserClient *fromClient, MockUserClient *toClient, NSData *messageData) {
        [self.groupConversation insertOTRMessageFromClient:fromClient toClient:toClient data:messageData];
    }];

    WaitForEverythingToBeDone();
    
    // then
    XCTAssertFalse(conversation.isArchived);
}

- (void)createClientsAndEncryptMessageData:(ZMGenericMessage *)message appendMessageBlock:(void(^)(MockUserClient *fromClient, MockUserClient *toClient, NSData *messageData))appendMessageBlock
{
    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    
    __block NSData *messageData;
    [self.syncMOC performGroupedBlockAndWait:^{
        messageData = [self encryptedMessage:message recipient:selfUser.selfClient];
    }];
    
    __block MockUserClient *remoteClientMock;
    __block MockUserClient *localClientMock;

    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        //kind of register 2 clients for selfUser (one local and one for another device)
        remoteClientMock = [session registerClientForUser:self.selfUser label:@"remoteClient" type:@"permanent"];
        
        localClientMock = [self.selfUser.clients.allObjects firstObjectMatchingWithBlock:^BOOL(MockUserClient *obj) {
            return [obj.identifier isEqualToString:selfUser.selfClient.remoteIdentifier];
        }];
        
        XCTAssertNotNil(localClientMock);
    }];
    
    [self.syncMOC performGroupedBlockAndWait:^{
        appendMessageBlock(remoteClientMock, localClientMock, messageData);
    }];
}

- (void)testThatItCreatesAnExternalMessageIfThePayloadIsToLargeAndAddsTheGenericMessageAsDataBlob
{
    // given
    NSMutableString *text = @"Very Long Text!".mutableCopy;
    while ([text dataUsingEncoding:NSUTF8StringEncoding].length < ZMClientMessageByteSizeExternalThreshold) {
        [text appendString:text];
    }
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    //register other users clients
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMClientMessage *message;
    // when
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:text nonce:NSUUID.createUUID];
    }];
    WaitForEverythingToBeDoneWithTimeout(1.0);
    
    // then
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    
    //check that recipient can read this message
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    MockUserClient *user1Client = [self.user1.clients anyObject];
    
    ZMGenericMessage *genericMessage = [self sessionMessage:lastEventPayload fromClient:selfClient toClient:user1Client];
    XCTAssertTrue(genericMessage.hasExternal);
}

- (void)testThatMessageWindowChangesWhenOTRAssetDataIsLoaded:(ZMImageFormat)format
{
    // given
    MockConversationWindowObserver *observer = [self windowObserverAfterLogginInAndInsertingMessagesInMockConversation:self.groupConversation];
    NSOrderedSet *initialMessageSet = observer.computedMessages;

    NSData *encryptedImageData;
    NSData *imageData = [self verySmallJPEGData];
    ZMGenericMessage *message = [self otrAssetGenericMessage:format imageData:imageData encryptedData:&encryptedImageData];
    
    MockConversation *conversation = self.groupConversation;
    ZMConversation *localGroupConversation = [self conversationForMockConversation:conversation];
    
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    MockUserClient *senderClient = [self.user1.clients anyObject];
    
    // when
    __block NSData *messageData;
    [self.mockTransportSession performRemoteChanges:^(id<MockTransportSessionObjectCreation> session){
        NSUUID *assetId = [NSUUID createUUID];
        messageData = [MockUserClient encryptedDataFromClient:senderClient toClient:selfClient data:message.data];
        [conversation insertOTRAssetFromClient:senderClient toClient:selfClient metaData:messageData imageData:encryptedImageData assetId:assetId isInline:format == ZMImageFormatPreview];
        
        [session createAssetWithData:encryptedImageData identifier:assetId.transportString contentType:@"" forConversation:self.groupConversation.identifier];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self spinMainQueueWithTimeout:0.5];
    
    ZMMessage *observedMessage = localGroupConversation.messages.lastObject;
    MessageChangeObserver *messageObserver = [[MessageChangeObserver alloc] initWithMessage:observedMessage];
    XCTAssertTrue([observedMessage isKindOfClass:ZMAssetClientMessage.class]);
    
    [observedMessage requestImageDownload];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(messageObserver.notifications.count, 1lu);
    
    NSOrderedSet *currentMessageSet = observer.computedMessages;
    NSOrderedSet *windowMessageSet = observer.window.messages;
    
    XCTAssertEqualObjects(currentMessageSet, windowMessageSet);
    
    for(NSUInteger i = 0; i < observer.window.size; ++ i) {
        if(i == 0) {
            ZMAssetClientMessage *windowMessage = currentMessageSet[i];
            XCTAssertEqualObjects([windowMessage.imageAssetStorage genericMessageForFormat:format], message);
            NSData *recievedImageData = [self.uiMOC.zm_imageAssetCache assetData:windowMessage.nonce format:format encrypted:NO];
            XCTAssertEqualObjects(recievedImageData, imageData);
        }
        else {
            XCTAssertEqual(currentMessageSet[i], initialMessageSet[i-1]);
        }
    }
    
    [messageObserver tearDown];
}

- (void)testThatMessageWindowChangesWhenOTRAssetMediumIsLoaded
{
    // given
    MockConversationWindowObserver *observer = [self windowObserverAfterLogginInAndInsertingMessagesInMockConversation:self.groupConversation];
    NSOrderedSet *initialMessageSet = observer.computedMessages;
    
    NSData *encryptedImageData;
    NSData *imageData = [self verySmallJPEGData];
    ZMGenericMessage *message = [self otrAssetGenericMessage:ZMImageFormatMedium imageData:imageData encryptedData:&encryptedImageData];
    
    MockConversation *conversation = self.groupConversation;
    ZMConversation *localGroupConversation = [self conversationForMockConversation:conversation];
    
    MockUserClient *selfClient = [self.selfUser.clients anyObject];
    MockUserClient *senderClient = [self.user1.clients anyObject];
    
    // when
    __block NSData *messageData;
    [self.mockTransportSession performRemoteChanges:^(id<MockTransportSessionObjectCreation> session){
        NSUUID *assetId = [NSUUID createUUID];
        messageData = [MockUserClient encryptedDataFromClient:senderClient toClient:selfClient data:message.data];
        [conversation insertOTRAssetFromClient:senderClient toClient:selfClient metaData:messageData imageData:encryptedImageData assetId:assetId isInline:NO];
        
        [session createAssetWithData:encryptedImageData identifier:assetId.transportString contentType:@"" forConversation:self.groupConversation.identifier];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self spinMainQueueWithTimeout:0.5];
    
    ZMMessage *observedMessage = localGroupConversation.messages.lastObject; // the last message is the "you are using a new device message"

    MessageChangeObserver *messageObserver = [[MessageChangeObserver alloc] initWithMessage:observedMessage];
    XCTAssertTrue([observedMessage isKindOfClass:ZMAssetClientMessage.class]);
    
    [observedMessage requestImageDownload];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(messageObserver.notifications.count, 1lu);
    
    NSOrderedSet *currentMessageSet = observer.computedMessages;
    NSOrderedSet *windowMessageSet = observer.window.messages;
    
    XCTAssertEqualObjects(currentMessageSet, windowMessageSet);
    
    for(NSUInteger i = 0; i < observer.window.size; ++ i) {
        if(i == 0) {
            ZMAssetClientMessage *windowMessage = currentMessageSet[i];
            XCTAssertEqualObjects([windowMessage.imageAssetStorage genericMessageForFormat:ZMImageFormatMedium], message);
            NSData *recievedImageData = [self.uiMOC.zm_imageAssetCache assetData:windowMessage.nonce format:ZMImageFormatMedium encrypted:NO];
            XCTAssertEqualObjects(recievedImageData, imageData);
        }
        else {
            XCTAssertEqual(currentMessageSet[i], initialMessageSet[i-1]);
        }
    }
    
    [messageObserver tearDown];

}

- (void)testThatAssetMediumIsRedownloadedIfNoMessageDataIsStored
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);

    NSData *encryptedImageData;
    NSData *imageData = [self verySmallJPEGData];
    ZMGenericMessage *message = [self otrAssetGenericMessage:ZMImageFormatMedium imageData:imageData encryptedData:&encryptedImageData];
    NSUUID *assetId = [NSUUID createUUID];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
        [self createClientsAndEncryptMessageData:message appendMessageBlock:^(MockUserClient *fromClient, MockUserClient *toClient, NSData *messageData) {
            [self.groupConversation insertOTRAssetFromClient:fromClient toClient:toClient metaData:messageData imageData:encryptedImageData assetId:assetId isInline:NO];
            [session createAssetWithData:encryptedImageData identifier:assetId.transportString contentType:@"" forConversation:self.groupConversation.identifier];
        }];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);

    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversation];
    ZMAssetClientMessage *imageMessageData = (ZMAssetClientMessage *)conversation.messages.lastObject;

    // remove all stored data, like cache is cleared
    [self.uiMOC.zm_imageAssetCache deleteAssetData:imageMessageData.nonce format:ZMImageFormatMedium encrypted:YES];
    [self.uiMOC.zm_imageAssetCache deleteAssetData:imageMessageData.nonce format:ZMImageFormatMedium encrypted:NO];
    
    
    XCTAssertNil([[imageMessageData imageMessageData] mediumData]);
    
    [imageMessageData requestImageDownload];
    WaitForAllGroupsToBeEmpty(0.5);

    XCTAssertNotNil([[imageMessageData imageMessageData] mediumData]);
}

- (void)testThatAssetMediumIsRedownloadedIfNoDecryptedMessageDataIsStored
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    NSData *encryptedImageData;
    NSData *imageData = [self verySmallJPEGData];
    ZMGenericMessage *message = [self otrAssetGenericMessage:ZMImageFormatMedium imageData:imageData encryptedData:&encryptedImageData];
    NSUUID *assetId = [NSUUID createUUID];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
        [self createClientsAndEncryptMessageData:message appendMessageBlock:^(MockUserClient *fromClient, MockUserClient *toClient, NSData *messageData) {
            [self.groupConversation insertOTRAssetFromClient:fromClient toClient:toClient metaData:messageData imageData:encryptedImageData assetId:assetId isInline:NO];
            [session createAssetWithData:encryptedImageData identifier:assetId.transportString contentType:@"" forConversation:self.groupConversation.identifier];
        }];
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversation];
    ZMAssetClientMessage *imageMessageData = (ZMAssetClientMessage *)conversation.messages.lastObject;
    
    // remove decrypted data, but keep encrypted, like we crashed during decryption
    [self.uiMOC.zm_imageAssetCache storeAssetData:imageMessageData.nonce format:ZMImageFormatMedium encrypted:YES data:encryptedImageData];
    [self.uiMOC.zm_imageAssetCache deleteAssetData:imageMessageData.nonce format:ZMImageFormatMedium encrypted:NO];
    
    XCTAssertNil([[imageMessageData imageMessageData] mediumData]);
    [imageMessageData requestImageDownload];
    WaitForAllGroupsToBeEmpty(0.5);
    
    XCTAssertNotNil([[imageMessageData imageMessageData] mediumData]);
}

@end


#pragma mark - Trust
@implementation ConversationTestsOTR (Trust)

- (void)makeConversationSecured:(ZMConversation *)conversation
{
    NSArray *allClients = [[conversation activeParticipants].array flattenWithBlock:^id(ZMUser *user) {
        return [user clients].allObjects;
    }];
    UserClient *selfClient = [ZMUser selfUserInUserSession:self.userSession].selfClient;
    
    [self.userSession performChanges:^{
        for (UserClient *client in allClients) {
            [selfClient trustClient:client];
        }
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    XCTAssertTrue(conversation.trusted);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
}

- (void)makeConversationSecuredWithIgnored:(ZMConversation *)conversation
{
    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    NSArray *allClients = [[conversation activeParticipants].array flattenWithBlock:^id(ZMUser *user) {
        return [user clients].allObjects;
    }];
    
    NSMutableSet *allClientsSet = [NSMutableSet setWithArray:allClients];
    [allClientsSet minusSet:[NSSet setWithObject:selfUser.selfClient]];
    
    [self.userSession performChanges:^{
        [selfUser.selfClient trustClients:allClientsSet];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
    
    [self.userSession performChanges:^{
        [selfUser.selfClient ignoreClients:allClientsSet];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
}

- (ZMClientMessage *)sendOtrMessageWithInitialSecurityLevel:(ZMConversationSecurityLevel)securityLevel
                                           numberOfMessages:(NSUInteger)numberOfMessages
                                     createAdditionalClient:(BOOL)createAdditionalClient
                            handleSecurityLevelNotification:(void(^)(ConversationChangeInfo *))handler
{
    return [self sendOtrMessageWithInitialSecurityLevel:securityLevel
                                       numberOfMessages:numberOfMessages
                                secureGroupConversation:NO
                                 createAdditionalClient:createAdditionalClient
                        handleSecurityLevelNotification:handler];
}

- (ZMClientMessage *)sendOtrMessageWithInitialSecurityLevel:(ZMConversationSecurityLevel)securityLevel
                                           numberOfMessages:(NSUInteger)numberOfMessages
                                    secureGroupConversation:(BOOL)secureGroupConversation
                                     createAdditionalClient:(BOOL)createAdditionalClient
                            handleSecurityLevelNotification:(void(^)(ConversationChangeInfo *))handler
{
    // login if needed
    if(!self.userSession.isLoggedIn) {
        XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
        WaitForAllGroupsToBeEmpty(0.5);
    }
    
    //register other users clients
    if([self userForMockUser:self.user1].clients.count == 0) {
        [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
        WaitForEverythingToBeDoneWithTimeout(0.5);
    }
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    // Setup security level
    [self setupInitialSecurityLevel:securityLevel inConversation:conversation];
    
    // make secondary group conversation trusted if needed
    if (secureGroupConversation) {
        ZMConversation *groupLocalConversation = [self conversationForMockConversation:self.groupConversationWithOnlyConnected];
        if(groupLocalConversation.securityLevel != ZMConversationSecurityLevelSecure) {
            for(MockUser* user in self.groupConversationWithOnlyConnected.activeUsers) {
                if(user != self.selfUser && user.clients.count == 0) {
                    [self setupOTREnvironmentForUser:user isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
                    WaitForAllGroupsToBeEmpty(0.5);
                }
            }
            [self.syncMOC saveOrRollback];
            [self.uiMOC saveOrRollback];
            [self makeConversationSecured:groupLocalConversation];
        }
    }
    
    if (createAdditionalClient) {
        [self setupOTREnvironmentForUser:self.user1 isSelfClient:YES numberOfKeys:1 establishSessionWithSelfUser:NO];
    }
    
    __block ConversationChangeObserver *observer;
    observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    observer.notificationCallback = ^(NSObject *note) {
        ConversationChangeInfo *changeInfo = (ConversationChangeInfo *)note;
        if ([changeInfo securityLevelChanged]) {
            if (handler) {
                [self.userSession performChanges:^{
                    handler(changeInfo);
                }];
            }
        }
    };
    [observer clearNotifications];
    [conversation addConversationObserver:observer];

    // when
    __block ZMClientMessage* message;
    [self.userSession performChanges:^{
        for (NSUInteger i = 0; i < numberOfMessages; i++) {
            message = [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
            [NSThread sleepForTimeInterval:0.1];
        }
    }];
    
    [observer tearDown];
    [message.managedObjectContext saveOrRollback];
    WaitForEverythingToBeDone();
    
    return message;
}

- (void)testThatItChangesTheSecurityLevelIfUnconnectedUntrustedParticipantIsAdded
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // register other users clients
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    [self setupOTREnvironmentForUser:self.user2 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversationWithOnlyConnected];
    [self makeConversationSecured:conversation];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        [self.groupConversationWithOnlyConnected addUsersByUser:self.user1 addedUsers:@[self.user5]];
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    // then
    ZMUser *addedUser = [self userForMockUser:self.user5];
    XCTAssertTrue([conversation.otherActiveParticipants containsObject:addedUser]);
    XCTAssertNil(addedUser.connection);
    
    XCTAssertFalse(conversation.trusted);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
    
    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        MockConversation *selfToUser5Conversation = [session insertOneOnOneConversationWithSelfUser:self.selfUser otherUser:self.user5];
        selfToUser5Conversation.creator = self.selfUser;
        MockConnection *connectionSelfToUser5 = [session insertConnectionWithSelfUser:self.selfUser toUser:self.user5];
        connectionSelfToUser5.status = @"accepted";
        connectionSelfToUser5.lastUpdate = [NSDate dateWithTimeIntervalSinceNow:-3];
        connectionSelfToUser5.conversation = selfToUser5Conversation;
    }];
    
    WaitForEverythingToBeDoneWithTimeout(0.5);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
    
    [self setupOTREnvironmentForUser:self.user5 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    
    [self.userSession performChanges:^{
        ZMUser *selfUser = [self userForMockUser:self.selfUser];
        [selfUser.selfClient trustClients:[self userForMockUser:self.user5].clients];
    }];
    
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    // then
    XCTAssertTrue(conversation.trusted);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
}

- (void)testThatItDeliversOTRMessageIfAllClientsAreTrustedAndNoMissingClients
{
    //given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    MockConversation *mockConversation = self.selfToUser1Conversation;
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    {
        // send a message to fetch all the missing client
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
    }
    
    [self makeConversationSecured:conversation];
    
    // when
    __block ZMClientMessage* message;
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
    }];
    
    [message.managedObjectContext saveOrRollback];
    WaitForEverythingToBeDone();
    
    MockPushEvent *lastEvent = self.mockTransportSession.updateEvents.lastObject;
    NSDictionary *lastEventPayload = lastEvent.payload.asDictionary;
    ZMTUpdateEventType lastEventType = [MockEvent typeFromString:lastEventPayload[@"type"]];
    
    XCTAssertEqual(lastEventType, ZMTUpdateEventConversationOTRMessageAdd);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    XCTAssertEqual(message.conversation.securityLevel, ZMConversationSecurityLevelSecure);
}


- (void)testThatItDeliveresOTRMessageAfterIgnoringAndResending
{
    __block BOOL notificationRecieved = NO;
    //given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    MockConversation *mockConversation = self.selfToUser1Conversation;
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    {
        // send a message to fetch all the missing client
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
    }
    [self makeConversationSecured:conversation];
    
    //when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session registerClientForUser:self.user1 label:@"remote client" type:@"permanent"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    __block ConversationChangeObserver *observer;
    observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    observer.notificationCallback = ^(NSObject *note) {
        ConversationChangeInfo *changeInfo = (ConversationChangeInfo *)note;
        if ([changeInfo securityLevelChanged]) {
            notificationRecieved = YES;
            XCTAssertTrue(changeInfo.didDegradeSecurityLevelBecauseOfMissingClients);
            [self.userSession performChanges:^{
                if (changeInfo.conversation.securityLevel == ZMConversationSecurityLevelSecureWithIgnored) {
                    [changeInfo.conversation resendLastUnsentMessages];
                }
            }];
        }
    };
    [observer clearNotifications];
    [conversation addConversationObserver:observer];
    
    // when
    __block ZMClientMessage* message;
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
    }];
    
    [observer tearDown];
    [message.managedObjectContext saveOrRollback];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue(notificationRecieved);
    XCTAssertEqual(message.deliveryState, ZMDeliveryStateSent);
    
    XCTAssertEqual(message.visibleInConversation, message.conversation);
    XCTAssertEqual(message.conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
}

- (void)testThatItDoesNotDeliveresOTRMessageAfterIgnoringExpiring
{
    __block BOOL notificationRecieved = NO;
    
    // when
    ZMClientMessage *message1 = [self sendOtrMessageWithInitialSecurityLevel:ZMConversationSecurityLevelSecure
                                                            numberOfMessages:1
                                                      createAdditionalClient:YES
                                             handleSecurityLevelNotification:^(ConversationChangeInfo *changeInfo) {
                                                 notificationRecieved = YES;
                                                 if (changeInfo.conversation.securityLevel == ZMConversationSecurityLevelSecureWithIgnored) {
                                                     XCTAssertTrue(changeInfo.didDegradeSecurityLevelBecauseOfMissingClients);
                                                 }
                                             }];
    WaitForEverythingToBeDone();
    
    // then
    XCTAssertTrue(notificationRecieved);
    
    XCTAssertEqual(message1.deliveryState, ZMDeliveryStateFailedToSend);
    
    XCTAssertEqual(message1.conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
}


// TODO(Florian): clean up setup code, while still being clear on the test intention
- (void)testThatItDoesNotDeliverOriginalOTRMessageAfterIgnoringExpiringAndThenSendingAnotherOne
{
    __block BOOL notificationRecieved = NO;
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    // Setup security level
    
    [self.userSession performChanges:^ {
        [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDone();
    [self makeConversationSecured:conversation];
    
    // make secondary group conversation trusted if needed
    [self.mockTransportSession performRemoteChanges:^(id<MockTransportSessionObjectCreation> session) {
        [session registerClientForUser:self.user1 label:@"remote client" type:@"permanent"];
    }];
    WaitForEverythingToBeDone();
    
    __block ConversationChangeObserver *observer;
    observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    observer.notificationCallback = ^(NSObject *note) {
        ConversationChangeInfo *changeInfo = (ConversationChangeInfo *)note;
        if ([changeInfo securityLevelChanged]) {
            notificationRecieved = YES;
            if (changeInfo.conversation.securityLevel == ZMConversationSecurityLevelSecureWithIgnored) {
                XCTAssertTrue(changeInfo.didDegradeSecurityLevelBecauseOfMissingClients);
            }
        }
    };
    
    [observer clearNotifications];
    [conversation addConversationObserver:observer];
    
    // when
    __block ZMClientMessage* message1;
    [self.userSession performChanges:^{
        message1 = [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDone();
    
    [observer tearDown];
    [message1.managedObjectContext saveOrRollback];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue(notificationRecieved);
    XCTAssertNotNil(message1);
    XCTAssertEqual(message1.deliveryState, ZMDeliveryStateFailedToSend);
    
    XCTAssertEqual(message1.conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
    
    // make secondary group conversation trusted if needed
    [self.mockTransportSession performRemoteChanges:^(id<MockTransportSessionObjectCreation> session) {
        [session registerClientForUser:self.user1 label:@"remote client" type:@"permanent"];
    }];
    WaitForEverythingToBeDone();
    
    observer.notificationCallback = ^(NSObject *note) {
        ConversationChangeInfo *changeInfo = (ConversationChangeInfo *)note;
        if ([changeInfo securityLevelChanged]) {
            notificationRecieved &= YES;
            if (changeInfo.conversation.securityLevel == ZMConversationSecurityLevelSecureWithIgnored) {
                XCTAssertTrue(changeInfo.didDegradeSecurityLevelBecauseOfMissingClients);
                [self.userSession performChanges:^{
                    [changeInfo.conversation resendLastUnsentMessages];
                }];
            }
        }
    };
    
    [conversation addConversationObserver:observer];
    
    // when
    __block ZMClientMessage* message2;
    [self.userSession performChanges:^{
        message2 = [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
    }];
    WaitForEverythingToBeDone();
    
    [observer tearDown];
    [message2.managedObjectContext saveOrRollback];
    
    // then
    XCTAssertTrue(notificationRecieved);
    
    XCTAssertEqual(message2.deliveryState, ZMDeliveryStateSent);
    XCTAssertNotNil(message2);
    XCTAssertEqual(message2.conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
    
    XCTAssertEqual(message1.deliveryState, ZMDeliveryStateFailedToSend);


}

- (void)testThatItInsertsNewClientSystemMessageWhenReceivedMissingClients
{
    ZMClientMessage *message = [self sendOtrMessageWithInitialSecurityLevel:ZMConversationSecurityLevelSecure
                                                           numberOfMessages:1
                                                     createAdditionalClient:YES
                                            handleSecurityLevelNotification:nil];
    
    WaitForEverythingToBeDone();
    
    ZMConversation *conversation = message.conversation;
    ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 2];
    XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
    
    NSArray<ZMUser *> *expectedUsers = @[[self userForMockUser:self.user1]];
    
    AssertArraysContainsSameObjects(lastMessage.users.allObjects, expectedUsers);
    XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeNewClient);
}

- (void)testThatItInsertsNewClientSystemMessageWhenReceivedMissingClientsEvenIfSeveralMessagesAppendedAfter
{
    ZMClientMessage *message = [self sendOtrMessageWithInitialSecurityLevel:ZMConversationSecurityLevelSecure
                                                           numberOfMessages:5
                                                     createAdditionalClient:YES
                                            handleSecurityLevelNotification:nil];
    
    WaitForEverythingToBeDone();
    
    ZMConversation *conversation = message.conversation;
    ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 6];
    XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
    
    NSArray<ZMUser *> *expectedUsers = @[[self userForMockUser:self.user1]];
    
    AssertArraysContainsSameObjects(lastMessage.users.allObjects, expectedUsers);
    XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeNewClient);
}

- (void)testThatInsertsSecurityLevelDecreasedMessageInTheEndIfMessageCausedIsInOtherConversation
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    //register other users clients
    
    void (^secureConversationBlock)(ZMConversation *) = ^(ZMConversation *conversation) {
        // send a message to fetch all the missing client
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
        [self makeConversationSecured:conversation];

    };
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    ZMConversation *groupLocalConversation = [self conversationForMockConversation:self.groupConversationWithOnlyConnected];

    secureConversationBlock(conversation);
    secureConversationBlock(groupLocalConversation);
    
    [self.mockTransportSession performRemoteChanges:^(id<MockTransportSessionObjectCreation> session){
        [session registerClientForUser:self.user1 label:@"remote client" type:@"permanent"];
    }];
    
    // when
    __block ZMClientMessage* message;
    [self.userSession performChanges:^{
        message = [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
    }];
    [message.managedObjectContext saveOrRollback];
    WaitForEverythingToBeDone();
    
    XCTAssertNotNil(message.conversation);
    
    ZMSystemMessage *lastMessage = [groupLocalConversation.messages objectAtIndex:groupLocalConversation.messages.count - 1];
    XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
    
    XCTAssertEqual(message.conversation, conversation);
    NSArray<ZMUser *> *expectedUsers = @[[self userForMockUser:self.user1]];
    
    AssertArraysContainsSameObjects(lastMessage.users.allObjects, expectedUsers);
    XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeNewClient);


}

- (void)testThatInsertsSecurityLevelDecreasedMessageInTheEndOfConversationIfNotCausedByMessage
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    UserClient *selfClient = [ZMUser selfUserInUserSession:self.userSession].selfClient;
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    [self makeConversationSecured:conversation];
    
    // when
    ZMUser *localUser1 = [self userForMockUser:self.user1];
    [selfClient ignoreClient:localUser1.clients.anyObject];
    
    // then
    ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 1];
    XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
    
    NSArray<ZMUser *> *expectedUsers = @[localUser1];
    
    AssertArraysContainsSameObjects(lastMessage.users.allObjects, expectedUsers);
    XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeIgnoredClient);

}

- (void)testThatItChangesSecurityLevelToInsecureCauseFailedMessageAttemptWhenSelfTriesToSendMessageInDegradingConversation
{
    [self testThatItChangesSecurityLevelToCorrectSubtypeSendingMessageFromSelfClient:YES];
}

- (void)testThatItChangesSecurityLevelToInsecureCauseOtherWhenOtherClientTriesToSendMessageAndDegradesDegradingConversation
{
    [self testThatItChangesSecurityLevelToCorrectSubtypeSendingMessageFromSelfClient:NO];
}

- (void)testThatItChangesSecurityLevelToCorrectSubtypeSendingMessageFromSelfClient:(BOOL)sendingFromSelfCLient
{
    self.registeredOnThisDevice = YES;
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];

    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    

    [self makeConversationSecured:conversation];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    if (sendingFromSelfCLient) {
        [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
        WaitForEverythingToBeDoneWithTimeout(0.5);
        
        // when
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:@"Hello" nonce:NSUUID.createUUID];
        }];
        
        WaitForEverythingToBeDone();
    } else {
        NSSet *user1Clients = [self.user1.clients copy];
        [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
        WaitForEverythingToBeDoneWithTimeout(0.5);
        
        NSMutableSet *newUser1Clients = [self.user1.clients mutableCopy];
        [newUser1Clients minusSet:user1Clients];
        MockUserClient *newClient = newUser1Clients.anyObject;
        
        // when
        __block NSError *error;
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused transportSession) {
            ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
            ZMGenericMessage *message = [ZMGenericMessage messageWithText:@"Test" nonce:[NSUUID createUUID].transportString expiresAfter:nil];
            NSData *messageData = [self encryptedMessage:message recipient:selfUser.selfClient];
            [self.selfToUser1Conversation insertOTRMessageFromClient:newClient toClient:[self.selfUser.clients anyObject] data:messageData];
        }];
        
        WaitForEverythingToBeDone();
        XCTAssertNil(error);
    }
    
    // then
    ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 2];
    ZMConversationSecurityLevel expectedLevel = ZMConversationSecurityLevelSecureWithIgnored;
    XCTAssertEqual(conversation.securityLevel, expectedLevel);
    XCTAssertEqual(conversation.messages.count, 4lu); // 3x system message (new device & secured & new client) + appended client message
    XCTAssertEqual(lastMessage.systemMessageData.systemMessageType, ZMSystemMessageTypeNewClient);

}

- (void)checkThatItShouldInsertSecurityLevelSystemMessageAfterSendingMessage:(BOOL)shouldInsert
                                                   shouldChangeSecurityLevel:(BOOL)shouldChangeSecurityLevel
                                                     forInitialSecurityLevel:(ZMConversationSecurityLevel)initialSecurityLevel
                                                       expectedSecurityLevel:(ZMConversationSecurityLevel)expectedSecurityLevel
{
    self.registeredOnThisDevice = YES;
    NSString *expectedText = @"The sky above the port was the color of ";
    ZMGenericMessage *message = [ZMGenericMessage messageWithText:expectedText nonce:[NSUUID createUUID].transportString expiresAfter:nil];
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    [self setupInitialSecurityLevel:initialSecurityLevel inConversation:conversation];
    
    //register new client for user1
    NSSet *user1Clients = [self.user1.clients copy];
    
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    NSMutableSet *newUser1Clients = [self.user1.clients mutableCopy];
    [newUser1Clients minusSet:user1Clients];
    MockUserClient *newUser1Client = [newUser1Clients anyObject];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    NSOrderedSet *previousMessage = conversation.messages.copy;
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused transportSession) {
        ZMUser *user = [self userForMockUser:self.selfUser];
        UserClient *selfClient = [user.clients anyObject];
        NSData *messageData = [self encryptedMessage:message recipient:selfClient];
        [self.selfToUser1Conversation insertOTRMessageFromClient:newUser1Client toClient:self.selfUser.clients.anyObject data:messageData];
    }];
    
    WaitForEverythingToBeDone();
    
    // then
    ConversationChangeInfo *note = [observer.notifications filterWithBlock:^BOOL(ConversationChangeInfo *notification) {
        return notification.securityLevelChanged;
    }].firstObject;
    if (shouldChangeSecurityLevel) {
        XCTAssertNotNil(note);
    }
    else {
        XCTAssertNil(note);
    }
    
    XCTAssertEqual(conversation.securityLevel, expectedSecurityLevel);

    NSMutableOrderedSet *messagesAfterInserting = conversation.messages.mutableCopy;
    [messagesAfterInserting minusOrderedSet:previousMessage];
    
    if (shouldInsert) {
        XCTAssertEqual(messagesAfterInserting.count, 2lu); // Client message and system message
        ZMSystemMessage *lastMessage = messagesAfterInserting.firstObject;
        XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
        
        NSArray<ZMUser *> *expectedUsers = @[[self userForMockUser:self.user1]];
        
        AssertArraysContainsSameObjects(lastMessage.users.allObjects, expectedUsers);
        XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeNewClient);
    }
    else {
        XCTAssertEqual(messagesAfterInserting.count, 1lu); // Only the added client message
    }
    
    [observer tearDown];
}

- (void)testThatItInsertsNewClientSystemMessageWhenReceivingMessageFromNewClientInSecuredConversation
{
    [self checkThatItShouldInsertSecurityLevelSystemMessageAfterSendingMessage:YES
                                                     shouldChangeSecurityLevel:YES
                                                       forInitialSecurityLevel:ZMConversationSecurityLevelSecure
                                                         expectedSecurityLevel:ZMConversationSecurityLevelSecureWithIgnored];
}

- (void)testThatItInsertsNewClientSystemMessageWhenReceivingMessageFromNewClientInPartialSecureConversation
{
    [self checkThatItShouldInsertSecurityLevelSystemMessageAfterSendingMessage:NO
                                                     shouldChangeSecurityLevel:NO
                                                       forInitialSecurityLevel:ZMConversationSecurityLevelSecureWithIgnored
                                                         expectedSecurityLevel:ZMConversationSecurityLevelSecureWithIgnored];
}

- (void)testThatItDoesNotInsertNewClientSystemMessageWhenReceivingMessageFromNewClientInNotSecuredConversation
{
    [self checkThatItShouldInsertSecurityLevelSystemMessageAfterSendingMessage:NO
                                                     shouldChangeSecurityLevel:NO
                                                       forInitialSecurityLevel:ZMConversationSecurityLevelNotSecure
                                                         expectedSecurityLevel:ZMConversationSecurityLevelNotSecure];
}

- (void)checkThatItShouldInsertIgnoredSystemMessageAfterIgnoring:(BOOL)shouldInsert
                                       shouldChangeSecurityLevel:(BOOL)shouldChangeSecurityLevel
                                         forInitialSecurityLevel:(ZMConversationSecurityLevel)initialSecurityLevel
                                           expectedSecurityLevel:(ZMConversationSecurityLevel)expectedSecurityLevel
{
    self.registeredOnThisDevice = YES;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    XCTAssertFalse(self.user1.clients.isEmpty);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    [self setupInitialSecurityLevel:initialSecurityLevel inConversation:conversation];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    NSUInteger messageCountAfterSetup = conversation.messages.count;
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    UserClient *selfClient = [ZMUser selfUserInUserSession:self.userSession].selfClient;
    ZMUser *user1 = [self userForMockUser:self.user1];
    
    if (initialSecurityLevel == ZMConversationSecurityLevelSecure) {
        [selfClient ignoreClients:user1.clients];
    } else {
        UserClient *trusted = [user1.clients.allObjects firstObjectMatchingWithBlock:^BOOL(UserClient *obj) {
            return [obj.trustedByClients containsObject:selfClient];
        }];
        if (nil != trusted) {
            [selfClient ignoreClient:trusted];
        }
    }

    WaitForAllGroupsToBeEmpty(0.5);
    
    if (shouldChangeSecurityLevel) {
        ConversationChangeInfo *note = observer.notifications.firstObject;
        XCTAssertNotNil(note);
        XCTAssertTrue(note.securityLevelChanged);
    }
    else {
        ConversationChangeInfo *note = observer.notifications.firstObject;
        if (note) {
            XCTAssertFalse(note.securityLevelChanged);
        }
    }
    
    XCTAssertEqual(conversation.securityLevel, expectedSecurityLevel);
    
    if (shouldInsert) {
        __block ZMSystemMessage *systemMessage;
        [conversation.messages enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id  _Nonnull msg, NSUInteger __unused idx, BOOL * _Nonnull stop) {
            if([msg isKindOfClass:ZMSystemMessage.class]) {
                systemMessage = msg;
                *stop = YES;
            }
        }];
        XCTAssertNotNil(systemMessage);
        
        NSArray<ZMUser *> *expectedUsers = @[[self userForMockUser:self.user1]];
        
        AssertArraysContainsSameObjects(systemMessage.users.allObjects, expectedUsers);
        XCTAssertEqual(systemMessage.systemMessageType, ZMSystemMessageTypeIgnoredClient);
    }
    else {
        XCTAssertEqual(messageCountAfterSetup, conversation.messages.count);
    }
    
    [observer tearDown];
}

- (void)setupInitialSecurityLevel:(ZMConversationSecurityLevel)initialSecurityLevel inConversation:(ZMConversation *)conversation
{
    if(conversation.securityLevel == initialSecurityLevel) {
        return;
    }
    switch (initialSecurityLevel) {
        case ZMConversationSecurityLevelSecure:
        {
            [self makeConversationSecured:conversation];
            XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
        }
            break;
            
        case ZMConversationSecurityLevelSecureWithIgnored:
        {
            [self makeConversationSecuredWithIgnored:conversation];
            XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
        }
            break;
        default:
            break;
    }
}


- (void)testThatItInsertsIgnoredSystemMessageWhenIgnoringClientFromSecuredConversation;
{
    [self checkThatItShouldInsertIgnoredSystemMessageAfterIgnoring:YES
                                         shouldChangeSecurityLevel:YES
                                           forInitialSecurityLevel:ZMConversationSecurityLevelSecure
                                             expectedSecurityLevel:ZMConversationSecurityLevelSecureWithIgnored];
}


- (void)testThatItDoesNotAppendsIgnoredSytemMessageWhenIgnoringClientFromNotSecuredConversation;
{
    [self checkThatItShouldInsertIgnoredSystemMessageAfterIgnoring:NO
                                         shouldChangeSecurityLevel:NO
                                           forInitialSecurityLevel:ZMConversationSecurityLevelNotSecure
                                             expectedSecurityLevel:ZMConversationSecurityLevelNotSecure];
    
}

- (void)testThatItInsertsSystemMessageWhenAllClientsBecomeTrusted
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:YES];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    // when
    [self makeConversationSecured:conversation];
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);
    ConversationChangeInfo *note = observer.notifications.firstObject;
    XCTAssertNotNil(note);
    XCTAssertTrue(note.securityLevelChanged);

    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
    
    ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 1];
    XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
    
    XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeConversationIsSecure);
    [observer tearDown];
}

- (void)testThatItInsertsSystemMessageWhenAllSelfUserClientsBecomeTrusted
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session registerClientForUser:self.selfUser label:@"Second client" type:@"permanent"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    UserClient *selfClient = [ZMUser selfUserInUserSession:self.userSession].selfClient;
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMUser *user1 = [self userForMockUser:self.user1];
    [self.userSession performChanges:^{
        [selfClient trustClient:user1.clients.anyObject];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    NSArray *clients = selfClient.user.clients.allObjects;
    UserClient *otherClient = [clients firstObjectMatchingWithBlock:^BOOL(UserClient *client) {
        return client.remoteIdentifier != selfClient.remoteIdentifier;
    }];
    XCTAssertNotNil(otherClient);
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelNotSecure);
    
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    // when
    [self.userSession performChanges:^{
        [selfClient trustClient:otherClient];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);
    ConversationChangeInfo *note = observer.notifications.firstObject;
    XCTAssertNotNil(note);
    XCTAssertTrue(note.securityLevelChanged);
    
    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
    
    ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 1];
    XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
    
    XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeConversationIsSecure);
    [observer tearDown];
}

- (void)testThatItInsertsSystemMessageWhenTheSelfUserDeletesAnUntrustedClient
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session registerClientForUser:self.selfUser label:@"other selfuser clients" type:@"permanent"];
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);

    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    ZMUser *otherUser = [self userForMockUser:self.user1];
    ZMUser *selfUser = [ZMUser selfUserInUserSession:self.userSession];

    XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelNotSecure);

    // (1) trust local client of user1
    {
        // adding a message to fetch client
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
        }];
        WaitForEverythingToBeDone();
        
        UserClient *selfClient = selfUser.selfClient;
        
        [self.userSession performChanges:^{
            for (UserClient *client in otherUser.clients) {
                [selfClient trustClient:client];
            }
        }];
        WaitForAllGroupsToBeEmpty(0.5);
        
        // then
        XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelNotSecure); // we do not trust one of our own devices,
    }
    
    NSArray *clients = selfUser.clients.allObjects;
    UserClient *otherSelfClient = [clients firstObjectMatchingWithBlock:^BOOL(UserClient *client) {
        return client.remoteIdentifier != selfUser.selfClient.remoteIdentifier;
    }];

    
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    NSUInteger currentMessageCount = conversation.messages.count;
    
    // when
    // (2) selfUser deletes remote selfUser client
    {
        [self.userSession performChanges:^{
            [self.userSession deleteClients:@[otherSelfClient] withCredentials:[ZMEmailCredentials credentialsWithEmail:SelfUserEmail password:SelfUserPassword]];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
        
        // then
        XCTAssertEqual(observer.notifications.count, 1u);
        ConversationChangeInfo *note = observer.notifications.firstObject;
        XCTAssertNotNil(note);
        XCTAssertTrue(note.securityLevelChanged);
        
        XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
        if (conversation.messages.count > currentMessageCount) {
            ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:currentMessageCount];
            XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
            
            XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeConversationIsSecure);
        }
        else {
            XCTFail(@"Did not create system message");
        }
    }
    [observer tearDown];
}

- (void)simulateResponseForFetchingUserClients:(NSArray *)clientIDs userID:(NSUUID *)userID
{
    NSMutableArray *payload = [NSMutableArray array];
    for (NSString *clientID in clientIDs){
        [payload addObject:@{@"id": clientID}];
    }
    
    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        NSString *path = [NSString stringWithFormat:@"users/%@/clients", userID.transportString];
        if ([request.path isEqualToString:path]) {
            return [ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil];
        }
        return nil;
    };
}

- (void)testThatItInsertsSystemMessageWhenTheOtherUserDeletesAnUntrustedClient
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    ZMUser *otherUser = [self userForMockUser:self.user1];
    
    __block NSString *trustedRemoteID;
    // (1) trust local client of user1
    {
        // adding a message
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
        }];
        WaitForEverythingToBeDone();
        [self makeConversationSecured:conversation];
        trustedRemoteID = [otherUser.clients.anyObject remoteIdentifier];

        // then
        XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
    }
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    // (2) insert new client for user 1
    {
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            [session registerClientForUser:self.user1 label:@"other user 1 clients" type:@"permanent"];
        }];
        WaitForEverythingToBeDoneWithTimeout(0.5);
        
        NSSet *clientIDs = [self.user1.clients mapWithBlock:^id(MockUserClient *obj) {
            return obj.identifier;
        }];
        [self simulateResponseForFetchingUserClients:clientIDs.allObjects userID:otherUser.remoteIdentifier];
        [self.userSession performChanges:^{
            [otherUser fetchUserClients];
        }];
        WaitForEverythingToBeDoneWithTimeout(0.5);
        XCTAssertEqual(otherUser.clients.count, 2u);
        
        XCTAssertEqual(observer.notifications.count, 1u);
        ConversationChangeInfo *note = observer.notifications.firstObject;
        XCTAssertNotNil(note);
        XCTAssertTrue(note.securityLevelChanged);
        
        XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecureWithIgnored);
        
        ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 1];
        XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
        
        XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeNewClient);
    }
    
    [observer clearNotifications];
    
    
    // (3) remove inserted client for user1
    {
        // when
        [self simulateResponseForFetchingUserClients:@[trustedRemoteID] userID:otherUser.remoteIdentifier];
        [self.userSession performChanges:^{
            [otherUser fetchUserClients];
        }];
        WaitForEverythingToBeDoneWithTimeout(0.5);
        XCTAssertEqual(otherUser.clients.count, 1u);
        
        // then
        XCTAssertEqual(observer.notifications.count, 1u);
        ConversationChangeInfo *note = observer.notifications.firstObject;
        XCTAssertNotNil(note);
        XCTAssertTrue(note.securityLevelChanged);
        
        XCTAssertEqual(conversation.securityLevel, ZMConversationSecurityLevelSecure);
        
        ZMSystemMessage *lastMessage = [conversation.messages objectAtIndex:conversation.messages.count - 1];
        XCTAssertTrue([lastMessage isKindOfClass:[ZMSystemMessage class]]);
        
        XCTAssertEqual(lastMessage.systemMessageType, ZMSystemMessageTypeConversationIsSecure);
    }
    [observer tearDown];
}

- (void)testThatItDoesNotSetAllConversationsToSecureWhenTrustingSelfUserClients
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session registerClientForUser:self.selfUser label:@"self" type:@"permanent"];
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation1 = [self conversationForMockConversation:self.selfToUser1Conversation];
    ZMConversation *conversation2 = [self conversationForMockConversation:self.selfToUser2Conversation];

    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    ZMUser *user1 = [self userForMockUser:self.user1];

    // when
    [self.userSession performChanges:^{
        for (UserClient *client in selfUser.clients){
            [selfUser.selfClient trustClient:client];
        }
        [selfUser.selfClient trustClient:user1.clients.anyObject];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(conversation1.securityLevel, ZMConversationSecurityLevelSecure);
    XCTAssertEqual(conversation2.securityLevel, ZMConversationSecurityLevelNotSecure);
}

- (void)testThatItDoesNotSetAllConversationsToSecureWhenDeletingATrustedSelfUserClients
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session registerClientForUser:self.selfUser label:@"self" type:@"permanent"];
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:1 establishSessionWithSelfUser:NO];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    ZMConversation *conversation1 = [self conversationForMockConversation:self.selfToUser1Conversation];
    ZMConversation *conversation2 = [self conversationForMockConversation:self.selfToUser2Conversation];
    
    ZMUser *selfUser = [self userForMockUser:self.selfUser];
    XCTAssertEqual(selfUser.clients.count, 2u);
    UserClient *notSelfClient = [selfUser.clients.allObjects firstObjectMatchingWithBlock:^BOOL(UserClient *obj) {
       return obj.remoteIdentifier != selfUser.selfClient.remoteIdentifier;
    }];
    ZMUser *user1 = [self userForMockUser:self.user1];
    
    // when
    [self.userSession performChanges:^{
        [selfUser.selfClient trustClient:user1.clients.anyObject];
    }];
    WaitForAllGroupsToBeEmpty(1.0);
    
    [self.userSession performChanges:^{
        [self.userSession deleteClients:@[notSelfClient] withCredentials:[ZMEmailCredentials credentialsWithEmail:SelfUserEmail password:SelfUserPassword]];
    }];
    WaitForAllGroupsToBeEmpty(1.0);
    
    // then
    XCTAssertEqual(conversation1.securityLevel, ZMConversationSecurityLevelSecure);
    XCTAssertEqual(conversation2.securityLevel, ZMConversationSecurityLevelNotSecure);
}

- (void)testThatItSendsMessagesWhenThereAreIgnoredClients
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);

    void (^secureConversationBlock)(ZMConversation *) = ^(ZMConversation *conversation) {
        // send a message to fetch all the missing client
        [self.userSession performChanges:^{
            [conversation appendOTRMessageWithText:[NSString stringWithFormat:@"Hey %lu", conversation.messages.count] nonce:[NSUUID createUUID]];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
        [self makeConversationSecured:conversation];
        
    };

    ZMConversation *conversation1 = [self conversationForMockConversation:self.selfToUser1Conversation];
    ZMConversation *conversation2 = [self conversationForMockConversation:self.selfToUser2Conversation];
    
    secureConversationBlock(conversation1);
    secureConversationBlock(conversation2);

    ZMUser *user1 = [self userForMockUser:self.user1];
    
    // add additional client for user1 remotely
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session registerClientForUser:self.user1 label:@"other user 1 clients" type:@"permanent"];
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    
    NSSet *clientIDs = [self.user1.clients mapWithBlock:^id(MockUserClient *obj) {
        return obj.identifier;
    }];
    [self simulateResponseForFetchingUserClients:clientIDs.allObjects userID:user1.remoteIdentifier];
    [self.userSession performChanges:^{
        [user1 fetchUserClients];
    }];
    WaitForEverythingToBeDoneWithTimeout(0.5);
    XCTAssertEqual(user1.clients.count, 2u);

    [self.mockTransportSession resetReceivedRequests];
    
    // send a message in the trusted conversation
    [self.userSession performChanges:^{
        [conversation2 appendMessageWithText:@"Hello"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.mockTransportSession.receivedRequests.count, 1u);
    [self.mockTransportSession resetReceivedRequests];

    // and when sending a message in the not safe conversation
    [self.userSession performChanges:^{
        [conversation1 appendMessageWithText:@"Hello"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.mockTransportSession.receivedRequests.count, 1u);
}

@end

#pragma mark - Unable to decrypt message
@implementation ConversationTestsOTR (UnableToDecrypt)


- (void)testThatItInsertsASystemMessageWhenItCanNotDecryptAMessage {
    
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:10 establishSessionWithSelfUser:YES];
    
    // when
    [self performIgnoringZMLogError:^{
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
            [self.selfToUser1Conversation insertOTRMessageFromClient:self.user1.clients.anyObject
                                                            toClient:self.selfUser.clients.anyObject
                                                                data:[@"😱" dataUsingEncoding:NSUTF8StringEncoding]];
        }];

        WaitForAllGroupsToBeEmpty(5);
    }];
    
    // then
    id<ZMConversationMessage> lastMessage = conversation.messages.lastObject;
    XCTAssertEqual(conversation.messages.count, 2lu);
    XCTAssertNotNil(lastMessage.systemMessageData);
    XCTAssertEqual(lastMessage.systemMessageData.systemMessageType, ZMSystemMessageTypeDecryptionFailed);
}

- (void)testThatItNotifiesWhenInsertingCannotDecryptMessage {
    
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:10 establishSessionWithSelfUser:YES];
    XCTestExpectation *expectation = [self expectationWithDescription:@"It should call the observer"];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:ZMConversationFailedToDecryptMessageNotificationName object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification * _Nonnull note) {
        XCTAssertEqualObjects(conversation.remoteIdentifier, [(ZMConversation *)note.object remoteIdentifier]);
        XCTAssertNotNil(note.userInfo[@"cause"]);
        XCTAssertEqualObjects(note.userInfo[@"cause"], @"CBErrorCodeDecodeError");
        [expectation fulfill];
    }];
    
    // when
    [self performIgnoringZMLogError:^{
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
            [self.selfToUser1Conversation insertOTRMessageFromClient:self.user1.clients.anyObject
                                                            toClient:self.selfUser.clients.anyObject
                                                                data:[@"😱" dataUsingEncoding:NSUTF8StringEncoding]];
        }];

        WaitForAllGroupsToBeEmpty(0.5);
    }];
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:5]);
}

- (void)testThatItDoesNotInsertsASystemMessageWhenItDecryptsADuplicatedMessage {
    
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    EncryptionContext *user1Context = [self setupOTREnvironmentForUser:self.user1 isSelfClient:NO numberOfKeys:10 establishSessionWithSelfUser:YES];
    __block NSData* firstMessageData;
    NSString *firstMessageText = @"Testing duplication";
    MockUserClient *mockSelfClient = self.selfUser.clients.anyObject;
    MockUserClient *mockUser1Client = self.user1.clients.anyObject;
    
    // when sending the fist message
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
        ZMGenericMessage *firstMessage = [ZMGenericMessage messageWithText:firstMessageText nonce:[NSUUID createUUID].transportString expiresAfter:nil];
        
        // get last prekey of selfClient
        ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
        __block NSString *lastPrekey;
        [selfUser.selfClient.keysStore.encryptionContext perform:^(EncryptionSessionsDirectory * _Nonnull sessionsDirectory) {
            __block NSError *error;
            lastPrekey = [sessionsDirectory generateLastPrekeyAndReturnError:&error];
            XCTAssertNil(error, @"Error generating preKey: %@", error);
        }];
        
        // use last prekrey of selfclient to establish session and create session message by user1Client
        [user1Context perform:^(EncryptionSessionsDirectory * _Nonnull sessionsDirectory) {
            __block NSError *error;
            [sessionsDirectory createClientSession:mockSelfClient.identifier base64PreKeyString:lastPrekey error:&error];
            firstMessageData = [sessionsDirectory encrypt:firstMessage.data recipientClientId:mockSelfClient.identifier error:&error];
            XCTAssertNil(error, @"Error encrypting message: %@", error);
        }];
        [self.selfToUser1Conversation insertOTRMessageFromClient:mockUser1Client toClient:mockSelfClient data:firstMessageData];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    
    // then
    NSUInteger previousNumberOfMessages = conversation.messages.count;
    id<ZMConversationMessage> lastMessage = conversation.messages.lastObject;
    XCTAssertNil(lastMessage.systemMessageData);
    XCTAssertEqualObjects(lastMessage.textMessageData.messageText, firstMessageText);
    
    // log out
    [self recreateUserSessionAndWipeCache:NO];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self performIgnoringZMLogError:^{
        // and when resending the same data (CBox should return DUPLICATED error)
        XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
            [self.selfToUser1Conversation insertOTRMessageFromClient:mockUser1Client toClient:mockSelfClient data:firstMessageData];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
    }];
    
    // then
    conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    NSUInteger newNumberOfMessages = conversation.messages.count;

    lastMessage = conversation.messages.lastObject;
    XCTAssertNil(lastMessage.systemMessageData);
    XCTAssertEqualObjects(lastMessage.textMessageData.messageText, firstMessageText);
    XCTAssertEqual(newNumberOfMessages, previousNumberOfMessages);
}

@end
