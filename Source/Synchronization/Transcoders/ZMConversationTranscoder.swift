////
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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

private let log = ZMSLog(tag: "ConversationTranscoder")

extension ZMConversationTranscoder {

    @objc
    static public let predicateForDownstreamSync: NSPredicate = {
        let needsToBeSynced = NSPredicate(
            format: "%K != nil AND needsToBeUpdatedFromBackend == YES",
            argumentArray: [ZMConversation.remoteIdentifierDataKey()!]
        )

        let hasNoPendingOrIgnoredConnection = NSPredicate(
            format: "connection == nil OR (connection.status != %d AND connection.status != %d)",
            argumentArray: [ZMConnectionStatus.pending.rawValue, ZMConnectionStatus.ignored.rawValue]
        )

        // Some of the participants may have been deleted on the backend, so we should first let them sync
        // before syncing the conversation.
        let hasNoParticipantsWaitingToBeSynced = NSPredicate(
            format: "SUBQUERY(participantRoles, $role, $role.user.needsToBeUpdatedFromBackend == YES).@count == 0"
        )

        let predicates = [needsToBeSynced, hasNoPendingOrIgnoredConnection, hasNoParticipantsWaitingToBeSynced]
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }()
    
    @objc(appendSystemMessageForUpdateEvent:inConversation:)
    public func appendSystemMessage(for event: ZMUpdateEvent, conversation: ZMConversation) {
        _ = ZMSystemMessage.createOrUpdate(from: event, in: self.managedObjectContext)
    }
    
    @objc(processMemberUpdateEvent:forConversation:previousLastServerTimeStamp:)
    public func processMemberUpdateEvent(
        _ event: ZMUpdateEvent,
        for conversation: ZMConversation?,
        previousLastServerTimeStamp previousLastServerTimestamp: Date?) {
        guard let dataPayload = (event.payload as NSDictionary).dictionary(forKey: "data"),
            let conversation = conversation
            else { return }
        
        let id = (dataPayload["target"] as? String).flatMap({ UUID.init(uuidString: $0)})
        if id == nil || id == ZMUser.selfUser(in: self.managedObjectContext).remoteIdentifier {
            conversation.updateSelfStatus(dictionary: dataPayload, timeStamp: event.timestamp, previousLastServerTimeStamp: previousLastServerTimestamp)
        } else {
            conversation.updateRoleFromEventPayload(dataPayload, userId: id!)
        }
    }

    @objc(createConversationFromEvent:)
    public func createConversation(from event: ZMUpdateEvent) {
        guard let payloadData = (event.payload as NSDictionary).dictionary(forKey: "data") else {
            log.error("Missing conversation payload in ZMUpdateEventConversationCreate")
            return
        }

        guard let serverTimestamp = (event.payload as NSDictionary).date(for: "time") else {
            log.error("serverTimeStamp is nil!")
            return
        }
        
        createConversation(from: payloadData,
                           serverTimeStamp: serverTimestamp,
                           source: .updateEvent)
    }

    @objc(createConversationFromTransportData:serverTimeStamp:source:)
    @discardableResult
    public func createConversation(from transportData: [AnyHashable : Any], serverTimeStamp: Date, source: ZMConversationSource) -> ZMConversation? {
        // If the conversation is not a group conversation, we need to make sure that we check if there's any existing conversation without a remote identifier for that user.
        // If it is a group conversation, we don't need to.
        
        guard let typeNumber: Int = (transportData as NSDictionary).number(forKey: "type") as? Int else {
            return nil
        }
        
        let type = BackendConversationType.clientConversationType(rawValue: typeNumber)
        
        if type == .group || type == .`self` {
            return createGroupOrSelfConversation(from: transportData as NSDictionary, serverTimeStamp: serverTimeStamp, source: source)
        } else {
            return createOneOnOneConversation(fromTransportData: transportData, type: type, serverTimeStamp: serverTimeStamp)
        }
    }

