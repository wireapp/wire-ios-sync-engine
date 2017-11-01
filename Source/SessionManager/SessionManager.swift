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
import avs
import WireTransport
import WireUtilities


private let log = ZMSLog(tag: "SessionManager")
public typealias LaunchOptions = [UIApplicationLaunchOptionsKey : Any]


@objc public protocol SessionManagerDelegate : class {
    func sessionManagerCreated(userSession : ZMUserSession)
    func sessionManagerDidFailToLogin(account: Account?, error : Error)
    func sessionManagerWillLogout(error : Error?, userSessionCanBeTornDown: @escaping () -> Void)
    func sessionManagerWillOpenAccount(_ account: Account, userSessionCanBeTornDown: @escaping () -> Void)
    func sessionManagerWillStartMigratingLocalStore()
    func sessionManagerDidBlacklistCurrentVersion()
}

public protocol LocalNotificationResponder : class {
    func processLocal(_ notification: ZMLocalNotification, forSession session: ZMUserSession)
}

/// The `SessionManager` class handles the creation of `ZMUserSession` and `UnauthenticatedSession`
/// objects, the handover between them as well as account switching.
///
/// There are multiple things neccessary in order to store (and switch between) multiple accounts on one device, a couple of them are:
/// 1. The folder structure in the app sandbox has to be modeled in a way in which files can be associated with a single account.
/// 2. The login flow should not rely on any persistent state (e.g. no database has to be created on disk before being logged in).
/// 3. There has to be a persistence layer storing information about accounts and the currently selected / active account.
/// 
/// The wire account database and a couple of other related files are stored in the shared container in a folder named by the accounts
/// `remoteIdentifier`. All information about different accounts on a device are stored by the `AccountManager` (see the documentation
/// of that class for more information). The `SessionManager`s main responsibility at the moment is checking whether there is a selected 
/// `Account` or not, and creating an `UnauthenticatedSession` or `ZMUserSession` accordingly. An `UnauthenticatedSession` is used
/// to create requests to either log in existing users or to register new users. It uses its own `UnauthenticatedOperationLoop`, 
/// which is a stripped down version of the regular `ZMOperationLoop`. This unauthenticated operation loop only uses a small subset
/// of transcoders needed to perform the login / registration (and related phone number verification) requests. For more information
/// see `UnauthenticatedOperationLoop`.
///
/// The result of using an `UnauthenticatedSession` is retrieving a remoteIdentifier of a logged in user, as well as a valid cookie.
/// Once those became available, the session will notify the session manager, which in turn will create a regular `ZMUserSession`.
/// For more information about the cookie retrieval consult the documentation in `UnauthenticatedSession`.
///
/// The flow creating either an `UnauthenticatedSession` or `ZMUserSession` after creating an instance of `SessionManager` 
/// is depicted on a high level in the following diagram:
///
///
/// +-----------------------------------------+
/// |         `SessionManager.init`           |
/// +-----------------------------------------+
///
///                    +
///                    |
///                    |
///                    v
///
/// +-----------------------------------------+        YES           Load the selected Account and its
/// | Is there a stored and selected Account? |   +------------->    cookie from disk.
/// +-----------------------------------------+                      Create a `ZMUserSession` using the cookie.
///
///                    +
///                    |
///                    | NO
///                    |
///                    v
///
/// +------------------+---------------------+
/// | Check if there is a database present   |        YES           Open the existing database, retrieve the user identifier,
/// | in the legacy directory (not keyed by  |  +-------------->    create an account with it and select it. Migrate the existing
/// | the users remoteIdentifier)?           |                      cookie for that account and start at the top again.
/// +----------------------------------------+
///
///                    +
///                    |
///                    | NO
///                    |
///                    v
///
/// +------------------+---------------------+
/// | Create a `UnauthenticatedSession` to   |
/// | start the registration or login flow.  |
/// +----------------------------------------+
///


@objc public class SessionManager : NSObject {

    /// Maximum number of accounts which can be logged in simultanously
    public static let maxNumberAccounts = 3
    
    public let appVersion: String
    var isAppVersionBlacklisted = false
    public weak var delegate: SessionManagerDelegate? = nil
    public weak var localNotificationResponder: LocalNotificationResponder?
    public let accountManager: AccountManager
    public fileprivate(set) var activeUserSession: ZMUserSession?

