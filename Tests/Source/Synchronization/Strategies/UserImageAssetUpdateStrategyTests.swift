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
import XCTest
@testable import WireSyncEngine

typealias ProfileImageSize = WireSyncEngine.ProfileImageSize

class MockImageUpdateStatus: WireSyncEngine.UserProfileImageUploadStatusProtocol {
    var allSizes: [ProfileImageSize] { return [.preview, .complete] }
    
    var assetIdsToDelete = Set<String>()
    func hasAssetToDelete() -> Bool {
        return !assetIdsToDelete.isEmpty
    }
    func consumeAssetToDelete() -> String? {
        return assetIdsToDelete.removeFirst()
    }
    
    var dataToConsume = [ProfileImageSize : Data]()
    func consumeImage(for size: ProfileImageSize) -> Data? {
        return dataToConsume[size]
    }
    func hasImageToUpload(for size: ProfileImageSize) -> Bool {
        return dataToConsume[size] != nil
    }
    
    var uploadDoneForSize: ProfileImageSize?
    var uploadDoneWithAssetId: String?
    func uploadingDone(imageSize: ProfileImageSize, assetId: String) {
        uploadDoneForSize = imageSize
        uploadDoneWithAssetId = assetId
    }
    
    var uploadFailedForSize: ProfileImageSize?
    var uploadFailedWithError: Error?
    func uploadingFailed(imageSize: ProfileImageSize, error: Error) {
        uploadFailedForSize = imageSize
        uploadFailedWithError = error
    }
}

class UserImageAssetUpdateStrategyTests : MessagingTest {
    
    var sut: WireSyncEngine.UserImageAssetUpdateStrategy!
    var mockApplicationStatus : MockApplicationStatus!
    var updateStatus: MockImageUpdateStatus!
    
    override func setUp() {
        super.setUp()
        self.mockApplicationStatus = MockApplicationStatus()
        self.mockApplicationStatus.mockSynchronizationState = .online
        self.updateStatus = MockImageUpdateStatus()
        
        sut = UserImageAssetUpdateStrategy(managedObjectContext: syncMOC,
                                           applicationStatus: mockApplicationStatus,
                                           imageUploadStatus: updateStatus)
        
        self.syncMOC.zm_userImageCache = UserImageLocalCache(location: nil)
        self.uiMOC.zm_userImageCache = self.syncMOC.zm_userImageCache
    }
    
    override func tearDown() {
        self.mockApplicationStatus = nil
        self.updateStatus = nil
        self.sut = nil
        self.syncMOC.zm_userImageCache = nil
        super.tearDown()
    }
}

// MARK: - Profile image upload
extension UserImageAssetUpdateStrategyTests {

    func testThatItDoesNotReturnARequestWhenThereIsNoImageToUpload() {
        // WHEN
        updateStatus.dataToConsume.removeAll()
        
        // THEN
        XCTAssertNil(sut.nextRequest())
    }
    
    func testThatItDoesNotReturnARequestWhenUserIsNotLoggedIn() {
        // WHEN
        updateStatus.dataToConsume[.preview] = Data()
        updateStatus.dataToConsume[.complete] = Data()
        mockApplicationStatus.mockSynchronizationState = .unauthenticated
        
        // THEN
        XCTAssertNil(sut.nextRequest())
    }
    
    func testThatItCreatesRequestSyncs() {
        XCTAssertNotNil(sut.upstreamRequestSyncs[.preview])
        XCTAssertNotNil(sut.upstreamRequestSyncs[.complete])
    }

    func testThatItReturnsCorrectSizeFromRequestSync() {
        // WHEN
        let previewSync = sut.upstreamRequestSyncs[.preview]!
        let completeSync = sut.upstreamRequestSyncs[.complete]!
        
        // THEN
        XCTAssertEqual(sut.size(for: previewSync), .preview)
        XCTAssertEqual(sut.size(for: completeSync), .complete)
    }
    
    func testThatItCreatesRequestWhenThereIsData() {
        // WHEN
        updateStatus.dataToConsume.removeAll()
        updateStatus.dataToConsume[.preview] = "Some".data(using: .utf8)
        
        // THEN
        let previewRequest = sut.nextRequest()
        XCTAssertNotNil(previewRequest)
        XCTAssertEqual(previewRequest?.path, "/assets/v3")
        XCTAssertEqual(previewRequest?.method, .methodPOST)

        
        // WHEN
        updateStatus.dataToConsume.removeAll()
        updateStatus.dataToConsume[.complete] = "Other".data(using: .utf8)
        
        // THEN
        let completeRequest = sut.nextRequest()
        XCTAssertNotNil(completeRequest)
        XCTAssertEqual(completeRequest?.path, "/assets/v3")
        XCTAssertEqual(completeRequest?.method, .methodPOST)

    }
    
