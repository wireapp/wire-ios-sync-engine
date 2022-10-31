//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
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
import XCTest

class APIVersionResolverTests: ZMTBaseTest {

    private var transportSession: MockTransportSession!
    private var mockDelegate: MockAPIVersionResolverDelegate!

    override func setUp() {
        mockDelegate = .init()
        transportSession = MockTransportSession(dispatchGroup: dispatchGroup)
        setCurrentAPIVersion(nil)
        super.setUp()
    }

    override func tearDown() {
        mockDelegate = nil
        transportSession = nil
        setCurrentAPIVersion(nil)
        super.tearDown()
    }

    private func createSUT(
        clientProdVersions: Set<APIVersion>,
        clientDevVersions: Set<APIVersion>,
        isDeveloperModeEnabled: Bool = false
    ) -> APIVersionResolver {
        let sut = APIVersionResolver(
            clientProdVersions: clientProdVersions,
            clientDevVersions: clientDevVersions,
            transportSession: transportSession,
            isDeveloperModeEnabled: isDeveloperModeEnabled
        )

        sut.delegate = mockDelegate
        return sut
    }

    private func mockBackendInfo(
        productionVersions: ClosedRange<Int32>,
        developmentVersions: ClosedRange<Int32>?,
        domain: String,
        isFederationEnabled: Bool
    ) {
        transportSession.supportedAPIVersions = productionVersions.map(NSNumber.init(value:))

        if let developmentVersions = developmentVersions {
            transportSession.developmentAPIVersions = developmentVersions.map(NSNumber.init(value:))
        }

        transportSession.domain = domain
        transportSession.federation = isFederationEnabled
    }

    // MARK: - Endpoint unavailable