    public fileprivate(set) var backgroundUserSessions: [UUID: ZMUserSession] = [:]
    public fileprivate(set) var unauthenticatedSession: UnauthenticatedSession?
    public weak var requestToOpenViewDelegate: ZMRequestsToOpenViewsDelegate?
    public let groupQueue: ZMSGroupQueue = DispatchGroupQueue(queue: .main)
    
    let application: ZMApplication
    var postLoginAuthenticationToken: Any?
    var preLoginAuthenticationToken: Any?
    var blacklistVerificator: ZMBlacklistVerificator?
    let reachability: ReachabilityProvider & ReachabilityTearDown
    let pushDispatcher: PushDispatcher
    
    internal var authenticatedSessionFactory: AuthenticatedSessionFactory
    internal let unauthenticatedSessionFactory: UnauthenticatedSessionFactory
    
    fileprivate let sessionLoadingQueue : DispatchQueue = DispatchQueue(label: "sessionLoadingQueue")
    
    fileprivate let sharedContainerURL: URL
    fileprivate let dispatchGroup: ZMSDispatchGroup?
    fileprivate var accountTokens : [UUID : [Any]] = [:]
    fileprivate var memoryWarningObserver: NSObjectProtocol?
    
    private static var token: Any?
    
    /// The entry point for SessionManager; call this instead of the initializers.
    ///
    public static func create(
        appVersion: String,
        mediaManager: AVSMediaManager,
        analytics: AnalyticsType?,
        delegate: SessionManagerDelegate?,
        application: ZMApplication,
        launchOptions: LaunchOptions,
        blacklistDownloadInterval : TimeInterval,
        completion: @escaping (SessionManager) -> Void
        ) {
        
        token = FileManager.default.executeWhenFileSystemIsAccessible {
            completion(SessionManager(
                appVersion: appVersion,
                mediaManager: mediaManager,
                analytics: analytics,
                delegate: delegate,
                application: application,
                launchOptions: launchOptions,
                blacklistDownloadInterval: blacklistDownloadInterval
            ))
            
            token = nil
        }
    }
    
    public override init() {
        fatal("init() not implemented")
    }
    
