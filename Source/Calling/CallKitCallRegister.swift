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

class CallKitCallRegister {

    // MARK: - Properties

    private var storage = [UUID: CallKitCall]()

    // MARK: - Persistence

    private func persistStorage() {
        VoIPPushHelper.knownCallHandles = storage.values.map {
            $0.handle.encodedString
        }
    }

    // MARK: - Registration

    func registerNewCall(with handle: CallHandle) -> CallKitCall {
        defer { persistStorage() }
        let call = CallKitCall(id: UUID(), handle: handle)
        storage[call.id] = call
        return call
    }

    func unregisterCall(_ call: CallKitCall) {
        defer { persistStorage() }
        storage.removeValue(forKey: call.id)
    }

    func reset() {
        defer { persistStorage() }
        storage.removeAll()
    }

    // MARK: - Lookup

    func callExists(id: UUID) -> Bool {
        return lookupCall(id: id) != nil
    }

    func lookupCall(id: UUID) -> CallKitCall? {
        return storage[id]
    }

    func callExists(handle: CallHandle) -> Bool {
        return lookupCall(handle: handle) != nil
    }

    func lookupCall(handle: CallHandle) -> CallKitCall? {
        return storage.values.first { $0.handle == handle }
    }

}
