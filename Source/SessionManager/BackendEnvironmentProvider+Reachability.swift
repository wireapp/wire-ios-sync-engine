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

public typealias Reachability = ReachabilityProvider & TearDownCapable

extension BackendEnvironmentProvider {

    var reachability: ZMReachability {

        let group = ZMSDispatchGroup(dispatchGroup: DispatchGroup(), label: "Reachability")!

        let serverNames: [String]
        if let proxy = self.proxy {
            serverNames = [proxy.host]
        } else {
            serverNames = [backendURL, backendWSURL].compactMap(\.host)
        }

        return ZMReachability(serverNames: serverNames, group: group)
    }

    func reachabilityWrapper() -> ReachabilityWrapper {
        ReachabilityWrapper(enabled: false, reachabilityClosure: {
            self.reachability
        })
    }
}

// MARK: - ReachabilityWrapper

/// Wrapper around Reachability to delay network calls if needed
final class ReachabilityWrapper: NSObject, ReachabilityProvider, TearDownCapable {

    var mayBeReachable: Bool {
        safeReachability?.mayBeReachable == true
    }

    var isMobileConnection: Bool {
        safeReachability?.isMobileConnection == true
    }

    var oldMayBeReachable: Bool {
        safeReachability?.oldMayBeReachable == true
    }

    var oldIsMobileConnection: Bool {
        safeReachability?.oldIsMobileConnection == true
    }

    func add(_ observer: ZMReachabilityObserver, queue: OperationQueue?) -> Any {
        guard let reachability = safeReachability, enabled else {
            return NSObject()
        }
        return reachability.add(observer, queue: queue)
    }

    func addReachabilityObserver(on queue: OperationQueue?, block: @escaping ReachabilityObserverBlock) -> Any {
        guard let reachability = safeReachability, enabled else {
            return NSObject()
        }

        return reachability.addReachabilityObserver(on: queue, block: block)
    }

    var enabled: Bool {
        didSet {
            if safeReachability == nil && enabled {
                safeReachability = reachabilityClosure()
            } else if !enabled {
                safeReachability?.tearDown()
                safeReachability = nil
            }
        }
    }
    var reachabilityClosure: () -> Reachability
    private var safeReachability: Reachability?

    init(enabled: Bool, reachabilityClosure: @escaping () -> Reachability) {
        self.enabled = enabled
        self.reachabilityClosure = reachabilityClosure
        super.init()
        if enabled {
            self.safeReachability = reachabilityClosure()
        }
    }

    func tearDown() {
        safeReachability?.tearDown()
    }
}
