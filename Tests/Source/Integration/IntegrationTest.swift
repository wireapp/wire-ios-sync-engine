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
import WireTesting

@testable import WireSyncEngine

class AuthenticationObserver : NSObject, ZMAuthenticationObserver {
    
    var onFailure : (() -> Void)?
    var onSuccess : (() -> Void)?
    
    func authenticationDidFail(_ error: Error) {
        onFailure?()
    }
    
    func authenticationDidSucceed() {
        onSuccess?()
    }
    
}

extension IntegrationTest {
    
    static let SelfUserEmail = "myself@user.example.com"
    static let SelfUserPassword = "fgf0934';$@#%"
    
    @objc
    func _setUp() {
        ZMPersistentCookieStorage.setDoNotPersistToKeychain(!useRealKeychain)
        
        NSManagedObjectContext.setUseInMemoryStore(useInMemoryStore)
        
        application = ApplicationMock()
        mockTransportSession = MockTransportSession(dispatchGroup: self.dispatchGroup)
        WireCallCenterV3Factory.wireCallCenterClass = WireCallCenterV3IntegrationMock.self;
        ZMCallFlowRequestStrategyInternalFlowManagerOverride = MockFlowManager()
        mockTransportSession?.cookieStorage.deleteUserKeychainItems()
                
        createSessionManager()
    }
    
    @objc
    func _tearDown() {
        ZMCallFlowRequestStrategyInternalFlowManagerOverride = nil
        sharedSearchDirectory?.tearDown()
        sharedSearchDirectory = nil
        userSession = nil
        unauthenticatedSession = nil
        mockTransportSession?.tearDown()
        mockTransportSession = nil
        sessionManager = nil
        selfUser = nil
        user1 = nil
        user2 = nil
        user3 = nil
        user4 = nil
        user5 = nil
        selfToUser1Conversation = nil
        selfToUser2Conversation = nil
        connectionSelfToUser1 = nil
        connectionSelfToUser2 = nil
        selfConversation = nil
        groupConversation = nil
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        resetInMemoryDatabases()
    }
    
    func resetInMemoryDatabases() {
        NSManagedObjectContext.resetUserInterfaceContext()
        NSManagedObjectContext.resetSharedPersistentStoreCoordinator()
    }
    
    @objc
    func destroySessionManager() {
        userSession = nil
        unauthenticatedSession = nil
        sessionManager = nil
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }
    
    @objc
    func deleteAuthenticationCookie() {
        mockTransportSession?.cookieStorage.deleteUserKeychainItems()
    }
    
    @objc
    func recreateSessionManager() {
        destroySharedSearchDirectory()
        destroySessionManager()
        createSessionManager()
    }
    
    @objc
    func createSessionManager() {
        
        guard let bundleIdentifier = Bundle.init(for: type(of: self)).bundleIdentifier,
              let mediaManager = mediaManager,
              let application = application,
              let transportSession = transportSession
        else { XCTFail(); return }
        
        let groupIdentifier = "group.\(bundleIdentifier)"
        
        sessionManager = SessionManager(appGroupIdentifier: groupIdentifier,
                                        appVersion: "0.0.0",
                                        transportSession: transportSession,
                                        apnsEnvironment: apnsEnvironment,
                                        mediaManager: mediaManager,
                                        analytics: nil,
                                        delegate: self,
                                        application: application,
                                        launchOptions: [:])
    }
    
    @objc
    func createSharedSearchDirectory() {
        guard sharedSearchDirectory == nil else { return }
        guard let userSession = userSession else { XCTFail("Could not create shared SearchDirectory");  return }
        sharedSearchDirectory = SearchDirectory(userSession: userSession)
    }
    
    func destroySharedSearchDirectory() {
        sharedSearchDirectory?.tearDown()
        sharedSearchDirectory = nil
    }
    
    @objc
    func createSelfUserAndConversation() {
        
        mockTransportSession?.performRemoteChanges({ session in
            let selfUser = session.insertSelfUser(withName: "The Self User")
            selfUser.email = IntegrationTest.SelfUserEmail
            selfUser.password = IntegrationTest.SelfUserPassword
            selfUser.phone = ""
            selfUser.accentID = 2
            session.addProfilePicture(to: selfUser)
            session.addV3ProfilePicture(to: selfUser)
            
            let selfConversation = session.insertSelfConversation(withSelfUser: selfUser)
            selfConversation.identifier = selfUser.identifier
            
            self.selfUser = selfUser
            self.selfConversation = selfConversation
        })
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }
    