    private convenience init(
        appVersion: String,
        mediaManager: AVSMediaManager,
        analytics: AnalyticsType?,
        delegate: SessionManagerDelegate?,
        application: ZMApplication,
        launchOptions: LaunchOptions,
        blacklistDownloadInterval : TimeInterval
        ) {
        
        ZMBackendEnvironment.setupEnvironments()
        let environment = ZMBackendEnvironment(userDefaults: .standard)
        let group = ZMSDispatchGroup(dispatchGroup: DispatchGroup(), label: "Session manager reachability")!
        let flowManager = FlowManager(mediaManager: mediaManager)

        let serverNames = [environment.backendURL, environment.backendWSURL].flatMap{ $0.host }
        let reachability = ZMReachability(serverNames: serverNames, group: group)
        let unauthenticatedSessionFactory = UnauthenticatedSessionFactory(environment: environment, reachability: reachability)
        let authenticatedSessionFactory = AuthenticatedSessionFactory(
            appVersion: appVersion,
            apnsEnvironment: nil,
            application: application,
            mediaManager: mediaManager,
            flowManager: flowManager,
            environment: environment,
            reachability: reachability,
            analytics: analytics
          )

        self.init(
            appVersion: appVersion,
            authenticatedSessionFactory: authenticatedSessionFactory,
            unauthenticatedSessionFactory: unauthenticatedSessionFactory,
            reachability: reachability,
            delegate: delegate,
            application: application,
            launchOptions: launchOptions
        )
        
        self.blacklistVerificator = ZMBlacklistVerificator(checkInterval: blacklistDownloadInterval,
                                                           version: appVersion,
                                                           working: nil,
                                                           application: application,
                                                           blacklistCallback:
            { [weak self] (blacklisted) in
                guard let `self` = self, !self.isAppVersionBlacklisted else { return }
                
                if blacklisted {
                    self.isAppVersionBlacklisted = true
                    self.delegate?.sessionManagerDidBlacklistCurrentVersion()
                }
        })
     
        self.memoryWarningObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.UIApplicationDidReceiveMemoryWarning,
                                                                            object: nil,
                                                                            queue: nil,
                                                                            using: {[weak self] _ in
            guard let `self` = self else {
                return
            }
            log.debug("Received memory warning, tearing down background user sessions.")
            self.tearDownAllBackgroundSessions()
        })
        
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground(_:)), name: .UIApplicationWillEnterForeground, object: nil)
    }

    init(
        appVersion: String,
        authenticatedSessionFactory: AuthenticatedSessionFactory,
        unauthenticatedSessionFactory: UnauthenticatedSessionFactory,
        reachability: ReachabilityProvider & ReachabilityTearDown,
        delegate: SessionManagerDelegate?,
        application: ZMApplication,
        launchOptions: LaunchOptions,
        dispatchGroup: ZMSDispatchGroup? = nil
        ) {

        SessionManager.enableLogsByEnvironmentVariable()
        self.appVersion = appVersion
        self.application = application
        self.delegate = delegate
        self.dispatchGroup = dispatchGroup

        guard let sharedContainerURL = Bundle.main.appGroupIdentifier.map(FileManager.sharedContainerDirectory) else {
            preconditionFailure("Unable to get shared container URL")
        }

        self.sharedContainerURL = sharedContainerURL
        self.accountManager = AccountManager(sharedDirectory: sharedContainerURL)
        
        log.debug("Starting the session manager:")
        
        if self.accountManager.accounts.count > 0 {
            log.debug("Known accounts:")
            self.accountManager.accounts.forEach { account in
                log.debug("\(account.userName) -- \(account.userIdentifier) -- \(account.teamName ?? "no team")")
            }
            
            if let selectedAccount = accountManager.selectedAccount {
                log.debug("Default account: \(selectedAccount.userIdentifier)")
            }
        }
        else {
            log.debug("No known accounts.")
        }
        
        self.authenticatedSessionFactory = authenticatedSessionFactory
        self.unauthenticatedSessionFactory = unauthenticatedSessionFactory
        self.reachability = reachability
        
        // we must set these before initializing the PushDispatcher b/c if the app
        // received a push from terminated state, it requires these properties to be
        // non nil in order to process the notification
        BackgroundActivityFactory.sharedInstance().application = UIApplication.shared
        BackgroundActivityFactory.sharedInstance().mainGroupQueue = groupQueue
        self.pushDispatcher = PushDispatcher()

        super.init()
        
        self.pushDispatcher.fallbackClient = self
        
        postLoginAuthenticationToken = PostLoginAuthenticationNotification.addObserver(self, queue: self.groupQueue)
        
        if let account = accountManager.selectedAccount {
            selectInitialAccount(account, launchOptions: launchOptions)
        } else {
            // We do not have an account, this means we are either dealing with a fresh install,
            // or an update from a previous version and need to store the initial Account.
            // In order to do so we open the old database and get the user identifier.
            LocalStoreProvider.fetchUserIDFromLegacyStore(
                in: sharedContainerURL,
                migration: { [weak self] in self?.delegate?.sessionManagerWillStartMigratingLocalStore() },
                completion: { [weak self] identifier in
                    guard let `self` = self else { return }
                    identifier.apply(self.migrateAccount)
                    
                    self.selectInitialAccount(self.accountManager.selectedAccount, launchOptions: launchOptions)
            })
        }
    }

    /// Creates an account with the given identifier and migrates its cookie storage.
    private func migrateAccount(with identifier: UUID) {
        let account = Account(userName: "", userIdentifier: identifier)
        accountManager.addAndSelect(account)
        let migrator = ZMPersistentCookieStorageMigrator(userIdentifier: identifier, serverName: authenticatedSessionFactory.environment.backendURL.host!)
        _ = migrator.createStoreMigratingLegacyStoreIfNeeded()
    }

    private func selectInitialAccount(_ account: Account?, launchOptions: LaunchOptions) {
        loadSession(for: account) { [weak self] session in
            guard let `self` = self else { return }
            self.updateCurrentAccount(in: session.managedObjectContext)
            session.application(self.application, didFinishLaunchingWithOptions: launchOptions)
            (launchOptions[.url] as? URL).apply(session.didLaunch)
        }
    }
    
    /// Select the account to be the active account.
    /// - completion: runs when the user session was loaded
    /// - tearDownCompletion: runs when the UI no longer holds any references to the previous user session.
    public func select(_ account: Account, completion: ((ZMUserSession)->())? = nil, tearDownCompletion: (() -> Void)? = nil) {
        delegate?.sessionManagerWillOpenAccount(account, userSessionCanBeTornDown: { [weak self] in
            self?.activeUserSession = nil
            tearDownCompletion?()
            self?.loadSession(for: account) { [weak self] session in
                self?.accountManager.select(account)
                completion?(session)
            }
        })
    }
    
    public func addAccount() {
        logoutCurrentSession(deleteCookie: false, error: NSError.userSessionErrorWith(.addAccountRequested, userInfo: nil))
    }
    
    public func delete(account: Account) {
        log.debug("Deleting account \(account.userIdentifier)...")
        if accountManager.selectedAccount != account {
            // Deleted an account associated with a background session
            self.tearDownBackgroundSession(for: account.userIdentifier)
            self.deleteAccountData(for: account)
        } else if let secondAccount = accountManager.accounts.first(where: { $0.userIdentifier != account.userIdentifier }) {
            // Deleted the active account but we can switch to another account
            select(secondAccount, tearDownCompletion: { [weak self] in
                self?.tearDownBackgroundSession(for: account.userIdentifier)
                self?.deleteAccountData(for: account)
            })
        } else {
            // Deleted the active account and there's not other account we can switch to
            logoutCurrentSession(deleteCookie: true, deleteAccount:true, error: NSError.userSessionErrorWith(.addAccountRequested, userInfo: nil))
        }
    }
    
    public func logoutCurrentSession(deleteCookie: Bool = true) {
        logoutCurrentSession(deleteCookie: deleteCookie, error: nil)
    }
    
    fileprivate func logoutCurrentSession(deleteCookie: Bool = true, deleteAccount: Bool = false, error : Error?) {
        guard let currentSession = activeUserSession, let account = accountManager.selectedAccount else {
            return
        }
    
        backgroundUserSessions[account.userIdentifier] = nil
        tearDownObservers(account: account.userIdentifier)
        self.createUnauthenticatedSession()
        
        delegate?.sessionManagerWillLogout(error: error, userSessionCanBeTornDown: { [weak self] in
            currentSession.closeAndDeleteCookie(deleteCookie)
            self?.activeUserSession = nil
            
            if deleteAccount {
                self?.deleteAccountData(for: account)
            }
        })
    }

    /// Loads a session for a given account.
    internal func loadSession(for selectedAccount: Account?, completion: @escaping (ZMUserSession) -> Void) {
        guard let account = selectedAccount, account.isAuthenticated else {
            createUnauthenticatedSession()
            delegate?.sessionManagerDidFailToLogin(account: selectedAccount, error: NSError.userSessionErrorWith(.accessTokenExpired, userInfo: nil))
            return
        }

        self.activateSession(for: account) { session in
            self.registerSessionForRemoteNotificationsIfNeeded(session)
            completion(session)
        }
    }

    public func deleteAccountData(for account: Account) {
        log.debug("Deleting the data for \(account.userName) -- \(account.userIdentifier)")
        
        account.cookieStorage().deleteKeychainItems()
        
        let accountID = account.userIdentifier
        self.accountManager.remove(account)
        
        do {
            try FileManager.default.removeItem(at: StorageStack.accountFolder(accountIdentifier: accountID, applicationContainer: sharedContainerURL))
        }
        catch let error {
            log.error("Impossible to delete the acccount \(account): \(error)")
        }
    }
    
    fileprivate func activateSession(for account: Account, completion: @escaping (ZMUserSession) -> Void) {
        self.withSession(for: account) { session in
            self.activeUserSession = session
            
            log.debug("Activated ZMUserSession for account \(String(describing: account.userName)) — \(account.userIdentifier)")
            completion(session)
            self.notifyNewUserSessionCreated(session)
            self.delegate?.sessionManagerCreated(userSession: session)
        }
    }

    fileprivate func registerObservers(account: Account, session: ZMUserSession) {
        
        let selfUser = ZMUser.selfUser(inUserSession: session)
        let teamObserver = TeamChangeInfo.add(observer: self, for: nil, managedObjectContext: session.managedObjectContext)
        let selfObserver = UserChangeInfo.add(observer: self, forBareUser: selfUser!, managedObjectContext: session.managedObjectContext)
        let conversationListObserver = ConversationListChangeInfo.add(observer: self, for: ZMConversationList.conversations(inUserSession: session), userSession: session)
        let connectionRequestObserver = ConversationListChangeInfo.add(observer: self, for: ZMConversationList.pendingConnectionConversations(inUserSession: session), userSession: session)
        let unreadCountObserver = NotificationInContext.addObserver(name: .AccountUnreadCountDidChangeNotification,
                                                                    context: account)
        { [weak self] note in
            guard let account = note.context as? Account else { return }
            self?.accountManager.addOrUpdate(account)
        }
        accountTokens[account.userIdentifier] = [teamObserver,
                                                 selfObserver!,
                                                 conversationListObserver,
                                                 connectionRequestObserver,
                                                 unreadCountObserver
        ]
    }
    
    fileprivate func createUnauthenticatedSession() {
        log.debug("Creating unauthenticated session")
        self.unauthenticatedSession?.tearDown()
        let unauthenticatedSession = unauthenticatedSessionFactory.session(withDelegate: self)
        self.unauthenticatedSession = unauthenticatedSession
        self.preLoginAuthenticationToken = unauthenticatedSession.addAuthenticationObserver(self)
    }
    
    fileprivate func configure(session userSession: ZMUserSession, for account: Account) {
        userSession.requestToOpenViewDelegate = self
        userSession.sessionManager = self
        require(self.backgroundUserSessions[account.userIdentifier] == nil, "User session is already loaded")
        self.backgroundUserSessions[account.userIdentifier] = userSession
        pushDispatcher.add(client: userSession)
        userSession.callNotificationStyle = callNotificationStyle
        userSession.useConstantBitRateAudio = useConstantBitRateAudio

        registerObservers(account: account, session: userSession)
    }
    
    // Loads user session for @c account given and executes the @c action block.
    public func withSession(for account: Account, perform completion: @escaping (ZMUserSession)->()) {
        log.debug("Request to load session for \(account)")
        let group = self.dispatchGroup
        group?.enter()
        self.sessionLoadingQueue.serialAsync(do: { onWorkDone in

            if let session = self.backgroundUserSessions[account.userIdentifier] {
                log.debug("Session for \(account) is already loaded")
                completion(session)
                onWorkDone()
                group?.leave()
            }
            else {
                LocalStoreProvider.createStack(
                    applicationContainer: self.sharedContainerURL,
                    userIdentifier: account.userIdentifier,
                    dispatchGroup: self.dispatchGroup,
                    migration: { [weak self] in self?.delegate?.sessionManagerWillStartMigratingLocalStore() },
                    completion: { provider in
                        let userSession = self.startBackgroundSession(for: account, with: provider)
                        completion(userSession)
                        onWorkDone()
                        group?.leave()
                    }
                )
            }
        })
    }

    // Creates the user session for @c account given, calls @c completion when done.
    private func startBackgroundSession(for account: Account, with provider: LocalStoreProviderProtocol) -> ZMUserSession {
        guard let newSession = authenticatedSessionFactory.session(for: account, storeProvider: provider) else {
            preconditionFailure("Unable to create session for \(account)")
        }
        
        self.configure(session: newSession, for: account)

        log.debug("Created ZMUserSession for account \(String(describing: account.userName)) — \(account.userIdentifier)")
        
        return newSession
    }
    
    internal func tearDownBackgroundSession(for accountId: UUID) {
        guard let userSession = self.backgroundUserSessions[accountId] else {
            log.error("No session to tear down for \(accountId), known sessions: \(self.backgroundUserSessions)")
            return
        }
        userSession.closeAndDeleteCookie(false)
        self.tearDownObservers(account: accountId)
        self.backgroundUserSessions[accountId] = nil
    }
    
    // Tears down and releases all background user sessions.
    internal func tearDownAllBackgroundSessions() {
        self.backgroundUserSessions.forEach { (accountId, session) in
            if self.activeUserSession != session {
                self.tearDownBackgroundSession(for: accountId)
            }
        }
    }
    
    fileprivate func tearDownObservers(account: UUID) {
        accountTokens.removeValue(forKey: account)
    }

    deinit {
        blacklistVerificator?.teardown()
        activeUserSession?.tearDown()
        unauthenticatedSession?.tearDown()
        reachability.tearDown()
    }
    
    @objc public var isUserSessionActive: Bool {
        return activeUserSession != nil
    }

    func updateProfileImage(imageData: Data) {
        activeUserSession?.enqueueChanges {
            self.activeUserSession?.profileUpdate.updateImage(imageData: imageData)
        }
    }

    public var callNotificationStyle: ZMCallNotificationStyle = .callKit {
        didSet {
            activeUserSession?.callNotificationStyle = callNotificationStyle
        }
    }
    
    public var useConstantBitRateAudio : Bool = false {
        didSet {
            activeUserSession?.useConstantBitRateAudio = useConstantBitRateAudio
        }
    }
}

