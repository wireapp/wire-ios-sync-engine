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
import WireDataModel

public final class PushTokenService: PushTokenServiceInterface {

    // MARK: - Properties

    public var localToken: PushToken? {
        return PushTokenStorage.pushToken
    }

    public var onTokenChange: ((PushToken?) -> Void)?
    public var onRegistrationComplete: (() -> Void)?
    public var onUnregistrationComplete: (() -> Void)?

    // MARK: - Life cycle

    public init() {}

    // MARK: - Methods

    public func storeLocalToken(_ token: PushToken?) {
        Logging.push.safePublic("setting local push token: \(token?.tokenType)")
        PushTokenStorage.pushToken = token
        onTokenChange?(token)
    }

    public func registerPushToken(
        _ token: PushToken,
        clientID: String,
        in context: NotificationContext
    ) async throws {
        Logging.push.safePublic("registering push token: \(token.tokenType)")

        var action = RegisterPushTokenAction(
            token: token,
            clientID: clientID
        )

        do {
            try await action.perform(in: context)
        } catch let error as RegisterPushTokenAction.Failure {
            Logging.push.safePublic("registering push token: \(token.tokenType), failed: \(error)")
            throw error
        }

        onRegistrationComplete?()
    }

    public func unregisterRemoteTokens(
        clientID: String,
        excluding excludedToken: PushToken? = nil,
        in context: NotificationContext
    ) async throws {
        Logging.push.safePublic("unregister remote tokens...")

        var getTokensAction = GetPushTokensAction(clientID: clientID)
        var remoteTokens = [PushToken]()

        do {
            remoteTokens = try await getTokensAction.perform(in: context)
        } catch let error as GetPushTokensAction.Failure {
            Logging.push.safePublic("unregister remote tokens, failed: \(error)")
            throw error
        }

        do {
            for remoteToken in remoteTokens where remoteToken != excludedToken {
                Logging.push.safePublic("unregister invalid token of type: \(remoteToken.tokenType)...")
                var removeAction = RemovePushTokenAction(deviceToken: remoteToken.deviceTokenString)
                try await removeAction.perform(in: context)
                Logging.push.safePublic("unregister invalid token of type: \(remoteToken.tokenType), success")
            }
        } catch let error as RemovePushTokenAction.Failure {
            Logging.push.safePublic("unregister remote tokens, failed: \(error)")
            throw error
        }

        onUnregistrationComplete?()
    }

}

// MARK: - Interface

public protocol PushTokenServiceInterface: AnyObject {

    var localToken: PushToken? { get }

    var onTokenChange: ((PushToken?) -> Void)? { get set }
    var onRegistrationComplete: (() -> Void)? { get set }
    var onUnregistrationComplete: (() -> Void)? { get set }

    func storeLocalToken(_ token: PushToken?)

    func registerPushToken(
        _ token: PushToken,
        clientID: String,
        in context: NotificationContext
    ) async throws

    func unregisterRemoteTokens(
        clientID: String,
        excluding token: PushToken?,
        in context: NotificationContext
    ) async throws

}

public extension PushTokenServiceInterface {

    func syncLocalTokenWithRemote(
        clientID: String,
        in context: NotificationContext
    ) async throws {
        guard let localToken = localToken else { return }

        try await registerPushToken(
            localToken,
            clientID: clientID,
            in: context
        )

        try await unregisterRemoteTokens(
            clientID: clientID,
            excluding: localToken,
            in: context
        )
    }

}

// MARK: - Helpers

extension PushToken.TokenType: SafeForLoggingStringConvertible {

    public var safeForLoggingDescription: String {
        switch self {
        case .standard:
            return "standard"

        case .voip:
            return "voip"
        }
    }

}

// MARK: - Async / Await

extension EntityAction {

    /// Perform the action with the given result handler.
    ///
    /// - Parameters:
    ///   - context the notification context in which to send the action's notification.
    ///   - resultHandler a closure to recieve the action's result.

    @available(*, renamed: "perform(in:)")
    mutating func perform(
        in context: NotificationContext,
        resultHandler: @escaping ResultHandler
    ) {
        self.resultHandler = resultHandler
        send(in: context)
    }

    /// Perform the action with the given result handler.
    ///
    /// - Parameters:
    ///   - context the notification context in which to send the action's notification.
    ///
    /// - Returns:
    ///   The result of the action.
    ///
    /// - Throws:
    ///   The action's error.

    mutating func perform(in context: NotificationContext) async throws -> Result {
        return try await withCheckedThrowingContinuation { continuation in
            perform(in: context, resultHandler: continuation.resume(with:))
        }
    }

}
