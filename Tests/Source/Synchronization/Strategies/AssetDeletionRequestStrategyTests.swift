//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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
import WireDataModel

class AssetDeletionRequestStrategyTests: MessagingTest {

    private var sut: AssetDeletionRequestStrategy!
    private var mockApplicationStatus: MockApplicationStatus!
    fileprivate var mockIdentifierProvider: MockIdentifierProvider!

    override func setUp() {
        super.setUp()
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .online
        mockIdentifierProvider = MockIdentifierProvider()
        sut = AssetDeletionRequestStrategy(
            context: syncMOC,
            applicationStatus: mockApplicationStatus,
            identifierProvider: mockIdentifierProvider
        )
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }

    override func tearDown() {
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        mockApplicationStatus = nil
        mockIdentifierProvider = nil
        sut = nil
        super.tearDown()
    }

    func testThatItCreatesNoRequestWhenThereIsNoIdentifier() {
        // When
        let request = sut.nextRequest(for: .v0)

        // Then
        XCTAssertNil(request)
    }

    func testThatItCreatesARequestIfThereIsAnIdentifier_V0() {
        testThatItCreatesARequestIfThereIsAnIdentifier(for: .v0)
    }

    func testThatItCreatesARequestIfThereIsAnIdentifier_V1() {
        testThatItCreatesARequestIfThereIsAnIdentifier(for: .v1)
    }

    func testThatItCreatesARequestIfThereIsAnIdentifier_V2() {
        testThatItCreatesARequestIfThereIsAnIdentifier(for: .v2)
    }

    func testThatItCallsDidDeleteIdentifierOnSuccess() {
        // Given
        let identifier = UUID.create().transportString()
        mockIdentifierProvider.nextIdentifier = identifier
        guard let request = sut.nextRequest(for: .v0) else { return XCTFail("No request created") }

        // When
        let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil, apiVersion: APIVersion.v0.rawValue)
        request.complete(with: response)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // Then
        XCTAssertEqual(mockIdentifierProvider.deletedIdentifiers.count, 1)
        XCTAssertEqual(mockIdentifierProvider.deletedIdentifiers.first, identifier)
        XCTAssert(mockIdentifierProvider.failedToDeleteIdentifiers.isEmpty)
    }

    func testThatItCallsDidFailToDeleteIdentifierOnPermamentError() {
        // Given
        let identifier = UUID.create().transportString()
        mockIdentifierProvider.nextIdentifier = identifier
        guard let request = sut.nextRequest(for: .v0) else { return XCTFail("No request created") }

        // When
        let response = ZMTransportResponse(payload: nil, httpStatus: 403, transportSessionError: nil, apiVersion: APIVersion.v0.rawValue)
        request.complete(with: response)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // Then
        XCTAssertEqual(mockIdentifierProvider.failedToDeleteIdentifiers.count, 1)
        XCTAssertEqual(mockIdentifierProvider.failedToDeleteIdentifiers.first, identifier)
        XCTAssert(mockIdentifierProvider.deletedIdentifiers.isEmpty)
    }

}

// MARK: Helper Method

extension AssetDeletionRequestStrategyTests {
    func testThatItCreatesARequestIfThereIsAnIdentifier(for apiVersion: APIVersion) {
        // Given
        let domain = "example.domain.com"
        BackendInfo.domain = domain
        let identifier = UUID.create().transportString()
        mockIdentifierProvider.nextIdentifier = identifier

        // When
        let request = sut.nextRequest(for: apiVersion)

        // Then
        let expectedPath: String
        switch apiVersion {
        case .v0:
            expectedPath = "/assets/v3/\(identifier)"
        case .v1:
            expectedPath = "/v1/assets/v3/\(identifier)"
        case .v2, .v3:
            expectedPath = "/v\(apiVersion.rawValue)/assets/\(domain)/\(identifier)"
        }
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.method, .methodDELETE)
        XCTAssertEqual(request?.path, expectedPath)
        XCTAssertNil(request?.payload)
    }
}

// MARK: - Helper

private class MockIdentifierProvider: AssetDeletionIdentifierProviderType {

    var nextIdentifier: String?
    var deletedIdentifiers = [String]()
    var failedToDeleteIdentifiers = [String]()

    func nextIdentifierToDelete() -> String? {
        return nextIdentifier
    }

    func didDelete(identifier: String) {
        deletedIdentifiers.append(identifier)
    }

    func didFailToDelete(identifier: String) {
        failedToDeleteIdentifiers.append(identifier)
    }

}