// MARK: - TeamObserver

extension SessionManager {
    func updateCurrentAccount(in managedObjectContext: NSManagedObjectContext) {
        let selfUser = ZMUser.selfUser(in: managedObjectContext)
        if let account = accountManager.accounts.first(where: { $0.userIdentifier == selfUser.remoteIdentifier }) {
            if let name = selfUser.team?.name {
                account.teamName = name
            }
            if let userName = selfUser.name {
                account.userName = userName
            }
            if let userProfileImage = selfUser.imageSmallProfileData, !selfUser.isTeamMember {
                account.imageData = userProfileImage
            }
            else {
                account.imageData = nil
            }
            accountManager.addOrUpdate(account)
        }
    }
}

extension SessionManager: TeamObserver {
    public func teamDidChange(_ changeInfo: TeamChangeInfo) {
        let team = changeInfo.team
        guard let managedObjectContext = (team as? Team)?.managedObjectContext else {
            return
        }
        updateCurrentAccount(in: managedObjectContext)
    }
}

// MARK: - ZMUserObserver

extension SessionManager: ZMUserObserver {
    public func userDidChange(_ changeInfo: UserChangeInfo) {
        if changeInfo.teamsChanged || changeInfo.nameChanged || changeInfo.imageSmallProfileDataChanged {
            guard let user = changeInfo.user as? ZMUser,
                let managedObjectContext = user.managedObjectContext else {
                return
            }
            updateCurrentAccount(in: managedObjectContext)
        }
    }
}