    @objc
    func createExtraUsersAndConversations() {
        
        mockTransportSession?.performRemoteChanges({ session in
            let user1 = session.insertUser(withName: "Extra User1")
            user1.email = "user1@example.com"
            user1.phone = "6543"
            user1.accentID = 3
            session.addProfilePicture(to: user1)
            session.addV3ProfilePicture(to: user1)
            self.user1 = user1
            
            let user2 = session.insertUser(withName: "Extra User2")
            user2.email = "user2@example.com"
            user2.phone = "4534"
            user2.accentID = 1
            self.user2 = user2
            
            let user3 = session.insertUser(withName: "Extra User3")
            user3.email = "user3@example.com"
            user3.phone = "340958"
            user3.accentID = 4
            session.addProfilePicture(to: user3)
            session.addV3ProfilePicture(to: user3)
            self.user3 = user3
            
            let user4 = session.insertUser(withName: "Extra User4")
            user4.email = "user4@example.com"
            user4.phone = "2349857"
            user4.accentID = 7
            session.addProfilePicture(to: user4)
            session.addV3ProfilePicture(to: user4)
            self.user4 = user4
            
            let user5 = session.insertUser(withName: "Extra User5")
            user5.email = "user5@example.com"
            user5.phone = "555466434325"
            user5.accentID = 7
            self.user5 = user5
            
            let selfToUser1Conversation = session.insertOneOnOneConversation(withSelfUser: self.selfUser!, otherUser:user1)
            selfToUser1Conversation.creator = self.selfUser
            selfToUser1Conversation.setValue("Connection conversation to user 1", forKey:"name")
            self.selfToUser1Conversation = selfToUser1Conversation
            
            let selfToUser2Conversation = session.insertOneOnOneConversation(withSelfUser: self.selfUser!, otherUser:user2)
            selfToUser2Conversation.creator = user2
            selfToUser2Conversation.setValue("Connection conversation to user 2", forKey:"name")
            self.selfToUser2Conversation = selfToUser2Conversation
            
            let groupConversation = session.insertGroupConversation(withSelfUser:self.selfUser!, otherUsers: [user1, user2, user3])
            groupConversation.creator = user3;
            groupConversation.changeName(by:self.selfUser!, name:"Group conversation")
            self.groupConversation = groupConversation
            
            let connectionSelfToUser1 = session.insertConnection(withSelfUser:self.selfUser!, to:user1)
            connectionSelfToUser1.status = "accepted"
            connectionSelfToUser1.lastUpdate = Date(timeIntervalSinceNow: -3)
            connectionSelfToUser1.conversation = selfToUser1Conversation
            self.connectionSelfToUser1 = connectionSelfToUser1
            
            let connectionSelfToUser2 = session.insertConnection(withSelfUser:self.selfUser!, to:user2)
            connectionSelfToUser2.status = "accepted"
            connectionSelfToUser2.lastUpdate = Date(timeIntervalSinceNow: -5)
            connectionSelfToUser2.conversation = selfToUser2Conversation
            self.connectionSelfToUser2 = connectionSelfToUser2
        })
    }
    
    @objc
    func login() -> Bool {
        let credentials = ZMEmailCredentials(email: IntegrationTest.SelfUserEmail, password: IntegrationTest.SelfUserPassword)
        return login(withCredentials: credentials, ignoreAuthenticationFailures: false)
    }
    
    @objc(loginAndIgnoreAuthenticationFailures:)
    func login(ignoreAuthenticationFailures: Bool) -> Bool {
        let credentials = ZMEmailCredentials(email: IntegrationTest.SelfUserEmail, password: IntegrationTest.SelfUserPassword)
        return login(withCredentials: credentials, ignoreAuthenticationFailures: ignoreAuthenticationFailures)
    }
    
    @objc
    func login(withCredentials credentials: ZMCredentials, ignoreAuthenticationFailures: Bool = false) -> Bool {
        
        let authenticationObserver = AuthenticationObserver()
        var didSucceed = false
        
        authenticationObserver.onSuccess = {
            didSucceed = true
        }
        
        authenticationObserver.onFailure = {
            if !ignoreAuthenticationFailures {
                XCTFail("Failed to authenticate")
            }
        }
        
        let token = ZMUserSessionAuthenticationNotification.addObserver(authenticationObserver)
        unauthenticatedSession?.login(with: credentials)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        ZMUserSessionAuthenticationNotification.removeObserver(for: token)
        
        return didSucceed
    }
    
