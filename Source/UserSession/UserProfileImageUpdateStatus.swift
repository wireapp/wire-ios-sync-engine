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
import WireDataModel

internal enum UserProfileImageUpdateError: Error {
    case preprocessingFailed
    case uploadFailed(Error)
}

internal protocol UserProfileImageUpdateStateDelegate: class {
    func failed(withError: UserProfileImageUpdateError)
}

internal protocol UserProfileImageUploadStatusProtocol: class {
    func consumeImage(for size: ProfileImageSize) -> Data?
    func hasImageToUpload(for size: ProfileImageSize) -> Bool
    func uploadingDone(imageSize: ProfileImageSize, assetId: String)
    func uploadingFailed(imageSize: ProfileImageSize, error: Error)
}

@objc public protocol UserProfileImageUpdateProtocol: class {
    @objc(updateImageWithImageData:)
    func updateImage(imageData: Data)
}

internal protocol UserProfileImageUploadStateChangeDelegate: class {
    func didTransition(from oldState: UserProfileImageUpdateStatus.ProfileUpdateState, to currentState: UserProfileImageUpdateStatus.ProfileUpdateState)
    func didTransition(from oldState: UserProfileImageUpdateStatus.ImageState, to currentState: UserProfileImageUpdateStatus.ImageState, for size: ProfileImageSize)
}

public final class UserProfileImageUpdateStatus: NSObject {
    
    fileprivate var log = ZMSLog(tag: "UserProfileImageUpdateStatus")
    
    internal enum ImageState {
        case ready
        case preprocessing
        case upload(image: Data)
        case uploading
        case uploaded(assetId: String)
        case failed(UserProfileImageUpdateError)
        
        internal func canTransition(to newState: ImageState) -> Bool {
            switch (self, newState) {
            case (.ready, .preprocessing),
                 (.preprocessing, .upload),
                 (.upload, .uploading),
                 (.uploading, .uploaded),
                 (.ready, .upload): // When re-uploading a preprocessed v2 to v3
                return true
            case (.uploaded, .ready),
                 (.failed, .ready):
                return true
            case (.failed, .failed):
                return false
            case (_, .failed):
                return true
            default:
                return false
            }
        }
    }
    
    internal enum ProfileUpdateState {
        case ready
        case preprocess(image: Data)
        case update(previewAssetId: String, completeAssetId: String)
        case failed(UserProfileImageUpdateError)
        
        internal func canTransition(to newState: ProfileUpdateState) -> Bool {
            switch (self, newState) {
            case (.ready, .preprocess),
                 (.preprocess, .update),
                 (.ready, .update): // When re-uploading a preprocessed v2 to v3
                return true
            case (.update, .ready),
                 (.failed, .ready):
                return true
            case (.failed, .failed):
                return false
            case (_, .failed):
                return true
            default:
                return false
            }
        }
    }
    
    internal var preprocessor: ZMAssetsPreprocessorProtocol?
    internal let queue: OperationQueue
    internal weak var changeDelegate: UserProfileImageUploadStateChangeDelegate?

    fileprivate var changeDelegates: [UserProfileImageUpdateStateDelegate] = []
    fileprivate var imageOwner: ImageOwner?
    fileprivate let syncMOC: NSManagedObjectContext
    fileprivate let uiMOC: NSManagedObjectContext

    fileprivate var imageState = [ProfileImageSize : ImageState]()
    fileprivate var resizedImages = [ProfileImageSize : Data]()
    internal fileprivate(set) var state: ProfileUpdateState = .ready
    
    public convenience init(managedObjectContext: NSManagedObjectContext) {
        self.init(managedObjectContext: managedObjectContext, preprocessor: ZMAssetsPreprocessor(delegate: nil), queue: ZMImagePreprocessor.createSuitableImagePreprocessingQueue(), delegate: nil)
    }
    
    internal init(managedObjectContext: NSManagedObjectContext, preprocessor: ZMAssetsPreprocessorProtocol, queue: OperationQueue, delegate: UserProfileImageUploadStateChangeDelegate?){
        log.debug("Created")
        self.queue = queue
        self.preprocessor = preprocessor
        self.syncMOC = managedObjectContext
        self.uiMOC = managedObjectContext.zm_userInterface
        self.changeDelegate = delegate
        super.init()
        self.preprocessor?.delegate = self
        
        // Check if we should re-upload an existing v2 in case we never uploaded a v3 asset.
        reuploadExisingImageIfNeeded()
    }
    
