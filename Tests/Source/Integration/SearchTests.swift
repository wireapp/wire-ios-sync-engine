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


extension SearchTests : ZMUserObserver {
    
    func userDidChange(_ changeInfo: UserChangeInfo) {
        userNotifications.append(changeInfo)
    }
    
}

class SearchTests : IntegrationTest {

    var userNotifications : [UserChangeInfo] = []
    
    override func setUp() {
        super.setUp()
        
        createSelfUserAndConversation()
        createExtraUsersAndConversations()
    }
    
    override func tearDown() {
        userNotifications.removeAll()
        
        super.tearDown()
    }
    
    // MARK: Connections
    
    func testThatItConnectsToAUserInASearchResult() {
        // given
        let userName = "JohnnyMnemonic"
        var user : MockUser? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            user = changes.insertUser(withName: userName)
            user?.email = "johnny@example.com"
            user?.phone = ""
        }
        
        XCTAssertTrue(login())
        
        // when
        searchAndConnectToUser(withName: userName, searchQuery: "Johnny")
        
        // then
        guard let newUser = self.user(for: user!) else { XCTFail(); return }
        guard let oneToOneConversation = newUser.oneToOneConversation else { XCTFail(); return }
        XCTAssertEqual(newUser.name, userName)
        XCTAssertNotNil(newUser.oneToOneConversation);
        XCTAssertFalse(newUser.isConnected)
        XCTAssertTrue(newUser.isPendingApprovalByOtherUser)
        
        // remote user accepts connection
        mockTransportSession.performRemoteChanges { (changes) in
            changes.remotelyAcceptConnection(to: user!)
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertTrue(newUser.isConnected)
        XCTAssertTrue(oneToOneConversation.activeParticipants.contains(newUser))
    }
    
    func testThatTheSelfUserCanAcceptAConnectionRequest() {
        // given
        let userName = "JohnnyMnemonic"
        var user : MockUser? = nil
        let remoteIdentifier = UUID.create()
        
        mockTransportSession.performRemoteChanges { (changes) in
            user = changes.insertUser(withName: userName)
            user?.email = "johnny@example.com"
            user?.phone = ""
            user?.identifier = remoteIdentifier.transportString()
            
            let connection = changes.createConnectionRequest(from: user!, to: self.selfUser, message: "Holo")
            connection.status = "pending"
            
        }
        
        XCTAssertTrue(login())
        
        let pendingConnections = ZMConversationList.pendingConnectionConversations(inUserSession: userSession!)
        XCTAssertEqual(pendingConnections.count, 1)
    }
    
    func testThatItNotifiesObserversWhenTheConnectionStatusChanges_InsertedUser() {
        // given
        let userName = "JohnnyMnemonic"
        var user : MockUser? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            user = changes.insertUser(withName: userName)
            user?.email = "johnny@example.com"
            user?.phone = ""
        }
        
        XCTAssertTrue(login())
        
        // find user
        guard let searchUser = searchForDirectoryUser(withName: userName, searchQuery: "Johnny") else { XCTFail(); return }
        
        // then
        var token = UserChangeInfo.add(observer: self, forBareUser: searchUser, userSession: userSession!)
        XCTAssertNotNil(token)
        XCTAssertNil(searchUser.user)
        XCTAssertEqual(userNotifications.count, 0)
        