// MARK: - UnauthenticatedSessionDelegate

extension SessionManager: UnauthenticatedSessionDelegate {

    public func session(session: UnauthenticatedSession, updatedCredentials credentials: ZMCredentials) -> Bool {
        guard let userSession = activeUserSession, let emailCredentials = credentials as? ZMEmailCredentials else { return false }
        
        userSession.setEmailCredentials(emailCredentials)
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
        return true
    }
    
    public func session(session: UnauthenticatedSession, updatedProfileImage imageData: Data) {
        updateProfileImage(imageData: imageData)
    }
    
    public func session(session: UnauthenticatedSession, createdAccount account: Account) {
        guard !(accountManager.accounts.count == SessionManager.maxNumberAccounts && accountManager.account(with: account.userIdentifier) == nil) else {
            session.authenticationStatus.notifyAuthenticationDidFail(NSError.userSessionErrorWith(.accountLimitReached, userInfo: nil))
            return
        }
        
        accountManager.addAndSelect(account)
        
        self.activateSession(for: account) { userSession in
            self.registerSessionForRemoteNotificationsIfNeeded(userSession)
            self.updateCurrentAccount(in: userSession.managedObjectContext)
            
            if let profileImageData = session.authenticationStatus.profileImageData {
                self.updateProfileImage(imageData: profileImageData)
            }
            
            let registered = session.authenticationStatus.completedRegistration
            let emailCredentials = session.authenticationStatus.emailCredentials()
            
            userSession.syncManagedObjectContext.performGroupedBlock {
                userSession.setEmailCredentials(emailCredentials)
                userSession.syncManagedObjectContext.registeredOnThisDevice = registered
                userSession.syncManagedObjectContext.registeredOnThisDeviceBeforeConversationInitialization = registered
                userSession.accountStatus.didCompleteLogin()
            }
        }
    }
}

