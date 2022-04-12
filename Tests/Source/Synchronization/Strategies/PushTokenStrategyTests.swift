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

@testable import WireSyncEngine
import WireRequestStrategy
import WireTesting

class PushTokenStrategyTests: MessagingTest {

    var sut: PushTokenStrategy!
    var mockApplicationStatus: MockApplicationStatus!
    var mockAnalytics: MockAnalytics!
    let deviceToken = Data(base64Encoded: "xeJOQeTUMpA3koRJNJSHVH7xTxYsd67jqo4So5yNsdU=")!
    var deviceTokenString: String {
        return deviceToken.zmHexEncodedString()
    }

    let deviceTokenB = Data(base64Encoded: "DBFjMBFIXEVYYVAJBFsCLVZeDDgKUzBETToPSxhaAUo=")!
    var deviceTokenBString: String {
        return deviceTokenB.zmHexEncodedString()
    }

    let identifier = "com.wire.WireSyncEngine-Test-Host"
    let transportTypeNormal = "APNS"
    let transportTypeVOIP = "APNS_VOIP"

    override func setUp() {
        super.setUp()
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .online
        mockAnalytics = MockAnalytics()
        syncMOC.performGroupedAndWait { moc in
            self.sut = PushTokenStrategy(withManagedObjectContext: moc, applicationStatus: self.mockApplicationStatus, analytics: self.mockAnalytics)
            self.setupSelfClient(inMoc: moc)
        }
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    @discardableResult func insertPushKitToken(isRegistered: Bool, shouldBeDeleted: Bool = false, shouldBeDownloaded: Bool = false) -> [String: String] {
        let client = ZMUser.selfUser(in: self.syncMOC).selfClient()
        var token = PushToken(deviceToken: deviceTokenB, pushTokenType: .voip, isRegistered: isRegistered)
        token.isMarkedForDeletion = shouldBeDeleted
        token.isMarkedForDownload = shouldBeDownloaded
        client?.pushToken = token
        self.syncMOC.saveOrRollback()
        self.notifyChangeTrackers()
        return [
            "token": token.deviceTokenString,
            "app": token.appIdentifier,
            "transport": token.transportType,
            "client": client!.remoteIdentifier!
        ]
    }

    func notifyChangeTrackers() {
        let client = ZMUser.selfUser(in: self.syncMOC).selfClient()
        self.sut.contextChangeTrackers.forEach {$0.objectsDidChange([client!])}
    }

    func clearPushKitToken() {
        let client = ZMUser.selfUser(in: self.syncMOC).selfClient()
        client?.pushToken = nil
        self.syncMOC.saveOrRollback()
    }

    func pushKitToken() -> PushToken? {
        let client = ZMUser.selfUser(in: self.syncMOC).selfClient()
        return client?.pushToken
    }

    func fakeResponse(transport: String, fallback: String? = nil) -> ZMTransportResponse {
        var responsePayload = ["token": deviceTokenBString,
                               "app": identifier,
                               "transport": transport]
        if let fallback = fallback {
            responsePayload["fallback"] = fallback
        }
        return ZMTransportResponse(payload: responsePayload as ZMTransportData?, httpStatus: 201, transportSessionError: nil, headers: [:], apiVersion: APIVersion.v0.rawValue)
    }
}

extension PushTokenStrategyTests {

    func testThatItDoesNotReturnARequestWhenThereIsNoPushToken() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.clearPushKitToken()

            // when
            let req = self.sut.nextRequest(for: .v0)

            // then
            XCTAssertNil(req)
        }
    }

    func testThatItReturnsNoRequestIfTheClientIsNotRegistered() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.mockApplicationStatus.mockSynchronizationState = .unauthenticated
            self.insertPushKitToken(isRegistered: false)
            self.sut.contextChangeTrackers.forEach {$0.objectsDidChange(Set())}

            // when
            let req = self.sut.nextRequest(for: .v0)

            // then
            XCTAssertNil(req)
        }
    }
}

// MARK: Reregistering
extension PushTokenStrategyTests {

    func testThatItNilsTheTokenWhenReceivingAPushRemoveEvent() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.insertPushKitToken(isRegistered: true)

            let payload = ["type": "user.push-remove",
                           "token": self.deviceTokenBString]
            let event = ZMUpdateEvent(fromEventStreamPayload: payload as ZMTransportData, uuid: nil)!

            // when
            self.sut.processEvents([event], liveEvents: true, prefetchResult: nil)
            self.syncMOC.saveOrRollback()

            // then
            XCTAssertNil(self.pushKitToken())
        }
    }

}

// MARK: - PushKit
extension PushTokenStrategyTests {

    func testThatItReturnsARequestWhenThePushKitTokenIsNotRegistered() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.insertPushKitToken(isRegistered: false)

            // when
            let req = self.sut.nextRequest(for: .v0)

            // then
            guard let request = req else { return XCTFail() }
            guard let payloadDictionary = request.payload as? [String: String] else { XCTFail(); return }

            let expectedPayload = ["token": "0c11633011485c4558615009045b022d565e0c380a5330444d3a0f4b185a014a",
                                   "app": "com.wire.WireSyncEngine-Test-Host",
                                   "transport": "APNS_VOIP",
                                   "client": (ZMUser.selfUser(in: self.syncMOC).selfClient()?.remoteIdentifier)!]