        // connect
        connect(withUser: searchUser)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(userNotifications.count, 1)
        guard let userChangeInfo = userNotifications.first else { XCTFail(); return }
        XCTAssertTrue(userChangeInfo.user === searchUser)
        XCTAssertTrue(userChangeInfo.connectionStateChanged)
        token = nil
    }
    
    func testThatItNotifiesObserversWhenTheConnectionStatusChanges_LocalUser() {
        // given
        let userName = "JohnnyMnemonic"
        var user : MockUser? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            user = changes.insertUser(withName: userName)
            user?.email = "johnny@example.com"
            user?.phone = ""
            
            self.groupConversation.addUsers(by: self.selfUser, addedUsers: [user!])
        }
        
        XCTAssertTrue(login())
        
        // find user
        guard let searchUser = searchForDirectoryUser(withName: userName, searchQuery: "Johnny") else { XCTFail(); return }
        
        // then
        var token = UserChangeInfo.add(observer: self, forBareUser: searchUser, userSession: userSession!)
        XCTAssertNotNil(token)
        XCTAssertNotNil(searchUser.user)
        XCTAssertEqual(userNotifications.count, 0)
        
        // connect
        connect(withUser: searchUser)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(userNotifications.count, 1)
        guard let userChangeInfo = userNotifications.first else { XCTFail(); return }
        XCTAssertTrue(userChangeInfo.user === searchUser)
        XCTAssertTrue(userChangeInfo.connectionStateChanged)
        token = nil
    }
    
    // MARK: Profile Images
    
    func testThatItReturnsTheProfileImageForAConnectedSearchUser() {
        
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user1.smallProfileImageIdentifier!)?.data
            userName = self.user1.name
        }
        
        XCTAssertTrue(login())
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let user = searchForConnectedUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        
        // when
        user.requestSmallProfileImage(in: userSession)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(user.imageSmallProfileData, profileImageData)
    }
    
    func testThatItReturnsTheProfileImageForAnUnconnectedSearchUser() {
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.smallProfileImageIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        // when
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(searchUser.imageSmallProfileData, profileImageData)   
    }
    
    func testThatItReturnsNoImageIfTheUnconnectedSearchUserHasNoImage() {
        // given
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            userName = self.user5.name
        }
        
        XCTAssertTrue(login())
        
        
        // when
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertNil(searchUser.imageSmallProfileData)
    }
    
    func testThatItNotifiesWhenANewImageIsAvailableForAnUnconnectedSearchUser() {
        // given
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        // delay mock transport session response
        let semaphore = DispatchSemaphore(value: 0)
        mockTransportSession.responseGeneratorBlock = { (request) in
            if request.path.hasPrefix("/asset") {
                semaphore.wait()
            }
            
            return nil
        }
        
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        var token = UserChangeInfo.add(observer: self, forBareUser: searchUser, userSession: userSession!)
        XCTAssertNotNil(token)
        
        // when
        semaphore.signal()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(userNotifications.count, 1)
        guard let userChangeInfo = userNotifications.first else { XCTFail(); return }
        XCTAssertTrue(userChangeInfo.user === searchUser)
        XCTAssertTrue(userChangeInfo.imageSmallProfileDataChanged)
        token = nil
    }
    
    func testThatItSetsTheMediumImageForAnUnconnectedSearchUser() {
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        // We need not to have v3 profile pictures
        user4.previewProfileAssetIdentifier = nil
        user4.completeProfileAssetIdentifier = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.smallProfileImageIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        let mediumAssetIDCache = ZMSearchUser.searchUserToMediumAssetIDCache()
        let mediumImageCache = ZMSearchUser.searchUserToMediumImageCache()
        
        guard let remoteIdentifer = UUID(uuidString: user4.identifier) else { XCTFail(); return }
        guard let mediumImageIdenitifer = UUID(uuidString: user4.mediumImageIdentifier!) else { XCTFail(); return }
        
        
        guard let searchUserAsset = mediumAssetIDCache?.object(forKey: remoteIdentifer as AnyObject) as? SearchUserAssetObjC else { XCTFail(); return }
        XCTAssertEqual(searchUserAsset.legacyID, mediumImageIdenitifer)
        XCTAssertNil(mediumImageCache?.object(forKey: remoteIdentifer as AnyObject))
        
        // when requesting medium image
        userSession?.performChanges {
            searchUser.requestMediumProfileImage(in: self.userSession)
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(searchUser.imageMediumData, profileImageData)
    }
    
    func testThatItRefetchesTheSearchUserIfTheMediumImageDataGotDeletedFromTheCache() {
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        // We need not to have v3 profile pictures
        user4.previewProfileAssetIdentifier = nil
        user4.completeProfileAssetIdentifier = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.smallProfileImageIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        let mediumAssetIDCache = ZMSearchUser.searchUserToMediumAssetIDCache()
        let mediumImageCache = ZMSearchUser.searchUserToMediumImageCache()
        
        guard let remoteIdentifer = UUID(uuidString: user4.identifier) else { XCTFail(); return }
        guard let mediumImageIdenitifer = UUID(uuidString: user4.mediumImageIdentifier!) else { XCTFail(); return }
        
        // first search
        do {
            guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
            guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
            XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
            
            guard let searchUserAsset = mediumAssetIDCache?.object(forKey: remoteIdentifer as AnyObject) as? SearchUserAssetObjC else { XCTFail(); return }
            XCTAssertEqual(searchUserAsset.legacyID, mediumImageIdenitifer)
            XCTAssertNil(mediumImageCache?.object(forKey: remoteIdentifer as AnyObject))
            
            // when requesting medium image
            userSession?.performChanges {
                searchUser.requestMediumProfileImage(in: self.userSession)
            }
            XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
            
            // then
            XCTAssertEqual(searchUser.imageMediumData, profileImageData)
        }
        
        // clear the cache
        mediumImageCache?.removeObject(forKey: remoteIdentifer as AnyObject)
        mediumAssetIDCache?.removeObject(forKey: remoteIdentifer as AnyObject)
        
        // second search
        do {
            guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
            guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
            XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
            
            guard let searchUserAsset = mediumAssetIDCache?.object(forKey: remoteIdentifer as AnyObject) as? SearchUserAssetObjC else { XCTFail(); return }
            XCTAssertEqual(searchUserAsset.legacyID, mediumImageIdenitifer)
            XCTAssertNil(mediumImageCache?.object(forKey: remoteIdentifer as AnyObject))
            
            // when requesting medium image
            userSession?.performChanges {
                searchUser.requestMediumProfileImage(in: self.userSession)
            }
            XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
            
            // then
            XCTAssertEqual(searchUser.imageMediumData, profileImageData)
        }
    }
    
    func testThatItRefetchesTheSearchUserIfTheMediumAssetIDIsNotSet() {
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        // We need not to have v3 profile pictures
        user4.previewProfileAssetIdentifier = nil
        user4.completeProfileAssetIdentifier = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.smallProfileImageIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        let mediumAssetIDCache = ZMSearchUser.searchUserToMediumAssetIDCache()
        let mediumImageCache = ZMSearchUser.searchUserToMediumImageCache()
        
        guard let remoteIdentifer = UUID(uuidString: user4.identifier) else { XCTFail(); return }
        guard let mediumImageIdenitifer = UUID(uuidString: user4.mediumImageIdentifier!) else { XCTFail(); return }
        
        // (1) search
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        guard let searchUserAsset = mediumAssetIDCache?.object(forKey: remoteIdentifer as AnyObject) as? SearchUserAssetObjC else { XCTFail(); return }
        XCTAssertEqual(searchUserAsset.legacyID, mediumImageIdenitifer)
        XCTAssertNil(mediumImageCache?.object(forKey: remoteIdentifer as AnyObject))
        
        // (2) remove mediumAssetID from cache
        mediumAssetIDCache?.removeObject(forKey: remoteIdentifer as AnyObject)
        
        // (3) when requesting medium image
        userSession?.performChanges {
            searchUser.requestMediumProfileImage(in: self.userSession)
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(searchUser.imageMediumData, profileImageData)
    }
    
    func testThatItNotifiesWhenANewMediumImageIsAvailableForAnUnconnectedSearchUser() {
        // given
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        // delay mock transport session response
        let semaphore = DispatchSemaphore(value: 0)
        var hasRun = false
        mockTransportSession.responseGeneratorBlock = { (request) in
            if request.path.hasPrefix("/asset") && !hasRun {
                hasRun = true
                semaphore.wait()
            }
            
            return nil
        }
        
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        var token = UserChangeInfo.add(observer: self, forBareUser: searchUser, userSession: userSession!)
        XCTAssertNotNil(token)
        
        // when small proile image response arrives
        semaphore.signal()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(userNotifications.count, 1)

        // when requesting medium
        userSession?.performChanges {
            searchUser.requestMediumProfileImage(in: self.userSession)
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(userNotifications.count, 2)
        guard let userChangeInfo = userNotifications.last else { XCTFail(); return }
        XCTAssertTrue(userChangeInfo.user === searchUser)
        XCTAssertTrue(userChangeInfo.imageMediumDataChanged)
        
        token = nil
    }
    
    // MARK: V3 Profile Assets
    
    func testThatItDownloadsV3PreviewAsset_ConnectedUser() {
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user1.smallProfileImageIdentifier!)?.data
            userName = self.user1.name
        }
        
        XCTAssertTrue(login())
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let user = searchForConnectedUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        
        // when
        mockTransportSession.resetReceivedRequests()
        user.requestSmallProfileImage(in: userSession)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(user.imageSmallProfileData, profileImageData)
        
        let requests = mockTransportSession.receivedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/assets/v3/\(user1.previewProfileAssetIdentifier!)")
        XCTAssertEqual(requests.first?.method, .methodGET)
    }
    
    func testThatItDownloadsV3PreviewAssetWhenOnlyV3AssetsArePrensentInSearchUserResponse_UnconnectedUser() {
        // given
        var profileImageData : Data? = nil
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            profileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.smallProfileImageIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        mockTransportSession.resetReceivedRequests()
        
        // when
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        searchUser.requestSmallProfileImage(in: userSession)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(searchUser.imageSmallProfileData, profileImageData)
        
        let requests = mockTransportSession.receivedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[3].path, "/assets/v3/\(user4.previewProfileAssetIdentifier!)")
        XCTAssertEqual(requests[3].method, .methodGET)
    }
    
    func testThatItDownloadsMediumAssetForSearchUserWhenAssetAndLegacyIdArePresentUsingV3() {
        verifyThatItDownloadsMediumV3AssetForSearchUser(withLegacyPayloadPresent: true)
    }
    
    func testThatItDownloadsMediumAssetForSearchUserLegacyIdsAreNotPresentUsingV3() {
        verifyThatItDownloadsMediumV3AssetForSearchUser(withLegacyPayloadPresent: false)
    }
    
    func verifyThatItDownloadsMediumV3AssetForSearchUser(withLegacyPayloadPresent legacyPayloadPresent: Bool) {
        // given
        var completeProfileImageData : Data? = nil
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            changes.addV3ProfilePicture(to: self.user4)
            
            if legacyPayloadPresent {
                self.user4.removeLegacyPictures()
            }
            
            completeProfileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.completeProfileAssetIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        let mediumAssetIDCache = ZMSearchUser.searchUserToMediumAssetIDCache()
        let mediumImageCache = ZMSearchUser.searchUserToMediumImageCache()
        
        guard let remoteIdentifer = UUID(uuidString: user4.identifier) else { XCTFail(); return }
        guard let searchUserAsset = mediumAssetIDCache?.object(forKey: remoteIdentifer as AnyObject) as? SearchUserAssetObjC else { XCTFail(); return }
        XCTAssertEqual(searchUserAsset.assetKey, user4.completeProfileAssetIdentifier)
        XCTAssertNil(mediumImageCache?.object(forKey: remoteIdentifer as AnyObject))
        
        mockTransportSession.resetReceivedRequests()
        
        // when requesting medium image
        userSession?.performChanges {
            searchUser.requestMediumProfileImage(in: self.userSession)
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(searchUser.imageMediumData, completeProfileImageData)
        
        let requests = mockTransportSession.receivedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].path, "/assets/v3/\(user4.completeProfileAssetIdentifier!)")
        XCTAssertEqual(requests[0].method, .methodGET)
    }
    
    func testThatItRefetchesTheSearchUserIfTheMediumAssetIDIsNotSet_V3Asset() {
        // given
        var completeProfileImageData : Data? = nil
        var userName : String? = nil
        
        mockTransportSession.performRemoteChanges { (changes) in
            changes.addV3ProfilePicture(to: self.user4)
            self.user4.removeLegacyPictures()
            
            completeProfileImageData = MockAsset.init(in: self.mockTransportSession.managedObjectContext, forID: self.user4.completeProfileAssetIdentifier!)?.data
            userName = self.user4.name
        }
        
        XCTAssertTrue(login())
        
        guard let searchQuery = userName?.components(separatedBy: " ").last else { XCTFail(); return }
        guard let searchUser = searchForDirectoryUser(withName: userName!, searchQuery: searchQuery) else { XCTFail(); return }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        let mediumAssetIDCache = ZMSearchUser.searchUserToMediumAssetIDCache()
        let mediumImageCache = ZMSearchUser.searchUserToMediumImageCache()
        
        guard let remoteIdentifer = UUID(uuidString: user4.identifier) else { XCTFail(); return }
        
        mediumAssetIDCache?.removeAllObjects()
        
        XCTAssertNil(mediumAssetIDCache?.object(forKey: remoteIdentifer as AnyObject))
        XCTAssertNil(mediumImageCache?.object(forKey: remoteIdentifer as AnyObject))
        XCTAssertNil(searchUser.completeAssetKey)
        
        // We reset the requests after having performed the search and fetching the users (in comparison to the other tests).
        mockTransportSession.resetReceivedRequests()
        
        // when requesting medium image
        userSession?.performChanges {
            searchUser.requestMediumProfileImage(in: self.userSession)
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(searchUser.imageMediumData, completeProfileImageData)
        
        let requests = mockTransportSession.receivedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].path, "/users?ids=\(user4.identifier)")
        XCTAssertEqual(requests[0].method, .methodGET)
        XCTAssertEqual(requests[1].path, "/assets/v3/\(user4.completeProfileAssetIdentifier!)")
        XCTAssertEqual(requests[1].method, .methodGET)
    }
    
}
