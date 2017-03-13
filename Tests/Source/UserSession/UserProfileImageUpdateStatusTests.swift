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

import XCTest
@testable import zmessaging
import ZMUtilities

var sampleUploadState: UserProfileImageUpdateStatus.ImageState {
    return UserProfileImageUpdateStatus.ImageState.upload(image: Data())
}
var sampleUploadedState: UserProfileImageUpdateStatus.ImageState {
    return UserProfileImageUpdateStatus.ImageState.uploaded(assetId: "foo")
}
var sampleFailedImageState: UserProfileImageUpdateStatus.ImageState {
    return UserProfileImageUpdateStatus.ImageState.failed(.preprocessingFailed)
}

var samplePreprocessState: UserProfileImageUpdateStatus.ProfileUpdateState {
    return UserProfileImageUpdateStatus.ProfileUpdateState.preprocess(image: Data(), size: .zero)
}
var sampleUpdateState: UserProfileImageUpdateStatus.ProfileUpdateState {
    return UserProfileImageUpdateStatus.ProfileUpdateState.update(previewAssetId: "id1", completeAssetId: "id2")
}
var sampleFailedState: UserProfileImageUpdateStatus.ProfileUpdateState {
    return UserProfileImageUpdateStatus.ProfileUpdateState.failed(.preprocessingFailed)
}

class MockPreprocessor: NSObject, ZMAssetsPreprocessorProtocol {
    weak var delegate: ZMAssetsPreprocessorDelegate? = nil
    var operations = [Operation]()

    var imageOwner: ZMImageOwner? = nil
    var operationsCalled: Bool = false
    
    func operations(forPreprocessingImageOwner imageOwner: ZMImageOwner) -> [Operation]? {
        operationsCalled = true
        self.imageOwner = imageOwner
        return operations
    }
}

class MockOperation: NSObject, ZMImageDownsampleOperationProtocol {
    let downsampleImageData: Data
    let format: ZMImageFormat
    let properties : ZMIImageProperties
    
    init(downsampleImageData: Data = Data(), format: ZMImageFormat = .original, properties: ZMIImageProperties = ZMIImageProperties(size: .zero, length: 0, mimeType: "foo")) {
        self.downsampleImageData = downsampleImageData
        self.format = format
        self.properties = properties
    }
}

class MockImageOwner: NSObject, ZMImageOwner {
    public func requiredImageFormats() -> NSOrderedSet! { return NSOrderedSet() }
    public func imageData(for format: ZMImageFormat) -> Data! { return Data() }
    public func setImageData(_ imageData: Data!, for format: ZMImageFormat, properties: ZMIImageProperties!) {}
    public func originalImageData() -> Data! { return Data() }
    public func originalImageSize() -> CGSize { return .zero }
    public func isInline(for format: ZMImageFormat) -> Bool { return false }
    public func isPublic(for format: ZMImageFormat) -> Bool { return false }
    public func isUsingNativePush(for format: ZMImageFormat) -> Bool { return false }
    public func processingDidFinish() {}
}

protocol StateTransition: Equatable {
    func canTransition(to: Self) -> Bool
    static var allStates: [Self] { get }
}

extension StateTransition {
    func checkThatTransition(to newState: Self, isValid: Bool, file: StaticString = #file, line: UInt = #line) {
        let result = self.canTransition(to: newState)
        if isValid {
            XCTAssertTrue(result, "Should transition: [\(self)] -> [\(newState)]", file: file, line: line)
        } else {
            XCTAssertFalse(result, "Should not transition: [\(self)] -> [\(newState)]", file: file, line: line)
        }
    }
    
    static func canTransition(from oldState: Self, onlyTo newStates: [Self], file: StaticString = #file, line: UInt = #line) {
        for state in Self.allStates {
            let isValid = newStates.contains(state)
            oldState.checkThatTransition(to: state, isValid: isValid, file: file, line: line)
        }
    }
}

extension UserProfileImageUpdateStatus.ImageState: Equatable {
    public static func ==(lhs: UserProfileImageUpdateStatus.ImageState, rhs: UserProfileImageUpdateStatus.ImageState) -> Bool {
        return String(describing: lhs) == String(describing: rhs)
    }
}

extension UserProfileImageUpdateStatus.ImageState: StateTransition {
    static var allStates: [UserProfileImageUpdateStatus.ImageState] {
        return [.ready, .preprocessing, sampleUploadState, .uploading, sampleUploadedState, .completed, sampleFailedImageState]
    }
}

extension UserProfileImageUpdateStatus.ProfileUpdateState: Equatable {
    public static func ==(lhs: UserProfileImageUpdateStatus.ProfileUpdateState, rhs: UserProfileImageUpdateStatus.ProfileUpdateState) -> Bool {
        return String(describing: lhs) == String(describing: rhs)
    }
}

extension UserProfileImageUpdateStatus.ProfileUpdateState: StateTransition {
    static var allStates: [UserProfileImageUpdateStatus.ProfileUpdateState] {
        return [.ready, samplePreprocessState, sampleUpdateState, .updating, .completed, sampleFailedState]
    }
}

