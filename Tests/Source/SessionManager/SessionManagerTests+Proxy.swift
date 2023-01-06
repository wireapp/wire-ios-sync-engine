//
//  SessionManagerTests+Proxy.swift
//  IntegrationTests
//
//  Created by F on 06/01/2023.
//  Copyright © 2023 Zeta Project Gmbh. All rights reserved.
//

import Foundation
@testable import WireSyncEngine

final class SessionManagerTests_Proxy: IntegrationTest {
    var reachabilityWrapper: ReachabilityWrapper!
    var unauthenticatedSessionFactory: MockUnauthenticatedSessionFactory!
    var authenticatedSessionFactory: MockAuthenticatedSessionFactory!

    override func createSessionManager() {
        guard
            let application = self.application,
            let transportSession = mockTransportSession
        else {
            return XCTFail()
        }

        let reachability = MockReachability()

        reachabilityWrapper = ReachabilityWrapper(enabled: false, reachabilityClosure: { reachability })

        unauthenticatedSessionFactory = MockUnauthenticatedSessionFactory(transportSession: transportSession, environment: mockEnvironment, reachability: reachability)
        authenticatedSessionFactory = MockAuthenticatedSessionFactory(
            application: application,
            mediaManager: mockMediaManager,
            flowManager: FlowManagerMock(),
            transportSession: transportSession,
            environment: mockEnvironment,
            reachability: reachability
        )

        let pushTokenService: PushTokenServiceInterface = mockPushTokenService ?? PushTokenService()
        application.pushTokenService = pushTokenService

        sessionManager = SessionManager(
            appVersion: "0.0.0",
            authenticatedSessionFactory: authenticatedSessionFactory,
            unauthenticatedSessionFactory: unauthenticatedSessionFactory,
            reachability: reachabilityWrapper,
            delegate: self,
            application: application,
            pushRegistry: pushRegistry,
            dispatchGroup: self.dispatchGroup,
            environment: mockEnvironment,
            configuration: sessionManagerConfiguration,
            detector: jailbreakDetector,
            requiredPushTokenType: shouldProcessLegacyPushes ? .voip : .standard,
            pushTokenService: pushTokenService,
            callKitManager: MockCallKitManager(),
            proxyCredentials: nil,
            isUnauthenticatedTransportSessionReady: false
        )

        sessionManager?.loginDelegate = mockLoginDelegete

        sessionManager?.start(launchOptions: [:])

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }

    func test_markNetworkSessionsAsReady_createsUnauthenticatedSession() {
        // GIVEN
        XCTAssertFalse(unauthenticatedSessionFactory.readyForRequests)

        // WHEN
        sessionManager?.markNetworkSessionsAsReady(true)

        // THEN
        XCTAssertTrue(reachabilityWrapper.enabled)
        XCTAssertTrue(unauthenticatedSessionFactory.readyForRequests)
        XCTAssertNotNil(sessionManager?.unauthenticatedSession)
        XCTAssertNotNil(sessionManager?.apiVersionResolver)
    }
}
