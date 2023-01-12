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

protocol APIMigration {
    func perform(with session: ZMUserSession, clientID: String) async throws
    var version: APIVersion { get }
}

class APIMigrationManager {
    let migrations: [APIMigration]
    var previousAPIVersion: APIVersion?

    private let logger = Logging.apiMigration

    init(migrations: [APIMigration]) {
        self.migrations = migrations
    }

    func isMigration(to apiVersion: APIVersion, neededForSessions sessions: [ZMUserSession]) -> Bool {
        return sessions.contains {
            isMigration(to: apiVersion, neededForSession: $0)
        }
    }

    private func isMigration(to apiVersion: APIVersion, neededForSession session: ZMUserSession) -> Bool {
        guard let clientID = clientId(for: session) else {
            return false
        }

        return !migrations(
            between: lastUsedAPIVersion(for: clientID),
            and: apiVersion
        ).isEmpty
    }

    func migrateIfNeeded(sessions: [ZMUserSession], to apiVersion: APIVersion) async {

        for session in sessions {

            guard let clientID = clientId(for: session) else {
                continue
            }

            await migrate(
                session: session,
                clientID: clientID,
                from: lastUsedAPIVersion(for: clientID),
                to: apiVersion
            )

            persistLastUsedAPIVersion(for: session, apiVersion: apiVersion)
        }
    }

    private func migrate(
        session: ZMUserSession,
        clientID: String,
        from lastVersion: APIVersion,
        to currentVersion: APIVersion
    ) async {
        guard lastVersion < currentVersion else {
            return
        }

        logger.info("starting API migrations from api v\(lastVersion.rawValue) to v\(currentVersion.rawValue) for session with clientID \(String(describing: clientID))")

        for migration in migrations(between: lastVersion, and: currentVersion) {
            do {
                logger.info("starting migration (\(String(describing: migration))) for api v\(migration.version.rawValue)")
                try await migration.perform(with: session, clientID: clientID)
            } catch {
                logger.warn("migration (\(String(describing: migration))) failed for session with clientID (\(String(describing: clientID)). error: \(String(describing: error))")
            }
        }
    }

    func persistLastUsedAPIVersion(for sessions: [ZMUserSession], apiVersion: APIVersion) {
        sessions.forEach {
            persistLastUsedAPIVersion(for: $0, apiVersion: apiVersion)
        }
    }

    // MARK: - Helpers

    func lastUsedAPIVersion(for clientID: String) -> APIVersion {
        return userDefaults(for: clientID).lastUsedAPIVersion ?? previousAPIVersion ?? .v2
    }

    func persistLastUsedAPIVersion(for session: ZMUserSession, apiVersion: APIVersion) {
        guard let clientID = clientId(for: session) else {
            return
        }

        logger.info("persisting last used API version (v\(apiVersion.rawValue)) for client (\(clientID))")
        userDefaults(for: clientID).lastUsedAPIVersion = apiVersion
    }

    private func userDefaults(for clientID: String) -> UserDefaults {
        return UserDefaults(suiteName: "com.wire.apiversion.\(clientID)")!
    }

    private func clientId(for session: ZMUserSession) -> String? {
        var clientID: String?

        session.viewContext.performAndWait {
            clientID = session.selfUserClient?.remoteIdentifier
        }

        return clientID
    }

    private func migrations(between lVersion: APIVersion, and rVersion: APIVersion) -> [APIMigration] {
        guard lVersion < rVersion else { return [] }

        return migrations.filter {
            (lVersion.rawValue+1..<rVersion.rawValue+1).contains($0.version.rawValue)
        }
    }

    // MARK: - Tests

    static func removeDefaults(for clientID: String) {
        UserDefaults.standard.removePersistentDomain(forName: "com.wire.apiversion.\(clientID)")
    }

}

private extension UserDefaults {

    private var lastUsedAPIVersionKey: String { "LastUsedAPIVersionKey" }

    var lastUsedAPIVersion: APIVersion? {

        get {
            guard let value = object(forKey: lastUsedAPIVersionKey) as? Int32 else {
                return nil
            }

            return APIVersion(rawValue: value)
        }

        set {
            set(newValue?.rawValue, forKey: lastUsedAPIVersionKey)
        }
    }
}