    func testThatItCreatesRequestWithExpectedData() {
        // GIVEN
        let previewData = "--1--".data(using: .utf8)
        let previewRequest = sut.requestFactory.upstreamRequestForAsset(withData: previewData!, shareable: true, retention: .eternal)
        let completeData = "1111111".data(using: .utf8)
        let completeRequest = sut.requestFactory.upstreamRequestForAsset(withData: completeData!, shareable: true, retention: .eternal)
        
        // WHEN
        updateStatus.dataToConsume.removeAll()
        updateStatus.dataToConsume[.preview] = previewData

        // THEN
        XCTAssertEqual(sut.nextRequest()?.binaryData, previewRequest?.binaryData)
        
        // WHEN
        updateStatus.dataToConsume.removeAll()
        updateStatus.dataToConsume[.complete] = completeData
        
        // THEN
        XCTAssertEqual(sut.nextRequest()?.binaryData, completeRequest?.binaryData)
    }
    
    func testThatItCreatesDeleteRequestIfThereAreAssetsToDelete() {
        // GIVEN
        let assetId = "12344"
        let deleteRequest = ZMTransportRequest(path: "/assets/v3/\(assetId)", method: .methodDELETE, payload: nil)
        
        // WHEN
        updateStatus.assetIdsToDelete = [assetId]

        // THEN
        XCTAssertEqual(sut.nextRequest(), deleteRequest)
        XCTAssert(updateStatus.assetIdsToDelete.isEmpty)
    }

    func testThatUploadMarkedAsFailedOnUnsuccessfulResponse() {
        // GIVEN
        let size = ProfileImageSize.preview
        let sync = sut.upstreamRequestSyncs[size]
        let failedResponse = ZMTransportResponse(payload: nil, httpStatus: 500, transportSessionError: nil)
        
        // WHEN
        sut.didReceive(failedResponse, forSingleRequest: sync!)
        
        // THEN
        XCTAssertEqual(updateStatus.uploadFailedForSize, size)
    }
    
    func testThatUploadIsMarkedAsDoneAfterSuccessfulResponse() {
        // GIVEN
        let size = ProfileImageSize.preview
        let sync = sut.upstreamRequestSyncs[size]
        let assetId = "123123"
        let payload: [String : String] = ["key" : assetId]
        let successResponse = ZMTransportResponse(payload: payload as NSDictionary, httpStatus: 200, transportSessionError: nil)
        
        // WHEN
        sut.didReceive(successResponse, forSingleRequest: sync!)

        // THEN
        XCTAssertEqual(updateStatus.uploadDoneForSize, size)
        XCTAssertEqual(updateStatus.uploadDoneWithAssetId, assetId)

    }
    
}

// MARK: - Profile image download
extension UserImageAssetUpdateStrategyTests {

    func testThatItCreatesDownstreamRequestSyncs() {
        XCTAssertNotNil(sut.downstreamRequestSyncs[.preview])
        XCTAssertNotNil(sut.downstreamRequestSyncs[.complete])
    }
    