    @objc(createGroupOrSelfConversationFromTransportData:serverTimeStamp:source:)
    public func createGroupOrSelfConversation(from transportData: NSDictionary,
                                       serverTimeStamp: Date,
                                       source: ZMConversationSource) -> ZMConversation? {
        guard let convRemoteID = transportData.uuid(forKey: "id") else {
            log.error("Missing ID in conversation payload")
            return nil
        }
        
        guard let transportData = transportData as? [String : Any] else {
            log.error("transportData can not be casted to [String : Any]")
            return nil
        }

        let domain = (transportData as NSDictionary).optionalDictionary(forKey: "qualified_id")?.optionalString(forKey: "domain")
        var created = false
        let conversation = ZMConversation.fetchOrCreate(with: convRemoteID,
                                                        domain: domain,
                                                        in: managedObjectContext,
                                                        created: &created)
        conversation.update(transportData: transportData, serverTimeStamp: serverTimeStamp)

        let selfUser = ZMUser.selfUser(in: self.managedObjectContext)
        let notInMyTeam = conversation.teamRemoteIdentifier == nil ||
            selfUser.team?.remoteIdentifier != conversation.teamRemoteIdentifier

        if created,
           conversation.conversationType == .group,
           notInMyTeam {
            conversation.needsToDownloadRoles = true
        }

        if created && conversation.conversationType != ZMConversationType.`self` {

            // we just got a new conversation, we display new conversation header
            conversation.appendNewConversationSystemMessage(at: serverTimeStamp,
                users: conversation.localParticipants)

            if source == .slowSync {
                // Slow synced conversations should be considered read from the start
                conversation.lastReadServerTimeStamp = conversation.lastModifiedDate
            }
        }

        return conversation
    }
    
    @objc (processMemberJoinEvent:forConversation:)
    public func processMemberJoinEvent(_ event: ZMUpdateEvent, conversation: ZMConversation) {
        guard let dataPayload = event.payload["data"] as? [String: Any] else { return }
        
        let usersAndRoleAPI = dataPayload.keys.contains("users")
        
        if usersAndRoleAPI {
            // new API: "user" object with role
            processMemberJoinEvent_APIWithRoles(conversation: conversation, event: event)
        } else {
            // old API: "user_ids"
            processMemberJoinEvent_APIWithUserIDs(conversation: conversation, event: event)
        }
        
    }
    
    private func processMemberJoinEvent_APIWithRoles(
        conversation: ZMConversation,
        event: ZMUpdateEvent)
    {
        guard let dataPayload = event.payload["data"] as? [String: Any],
            let usersAndRolesPayload = dataPayload["users"] as? [[String: Any]] else {
            return
        }
        let usersAndRoles = ConversationParsing.parseUsersPayloadToUserAndRole(
            payload: usersAndRolesPayload,
            userIdKey: "id",
            conversation: conversation)
        
        let selfUser = ZMUser.selfUser(in: self.managedObjectContext)
        let users = Set(usersAndRoles.map { $0.0 })
        
        let newUsers = !users.subtracting(conversation.localParticipants).isEmpty
        if users.contains(selfUser) || newUsers {
            self.appendSystemMessage(for: event, conversation: conversation)
        }
        
        conversation.addParticipantsAndUpdateConversationState(usersAndRoles: usersAndRoles)
    }
    
    private func processMemberJoinEvent_APIWithUserIDs(
        conversation: ZMConversation,
        event: ZMUpdateEvent)
    {
        let users = event.usersFromUserIDs(in: self.managedObjectContext, createIfNeeded: true) as! Set<ZMUser>
        let selfUser = ZMUser.selfUser(in: self.managedObjectContext)
        if !users.isSubset(of: conversation.localParticipantsExcludingSelf) || users.contains(selfUser) {
            self.appendSystemMessage(for: event, conversation: conversation)
        }
        conversation.addParticipantsAndUpdateConversationState(users: users, role: nil)
    }
    

    @objc (processAccessModeUpdateEvent:inConversation:)
    public func processAccessModeUpdate(event: ZMUpdateEvent, in conversation: ZMConversation) {
        precondition(event.type == .conversationAccessModeUpdate, "invalid update event type")
        guard let payload = event.payload["data"] as? [String : AnyHashable] else { return }
        guard let access = payload["access"] as? [String] else { return }
        guard let accessRole = payload["access_role"] as? String else { return }

        conversation.accessMode = ConversationAccessMode(values: access)
        conversation.accessRole = ConversationAccessRole(rawValue: accessRole)
    }
    
    @objc (processDestructionTimerUpdateEvent:inConversation:)
    public func processDestructionTimerUpdate(event: ZMUpdateEvent, in conversation: ZMConversation?) {
        precondition(event.type == .conversationMessageTimerUpdate, "invalid update event type")
        guard let payload = event.payload["data"] as? [String : AnyHashable],
            let senderUUID = event.senderUUID,
            let user = ZMUser.fetch(with: senderUUID, domain: nil, in: managedObjectContext) else { return }
        
        var timeout: MessageDestructionTimeout?
        let timeoutIntegerValue = (payload["message_timer"] as? Int64) ?? 0
        
        // Backend is sending the miliseconds, we need to convert to seconds.
        timeout = .synced(MessageDestructionTimeoutValue(rawValue: TimeInterval(timeoutIntegerValue / 1000)))
        
        let fromSelf = user.isSelfUser
        let fromOffToOff = !(conversation?.hasSyncedDestructionTimeout ?? false) && timeout == .synced(.none)
        
        let noChange = fromOffToOff || conversation?.messageDestructionTimeout == timeout
        
        // We seem to get duplicate update events for timeout changes, returning
        // early will avoid duplicate system messages.
        if fromSelf && noChange { return }

        conversation?.messageDestructionTimeout = timeout
        
        if let timestamp = event.timestamp, let conversation = conversation {
            // system message should reflect the synced timer value, not local
            let timer = conversation.hasSyncedDestructionTimeout ? conversation.messageDestructionTimeoutValue : 0
            _ = conversation.appendMessageTimerUpdateMessage(fromUser: user, timer: timer, timestamp: timestamp)
        }
    }
    
