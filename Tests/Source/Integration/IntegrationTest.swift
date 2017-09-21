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

class AuthenticationObserver : NSObject, PreLoginAuthenticationObserver, PostLoginAuthenticationObserver {
    
    var onFailure : (() -> Void)?
    var onSuccess : (() -> Void)?
    
    var preLoginToken : Any?
    var postLoginToken : Any?
    
    init(unauthenticatedSession : UnauthenticatedSession, groupQueue: ZMSGroupQueue) {
        super.init()
        
        preLoginToken = unauthenticatedSession.addAuthenticationObserver(self)
        postLoginToken = PostLoginAuthenticationNotification.addObserver(self, queue: groupQueue)
    }
    
    func clientRegistrationDidSucceed(accountId: UUID) {
        onSuccess?()
    }
    
    func authenticationDidSucceed() {
        onSuccess?()
    }
    
    func clientRegistrationDidFail(_ error: NSError, accountId: UUID) {
        onFailure?()
    }
    
    func authenticationDidFail(_ error: NSError) {
        onFailure?()
    }
    
}

final class MockAuthenticatedSessionFactory: AuthenticatedSessionFactory {

    let transportSession: ZMTransportSession

    init(apnsEnvironment: ZMAPNSEnvironment?, application: ZMApplication, mediaManager: AVSMediaManager, flowManager: FlowManagerType, transportSession: ZMTransportSession, environment: ZMBackendEnvironment, reachability: ReachabilityProvider) {
        self.transportSession = transportSession
        super.init(
            appVersion: "0.0.0",
            apnsEnvironment: apnsEnvironment,
            application: application,
            mediaManager: mediaManager,
            flowManager: flowManager,
            environment: environment,
            reachability: reachability,
            analytics: nil
        )
    }

    override func session(for account: Account, storeProvider: LocalStoreProviderProtocol) -> ZMUserSession? {
        return ZMUserSession(
            mediaManager: mediaManager,
            flowManager: flowManager,
            analytics: analytics,
            transportSession: transportSession,
            apnsEnvironment: apnsEnvironment,
            application: application,
            appVersion: appVersion,
            storeProvider: storeProvider
        )
    }

}


final class MockUnauthenticatedSessionFactory: UnauthenticatedSessionFactory {

    let transportSession: UnauthenticatedTransportSessionProtocol
    
    init(transportSession: UnauthenticatedTransportSessionProtocol, environment: ZMBackendEnvironment, reachability: ReachabilityProvider) {
        self.transportSession = transportSession
        super.init(environment: environment, reachability: reachability)
    }

    override func session(withDelegate delegate: WireSyncEngine.UnauthenticatedSessionDelegate) -> UnauthenticatedSession {
        return UnauthenticatedSession(transportSession: transportSession, reachability: reachability, delegate: delegate)
    }

}


extension IntegrationTest {
    
    static let SelfUserEmail = "myself@user.example.com"
    static let SelfUserPassword = "fgf0934';$@#%"
    
    @objc
    func _setUp() {
        sharedContainerDirectory = Bundle.main.appGroupIdentifier.map(FileManager.sharedContainerDirectory)
        deleteSharedContainerContent()
        ZMPersistentCookieStorage.setDoNotPersistToKeychain(!useRealKeychain)
        StorageStack.shared.createStorageAsInMemory = useInMemoryStore
        
        application = ApplicationMock()
        mockTransportSession = MockTransportSession(dispatchGroup: self.dispatchGroup)
        mockTransportSession.cookieStorage = ZMPersistentCookieStorage(forServerName: "ztest.example.com", userIdentifier: currentUserIdentifier)
        WireCallCenterV3Factory.wireCallCenterClass = WireCallCenterV3IntegrationMock.self;
        mockTransportSession.cookieStorage.deleteKeychainItems()
                
        createSessionManager()
    }
    
    @objc
    func _tearDown() {
        sharedSearchDirectory?.tearDown()
        sharedSearchDirectory = nil
        userSession = nil
        userSession?.tearDown()
        unauthenticatedSession?.tearDown()
        unauthenticatedSession = nil
        mockTransportSession?.cleanUp()
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
        application = nil
        resetInMemoryDatabases()
        deleteSharedContainerContent()
        sharedContainerDirectory = nil
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
    }
    
    func resetInMemoryDatabases() {
        StorageStack.reset()
    }
    