// MARK: - ZMAuthenticationObserver

extension SessionManager: PostLoginAuthenticationObserver {

    @objc public func clientRegistrationDidSucceed(accountId: UUID) {
        log.debug("Tearing down unauthenticated session as reaction to successful client registration")
        unauthenticatedSession?.tearDown()
        unauthenticatedSession = nil
    }
    
    public func accountDeleted(accountId: UUID) {
        log.debug("\(accountId): Account was deleted")
        
        if let account = accountManager.account(with: accountId) {
            delete(account: account)
        }
    }
    
    public func clientRegistrationDidFail(_ error: NSError, accountId: UUID) {
        if unauthenticatedSession == nil {
            createUnauthenticatedSession()
        }
        
        delegate?.sessionManagerDidFailToLogin(account: accountManager.account(with: accountId), error: error)
    }
    
    public func authenticationInvalidated(_ error: NSError, accountId: UUID) {
        guard let userSessionErrorCode = ZMUserSessionErrorCode(rawValue: UInt(error.code)) else {
            return
        }
        
        log.debug("Authentication invalidated for \(accountId): \(error.code)")
        
        switch userSessionErrorCode {
        case .clientDeletedRemotely,
             .accessTokenExpired:
            
            if let session = self.backgroundUserSessions[accountId] {
                if session == activeUserSession {
                    logoutCurrentSession(deleteCookie: true, error: error)
                }
                else {
                    self.tearDownBackgroundSession(for: accountId)
                }
            }
            
        default:
            if unauthenticatedSession == nil {
                createUnauthenticatedSession()
            }
            
            delegate?.sessionManagerDidFailToLogin(account: accountManager.account(with: accountId), error: error)
        }
    }

}

