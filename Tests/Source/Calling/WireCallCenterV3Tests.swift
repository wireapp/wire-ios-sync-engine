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

import Foundation
@testable import WireSyncEngine

class WireCallCenterTransportMock : WireCallCenterTransport {
    
    var mockCallConfigResponse : (String, Int)?
    
    
    func send(data: Data, conversationId: UUID, userId: UUID, completionHandler: @escaping ((Int) -> Void)) {
        
    }
    
    func requestCallConfig(completionHandler: @escaping CallConfigRequestCompletion) {
        if let mockCallConfigResponse = mockCallConfigResponse {
            completionHandler(mockCallConfigResponse.0, mockCallConfigResponse.1)
        }
    }
    
}

class WireCallCenterV3Tests: MessagingTest {

    var flowManager : FlowManagerMock!
    var mockAVSWrapper : MockAVSWrapper!
    var sut : WireCallCenterV3!
    let otherUserID : UUID = UUID()
    var selfUserID : UUID!
    var oneOnOneConversationID : UUID!
    var groupConversationID : UUID!
    var clientID: String!
    var mockTransport : WireCallCenterTransportMock!
    var oneOnOneConversationIDRef : [CChar]!
    var groupConversationIDRef : [CChar]!
    var otherUserIDRef : [CChar]!
    var context : UnsafeMutableRawPointer!
    
    override func setUp() {
        super.setUp()
        
        let selfUser = ZMUser.selfUser(in: uiMOC)
        selfUser.remoteIdentifier = UUID.create()
        selfUserID = selfUser.remoteIdentifier!
        
        let oneOnOneConversation = ZMConversation.insertNewObject(in: self.uiMOC)
        oneOnOneConversation.remoteIdentifier = UUID.create()
        oneOnOneConversation.conversationType = .oneOnOne
        oneOnOneConversationID = oneOnOneConversation.remoteIdentifier!
        
        let groupConversation = ZMConversation.insertNewObject(in: self.uiMOC)
        groupConversation.remoteIdentifier = UUID.create()
        groupConversation.conversationType = .group
        groupConversationID = groupConversation.remoteIdentifier!
        
        clientID = "foo"
        flowManager = FlowManagerMock()
        mockAVSWrapper = MockAVSWrapper(userId: selfUserID, clientId: clientID, observer: nil)
        mockTransport = WireCallCenterTransportMock()
        sut = WireCallCenterV3(userId: selfUserID, clientId: clientID, avsWrapper: mockAVSWrapper, uiMOC: uiMOC, flowManager: flowManager, transport: mockTransport)
        oneOnOneConversationIDRef = oneOnOneConversationID.transportString().cString(using: .utf8)
        groupConversationIDRef = groupConversationID.transportString().cString(using: .utf8)
        otherUserIDRef = otherUserID.transportString().cString(using: .utf8)
        context = Unmanaged.passUnretained(self.sut).toOpaque()
    }
    
    override func tearDown() {
        sut = nil
        flowManager = nil
        clientID = nil
        selfUserID = nil
        oneOnOneConversationID = nil
        mockTransport = nil
        mockAVSWrapper = nil
        oneOnOneConversationIDRef = nil
        otherUserIDRef = nil
        context = nil
        
        super.tearDown()
    }
    
    func checkThatItPostsNotification(expectedCallState: CallState, expectedCallerId: UUID, expectedConversationId: UUID, line: UInt = #line, file : StaticString = #file, actionBlock: () -> Void) {
        // expect
        expectation(forNotification: WireCallCenterCallStateNotification.notificationName.rawValue, object: nil) { wrappedNote in
            guard let note = wrappedNote.userInfo?[WireCallCenterCallStateNotification.userInfoKey] as? WireCallCenterCallStateNotification else { return false }
            XCTAssertEqual(note.conversationId, expectedConversationId, "conversationIds are not the same", file: file, line: line)
            XCTAssertEqual(note.callerId, expectedCallerId, "callerIds are not the same", file: file, line: line)
            XCTAssertEqual(note.callState, expectedCallState, "callStates are not the same", file: file, line: line)

            return true
        }
        
        // when
        actionBlock()
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatTheIncomingCallHandlerPostsTheRightNotification_IsVideo() {
        checkThatItPostsNotification(expectedCallState: .incoming(video: true, shouldRing: false, degraded: false), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef,
                                               messageTime: 0,
                                               userId: otherUserIDRef,
                                               isVideoCall: 1,
                                               shouldRing: 0,
                                               contextRef: context)
        }
    }
    
