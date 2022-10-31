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

    private var sut: APIVersionResolver!
    private var transportSession: MockTransportSession!
    private var mockDelegate: MockAPIVersionResolverDelegate!

    override func setUp() {
        mockDelegate = .init()
        transportSession = MockTransportSession(dispatchGroup: dispatchGroup)
        sut = APIVersionResolver(transportSession: transportSession)
        sut.delegate = mockDelegate
        setCurrentAPIVersion(nil)
        super.setUp()
    }

    override func tearDown() {
        mockDelegate = nil
        transportSession = nil
        sut = nil
        setCurrentAPIVersion(nil)
        super.tearDown()
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

    // MARK: - Tests

    func testThatItResolvesTheAPIVersion() throws {
        // Given
        let supportedDevelopmentAPIVersion = try XCTUnwrap(APIVersion.allCases.max())
        let maxSupportedAPIVersion = try XCTUnwrap(APIVersion.allCases.dropLast().max())

        mockBackendInfo(
            productionVersions: 0...(maxSupportedAPIVersion.rawValue),
            developmentVersions: (supportedDevelopmentAPIVersion.rawValue)...(supportedDevelopmentAPIVersion.rawValue),
            domain: "foo.com",
            isFederationEnabled: true
        )

        XCTAssertNil(BackendInfo.apiVersion)

        // When
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then
        XCTAssertEqual(BackendInfo.apiVersion, maxSupportedAPIVersion)
        XCTAssertEqual(APIVersion.developmentVersions, [supportedDevelopmentAPIVersion])
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    func testThatItResolvesTheAPIVersionWhenDevelopmentVersionsAreAbsent() throws {
        // Given
        let maxSupportedAPIVersion = try XCTUnwrap(APIVersion.allCases.max())

        mockBackendInfo(
            productionVersions: 0...(maxSupportedAPIVersion.rawValue),
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        XCTAssertNil(BackendInfo.apiVersion)

        // When
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then
        XCTAssertEqual(BackendInfo.apiVersion, maxSupportedAPIVersion)
        XCTAssertTrue(APIVersion.developmentVersions.isEmpty)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
    }

    func testThatItDefaultsToVersionZeroIfEndpointIsUnavailable() throws {
        // Given
        transportSession.isAPIVersionEndpointAvailable = false

        // When
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then
        let resolvedVersion = try XCTUnwrap(BackendInfo.apiVersion)
        XCTAssertEqual(resolvedVersion, .v0)
        XCTAssertEqual(BackendInfo.domain, "wire.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, false)
    }

    func testThatItReportsBlacklistReasonWhenBackendIsObsolete() throws {
        // Given
        setCurrentAPIVersion(.v0)

        let minSupportedAPIVersion = try XCTUnwrap(APIVersion.allCases.min())

        mockBackendInfo(
            productionVersions: (minSupportedAPIVersion.rawValue - 3)...(minSupportedAPIVersion.rawValue - 1),
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // When
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then
        XCTAssertNil(BackendInfo.apiVersion)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
        XCTAssertEqual(mockDelegate.blacklistReason, .backendAPIVersionObsolete)

    }

    func testThatItReportsBlacklistReasonWhenClientIsObsolete() throws {
        // Given
        setCurrentAPIVersion(.v0)

        let maxSupportedAPIVersion = try XCTUnwrap(APIVersion.allCases.max())

        mockBackendInfo(
            productionVersions: (maxSupportedAPIVersion.rawValue + 1)...(maxSupportedAPIVersion.rawValue + 3),
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // When
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then
        XCTAssertNil(BackendInfo.apiVersion)
        XCTAssertEqual(BackendInfo.domain, "foo.com")
        XCTAssertEqual(BackendInfo.isFederationEnabled, true)
        XCTAssertEqual(mockDelegate.blacklistReason, .clientAPIVersionObsolete)
    }

    func testThatItReportsToDelegate_WhenFederationHasBeenEnabled() throws {
        // Given
        BackendInfo.isFederationEnabled = false
        let maxSupportedAPIVersion = try XCTUnwrap(APIVersion.allCases.max())

        mockBackendInfo(
            productionVersions: 0...(maxSupportedAPIVersion.rawValue),
            developmentVersions: nil,
            domain: "foo.com",
            isFederationEnabled: true
        )

        // When
        let done = expectation(description: "done")
        sut.resolveAPIVersion(completion: done.fulfill)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

        // Then
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
