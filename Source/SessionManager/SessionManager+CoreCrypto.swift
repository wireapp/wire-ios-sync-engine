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

public protocol CoreCryptoConfigurationProvider: AnyObject {
    var coreCryptoConfiguration: CoreCryptoConfiguration? { get }
}

public protocol CoreCryptoProvider: AnyObject {
    var coreCrypto: CoreCryptoProtocol? { get set }
}

extension SessionManager: CoreCryptoProvider {
    public var coreCrypto: CoreCryptoProtocol? {
        get {
            return activeUserSession?.coreCrypto
        }
        set {
            activeUserSession?.coreCrypto = newValue
        }
    }
}

extension SessionManager: CoreCryptoConfigurationProvider {
    public var coreCryptoConfiguration: CoreCryptoConfiguration? {
        return activeUserSession?.coreCryptoConfiguration
    }
}