    func testThatTheIncomingCallHandlerPostsTheRightNotification() {
        checkThatItPostsNotification(expectedCallState: .incoming(video: false, shouldRing: false, degraded: false), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef,
                                               messageTime: 0,
                                               userId: otherUserIDRef,
                                               isVideoCall: 0,
                                               shouldRing: 0,
                                               contextRef: context)
        }
    }
    
    func testThatTheIncomingCallHandlerPostsTheRightNotification_IsVideo_ShouldRing() {
        checkThatItPostsNotification(expectedCallState: .incoming(video: true, shouldRing: true, degraded: false), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef,
                                               messageTime: 0,
                                               userId: otherUserIDRef,
                                               isVideoCall: 1,
                                               shouldRing: 1,
                                               contextRef: context)
        }
    }
    
    func testThatTheIncomingCallHandlerPostsTheRightNotification_ShouldRing() {
        checkThatItPostsNotification(expectedCallState: .incoming(video: false, shouldRing: true, degraded: false), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef,
                                               messageTime: 0,
                                               userId: otherUserIDRef,
                                               isVideoCall: 0,
                                               shouldRing: 1,
                                               contextRef: context)
        }
    }
    
    
    func testThatTheMissedCallHandlerPostANotification() {
        // given
        let conversationId = UUID()
        let userId = UUID()
        let conversationIdRef = conversationId.transportString().cString(using: .utf8)
        let userIdRef = userId.transportString().cString(using: .utf8)
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        let isVideo = false
        let timestamp = Date()
        
        // expect
        expectation(forNotification: WireCallCenterMissedCallNotification.notificationName.rawValue, object: nil) { wrappedNote in
            guard let note = wrappedNote.userInfo?[WireCallCenterMissedCallNotification.userInfoKey] as? WireCallCenterMissedCallNotification else { return false }
            XCTAssertEqual(note.conversationId, conversationId)
            XCTAssertEqual(note.callerId, userId)
            XCTAssertEqual(note.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(note.video, isVideo)
            return true
        }
        
        // when
        WireSyncEngine.missedCallHandler(conversationId: conversationIdRef, messageTime: UInt32(timestamp.timeIntervalSince1970), userId: userIdRef, isVideoCall: 0, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatTheAnsweredCallHandlerPostsTheRightNotification() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        checkThatItPostsNotification(expectedCallState: .answered(degraded: false), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.answeredCallHandler(conversationId: oneOnOneConversationIDRef, contextRef: context)
        }
    }
    
    func testThatTheEstablishedHandlerPostsTheRightNotification() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        checkThatItPostsNotification(expectedCallState: .established, expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        }
    }
    
    func testThatTheEstablishedHandlerSetsTheStartTime() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNil(sut.establishedDate)
        
        // when
        checkThatItPostsNotification(expectedCallState: .established, expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        }
        
        // then
        XCTAssertNotNil(sut.establishedDate)
    }
    
    func testThatTheEstablishedHandlerDoesntSetTheStartTimeIfCallIsAlreadyEstablished() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNil(sut.establishedDate)
        
        // call is established
        WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNotNil(sut.establishedDate)
        let previousEstablishedDate = sut.establishedDate
        spinMainQueue(withTimeout: 0.1)
        
        // when
        WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(sut.establishedDate, previousEstablishedDate)
    }
    
    func testThatTheClosedCallHandlerPostsTheRightNotification() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        checkThatItPostsNotification(expectedCallState: .terminating(reason: .canceled), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            WireSyncEngine.closedCallHandler(reason: WCALL_REASON_CANCELED, conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, contextRef: context)
        }
    }
    
    func testThatOtherIncomingCallsAreRejectedWhenWeAnswerCall() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        WireSyncEngine.incomingCallHandler(conversationId: groupConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        XCTAssertTrue(sut.answerCall(conversationId: oneOnOneConversationID))
        
        // then
        XCTAssertTrue(mockAVSWrapper.didCallRejectCall)
    }
    
    func testThatOtherOutgoingCallsAreCanceledWhenWeAnswerCall() {
        // given
        XCTAssertTrue(sut.startCall(conversationId: groupConversationID, video: false))
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        XCTAssertTrue(sut.answerCall(conversationId: oneOnOneConversationID))
        
        // then
        XCTAssertTrue(mockAVSWrapper.didCallEndCall)
    }
    
    func testThatOtherIncomingCallsAreRejectedWhenWeStartCall() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        XCTAssertTrue(sut.startCall(conversationId: groupConversationID, video: false))
        
        // then
        XCTAssertTrue(mockAVSWrapper.didCallRejectCall)
    }
    
    func testThatItRejectsACall_Group() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: groupConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // expect
        expectation(forNotification: WireCallCenterCallStateNotification.notificationName.rawValue, object: nil) { wrappedNote in
            guard let note = wrappedNote.userInfo?[WireCallCenterCallStateNotification.userInfoKey] as? WireCallCenterCallStateNotification else { return false }
            XCTAssertEqual(note.conversationId, self.groupConversationID)
            XCTAssertEqual(note.callerId, self.otherUserID)
            XCTAssertEqual(note.callState, .incoming(video: false, shouldRing: false, degraded: false))
            return true
        }
        
        // when
        sut.rejectCall(conversationId: oneOnOneConversationID)
        WireSyncEngine.closedCallHandler(reason: WCALL_REASON_STILL_ONGOING, conversationId: groupConversationIDRef, messageTime: 0, userId: otherUserIDRef, contextRef: context)

        // then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(mockAVSWrapper.didCallRejectCall)
    }
    
    func testThatItRejectsACall_1on1() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // expect
        expectation(forNotification: WireCallCenterCallStateNotification.notificationName.rawValue, object: nil) { wrappedNote in
            guard let note = wrappedNote.userInfo?[WireCallCenterCallStateNotification.userInfoKey] as? WireCallCenterCallStateNotification else { return false }
            XCTAssertEqual(note.conversationId, self.oneOnOneConversationID)
            XCTAssertEqual(note.callerId, self.otherUserID)
            XCTAssertEqual(note.callState, .incoming(video: false, shouldRing: false, degraded: false))
            return true
        }
        
        // when
        sut.rejectCall(conversationId: oneOnOneConversationID)
        WireSyncEngine.closedCallHandler(reason: WCALL_REASON_STILL_ONGOING, conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, contextRef: context)

        // then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(mockAVSWrapper.didCallRejectCall)
    }
    
    func testThatItAnswersACall() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        checkThatItPostsNotification(expectedCallState: .answered(degraded: false), expectedCallerId: otherUserID, expectedConversationId: oneOnOneConversationID) {
            // when
            _ = sut.answerCall(conversationId: oneOnOneConversationID)
            
            // then
            XCTAssertTrue(mockAVSWrapper.didCallAnswerCall)
        }
    }
    
    func testThatItStartsACall(){
        checkThatItPostsNotification(expectedCallState: .outgoing(degraded: false), expectedCallerId: selfUserID, expectedConversationId: groupConversationID) {
            // when
            _ = sut.startCall(conversationId: groupConversationID, video: false)
            
            // then
            XCTAssertTrue(mockAVSWrapper.didCallStartCall)
        }
    }
    
    func testThatItSetsTheCallStartTimeBeforePostingTheNotification() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNil(sut.establishedDate)
        
        // expect
        expectation(forNotification: WireCallCenterCallStateNotification.notificationName.rawValue, object: nil) { wrappedNote in
            XCTAssertNotNil(self.sut.establishedDate)
            return true
        }
        
        // when
        WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        
        // then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItBuffersEventsUntilAVSIsReady() {
        // given
        let userId = UUID()
        let clientId = "foo"
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        let data = self.verySmallJPEGData()
        
        // when
        sut.received(data: data, currentTimestamp: Date(), serverTimestamp: Date(), conversationId: oneOnOneConversationID, userId: userId, clientId: clientId)
        XCTAssertEqual((sut.avsWrapper as! MockAVSWrapper).receivedCallEvents.count, 0)
        
        // and when
        WireSyncEngine.readyHandler(version: 2, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual((sut.avsWrapper as! MockAVSWrapper).receivedCallEvents.count, 1)
        if let event = (sut.avsWrapper as! MockAVSWrapper).receivedCallEvents.last {
            XCTAssertEqual(event.conversationId, oneOnOneConversationID)
            XCTAssertEqual(event.userId, userId)
            XCTAssertEqual(event.clientId, clientId)
            XCTAssertEqual(event.data, data)
        }
    }
    
    func testThatCBRIsEnabledOnAudioCBRChangeHandler_whenCallIsEstablished() {
        // given
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        WireSyncEngine.constantBitRateChangeHandler(userId: otherUserIDRef, enabled: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertTrue(sut.isContantBitRate(conversationId: oneOnOneConversationID))
    }
    
    func testThatCBRIsEnabledOnAudioCBRChangeHandler_whenDataChannelIsEstablished() {
        // given
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        WireSyncEngine.dataChannelEstablishedHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        WireSyncEngine.constantBitRateChangeHandler(userId: otherUserIDRef, enabled: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertTrue(sut.isContantBitRate(conversationId: oneOnOneConversationID))
    }
    
    func testThatCBRIsDisabledOnAudioCBRChangeHandler() {
        // given
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        WireSyncEngine.constantBitRateChangeHandler(userId: otherUserIDRef, enabled: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))        
        XCTAssertTrue(sut.isContantBitRate(conversationId: oneOnOneConversationID))
        
        // when
        WireSyncEngine.constantBitRateChangeHandler(userId: otherUserIDRef, enabled: 0, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // then
        XCTAssertFalse(sut.isContantBitRate(conversationId: oneOnOneConversationID))
    }
    
    func testThatCBRIsNotEnabledOnAudioCBRChangeHandlerWhenCallIsNotEstablished() {
        // given
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        WireSyncEngine.constantBitRateChangeHandler(userId: otherUserIDRef, enabled: 0, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertFalse(sut.isContantBitRate(conversationId: oneOnOneConversationID))
    }
    
    func testThatCBRIsNotEnabledAfterCallIsTerminated() {
        // given
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        WireSyncEngine.establishedCallHandler(conversationId: oneOnOneConversationIDRef, userId: otherUserIDRef, contextRef: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        WireSyncEngine.constantBitRateChangeHandler(userId: otherUserIDRef, enabled: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        WireSyncEngine.closedCallHandler(reason: WCALL_REASON_NORMAL, conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertFalse(sut.isContantBitRate(conversationId: oneOnOneConversationID))
    }
    
}

// MARK: - Ignoring Calls

extension WireCallCenterV3Tests {
    
    func testThatItWhenIgnoringACallItWillSetsTheCallStateToIncomingInactive() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        sut.rejectCall(conversationId: oneOnOneConversationID)
        
        // then
        XCTAssertEqual(sut.callState(conversationId: oneOnOneConversationID), .incoming(video: false, shouldRing: false, degraded: false))
    }
    
    func testThatItWhenRejectingAOneOnOneCallItWilltSetTheCallStateToIncomingInactive() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        sut.rejectCall(conversationId: oneOnOneConversationID)
        
        // then
        XCTAssertEqual(sut.callState(conversationId: oneOnOneConversationID), .incoming(video: false, shouldRing: false, degraded: false))
    }
    
    func testThatItWhenClosingAGroupCallItWillSetsTheCallStateToIncomingInactive() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: groupConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        sut.closeCall(conversationId: groupConversationID)
        
        // then
        XCTAssertEqual(sut.callState(conversationId: groupConversationID), .incoming(video: false, shouldRing: false, degraded: false))
    }
    
    func testThatItWhenClosingAOneOnOneCallItDoesNotSetTheCallStateToIncomingInactive() {
        // given
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        sut.closeCall(conversationId: oneOnOneConversationID)
        
        // then
        XCTAssertNotEqual(sut.callState(conversationId: oneOnOneConversationID), .incoming(video: false, shouldRing: false, degraded: false))
    }
    
}


// MARK: - Participants
extension WireCallCenterV3Tests {

    func testThatItCreatesAParticipantSnapshotForAnIncomingCall() {
        // when
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(sut.callParticipants(conversationId: oneOnOneConversationID), [otherUserID])
    }
    
    func callBackMemberHandler(conversationIdRef: UnsafePointer<Int8>?, userId: UUID, audioEstablished: Bool, context: UnsafeMutableRawPointer?) {
        mockAVSWrapper.mockMembers = [CallMember(userId: userId, audioEstablished: audioEstablished)]
        WireSyncEngine.groupMemberHandler(conversationIdRef: conversationIdRef, contextRef: context)
    }
    
    func testThatItUpdatesTheParticipantsWhenGroupHandlerIsCalled() {
        // when
        callBackMemberHandler(conversationIdRef: oneOnOneConversationIDRef, userId: otherUserID, audioEstablished: false, context: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(sut.callParticipants(conversationId: oneOnOneConversationID), [otherUserID])
    }
    
    func testThatItUpdatesTheStateForParticipant() {
        // when
        WireSyncEngine.incomingCallHandler(conversationId: oneOnOneConversationIDRef, messageTime: 0, userId: otherUserIDRef, isVideoCall: 0, shouldRing: 1, contextRef: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        let connectingState = sut.state(forUser: otherUserID, in: oneOnOneConversationID)
        XCTAssertEqual(connectingState, CallParticipantState.connecting)
        
        // when
        callBackMemberHandler(conversationIdRef: oneOnOneConversationIDRef, userId: otherUserID, audioEstablished: true, context: context)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        let connectedState = sut.state(forUser: otherUserID, in: oneOnOneConversationID)
        XCTAssertEqual(connectedState, CallParticipantState.connected(muted: false, sendingVideo: false))
    }
}

// MARK: - Call Config
extension WireCallCenterV3Tests {
    
    func testThatCallConfigRequestsAreForwaredToTransportAndAVS() {
        // given
        mockTransport.mockCallConfigResponse = ("call_config", 200)
        let context = Unmanaged.passUnretained(self.sut).toOpaque()
        
        // when
        XCTAssertEqual(WireSyncEngine.requestCallConfigHandler(handle: nil, contextRef: context), 0)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertTrue(mockAVSWrapper.didUpdateCallConfig)
    }
    
}