typealias ProfileUpdateState = UserProfileImageUpdateStatus.ProfileUpdateState
typealias ImageState = UserProfileImageUpdateStatus.ImageState

class UserProfileImageUpdateStatusTests: MessagingTest {
    var sut : UserProfileImageUpdateStatus!
    var preprocessor : MockPreprocessor!
    var tinyImage: Data!
    var imageOwner: ZMImageOwner!
    
    override func setUp() {
        super.setUp()
        preprocessor = MockPreprocessor()
        preprocessor.operations = [Operation()]
        sut = UserProfileImageUpdateStatus(preprocessor: preprocessor)
        tinyImage = data(forResource: "tiny", extension: "jpg")
        imageOwner = UserProfileImageOwner(imageData: tinyImage, size: .zero)
    }
    
    func operationWithExpectation(description: String) -> Operation {
        let expectation = self.expectation(description: description)
        return BlockOperation {
            expectation.fulfill()
        }
    }
}

// MARK: Image state transitions
extension UserProfileImageUpdateStatusTests {
    func testThatImageStateStartsWithReadyState() {
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)
    }
    
    func testImageStateTransitions() {
        ImageState.canTransition(from: .ready, onlyTo: [sampleFailedImageState, .preprocessing])
        ImageState.canTransition(from: .preprocessing, onlyTo: [sampleFailedImageState, sampleUploadState])
        ImageState.canTransition(from: sampleUploadState, onlyTo: [sampleFailedImageState, .uploading])
        ImageState.canTransition(from: .uploading, onlyTo: [sampleFailedImageState, sampleUploadedState])
        ImageState.canTransition(from: sampleUploadedState, onlyTo: [sampleFailedImageState, .completed])
        ImageState.canTransition(from: .completed, onlyTo: [sampleFailedImageState, .ready])
        ImageState.canTransition(from: sampleFailedImageState, onlyTo: [.ready])
    }
    
    func testThatImageStateCanTransitionToValidState() {
        // WHEN
        sut.setState(state: .preprocessing, for: .complete)
        
        // THEN
        XCTAssertEqual(sut.imageState(for: .complete), .preprocessing)
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
    }
    
    func testThatImageStateDoesntTransitionToInvalidState() {
        // WHEN
        sut.setState(state: .uploading, for: .preview)
        
        // THEN
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)
    }
    
    func testThatImageStateMaintainsSeparateStatesForDifferentSizes() {
        // WHEN
        sut.setState(state: .preprocessing, for: .preview)
        
        // THEN
        XCTAssertEqual(sut.imageState(for: .preview), .preprocessing)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)
    }
    
    func testThatProfileUpdateStateIsSetToUpdateAfterAllImageStatesAreUploaded() {
        // GIVEN
        sut.setState(state: samplePreprocessState)
        sut.setState(state: .preprocessing, for: .preview)
        sut.setState(state: .preprocessing, for: .complete)
        sut.setState(state: sampleUploadState, for: .preview)
        sut.setState(state: sampleUploadState, for: .complete)
        sut.setState(state: .uploading, for: .preview)
        sut.setState(state: .uploading, for: .complete)
        XCTAssertEqual(sut.imageState(for: .preview), .uploading)
        XCTAssertEqual(sut.imageState(for: .complete), .uploading)

        // WHEN
        let previewAssetId = "asset_preview"
        let completeAssetId = "asset_complete"

        sut.setState(state: .uploaded(assetId: previewAssetId), for: .preview)
        sut.setState(state: .uploaded(assetId: completeAssetId), for: .complete)

        // THEN
        XCTAssertEqual(sut.state, .update(previewAssetId: previewAssetId, completeAssetId: completeAssetId))
    }
    
    func testThatProfileUpdateStateIsSetToFailedAfterAnyImageStatesIsFailed() {
        // WHEN
        sut.setState(state: .preprocessing, for: .preview)
        sut.setState(state: sampleUploadState, for: .preview)
        sut.setState(state: sampleFailedImageState, for: .preview)

        // THEN
        XCTAssertEqual(sut.state, .failed(.preprocessingFailed))
    }

}

// MARK: Main state transitions
extension UserProfileImageUpdateStatusTests {
    func testThatProfileUpdateStateStartsWithReadyState() {
        XCTAssertEqual(sut.state, .ready)
    }
    
    func testProfileUpdateStateTransitions() {
        ProfileUpdateState.canTransition(from: .ready, onlyTo: [sampleFailedState, samplePreprocessState])
        ProfileUpdateState.canTransition(from: samplePreprocessState, onlyTo: [sampleFailedState, sampleUpdateState])
        ProfileUpdateState.canTransition(from: sampleUpdateState, onlyTo: [sampleFailedState, .updating])
        ProfileUpdateState.canTransition(from: .updating, onlyTo: [sampleFailedState, .completed])
        ProfileUpdateState.canTransition(from: .completed, onlyTo: [.ready])
        ProfileUpdateState.canTransition(from: sampleFailedState, onlyTo: [.ready])
    }
    