    @objc
    func destroySessionManager() {
        userSession?.tearDown()
        userSession = nil
        unauthenticatedSession?.tearDown()
        unauthenticatedSession = nil
        sessionManager = nil
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }

    private func deleteSharedContainerContent() {
        try? FileManager.default.contentsOfDirectory(at: sharedContainerDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).forEach {
            try? FileManager.default.removeItem(at: $0)
        }
    }
    
    @objc
    func deleteAuthenticationCookie() {
        ZMPersistentCookieStorage.deleteAllKeychainItems()
        mockTransportSession.cookieStorage.deleteKeychainItems()
    }
    
    @objc
    func recreateSessionManager() {
        destroySharedSearchDirectory()
        destroySessionManager()
        createSessionManager()
    }
    
    @objc
    func recreateSessionManagerAndDeleteLocalData() {
        destroySharedSearchDirectory()
        destroySessionManager()
        destroyPersistentStore()
        deleteAuthenticationCookie()
        createSessionManager()
    }
    
    @objc
    func createSessionManager() {
        guard let mediaManager = mediaManager, let application = application, let transportSession = transportSession else { return XCTFail() }
        StorageStack.shared.createStorageAsInMemory = useInMemoryStore
        let environment = ZMBackendEnvironment(type: .staging)
        let reachability = TestReachability()
        let unauthenticatedSessionFactory = MockUnauthenticatedSessionFactory(transportSession: transportSession as! UnauthenticatedTransportSessionProtocol, environment: environment, reachability: reachability)
        let authenticatedSessionFactory = MockAuthenticatedSessionFactory(
            apnsEnvironment: apnsEnvironment,
            application: application,
            mediaManager: mediaManager,
            flowManager: FlowManagerMock(),
            transportSession: transportSession,
            environment: environment,
            reachability: reachability
        )

        sessionManager = SessionManager(
            appVersion: "0.0.0",
            authenticatedSessionFactory: authenticatedSessionFactory,
            unauthenticatedSessionFactory: unauthenticatedSessionFactory,
            reachability: reachability,
            delegate: self,
            application: application,
            launchOptions: [:],
            dispatchGroup: self.dispatchGroup
        )
        
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

    }
    
    @objc
    func createSharedSearchDirectory() {
        guard sharedSearchDirectory == nil else { return }
        guard let userSession = userSession else { XCTFail("Could not create shared SearchDirectory");  return }
        sharedSearchDirectory = SearchDirectory(userSession: userSession)
    }
    
    @objc
    func destroySharedSearchDirectory() {
        sharedSearchDirectory?.tearDown()
        sharedSearchDirectory = nil
    }
    
    @objc
    func destroyPersistentStore() {
        StorageStack.reset()
    }
    