    deinit {
        log.debug("Deallocated")
    }
}

// MARK: Main state transitions
extension UserProfileImageUpdateStatus {
    internal func setState(state newState: ProfileUpdateState) {
        let currentState = self.state
        guard currentState.canTransition(to: newState) else {
            log.debug("Invalid transition: [\(currentState)] -> [\(newState)], ignoring")
            // Trying to transition to invalid state - ignore
            return
        }
        self.state = newState
        self.didTransition(from: currentState, to: newState)
    }
    
    private func didTransition(from oldState: ProfileUpdateState, to currentState: ProfileUpdateState) {
        log.debug("Transition: [\(oldState)] -> [\(currentState)]")
        changeDelegate?.didTransition(from: oldState, to: currentState)
        switch (oldState, currentState) {
        case (_, .ready):
            resetImageState()
        case let (_, .preprocess(image: data)):
            startPreprocessing(imageData: data)
        case let (_, .update(previewAssetId: previewAssetId, completeAssetId: completeAssetId)):
            updateUserProfile(with:previewAssetId, completeAssetId: completeAssetId)
        case (_, .failed):
            resetImageState()
            setState(state: .ready)
        }
    }
    
    private func updateUserProfile(with previewAssetId: String, completeAssetId: String) {
        let selfUser = ZMUser.selfUser(in: self.syncMOC)
        selfUser.updateAndSyncProfileAssetIdentifiers(previewIdentifier: previewAssetId, completeIdentifier: completeAssetId)
        selfUser.imageSmallProfileData = self.resizedImages[.preview]
        selfUser.imageMediumData = self.resizedImages[.complete]
        self.resetImageState()
        self.syncMOC.saveOrRollback()
        self.setState(state: .ready)
    }
    
    private func startPreprocessing(imageData: Data) {
        ProfileImageSize.allSizes.forEach {
            setState(state: .preprocessing, for: $0)
        }
        
        let imageOwner = UserProfileImageOwner(imageData: imageData)
        guard let operations = preprocessor?.operations(forPreprocessingImageOwner: imageOwner), !operations.isEmpty else {
            resetImageState()
            setState(state: .failed(.preprocessingFailed))
            return
        }
        
        queue.addOperations(operations, waitUntilFinished: false)
    }
}

// MARK: Image state transitions
extension UserProfileImageUpdateStatus {
    internal func imageState(for imageSize: ProfileImageSize) -> ImageState {
        return imageState[imageSize] ?? .ready
    }
    
    internal func setState(state newState: ImageState, for imageSize: ProfileImageSize) {
        let currentState = self.imageState(for: imageSize)
        guard currentState.canTransition(to: newState) else {
            // Trying to transition to invalid state - ignore
            return
        }
        
        self.imageState[imageSize] = newState
        self.didTransition(from: currentState, to: newState, for: imageSize)
    }
    
    internal func resetImageState() {
        imageState.removeAll()
        resizedImages.removeAll()
    }
    
    private func didTransition(from oldState: ImageState, to currentState: ImageState, for size: ProfileImageSize) {
        log.debug("Transition [\(size)]: [\(oldState)] -> [\(currentState)]")
        changeDelegate?.didTransition(from: oldState, to: currentState, for: size)
        switch (oldState, currentState) {
        case let (_, .upload(image)):
            resizedImages[size] = image
            RequestAvailableNotification.notifyNewRequestsAvailable(self)
        case (_, .uploaded):
            // When one image is uploaded we check state of all other images
            let previewState = imageState(for: .preview)
            let completeState = imageState(for: .complete)
            
            switch (previewState, completeState) {
            case let (.uploaded(assetId: previewAssetId), .uploaded(assetId: completeAssetId)):
                // If both images are uploaded we can update profile
                setState(state: .update(previewAssetId: previewAssetId, completeAssetId: completeAssetId))
            default:
                break // Need to wait until both images are uploaded
            }
        case let (_, .failed(error)):
            setState(state: .failed(error))
        default:
            break
        }
    }
}

// Called from the UI to update a v3 image
extension UserProfileImageUpdateStatus: UserProfileImageUpdateProtocol {
    
    /// Starts the process of updating profile picture. 
    ///
    /// - Important: Expected to be run from UI thread
    ///
    /// - Parameter imageData: image data of the new profile picture
    public func updateImage(imageData: Data) {
        let editableUser = ZMUser.selfUser(in: uiMOC) as ZMEditableUser
        editableUser.originalProfileImageData = imageData
        syncMOC.performGroupedBlock {
            self.setState(state: .preprocess(image: imageData))
        }
    }
}