    func testThatItReturnsCorrectSizeFromDownstreamRequestSync() {
        // WHEN
        let previewSync = sut.downstreamRequestSyncs[.preview]!
        let completeSync = sut.downstreamRequestSyncs[.complete]!
        
        // THEN
        XCTAssertEqual(sut.size(for: previewSync), .preview)
        XCTAssertEqual(sut.size(for: completeSync), .complete)
    }

    
    func testThatItWhitelistsUserOnPreviewSyncForPreviewImageNotification() {
        // GIVEN
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        user.previewProfileAssetIdentifier = "fooo"
        let sync = self.sut.downstreamRequestSyncs[.preview]!
        XCTAssertFalse(sync.hasOutstandingItems)
        syncMOC.saveOrRollback()
        
        // WHEN
        uiMOC.performGroupedBlock {
            (self.uiMOC.object(with: user.objectID) as? ZMUser)?.requestPreviewProfileImage()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertTrue(sync.hasOutstandingItems)
    }
    
    func testThatItWhitelistsUserOnPreviewSyncForCompleteImageNotification() {
        // GIVEN
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        user.completeProfileAssetIdentifier = "fooo"
        let sync = self.sut.downstreamRequestSyncs[.complete]!
        XCTAssertFalse(sync.hasOutstandingItems)
        syncMOC.saveOrRollback()
        
        // WHEN
        uiMOC.performGroupedBlock {
            (self.uiMOC.object(with: user.objectID) as? ZMUser)?.requestCompleteProfileImage()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertTrue(sync.hasOutstandingItems)
    }
    
    func testThatItCreatesRequestForCorrectAssetIdentifierForPreviewImage() {
        // GIVEN
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        let assetId = "foo-bar"
        user.previewProfileAssetIdentifier = assetId
        syncMOC.saveOrRollback()
        
        // WHEN
        uiMOC.performGroupedBlock {
            (self.uiMOC.object(with: user.objectID) as? ZMUser)?.requestPreviewProfileImage()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        let request = self.sut.downstreamRequestSyncs[.preview]?.nextRequest()
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/assets/v3/\(assetId)")
        XCTAssertEqual(request?.method, .methodGET)
    }
    
    func testThatItCreatesRequestForCorrectAssetIdentifierForCompleteImage() {
        // GIVEN
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        let assetId = "foo-bar"
        user.completeProfileAssetIdentifier = assetId
        syncMOC.saveOrRollback()
        
        // WHEN
        uiMOC.performGroupedBlock {
            (self.uiMOC.object(with: user.objectID) as? ZMUser)?.requestCompleteProfileImage()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        let request = self.sut.downstreamRequestSyncs[.complete]?.nextRequest()
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/assets/v3/\(assetId)")
        XCTAssertEqual(request?.method, .methodGET)
    }
    
    func testThatItUpdatesCorrectUserImageDataForPreviewImage() {
        // GIVEN
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        let imageData = "image".data(using: .utf8)!
        let sync = self.sut.downstreamRequestSyncs[.preview]!
        user.previewProfileAssetIdentifier = "foo"
        let response = ZMTransportResponse(imageData: imageData, httpStatus: 200, transportSessionError: nil, headers: nil)
        
        // WHEN
        self.sut.update(user, with: response, downstreamSync: sync)
        
        // THEN
        XCTAssertEqual(user.imageSmallProfileData, imageData)
    }
    
    func testThatItUpdatesCorrectUserImageDataForCompleteImage() {
        // GIVEN
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        let imageData = "image".data(using: .utf8)!
        let sync = self.sut.downstreamRequestSyncs[.complete]!
        user.completeProfileAssetIdentifier = "foo"
        let response = ZMTransportResponse(imageData: imageData, httpStatus: 200, transportSessionError: nil, headers: nil)
        
        // WHEN
        self.sut.update(user, with: response, downstreamSync: sync)
        
        // THEN
        XCTAssertEqual(user.imageMediumData, imageData)
    }
    
    func testThatItDeletesPreviewProfileAssetIdentifierWhenReceivingAPermanentErrorForPreviewImage() {
        // Given
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        let assetId = UUID.create().transportString()
        user.previewProfileAssetIdentifier = assetId
        syncMOC.saveOrRollback()
        
        // When
        uiMOC.performGroupedBlock {
            (self.uiMOC.object(with: user.objectID) as? ZMUser)?.requestPreviewProfileImage()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        guard let request = sut.nextRequestIfAllowed() else { return XCTFail("nil request generated") }
        XCTAssertEqual(request.path, "/assets/v3/\(assetId)")
        XCTAssertEqual(request.method, .methodGET)
        
        // Given
        let response = ZMTransportResponse(payload: nil, httpStatus: 404, transportSessionError: nil)
        request.complete(with: response)
        
        // THEN
        user.requestPreviewProfileImage()
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNil(user.previewProfileAssetIdentifier)
        XCTAssertNil(sut.nextRequestIfAllowed())
    }
    
    func testThatItDeletesCompleteProfileAssetIdentifierWhenReceivingAPermanentErrorForCompleteImage() {
        // Given
        let user = ZMUser.fetchOrCreate(with: UUID.create(), domain: nil, in: self.syncMOC)
        let assetId = UUID.create().transportString()
        user.completeProfileAssetIdentifier = assetId
        syncMOC.saveOrRollback()
        
        // When
        uiMOC.performGroupedBlock {
            (self.uiMOC.object(with: user.objectID) as? ZMUser)?.requestCompleteProfileImage()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        guard let request = sut.nextRequestIfAllowed() else { return XCTFail("nil request generated") }
        XCTAssertEqual(request.path, "/assets/v3/\(assetId)")
        XCTAssertEqual(request.method, .methodGET)
        
        // Given
        let response = ZMTransportResponse(payload: nil, httpStatus: 404, transportSessionError: nil)
        request.complete(with: response)
        
        // THEN
        user.requestCompleteProfileImage()
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNil(user.completeProfileAssetIdentifier)
        XCTAssertNil(sut.nextRequestIfAllowed())
    }

}