    @objc
    func createSelfUserAndConversation() {
        
        mockTransportSession.performRemoteChanges({ session in
            let selfUser = session.insertSelfUser(withName: "The Self User")
            selfUser.email = IntegrationTest.SelfUserEmail
            selfUser.password = IntegrationTest.SelfUserPassword
            selfUser.identifier = self.currentUserIdentifier.transportString()
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
        
        mockTransportSession.performRemoteChanges({ session in
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
            
            let selfToUser1Conversation = session.insertOneOnOneConversation(withSelfUser: self.selfUser, otherUser:user1)
            selfToUser1Conversation.creator = self.selfUser
            selfToUser1Conversation.setValue("Connection conversation to user 1", forKey:"name")
            self.selfToUser1Conversation = selfToUser1Conversation
            
            let selfToUser2Conversation = session.insertOneOnOneConversation(withSelfUser: self.selfUser, otherUser:user2)
            selfToUser2Conversation.creator = user2

            selfToUser2Conversation.setValue("Connection conversation to user 2", forKey:"name")
            self.selfToUser2Conversation = selfToUser2Conversation
            
            let groupConversation = session.insertGroupConversation(withSelfUser:self.selfUser, otherUsers: [user1, user2, user3])
            groupConversation.creator = user3;
            groupConversation.changeName(by:self.selfUser, name:"Group conversation")
            self.groupConversation = groupConversation
            
            let connectionSelfToUser1 = session.insertConnection(withSelfUser:self.selfUser, to:user1)
            connectionSelfToUser1.status = "accepted"
            connectionSelfToUser1.lastUpdate = Date(timeIntervalSinceNow: -3)
            connectionSelfToUser1.conversation = selfToUser1Conversation
            self.connectionSelfToUser1 = connectionSelfToUser1
            
            let connectionSelfToUser2 = session.insertConnection(withSelfUser:self.selfUser, to:user2)
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
        let queue = DispatchGroupQueue(queue: .main)
        queue.add(self.dispatchGroup)
        var authenticationObserver : AuthenticationObserver? = AuthenticationObserver(unauthenticatedSession: unauthenticatedSession!, groupQueue: queue)
        var didSucceed = false
        
        authenticationObserver?.onSuccess = {
            didSucceed = true
        }
        
        authenticationObserver?.onFailure = {
            if !ignoreAuthenticationFailures {
                XCTFail("Failed to authenticate")
            }
        }
        
        unauthenticatedSession?.login(with: credentials)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        authenticationObserver = nil
        
        return didSucceed
    }


    @objc(prefetchRemoteClientByInsertingMessageInConversation:)
    func prefetchClientByInsertingMessage(in mockConversation: MockConversation) {
        guard let convo = conversation(for: mockConversation) else { return }
        userSession?.performChanges {
            convo.appendMessage(withText: "hum, t'es sûr?")
        }

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.2))
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
        mockTransportSession.performRemoteChanges({ session in
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
        
        mockTransportSession.performRemoteChanges({ session in
            let connection = session.insertConnection(withSelfUser:self.selfUser, to:mockUser)
            connection.message = "Hello, my friend."
            connection.status = status
            connection.lastUpdate = Date(timeIntervalSinceNow:-20000)
            
            let conversation = session.insertConversation(withSelfUser: self.selfUser, creator:mockUser, otherUsers:[], type:.invalid)
            connection.conversation = conversation
        })
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        return mockUser
    }
    
    @discardableResult
    @objc(createUserWithName:uuid:)
    func createUser(withName name: String, uuid: UUID) -> MockUser {
        var user : MockUser? = nil
        mockTransportSession.performRemoteChanges({ session in
            user = session.insertUser(withName: name)
            user?.identifier = uuid.transportString()
        })
        
        return user!
    }
        
}

extension IntegrationTest {
    @objc(remotelyAppendSelfConversationWithZMClearedForMockConversation:atTime:)
    func remotelyAppendSelfConversationWithZMCleared(for mockConversation: MockConversation, at time: Date) {
        let genericMessage = ZMGenericMessage(clearedTimestamp: time, ofConversationWithID: mockConversation.identifier, nonce: NSUUID.create().transportString())
        mockTransportSession.performRemoteChanges { session in
            self.selfConversation.insertClientMessage(from: self.selfUser, data: genericMessage.data())
        }
    }
    
    @objc(remotelyAppendSelfConversationWithZMLastReadForMockConversation:atTime:)
    func remotelyAppendSelfConversationWithZMLastRead(for mockConversation: MockConversation, at time: Date) {
        let genericMessage = ZMGenericMessage(lastRead: time, ofConversationWithID: mockConversation.identifier, nonce: NSUUID.create().transportString())
        mockTransportSession.performRemoteChanges { session in
            self.selfConversation.insertClientMessage(from: self.selfUser, data: genericMessage.data())
        }
    }
}

extension IntegrationTest : SessionManagerDelegate {
    
    public func sessionManagerCreated(userSession: ZMUserSession) {
        self.userSession = userSession
        
        userSession.syncManagedObjectContext.performGroupedBlock {
            userSession.syncManagedObjectContext.setPersistentStoreMetadata(NSNumber(value: true), key: ZMSkipHotfix)
        }
    }
    
    public func sessionManagerCreated(unauthenticatedSession: UnauthenticatedSession) {
        self.unauthenticatedSession = unauthenticatedSession
        unauthenticatedSession.groupQueue.add(self.dispatchGroup)
    }
    
    public func sessionManagerWillStartMigratingLocalStore() {
        // no-op
    }

    public func sessionManagerDidLogout(error: Error?) {
        guard let error = error as NSError? else { return }
        
        guard let userSessionErrorCode = ZMUserSessionErrorCode(rawValue: UInt(error.code)) else {
            return
        }
        
        switch userSessionErrorCode {
        case .clientDeletedRemotely,
             .accessTokenExpired,
             .accountDeleted:
            self.userSession = nil
        default:
            break
        }
    }

    public func sessionManagerDidBlacklistCurrentVersion() {
        // no-op
    }
    
    public func sessionManagerWillOpenAccount(_ account: Account) {
        // no-op
    }
    
}
