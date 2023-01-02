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

    private let logger = Logging.apiMigration

    init(migrations: [APIMigration]) {
        self.migrations = migrations
    }

    func migrate(
        session: ZMUserSession,
        clientID: String,
        from lastVersion: APIVersion,
        to currentVersion: APIVersion
    ) async {
        guard lastVersion.rawValue < currentVersion.rawValue else {
            return
        }

        logger.info("starting API migrations from api v\(lastVersion.rawValue) to v\(currentVersion.rawValue) for session with clientID \(String(describing: clientID))")

        for migration in migrations.filter({
            (lastVersion.rawValue+1..<currentVersion.rawValue+1).contains($0.version.rawValue)
        }) {
            do {
                logger.info("starting migration (\(String(describing: migration))) for api v\(migration.version.rawValue)")
                try await migration.perform(with: session, clientID: clientID)
            } catch {
                logger.warn("migration (\(String(describing: migration))) failed for session with clientID (\(String(describing: clientID)). error: \(String(describing: error))")
            }
        }
    }

    func migrateIfNeeded(sessions: [ZMUserSession], to apiVersion: APIVersion) async {

        for session in sessions {

            guard let clientID = clientId(for: session) else {
                return
            }

            // TODO: David
            // What if there is no last used API version, but we still need the migrations to be done?
            // e.g: client with active session installs latest version of the app,
            // has no last used version saved.
            // previous version was v2, and current version is v3.
            // we need the client to migrate the access token,
            // but, since no last used version is recorded, we won't perform the migration.
            //
            // solution: maybe we can persist the last used version before resolving the api version?
            // -> note that we may need to do that for all sessions
            guard let lastUsedVersion = lastUsedAPIVersion(for: clientID) else {
                persistLastUsedAPIVersion(for: clientID, apiVersion: apiVersion)
                return
            }

            await migrate(
                session: session,
                clientID: clientID,
                from: lastUsedVersion,
                to: apiVersion
            )
            persistLastUsedAPIVersion(for: clientID, apiVersion: apiVersion)
        }
    }

    func lastUsedAPIVersion(for clientID: String) -> APIVersion? {
        return userDefaults(for: clientID).lastUsedAPIVersion
    }

    func persistLastUsedAPIVersion(for clientID: String, apiVersion: APIVersion) {
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

    // MARK: - Tests

    func resetLastUsedAPIVersion(for clientID: String) {
        userDefaults(for: clientID).lastUsedAPIVersion = nil
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
