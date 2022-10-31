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
import WireTransport

final class APIVersionResolver {

    // MARK: - Properties

    weak var delegate: APIVersionResolverDelegate?
    var isDeveloperModeEnabled: Bool

    private let queue: ZMSGroupQueue = DispatchGroupQueue(queue: .main)
    private let transportSession: UnauthenticatedTransportSessionProtocol

    // MARK: - Life cycle

    init(
        transportSession: UnauthenticatedTransportSessionProtocol,
        isDeveloperModeEnabled: Bool
    ) {
        self.transportSession = transportSession
        self.isDeveloperModeEnabled = isDeveloperModeEnabled
    }

    // MARK: - Methods

    func resolveAPIVersion(completion: @escaping () -> Void = {}) {
        // This is endpoint isn't versioned, so it always version 0.
        let request = ZMTransportRequest(getFromPath: "/api-version", apiVersion: APIVersion.v0.rawValue)
        let completionHandler = ZMCompletionHandler(on: queue) { [weak self] response in
            self?.handleResponse(response)
            completion()
        }

        request.add(completionHandler)
        transportSession.enqueueOneTime(request)
    }

    private func handleResponse(_ response: ZMTransportResponse) {
        guard response.result == .success else {
            BackendInfo.apiVersion = .v0
            BackendInfo.domain = "wire.com"
            BackendInfo.isFederationEnabled = false
            return
        }

        guard
            let data = response.rawData,
            let payload = APIVersionResponsePayload(data)
        else {
            fatalError()
        }

        let backendProdVersions = Set(payload.supported.compactMap(APIVersion.init(rawValue:)))
        let backendDevVersions = Set(payload.development?.compactMap(APIVersion.init(rawValue:)) ?? [])
        let allBackendVersions = backendProdVersions.union(backendDevVersions)
        let clientProdVersions = APIVersion.productionVersions

        let highestCommonVersion = backendProdVersions
            .intersection(clientProdVersions)
            .max()

        if
            isDeveloperModeEnabled,
            let preferredAPIVersion = BackendInfo.preferredAPIVersion,
            allBackendVersions.contains(preferredAPIVersion)
        {
            BackendInfo.apiVersion = preferredAPIVersion
        } else {
            BackendInfo.apiVersion = highestCommonVersion
        }

        BackendInfo.domain = payload.domain

        let wasFederationEnabled = BackendInfo.isFederationEnabled
        BackendInfo.isFederationEnabled = payload.federation

        guard BackendInfo.apiVersion != nil else {
            return reportBlacklist(payload: payload)
        }

        if !wasFederationEnabled && BackendInfo.isFederationEnabled {
            delegate?.apiVersionResolverDetectedFederationHasBeenEnabled()
        }
    }

    private func reportBlacklist(payload: APIVersionResponsePayload) {
        guard let maxBackendVersion = payload.supported.max() else {
            blacklistApp(reason: .backendAPIVersionObsolete)
            return
        }

        guard let minClientVersion = APIVersion.allCases.min()?.rawValue else {
            blacklistApp(reason: .clientAPIVersionObsolete)
            return
        }

        if maxBackendVersion < minClientVersion {
            blacklistApp(reason: .backendAPIVersionObsolete)
        } else {
            blacklistApp(reason: .clientAPIVersionObsolete)
        }
    }

    private func blacklistApp(reason: BlacklistReason) {
        delegate?.apiVersionResolverFailedToResolveVersion(reason: reason)
    }

    private struct APIVersionResponsePayload: Decodable {

        let supported: [Int32]
        let development: [Int32]?
        let federation: Bool
        let domain: String

    }

}

// MARK: - Delegate

protocol APIVersionResolverDelegate: AnyObject {

    func apiVersionResolverDetectedFederationHasBeenEnabled()
    func apiVersionResolverFailedToResolveVersion(reason: BlacklistReason)

}

extension APIVersion {

    public static var developmentVersions: Set<Self> {
        return Set(allCases).subtracting(productionVersions)
    }

    public static var productionVersions: Set<Self> {
        return Set(allCases.filter(\.isProductionVersion))
    }

    var isProductionVersion: Bool {
        switch self {
        case .v0, .v1, .v2:
            return true
        }
    }

}
