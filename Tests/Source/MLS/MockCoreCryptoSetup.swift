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

import WireSyncEngine
import XCTest

@objc
class MockCoreCryptoSetup: NSObject {

    struct Calls {
        var setup = [CoreCryptoConfiguration]()
    }

    var calls = Calls()

    var mockCoreCrypto: CoreCryptoProtocol?
    var mockError: Error?

    func setup(with configuration: CoreCryptoConfiguration) throws -> CoreCryptoProtocol {
        calls.setup.append(configuration)

        if let mockError = mockError {
            throw mockError
        }

        return try XCTUnwrap(mockCoreCrypto, "return value not mocked")
    }

}

extension MockCoreCryptoSetup {
    static var `default`: MockCoreCryptoSetup {
        let coreCryptoSetup = MockCoreCryptoSetup()
        coreCryptoSetup.mockCoreCrypto = MockCoreCrypto()
        return coreCryptoSetup
    }
}