// Called internally with existing image data to reupload to v3 (no preprocessing needed)
extension UserProfileImageUpdateStatus: ZMContextChangeTracker {

    public func objectsDidChange(_ object: Set<NSManagedObject>) {
        guard object.contains(ZMUser.selfUser(in: syncMOC)) else { return }
        reuploadExisingImageIfNeeded()
    }

    public func fetchRequestForTrackedObjects() -> NSFetchRequest<NSFetchRequestResult>? {
        return nil
    }

    public func addTrackedObjects(_ objects: Set<NSManagedObject>) {
        // no-op
    }

    internal func reuploadExisingImageIfNeeded() {
        // If the user updated to a build which added profile picture asset v3 support
        // we want to re-upload existing pictures to `/assets/v3`.
        let selfUser = ZMUser.selfUser(in: syncMOC)

        // We need to ensure we already re-fetched the selfUser (see HotFix 76.0.0),
        // as other clients could already have uploaded a v3 asset.
        guard !selfUser.needsToBeUpdatedFromBackend else { return }

        // We only want to re-upload in case the user did not yet upload a picture to `/assets/v3`.
        guard nil == selfUser.previewProfileAssetIdentifier, nil == selfUser.completeProfileAssetIdentifier else { return }
        guard let preview = selfUser.imageSmallProfileData, let complete = selfUser.imageMediumData else { return }
        log.debug("V3 profile picture not found, re-uploading V2")
        updatePreprocessedImages(preview: preview, complete: complete)
    }

    internal func updatePreprocessedImages(preview: Data, complete: Data) {
        setState(state: .upload(image: preview), for: .preview)
        setState(state: .upload(image: complete), for: .complete)
    }

}

extension UserProfileImageUpdateStatus: ZMAssetsPreprocessorDelegate {
    
    public func completedDownsampleOperation(_ operation: ZMImageDownsampleOperationProtocol, imageOwner: ZMImageOwner) {
        syncMOC.performGroupedBlock {
            ProfileImageSize.allSizes.forEach {
                if operation.format == $0.imageFormat {
                    self.setState(state: .upload(image: operation.downsampleImageData), for: $0)
                }
            }
        }
    }
    
    public func failedPreprocessingImageOwner(_ imageOwner: ZMImageOwner) {
        syncMOC.performGroupedBlock {
            self.setState(state: .failed(.preprocessingFailed))
        }
    }
    
    public func didCompleteProcessingImageOwner(_ imageOwner: ZMImageOwner) {}
    
    public func preprocessingCompleteOperation(for imageOwner: ZMImageOwner) -> Operation? {
        let dispatchGroup = syncMOC.dispatchGroup
        dispatchGroup?.enter()
        return BlockOperation() {
            dispatchGroup?.leave()
        }
    }
}

extension UserProfileImageUpdateStatus: UserProfileImageUploadStatusProtocol {
    
    /// Checks if there is an image to upload
    ///
    /// - Important: should be called from sync thread
    /// - Parameter size: which image size to check
    /// - Returns: true if there is an image of this size ready for upload
    internal func hasImageToUpload(for size: ProfileImageSize) -> Bool {
        switch imageState(for: size) {
        case .upload:
            return true
        default:
            return false
        }
    }
    
    /// Takes an image that is ready for upload and marks it internally
    /// as currently being uploaded.
    ///
    /// - Parameter size: size of the image
    /// - Returns: Image data if there is image of this size ready for upload
    internal func consumeImage(for size: ProfileImageSize) -> Data? {
        switch imageState(for: size) {
        case .upload(image: let image):
            setState(state: .uploading, for: size)
            return image
        default:
            return nil
        }
    }
    
    /// Marks the image as uploaded successfully
    ///
    /// - Parameters:
    ///   - imageSize: size of the image
    ///   - assetId: resulting asset identifier after uploading it to the store
    internal func uploadingDone(imageSize: ProfileImageSize, assetId: String) {
        setState(state: .uploaded(assetId: assetId), for: imageSize)
    }
    
    /// Marks the image as failed to upload
    ///
    /// - Parameters:
    ///   - imageSize: size of the image
    ///   - error: transport error
    internal func uploadingFailed(imageSize: ProfileImageSize, error: Error) {
        setState(state: .failed(.uploadFailed(error)), for: imageSize)
    }
}