    func testThatItDefaultsToVersionZeroIfEndpointIsUnavailable() throws {
        // Given the client supports API versioning.
        let sut = createSUT(
            clientProdVersions: Set(APIVersion.allCases),
            clientDevVersions: []
        )

        // Given the backend does not.
        transportSession.isAPIVersionEndpointAvailable = false

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then it resolves to v0.
        let resolvedVersion = try XCTUnwrap(BackendInfo.apiVersion)
        XCTAssertEqual(resolvedVersion, .v0)
        XCTAssertEqual(BackendInfo.domain, "wire.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, false)
    }

    // MARK: - Highest productino version

    func testThatItResolvesTheHighestProductionAPIVersion() throws {
        // Given client has prod and dev versions.
        let sut = createSUT(
            clientProdVersions: [.v0, .v1],
            clientDevVersions: [.v2]
        )

        // Given backend also has prod and dev versions.
        mockBackendInfo(
            productionVersions: 0...1,
            developmentVersions: 2...2,
            domain: "foo.com",
            isFederationEnabled: true
        )

        XCTAssertNil(BackendInfo.apiVersion)

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then it's the highest common prod version.
        XCTAssertEqual(BackendInfo.apiVersion, .v1)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    func testThatItResolvesTheHighestProductionAPIVersionWhenDevelopmentVersionsAreAbsent() throws {
        // Given client has prod and dev versions.
        let sut = createSUT(
            clientProdVersions: [.v0, .v1],
            clientDevVersions: [.v2]
        )

        // Given backend only has prod versons.
        mockBackendInfo(
            productionVersions: 0...1,
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        XCTAssertNil(BackendInfo.apiVersion)

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then it's the highest common prod version.
        XCTAssertEqual(BackendInfo.apiVersion, .v1)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    // MARK: - Peferred version

    func testThatItResolvesThePreferredAPIVersion() throws {
        // Given client has prod and dev versions in dev mode.
        let sut = createSUT(
            clientProdVersions: [.v0, .v1],
            clientDevVersions: [.v2],
            isDeveloperModeEnabled: true
        )

        // Given backend also has prod and dev versions.
        mockBackendInfo(
            productionVersions: 0...1,
            developmentVersions: 2...2,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // Given there is a preferred version.
        BackendInfo.preferredAPIVersion = .v2
        XCTAssertNil(BackendInfo.apiVersion)

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then it's the preferred version.
        XCTAssertEqual(BackendInfo.apiVersion, .v2)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    func testThatItDoesNotResolvePreferredAPIVersionIfNotInDevMode() throws {
        // Given client has prod and dev versions not in dev mode.
        let sut = createSUT(
            clientProdVersions: [.v0, .v1],
            clientDevVersions: [.v2],
            isDeveloperModeEnabled: false
        )

        // Given backend also has prod and dev versions.
        mockBackendInfo(
            productionVersions: 0...1,
            developmentVersions: 2...2,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // Given there is a preferred version.
        BackendInfo.preferredAPIVersion = .v2
        XCTAssertNil(BackendInfo.apiVersion)

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then it's the highest common prod version.
        XCTAssertEqual(BackendInfo.apiVersion, .v1)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    func testThatItDoesNotResolvePreferredAPIVersionIfNotSupportedByBackend() throws {
        // Given client has prod and dev versions in dev mode.
        let sut = createSUT(
            clientProdVersions: [.v0, .v1],
            clientDevVersions: [.v2],
            isDeveloperModeEnabled: true
        )

        // Given backend also has prod and dev versions.
        mockBackendInfo(
            productionVersions: 0...1,
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // Given there is a preferred version.
        BackendInfo.preferredAPIVersion = .v2
        XCTAssertNil(BackendInfo.apiVersion)

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then it's the highest common prod version.
        XCTAssertEqual(BackendInfo.apiVersion, .v1)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    // MARK: - Blacklist

    func testThatItReportsBlacklistReasonWhenBackendIsObsolete() throws {
        // Given version one was selected.
        setCurrentAPIVersion(.v1)

        // Given now we only support version 2.
        let sut = createSUT(
            clientProdVersions: [.v2],
            clientDevVersions: []
        )

        // Given backend doesn't support version 2
        mockBackendInfo(
            productionVersions: 0...1,
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // When version is resolved
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then no version could be resolved & blacklist reason is generated.
        XCTAssertNil(BackendInfo.apiVersion)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
        XCTAssertEqual(mockDelegate.blacklistReason, .backendAPIVersionObsolete)
    }

    func testThatItReportsBlacklistReasonWhenClientIsObsolete() throws {
        // Given version one was selected.
        setCurrentAPIVersion(.v1)

        // Given we still only support v1.
        let sut = createSUT(
            clientProdVersions: [.v1],
            clientDevVersions: []
        )

        // Given backend no longer supports v1.
        mockBackendInfo(
            productionVersions: 2...2,
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // When version is resolved
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then no version could be resolved & blacklist reason is generated.
        XCTAssertNil(BackendInfo.apiVersion)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
        XCTAssertEqual(mockDelegate.blacklistReason, .clientAPIVersionObsolete)
    }

    // MARK: - Federation

    func testThatItReportsToDelegate_WhenFederationHasBeenEnabled() throws {
        // Given client has prod versions.
        let sut = createSUT(
            clientProdVersions: Set(APIVersion.allCases),
            clientDevVersions: []
        )

        // Given federation is not enabled.
        BackendInfo.isFederationEnabled = false

        // Backend now has federation enabled.
        mockBackendInfo(
            productionVersions: 0...2,
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // When version is resolved.
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then federation is enabled and forwarded to delegate.
        XCTAssertTrue(BackendInfo.isFederationEnabled)
        XCTAssertTrue(mockDelegate.didReportFederationHasBeenEnabled)
    }

}

// MARK: - Mocks

private class MockAPIVersionResolverDelegate: APIVersionResolverDelegate {

    var blacklistReason: BlacklistReason?

    func apiVersionResolverFailedToResolveVersion(reason: BlacklistReason) {
        blacklistReason = reason
    }

    var didReportFederationHasBeenEnabled: Bool = false
    func apiVersionResolverDetectedFederationHasBeenEnabled() {
        didReportFederationHasBeenEnabled = true
    }
}
