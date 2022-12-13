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

class PatchApplicatorSyncEngineTest: DatabaseTest {

    var patchCountByVersion = [Int: Int]()
    let applicator = PatchApplicator<String>(lastRunVersionKey: "zm_PatchApplicatorSyncEngineLastRunPatchVersion")

    override func setUp() {
        super.setUp()
        self.setCurrentVersion(.none)
        patchCountByVersion = [:]
    }

    override func tearDown() {
        self.setCurrentVersion(.none)
        super.tearDown()
    }

    // MARK: - Helpers

    func setCurrentVersion(_ version: Int?) {
        self.syncMOC.performGroupedBlockAndWait {
            self.syncMOC.setPersistentStoreMetadata(version, key: self.applicator.lastRunVersionKey)
            self.syncMOC.saveOrRollback()
        }
    }

    var previousVersion: Int? {
        return syncMOC.persistentStoreMetadata(forKey: self.applicator.lastRunVersionKey) as? Int
    }

    func createTestPatches(forVersions versions: ClosedRange<Int>) -> [TestPatch] {
        return versions.map { version in
            TestPatch(version: version) { _ in
                self.patchCountByVersion[version, default: 0] += 1
            }
        }
    }

    // MARK: - Tests

    func testItAppliesNoPatchesWhenThereIsNoPreviousVersion() {
        syncMOC.performGroupedBlockAndWait {
            // Given no previous version
            self.setCurrentVersion(.none)

            // Given some patches
            TestPatch.allCases = self.createTestPatches(forVersions: 1...3)

            // When I apply some patches
            self.applicator.applyPatches(TestPatch.self, in: self.syncMOC)

            // Then no patches were run
            XCTAssertTrue(self.patchCountByVersion.isEmpty)

            // Then the current version is set as the previous version
            XCTAssertEqual(self.previousVersion, 3)
        }
    }

    func testThatItAppliesOnlyNecessaryPatches() {
        self.syncMOC.performGroupedBlockAndWait {
            // Given a previous version as 2
            self.setCurrentVersion(2)

            // Given some patches of various versions
            TestPatch.allCases = self.createTestPatches(forVersions: 1...5)

            // When I apply some patches
            self.applicator.applyPatches(TestPatch.self, in: self.syncMOC)

            // Then
            XCTAssertEqual(self.patchCountByVersion[1], nil)
            XCTAssertEqual(self.patchCountByVersion[2], nil)
            XCTAssertEqual(self.patchCountByVersion[3], 1)
            XCTAssertEqual(self.patchCountByVersion[4], 1)
            XCTAssertEqual(self.patchCountByVersion[5], 1)

            // Then the current version is set as the previous version
            XCTAssertEqual(self.previousVersion, 5)
        }
    }

    func testItAppliesFirstPatchSuccessfully() {
        self.syncMOC.performGroupedBlockAndWait {
            // Given no patches were run previously (previous version is 0)
            self.setCurrentVersion(0)

            // Given there exist a patch not yet run
            TestPatch.allCases = self.createTestPatches(forVersions: 1...1)

            // When I run all patches
            self.applicator.applyPatches(TestPatch.self, in: self.syncMOC)

            // Then the patch was executed
            XCTAssertEqual(self.patchCountByVersion[1], 1)

            // Then previous version is 1t
            XCTAssertEqual(self.previousVersion, 1)
        }
    }

    func testItOnlyAppliesPatchesOnce() {
        self.syncMOC.performGroupedBlockAndWait {
            // Given no patches were run previously (previous version is 0)
            self.setCurrentVersion(0)

            // Given there exist a patch not yet run
            TestPatch.allCases = self.createTestPatches(forVersions: 1...1)

            // When I run all patches
            self.applicator.applyPatches(TestPatch.self, in: self.syncMOC)

            // Then the patch was executed
            XCTAssertEqual(self.patchCountByVersion[1], 1)

            // Then previous version is 1
            XCTAssertEqual(self.previousVersion, 1)

            // When I run the patches again
            self.applicator.applyPatches(TestPatch.self, in: self.syncMOC)

            // Then the patch was not executed again
            XCTAssertEqual(self.patchCountByVersion[1], 1)

            // Then previous version is still 1
            XCTAssertEqual(self.previousVersion, 1)
        }
    }
}

struct TestPatch: DataPatchInterface {

    static var allCases = [TestPatch]()

    var version: Int
    let block: (NSManagedObjectContext) -> Void

    func execute(in context: NSManagedObjectContext) {
        return block(context)
    }

}
