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
import WireMockTransport

class UserProfileImageV3Tests: IntegrationTestBase {
    
    func checkProfileImagesMatch(local: ZMUser, remote: MockUser, file: StaticString = #file, line: UInt = #line) {
        XCTAssertNotNil(remote.completeProfileAssetIdentifier, "Complete assetId should bet set on remote user", file: file, line: line)
        XCTAssertNotNil(remote.previewProfileAssetIdentifier, "Preview assetId should bet set on remote user", file: file, line: line)
        XCTAssertNotNil(local.completeProfileAssetIdentifier, "Complete assetId should bet set on local user", file: file, line: line)
        XCTAssertNotNil(local.previewProfileAssetIdentifier, "Preview assetId should bet set on local user", file: file, line: line)

        guard let previewId = remote.previewProfileAssetIdentifier, let completeId = remote.completeProfileAssetIdentifier else { return }
        let previewAsset = MockAsset(in: mockTransportSession.managedObjectContext, forID: previewId)
        let completeAsset = MockAsset(in: mockTransportSession.managedObjectContext, forID: completeId)
        checkProfileImagesMatch(local: local, previewAsset: previewAsset, completeAsset: completeAsset, file: file, line: line)
    }
    
    func checkProfileImagesMatch(local: ZMUser, previewAsset: MockAsset?, completeAsset: MockAsset?, file: StaticString = #file, line: UInt = #line) {
        XCTAssertNotNil(completeAsset, "Complete asset should exist on server", file: file, line: line)
        XCTAssertNotNil(previewAsset, "Complete asset should exist on server", file: file, line: line)
        
        XCTAssertEqual(local.previewProfileAssetIdentifier, previewAsset?.identifier, "Preview assetId should match remote assetId", file: file, line: line)
        XCTAssertEqual(local.completeProfileAssetIdentifier, completeAsset?.identifier, "Complete assetId should match remote assetId", file: file, line: line)
        XCTAssertEqual(local.imageMediumData, completeAsset?.data, "Complete asset should match remote data", file: file, line: line)
        XCTAssertEqual(local.imageSmallProfileData, previewAsset?.data, "Preview asset should match remote data", file: file, line: line)
    }
    
    func testThatSelfUserImagesAreUploadedAfterLoginIfThereWereOnlyV2() {
        // GIVEN
        mockTransportSession.performRemoteChanges { session in
            self.selfUser.completeProfileAssetIdentifier = nil
            self.selfUser.previewProfileAssetIdentifier = nil
        }
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())
        
        // THEN
        checkProfileImagesMatch(local: ZMUser.selfUser(inUserSession: userSession)!, remote: selfUser)
    }
    
    func testThatSelfUserImagesAreUploadedWhenThereAreNone() {
        // GIVEN
        mockTransportSession.performRemoteChanges { session in
            self.selfUser.pictures = []
            self.selfUser.previewProfileAssetIdentifier = nil
            self.selfUser.completeProfileAssetIdentifier = nil
        }
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())

        // WHEN
        userSession.performChanges {
            self.userSession.profileUpdate.updateImage(imageData: self.mediumJPEGData())
        }
        XCTAssertTrue(waitForEverythingToBeDone(withTimeout: 0.5))

        // THEN
        checkProfileImagesMatch(local: ZMUser.selfUser(inUserSession: userSession)!, remote: selfUser)
    }
    
    func testThatSelfUserImagesAreChanged() {
        // GIVEN
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())
        
        // WHEN
        userSession.performChanges {
            self.userSession.profileUpdate.updateImage(imageData: self.mediumJPEGData())
        }
        XCTAssertTrue(waitForEverythingToBeDone(withTimeout: 0.5))
        
        // THEN
        checkProfileImagesMatch(local: ZMUser.selfUser(inUserSession: userSession)!, remote: selfUser)
    }

    func testThatSelfUserImagesAreDownloadedIfAddedRemotely() {
        // GIVEN
        mockTransportSession.performRemoteChanges { session in
            self.selfUser.pictures = []
            session.addV3ProfilePicture(to: self.selfUser)
        }
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())
        
        // THEN
        checkProfileImagesMatch(local: ZMUser.selfUser(inUserSession: userSession)!, remote: selfUser)
    }

    func testThatSelfUserImagesAreDownloadedIfChangedRemotely() {
        // GIVEN
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())

        // WHEN
        var assets: [String : MockAsset]?
        mockTransportSession.performRemoteChanges { session in
            assets = session.addV3ProfilePicture(to: self.selfUser)
        }
        XCTAssertTrue(waitForEverythingToBeDone(withTimeout: 0.5))
        
        // THEN
        let localUser = ZMUser.selfUser(inUserSession: userSession)!
        let completeAsset = assets?["complete"]
        let previewAsset = assets?["preview"]
        checkProfileImagesMatch(local: localUser, previewAsset: previewAsset, completeAsset: completeAsset)
    }

}