    func testThatProfileUpdateStateCanTransitionToValidState() {
        // WHEN
        sut.setState(state: samplePreprocessState)
        
        // THEN
        XCTAssertEqual(sut.state, samplePreprocessState)
    }
    
    func testThatProfileUpdateStateDoesntTransitionToInvalidState() {
        // WHEN
        sut.setState(state: .updating)
        
        // THEN
        XCTAssertEqual(sut.state, .ready)
    }
    
    func testThatWhenProfileUpdateStateIsFailedImageStatesAreBackToReady() {
        // GIVEN
        sut.setState(state: .preprocessing, for: .preview)
        sut.setState(state: .preprocessing, for: .complete)

        // WHEN
        sut.setState(state: .failed(.preprocessingFailed))

        // THEN
        XCTAssertEqual(sut.state, .failed(.preprocessingFailed))
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)
    }
}

// MARK: Preprocessing
extension UserProfileImageUpdateStatusTests {
    func testThatItSetsPreprocessorDelegateWhenProcessing() {
        // WHEN
        sut.updateImage(imageData: tinyImage, size: .zero)

        // THEN
        XCTAssertNotNil(preprocessor.delegate)
    }
    
    func testThatItAsksPreprocessorForOperationsWithCorrectImageOwner() {
        // WHEN
        sut.updateImage(imageData: tinyImage, size: .zero)

        // THEN
        XCTAssertTrue(preprocessor.operationsCalled)
        let imageOwner = preprocessor.imageOwner
        XCTAssertNotNil(imageOwner)
        XCTAssertEqual(imageOwner?.originalImageData(), tinyImage)
    }
    
    func testThatPreprocessingFailsWhenNoOperationsAreReturned() {
        // GIVEN
        preprocessor.operations = []
        
        // WHEN
        sut.updateImage(imageData: tinyImage, size: .zero)

        // THEN
        XCTAssertEqual(sut.state, .failed(.preprocessingFailed))
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)
    }
    
    func testThatResizeOperationsAreEnqueued() {
        // GIVEN
        let e1 = self.operationWithExpectation(description: "#1 Image processing done")
        let e2 = self.operationWithExpectation(description: "#2 Image processing done")
        preprocessor.operations = [e1, e2]
        
        // WHEN
        sut.updateImage(imageData: tinyImage, size: .zero)

        // THEN 
        XCTAssertTrue(self.waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatAfterDownsamplingImageItSetsCorrectState() {
        // GIVEN
        sut.setState(state: .preprocessing, for: .complete)
        sut.setState(state: .preprocessing, for: .preview)
        
        let previewOperation = MockOperation(downsampleImageData: "preview".data(using: .utf8)!, format: ProfileImageSize.preview.imageFormat)
        let completeOperation = MockOperation(downsampleImageData: "complete".data(using: .utf8)!, format: ProfileImageSize.complete.imageFormat)

        // WHEN
        sut.completedDownsampleOperation(previewOperation, imageOwner: imageOwner)
        
        // THEN
        XCTAssertEqual(sut.imageState(for: .preview), .upload(image: previewOperation.downsampleImageData))
        XCTAssertEqual(sut.imageState(for: .complete), .preprocessing)

        // WHEN
        sut.completedDownsampleOperation(completeOperation, imageOwner: imageOwner)
        
        // THEN
        XCTAssertEqual(sut.imageState(for: .preview), .upload(image: previewOperation.downsampleImageData))
        XCTAssertEqual(sut.imageState(for: .complete), .upload(image: completeOperation.downsampleImageData))
    }
    
    func testThatIfDownsamplingFailsStateForAllSizesIsSetToFail() {
        // GIVEN
        sut.setState(state: .preprocessing, for: .complete)
        sut.setState(state: .preprocessing, for: .preview)
        
        // WHEN
        sut.failedPreprocessingImageOwner(imageOwner)
        
        // THEN
        XCTAssertEqual(sut.state, .failed(.preprocessingFailed))
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)
    }
    
    func testThatItIsNotPossibleToStartPreprocessingAgainIfProfileUpdateFails() {
        // GIVEN
        sut.updateImage(imageData: Data(), size: .zero)
        XCTAssertEqual(sut.state, .preprocess(image: Data(), size: .zero))
        XCTAssertEqual(sut.imageState(for: .preview), .preprocessing)
        XCTAssertEqual(sut.imageState(for: .complete), .preprocessing)
        sut.setState(state: .failed(.preprocessingFailed))

        // WHEN
        sut.updateImage(imageData: Data(), size: .zero)
        
        // THEN
        XCTAssertEqual(sut.state, .failed(.preprocessingFailed))
        XCTAssertEqual(sut.imageState(for: .preview), .ready)
        XCTAssertEqual(sut.imageState(for: .complete), .ready)

    }
}
