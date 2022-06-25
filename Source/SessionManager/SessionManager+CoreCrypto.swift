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

public struct CoreCryptoConfiguration {
    public let path: String
    public let key: String
    public let clientId: String
}

public protocol CoreCryptoSetupDelegate: AnyObject {
    func setUpCoreCryptoIfNeeded()
}

public protocol CoreCryptoConfigurationProvider: AnyObject {
    var coreCryptoConfiguration: CoreCryptoConfiguration? { get }
}

public protocol CoreCryptoProvider: AnyObject {
    var coreCrypto: CoreCryptoProtocol? { get set }
}

extension SessionManager: CoreCryptoProvider {
    public var coreCrypto: CoreCryptoProtocol? {
        get {
            guard let context = activeUserSession?.syncContext else { return nil }
            return context.coreCrypto
        }
        set {
            guard let context = activeUserSession?.syncContext else { return }
            context.coreCrypto = newValue
        }
    }
}

extension NSManagedObjectContext {
    private static let coreCrytpoUserInfoKey = "CoreCryptoKey"

    public var coreCrypto: CoreCryptoProtocol? {
        get {
            userInfo[Self.coreCrytpoUserInfoKey] as? CoreCryptoProtocol
        }
        set {
            userInfo[Self.coreCrytpoUserInfoKey] = newValue
        }
    }
}

extension SessionManager: CoreCryptoConfigurationProvider {
    public var coreCryptoConfiguration: CoreCryptoConfiguration? {
        guard let userSession = activeUserSession else { return nil }

        let context = userSession.syncContext
        let user = ZMUser.selfUser(in: context)

        guard let clientId = user.selfClient()?.remoteIdentifier else { return nil }

        let accountDirectory = CoreDataStack.accountDataFolder(
            accountIdentifier: user.remoteIdentifier,
            applicationContainer: userSession.sharedContainerURL
        )
        FileManager.default.createAndProtectDirectory(at: accountDirectory)
        let mlsDirectory = accountDirectory.appendingMLSFolder()

        do {
            let key = try CoreCryptoKeyProvider.coreCryptoKey()
            return CoreCryptoConfiguration(
                path: mlsDirectory.path,
                key: key.base64EncodedString(),
                clientId: clientId
            )
        } catch {
            fatalError(String(describing: error))
        }
    }
}

extension URL {
    func appendingMLSFolder() -> URL {
        return appendingPathComponent("mls")
    }
}
