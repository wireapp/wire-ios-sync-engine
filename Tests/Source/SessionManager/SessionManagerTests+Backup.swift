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

import XCTest
import WireTesting
@testable import WireSyncEngine

class SessionManagerTests_Backup: IntegrationTest {
    
    override var useInMemoryStore: Bool {
        return false
    }
    
    private var backupURL: URL!
    private var unzippedURL: URL!
    
    override func setUp() {
        super.setUp()
        createSelfUserAndConversation()
        createExtraUsersAndConversations()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        backupURL = directory.appendingPathComponent("BackupTests")
        unzippedURL = directory.appendingPathComponent("BackupTests_Unzipped")
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: unzippedURL)
        backupURL = nil
        unzippedURL = nil
        super.tearDown()
    }
    
    @discardableResult private func createSelfClient() -> UserClient? {
        var client: UserClient?
        let identifier = name!
        guard let context = sessionManager?.activeUserSession?.managedObjectContext else { return nil }
        context.performGroupedBlockAndWait {
            client = UserClient.insertNewObject(in: context)
            client?.remoteIdentifier = identifier
            client?.user = ZMUser.selfUser(in: context)
            context.saveOrRollback()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        context.setPersistentStoreMetadata(identifier, key: "PersistedClientId")
        return client
    }
    
    func testThatItReturnsAnErrorWhenThereIsNoSelectedAccount() {
        XCTAssertEqual(backupActiveAcount().error as? SessionManager.BackupError, .noActiveAccount)
    }
    
    func testThatItCreatesABackupIncludingMetadataAndZipsIt() throws {
        // Given
        XCTAssert(login())
        prefetchClientByInsertingMessage(in: selfToUser1Conversation)
        
        mockTransportSession.performRemoteChanges {
            $0.registerClient(for: self.selfUser, label: self.name!, type: "permanent")
        }
        
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.2))
        
        // When
        let result = backupActiveAcount()
        guard let url = result.value else { return XCTFail("\(result.error!)") }
        guard url.unzip(to: unzippedURL) else { return XCTFail("Decompression failed") }
        
        // Then
        XCTAssertEqual(url.pathExtension, "wireiosbackup")
        let dataURL = unzippedURL.appendingPathComponent("data")
        let metadataURL = unzippedURL.appendingPathComponent("export.json")
        let metadata = try BackupMetadata(url: metadataURL)
        
        XCTAssertEqual(metadata.platform, .iOS)
        XCTAssertEqual(metadata.appVersion, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(metadata.userIdentifier, sessionManager?.accountManager.selectedAccount?.userIdentifier)
        XCTAssert(FileManager.default.fileExists(atPath: dataURL.path))
    }
    
    private func backupActiveAcount(file: StaticString = #file, line: UInt = #line) -> Result<URL> {
        var result: Result<URL> = .failure(TestError.uninitialized)
        sessionManager?.backupActiveAccount { result = $0 }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5), file: file, line: line)
        return result
    }
    
}

private enum TestError: Error {
    case uninitialized
}
