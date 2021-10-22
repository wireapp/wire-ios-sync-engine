//
// Wire
// Copyright (C) 2019 Wire Swiss GmbH
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
import WireRequestStrategy

/// TeamImageAssetUpdateStrategy is responsible for downloading images (logo and splash image) associated with a team

public final class TeamImageAssetUpdateStrategy: AbstractRequestStrategy, ZMContextChangeTrackerSource, ZMDownstreamTranscoder {
    
    fileprivate var downstreamRequestSyncs = [TeamImageType : ZMDownstreamObjectSyncWithWhitelist]()
    fileprivate var observers: [Any] = []

    public override init(withManagedObjectContext managedObjectContext: NSManagedObjectContext, applicationStatus: ApplicationStatus) {
        
        super.init(withManagedObjectContext: managedObjectContext, applicationStatus: applicationStatus)

        downstreamRequestSyncs[.logo] = ZMDownstreamObjectSyncWithWhitelist(transcoder: self,
                                                                    entityName: Team.entityName(),
                                                                    predicateForObjectsToDownload: Team.logoDownloadFilter,
                                                                    managedObjectContext: managedObjectContext)
        downstreamRequestSyncs[.splashImage] = ZMDownstreamObjectSyncWithWhitelist(transcoder: self,
                                                                    entityName: Team.entityName(),
                                                                    predicateForObjectsToDownload: Team.splashImageDownloadFilter,
                                                                    managedObjectContext: managedObjectContext)
        
        observers.append(NotificationInContext.addObserver(name: .teamDidRequestLogoImage, context: managedObjectContext.notificationContext, using: { [weak self] in self?.requestAssetForNotification(note: $0) }))

        observers.append(NotificationInContext.addObserver(name: .teamDidRequestSplashImage, context: managedObjectContext.notificationContext, using: { [weak self] in self?.requestAssetForNotification(note: $0) }))

    }

    private func requestAssetForNotification(note: NotificationInContext) {
        managedObjectContext.performGroupedBlock {
            guard let objectID = note.object as? NSManagedObjectID,
                  let object = self.managedObjectContext.object(with: objectID) as? ZMManagedObject else { return }

            switch note.name {
            case .teamDidRequestLogoImage:
                self.downstreamRequestSyncs[.logo]?.whiteListObject(object)
            case .teamDidRequestSplashImage:
                self.downstreamRequestSyncs[.splashImage]?.whiteListObject(object)
            default:
                break
            }

            RequestAvailableNotification.notifyNewRequestsAvailable(nil)
        }
    }

    // TODO:
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        return downstreamRequestSyncs[.logo]?.nextRequest()
    }
    
    //MARK:- ZMContextChangeTrackerSource {
        
    public var contextChangeTrackers: [ZMContextChangeTracker] {
        return Array(downstreamRequestSyncs.values)
    }

    //MARK:- ZMDownstreamTranscoder
    
    public func request(forFetching object: ZMManagedObject!, downstreamSync: ZMObjectSync!) -> ZMTransportRequest! {
        guard let whitelistSync = downstreamSync as? ZMDownstreamObjectSyncWithWhitelist,
              let imageType = type(for: whitelistSync),
              let team = object as? Team else {
            return nil
        }

        let asset: String?
        switch imageType {
        case .logo:
            asset = team.pictureAssetId
        case .splashImage:
            asset = team.splashImageId
        }
        guard let assetId = asset else { return nil }

        return ZMTransportRequest.imageGet(fromPath: "/assets/v3/\(assetId)")
    }

    public func delete(_ object: ZMManagedObject!, with response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        guard let whitelistSync = downstreamSync as? ZMDownstreamObjectSyncWithWhitelist,
              let imageType = type(for: whitelistSync),
              let team = object as? Team else { return }

        switch imageType {
        case .logo:
            team.pictureAssetId = nil
        case .splashImage:
            team.splashImageId = nil
        }
    }

    public func update(_ object: ZMManagedObject!, with response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        guard let whitelistSync = downstreamSync as? ZMDownstreamObjectSyncWithWhitelist,
              let imageType = type(for: whitelistSync),
              let team = object as? Team else { return }

        switch imageType {
        case .logo:
            team.logoImageData = response.rawData
        case .splashImage:
            team.splashImageData = response.rawData
        }
    }

    //MARK:- Helpers

    private func type(for requestSync: ZMDownstreamObjectSyncWithWhitelist) -> TeamImageType? {
        return downstreamRequestSyncs.first { (type, sync) -> Bool in
            sync === requestSync
        }?.key
    }

}