// MARK: - Unread Conversation Count

extension SessionManager: ZMConversationListObserver {
    
    @objc fileprivate func applicationWillEnterForeground(_ note: Notification) {
        updateAllUnreadCounts()
    }
    
    public func conversationListDidChange(_ changeInfo: ConversationListChangeInfo) {
        
        // find which account/session the conversation list belongs to & update count
        guard let moc = changeInfo.conversationList.managedObjectContext else { return }
        
        for (accountId, session) in backgroundUserSessions where session.managedObjectContext == moc {
            updateUnreadCount(for: accountId)
        }
    }

    fileprivate func updateUnreadCount(for accountID: UUID) {
        guard
            let account = self.accountManager.account(with: accountID),
            let session = backgroundUserSessions[accountID]
        else {
            return
        }
        
        account.unreadConversationCount = Int(ZMConversation.unreadConversationCount(in: session.managedObjectContext))
    }
    
    fileprivate func updateAllUnreadCounts() {
        for accountID in backgroundUserSessions.keys {
            updateUnreadCount(for: accountID)
        }
    }
    
    func updateAppIconBadge() {
        DispatchQueue.main.async {
            for (accountID, session) in self.backgroundUserSessions {
                let account = self.accountManager.account(with: accountID)
                account?.unreadConversationCount = Int(ZMConversation.unreadConversationCount(in: session.managedObjectContext))
            }
            self.application.applicationIconBadgeNumber = self.accountManager.totalUnreadCount
        }
    }
}

extension SessionManager : PreLoginAuthenticationObserver {
    
    @objc public func authenticationDidSucceed() {
        if nil != activeUserSession {
            return RequestAvailableNotification.notifyNewRequestsAvailable(self)
        }
    }
    
    public func authenticationDidFail(_ error: NSError) {
        if unauthenticatedSession == nil {
            createUnauthenticatedSession()
        }
        
        delegate?.sessionManagerDidFailToLogin(account: nil, error: error)
    }
}

// MARK: - Session manager observer
@objc public protocol SessionManagerObserver: class {
    func sessionManagerCreated(userSession : ZMUserSession)
}

private let sessionManagerObserverNotificationName = Notification.Name(rawValue: "ZMSessionManagerObserverNotification")

extension SessionManager: NotificationContext {
    
    @objc public func addSessionManagerObserver(_ observer: SessionManagerObserver) -> Any {
        return NotificationInContext.addObserver(
            name: sessionManagerObserverNotificationName,
            context: self) { [weak observer] note in
                observer?.sessionManagerCreated(userSession: note.object as! ZMUserSession)
        }
    }
    
    fileprivate func notifyNewUserSessionCreated(_ userSession: ZMUserSession) {
        NotificationInContext(name: sessionManagerObserverNotificationName, context: self, object: userSession).post()
    }
}