    @objc(userForMockUser:)
    func user(for mockUser: MockUser) -> ZMUser? {
        let uuid = mockUser.identifier.uuid()
        let data = (uuid as NSUUID).data() as NSData
        let predicate = NSPredicate(format: "remoteIdentifier_data == %@", data)
        let request = ZMUser.sortedFetchRequest(with: predicate)
        let result = userSession?.managedObjectContext.executeFetchRequestOrAssert(request) as? [ZMUser]
        
        if let user = result?.first {
            return user
        } else {
            return nil
        }
    }
    
    @objc(conversationForMockConversation:)
    func conversation(for mockConversation: MockConversation) -> ZMConversation? {
        let uuid = mockConversation.identifier.uuid()
        let data = (uuid as NSUUID).data() as NSData
        let predicate = NSPredicate(format: "remoteIdentifier_data == %@", data)
        let request = ZMConversation.sortedFetchRequest(with: predicate)
        let result = userSession?.managedObjectContext.executeFetchRequestOrAssert(request) as? [ZMConversation]
        
        if let conversation = result?.first {
            return conversation
        } else {
            return nil
        }
    }
        
    @objc(establishSessionWithMockUser:)
    func establishSession(with mockUser: MockUser) {
        mockTransportSession?.performRemoteChanges({ session in
            if mockUser.clients.count == 0 {
                session.registerClient(for: mockUser, label: "Wire for MS-DOS", type: "permanent")
            }
            
            for client in mockUser.clients {
                self.userSession?.syncManagedObjectContext.performGroupedBlockAndWait {
                    self.establishSessionFromSelf(toRemote: client as! MockUserClient)
                }
            }
        })
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }
    
}

extension IntegrationTest {
    
    @discardableResult
    @objc(createSentConnectionFromUserWithName:uuid:)
    func createSentConnection(fromUserWithName name: String, uuid: UUID) -> MockUser {
        return createConnection(fromUserWithName: name, uuid: uuid, status: "sent")
    }
    
    @discardableResult
    @objc(createPendingConnectionFromUserWithName:uuid:)
    func createPendingConnection(fromUserWithName name: String, uuid: UUID) -> MockUser {
        return createConnection(fromUserWithName: name, uuid: uuid, status: "pending")
    }

    @discardableResult
    @objc(createConnectionFromUserWithName:uuid:status:)
    func createConnection(fromUserWithName name: String, uuid: UUID, status: String) -> MockUser {
        let mockUser = createUser(withName: name, uuid: uuid)
        
        mockTransportSession?.performRemoteChanges({ session in
            let connection = session.insertConnection(withSelfUser:self.selfUser!, to:mockUser)
            connection.message = "Hello, my friend."
            connection.status = status
            connection.lastUpdate = Date(timeIntervalSinceNow:-20000)
            
            let conversation = session.insertConversation(withSelfUser: self.selfUser!, creator:mockUser, otherUsers:[], type:.invalid)
            connection.conversation = conversation
        })
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        return mockUser
    }
    
    @discardableResult
    @objc(createUserWithName:uuid:)
    func createUser(withName name: String, uuid: UUID) -> MockUser {
        var user : MockUser? = nil
        mockTransportSession?.performRemoteChanges({ session in
            user = session.insertUser(withName: name)
            user?.identifier = uuid.transportString()
        })
        
        return user!
    }
    
}

extension IntegrationTest : SessionManagerDelegate {
    
    public func sessionManagerCreated(userSession: ZMUserSession) {
        self.userSession = userSession
        
        userSession.syncManagedObjectContext.performGroupedBlockAndWait {
            userSession.syncManagedObjectContext.setPersistentStoreMetadata(NSNumber(value: true), key: ZMSkipHotfix)
            userSession.syncManagedObjectContext.add(self.dispatchGroup)
        }
        
        userSession.managedObjectContext.performGroupedBlockAndWait {
            userSession.managedObjectContext.add(self.dispatchGroup)
        }
        
        userSession.managedObjectContext.performGroupedBlock {
            userSession.start()
        }
    }
    
    public func sessionManagerCreated(unauthenticatedSession: UnauthenticatedSession) {
        self.unauthenticatedSession = unauthenticatedSession
        
        unauthenticatedSession.moc.performGroupedBlockAndWait {
            unauthenticatedSession.moc.add(self.dispatchGroup)
        }
    }
    
    public func sessionManagerWillStartMigratingLocalStore() {
        
    }
    
}