    @objc (processReceiptModeUpdate:inConversation:lastServerTimestamp:)
    public func processReceiptModeUpdate(event: ZMUpdateEvent,
                                         in conversation: ZMConversation,
                                         lastServerTimestamp: Date?) {
        precondition(event.type == .conversationReceiptModeUpdate, "invalid update event type")
        
        guard let payload = event.payload["data"] as? [String : AnyHashable],
              let readReceiptMode = payload["receipt_mode"] as? Int,
              let serverTimestamp = event.timestamp,
              let senderUUID = event.senderUUID,
              let sender = ZMUser.fetch(with: senderUUID, domain: nil, in: managedObjectContext)
        else { return }
        
        // Discard event if it has already been applied
        guard let lastServerTimestamp = lastServerTimestamp else { return }
        guard serverTimestamp.compare(lastServerTimestamp) == .orderedDescending else { return }
        
        let newValue = readReceiptMode > 0
        conversation.hasReadReceiptsEnabled = newValue
        conversation.appendMessageReceiptModeChangedMessage(fromUser: sender, timestamp: serverTimestamp, enabled: newValue)
    }
}

extension ZMConversation {
    @objc public var accessPayload: [String]? {
        return accessMode?.stringValue
    }
    
    @objc public var accessRolePayload: String? {
        return accessRole?.rawValue
    }
    
    @objc
    public func requestForUpdatingSelfInfo() -> ZMUpstreamRequest? {
        guard let remoteIdentifier = self.remoteIdentifier else {
            return nil
        }
        
        var payload: [String: Any] = [:]
        var updatedKeys: Set<String> = Set()
        
        if hasLocalModifications(forKey: ZMConversationSilencedChangedTimeStampKey) {
            if silencedChangedTimestamp == nil {
                silencedChangedTimestamp = Date()
            }
            
            payload[ZMConversation.PayloadKeys.OTRMutedValueKey] = mutedMessageTypes != .none
            payload[ZMConversation.PayloadKeys.OTRMutedStatusValueKey] = mutedMessageTypes.rawValue
            payload[ZMConversation.PayloadKeys.OTRMutedReferenceKey] = silencedChangedTimestamp?.transportString()
            
            updatedKeys.insert(ZMConversationSilencedChangedTimeStampKey)
        }
        
        if hasLocalModifications(forKey: ZMConversationArchivedChangedTimeStampKey) {
            if archivedChangedTimestamp == nil {
                archivedChangedTimestamp = Date()
            }
            
            payload[ZMConversation.PayloadKeys.OTRArchivedValueKey] = isArchived
            payload[ZMConversation.PayloadKeys.OTRArchivedReferenceKey] = archivedChangedTimestamp?.transportString()
            
            updatedKeys.insert(ZMConversationArchivedChangedTimeStampKey)
        }
        
        guard !updatedKeys.isEmpty else {
            return nil
        }
        
        let path = NSString.path(withComponents: [ConversationsPath, remoteIdentifier.transportString(), "self"])
        let request = ZMTransportRequest(path: path, method: .methodPUT, payload: payload as NSDictionary)
        return ZMUpstreamRequest(keys: updatedKeys, transportRequest: request)
    }
    
    fileprivate func updateRoleFromEventPayload(_ payload: [String: Any], userId: UUID) {
        guard let roleName = payload["conversation_role"] as? String else { return }

        // TODO jacob extract domain
        let user = ZMUser.fetchOrCreate(with: userId, domain: nil, in: self.managedObjectContext!)
        let teamOrConvo: TeamOrConversation = self.team != nil ?
            TeamOrConversation.team(self.team!) : TeamOrConversation.conversation(self)
        let role = self.getRoles().first(where: {$0.name == roleName }) ??
            Role.create(
                managedObjectContext: self.managedObjectContext!,
                name: roleName,
                teamOrConversation: teamOrConvo)
        self.addParticipantAndUpdateConversationState(user: user, role: role)
    }
}
