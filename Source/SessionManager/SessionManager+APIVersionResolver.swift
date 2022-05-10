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

// TODO: David - move to Logging extension in RS
private let log = ZMSLog(tag: "APIVersion")

extension SessionManager: APIVersionResolverDelegate {

    public func resolveAPIVersion() {
        if apiVersionResolver == nil {
            apiVersionResolver = createAPIVersionResolver()
        }

        apiVersionResolver!.resolveAPIVersion()
    }

    func createAPIVersionResolver() -> APIVersionResolver {
        let transportSession = UnauthenticatedTransportSession(
            environment: environment,
            reachability: reachability,
            applicationVersion: appVersion
        )

        let apiVersionResolver = APIVersionResolver(transportSession: transportSession)
        apiVersionResolver.delegate = self
        return apiVersionResolver
    }

    func apiVersionResolverFailedToResolveVersion(reason: BlacklistReason) {
        delegate?.sessionManagerDidBlacklistCurrentVersion(reason: reason)
    }

    func apiVersionResolverDetectedFederationHasBeenEnabled() {
        delegate?.sessionManagerWillMigrateAccount { [weak self] in
            self?.migrateAllAccountsForFederation()
        }
    }

    private func migrateAllAccountsForFederation() {
        let accountMigrationGroup = DispatchGroup()

        activeUserSession = nil
        accountManager.accounts.forEach { account in
            accountMigrationGroup.enter()
            // 1. Tear down the user sessions
            tearDownBackgroundSession(for: account.userIdentifier)

            // 2. do the migration
            CoreDataStack.migrateLocalStorage(
                accountIdentifier: account.userIdentifier,
                applicationContainer: sharedContainerURL,
                dispatchGroup: dispatchGroup,
                migration: { context in
                    // TODO: extend the context to perform users and conversations migration
                },
                completion: { result in
                    if case let .failure(error) = result {
                        log.error("Failed to migrate account: \(error)")
                    }

                    accountMigrationGroup.leave()
                }
            )
        }

        accountMigrationGroup.wait()

        // 4. Reload sessions
        accountManager.accounts.forEach { account in
            if account == accountManager.selectedAccount {
                // When completed, this should trigger an AppState change through the SessionManagerDelegate
                loadSession(for: account, completion: { _ in })
            } else {
                withSession(for: account, perform: { _ in })
            }
        }
    }

}