            XCTAssertEqual(request.method, .methodPOST)
            XCTAssertEqual(request.path, "/push/tokens")
            XCTAssertEqual(payloadDictionary, expectedPayload)
        }
    }

    func testThatItMarksThePushKitTokenAsRegisteredWhenTheRequestCompletes() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.insertPushKitToken(isRegistered: false)

            let response = self.fakeResponse(transport: self.transportTypeVOIP)

            // when
            let request = self.sut.nextRequest(for: .v0)
            request?.complete(with: response)
        }
        self.syncMOC.performGroupedAndWait { _ in
            // then
            guard let token = self.pushKitToken() else { XCTFail("Push token should not be nil"); return }
            XCTAssertTrue(token.isRegistered)
            XCTAssertEqual(token.appIdentifier, self.identifier)
            XCTAssertEqual(token.deviceToken, self.deviceTokenB)
        }
    }

    func testThatItDoesNotRegisterThePushKitTokenAgainAfterTheRequestCompletes() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.insertPushKitToken(isRegistered: false)
            let response = self.fakeResponse(transport: self.transportTypeVOIP, fallback: "APNS")

            // when
            let request = self.sut.nextRequest(for: .v0)
            request?.complete(with: response)
        }
        self.syncMOC.performGroupedAndWait { _ in
            // then
            XCTAssertNotNil(ZMUser.selfUser(in: self.uiMOC).selfClient()?.pushToken)
            self.notifyChangeTrackers()

            // and when
            let request2 = self.sut.nextRequest(for: .v0)
            XCTAssertNil(request2)
        }
    }
}

// MARK: - Deleting Tokens
extension PushTokenStrategyTests {

    func testThatItSyncsTokensThatWereMarkedToDeleteAndDeletesThem() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.insertPushKitToken(isRegistered: true, shouldBeDeleted: true)
            self.sut.contextChangeTrackers.forEach {$0.objectsDidChange(Set())}
            let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil, headers: [:], apiVersion: APIVersion.v0.rawValue)

            // when
            let req = self.sut.nextRequest(for: .v0)

            guard let request = req else { XCTFail(); return }
            XCTAssertEqual(request.method, .methodDELETE)
            XCTAssertTrue(request.path.contains("push/tokens"))
            XCTAssertNil(request.payload)

            request.complete(with: response)
        }
        self.syncMOC.performGroupedAndWait { _ in
            // then
            XCTAssertNil(self.pushKitToken())
            self.notifyChangeTrackers()

            // and when
            let request2 = self.sut.nextRequest(for: .v0)
            XCTAssertNil(request2)
        }
    }

    func testThatItDoesNotDeleteTokensThatAreNotMarkedForDeletion() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            self.insertPushKitToken(isRegistered: true, shouldBeDeleted: true)
            XCTAssertNotNil(self.pushKitToken())
            let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil, headers: [:], apiVersion: APIVersion.v0.rawValue)

            // when
            let req = self.sut.nextRequest(for: .v0)

            guard let request = req else { XCTFail(); return }
            XCTAssertEqual(request.method, .methodDELETE)
            XCTAssertTrue(request.path.contains("push/tokens"))
            XCTAssertNil(request.payload)

            // and replacing the token while the request is in progress
            self.insertPushKitToken(isRegistered: true)

            request.complete(with: response)
        }
        self.syncMOC.performGroupedAndWait { _ in
            // then
            XCTAssertNotNil(self.pushKitToken())
        }
    }
}

// MARK: - Getting Tokens
extension PushTokenStrategyTests {
    func testThatItDownloadsTokensAndChecksIfItMatches() {
        self.syncMOC.performGroupedAndWait { _ in
            // given
            let payload = self.insertPushKitToken(isRegistered: true, shouldBeDeleted: false, shouldBeDownloaded: true)
            XCTAssertNotNil(self.pushKitToken())
            let response = ZMTransportResponse(payload: ["tokens": [payload]] as NSDictionary, httpStatus: 200, transportSessionError: nil, headers: [:], apiVersion: APIVersion.v0.rawValue)

            // when
            let req = self.sut.nextRequest(for: .v0)

            guard let request = req else { XCTFail(); return }
            XCTAssertEqual(request.method, .methodGET)
            XCTAssertEqual(request.path, "/push/tokens")
            XCTAssertNil(request.payload)

            request.complete(with: response)
        }

        self.syncMOC.performGroupedAndWait { _ in
            // then
            guard let token = self.pushKitToken() else { XCTFail(); return }
            XCTAssertFalse(token.isMarkedForDownload)

            // Nothing is tracked if everything is fine
            XCTAssertTrue(self.mockAnalytics.taggedEvents.isEmpty)
        }
    }

    func testThatItDownloadsTokensAndResetsIfNotValid() {
        // Should be fired when we have to reupload the token
        expectation(forNotification: ZMUserSession.registerCurrentPushTokenNotificationName, object: nil, handler: nil)

        self.syncMOC.performGroupedAndWait { _ in
            // given
            var payload = self.insertPushKitToken(isRegistered: true, shouldBeDeleted: false, shouldBeDownloaded: true)
            // Token for this client is different
            payload["token"] = "something else"
            XCTAssertNotNil(self.pushKitToken())
            let response = ZMTransportResponse(payload: ["tokens": [payload]] as NSDictionary, httpStatus: 200, transportSessionError: nil, headers: [:], apiVersion: APIVersion.v0.rawValue)

            // when
            let req = self.sut.nextRequest(for: .v0)

            guard let request = req else { XCTFail(); return }
            XCTAssertEqual(request.method, .methodGET)
            XCTAssertEqual(request.path, "/push/tokens")
            XCTAssertNil(request.payload)

            request.complete(with: response)
        }
        self.syncMOC.performGroupedAndWait { _ in
            // then
            XCTAssertNil(self.pushKitToken())

            let payload: [String: NSObject] = [
                NotificationsTracker.Attributes.tokenMismatch.identifier: 1 as NSObject
            ]
            guard let attributes = self.mockAnalytics.eventAttributes.first else { XCTFail(); return }
            XCTAssertEqual(attributes.value, payload)
        }

        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
    }

}
