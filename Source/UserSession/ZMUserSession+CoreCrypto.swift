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
import WireRequestStrategy

extension ZMUserSession {
    var coreCryptoConfiguration: CoreCryptoConfiguration? {
        let user = ZMUser.selfUser(in: managedObjectContext)

        guard
            let qualifiedClientId = MLSQualifiedClientID(user: user).qualifiedClientId
        else {
            return nil
        }

        let accountDirectory = CoreDataStack.accountDataFolder(
            accountIdentifier: user.remoteIdentifier,
            applicationContainer: sharedContainerURL
        )
        FileManager.default.createAndProtectDirectory(at: accountDirectory)
        let mlsDirectory = accountDirectory.appendingMLSFolder()

        do {
            let key = try CoreCryptoKeyProvider.coreCryptoKey()
            return CoreCryptoConfiguration(
                path: mlsDirectory.path,
                key: key.base64EncodedString(),
                clientId: qualifiedClientId
            )
        } catch {
            // TODO: Error handling
            fatalError(String(describing: error))
        }
    }

    var isMLSControllerInitialized: Bool {
        var result = false

        syncContext.performAndWait {
            result = syncContext.isMLSControllerInitialized
        }

        return result
    }

    func initializeMLSController(coreCrypto: CoreCryptoProtocol) {
        syncContext.performAndWait {
            syncContext.initializeMLSController(
                coreCrypto: coreCrypto,
                conversationEventProcessor: ConversationEventProcessor(context: syncContext)
            )
        }
    }

}

extension URL {
    func appendingMLSFolder() -> URL {
        return appendingPathComponent("mls")
    }
}
