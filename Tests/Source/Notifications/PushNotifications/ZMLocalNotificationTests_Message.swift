//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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

import WireTesting;
import WireDataModel;
@testable import WireSyncEngine


class ZMLocalNotificationTests_Message : ZMLocalNotificationTests {
    
    // MARK: - Text Messages
    // MARK: Helpers
    
    func textNotification(_ conversation: ZMConversation, sender: ZMUser, text: String? = nil, isEphemeral: Bool = false) -> ZMLocalNotification? {
        if isEphemeral { conversation.messageDestructionTimeout = 0.5 }
        let message = conversation.appendMessage(withText: text ?? "Hello Hello!") as! ZMOTRMessage
        message.sender = sender
        conversation.lastReadServerTimeStamp = Date()
        message.serverTimestamp = conversation.lastReadServerTimeStamp!.addingTimeInterval(20)
        return ZMLocalNotification(message: message)
    }
    
    func unknownNotification(_ conversation: ZMConversation, sender: ZMUser) -> ZMLocalNotification? {
        let message = ZMClientMessage.insertNewObject(in: self.syncMOC)
        message.sender = sender;
        message.visibleInConversation = conversation
        message.nonce = UUID()
        message.serverTimestamp = conversation.lastReadServerTimeStamp!.addingTimeInterval(20)
        return ZMLocalNotification(message: message)
    }
    
    func bodyForNote(_ conversation: ZMConversation, sender: ZMUser, text: String? = nil, isEphemeral: Bool = false) -> String {
        let note = textNotification(conversation, sender: sender, text: text, isEphemeral: isEphemeral)
        XCTAssertNotNil(note)
        return note!.body
    }
    
    func bodyForUnknownNote(_ conversation: ZMConversation, sender: ZMUser) -> String {
        let note = unknownNotification(conversation, sender: sender)
        XCTAssertNotNil(note)
        return note!.body
    }
    
    // MARK: Tests
    
    func testThatItShowsDefaultAlertBodyWhenHidePreviewSettingIsTrue() {
        // given
        let note1 = textNotification(oneOnOneConversation, sender: sender)
        XCTAssertEqual(note1?.uiLocalNotification.alertTitle, "Super User")
        XCTAssertEqual(note1?.uiLocalNotification.alertBody, "Hello Hello!")
        
        // when
        let moc = oneOnOneConversation.managedObjectContext!
        let key = LocalNotificationDispatcher.ZMShouldHideNotificationContentKey
        moc.setPersistentStoreMetadata(true as NSNumber, key: key)
        let setting = moc.persistentStoreMetadata(forKey: key) as? NSNumber
        XCTAssertEqual(setting?.boolValue, true)
        let note2 = textNotification(oneOnOneConversation, sender: sender)
        
        // then
        XCTAssertNil(note2?.uiLocalNotification.alertTitle)
        XCTAssertEqual(note2?.uiLocalNotification.alertBody, "New message")
    }
    
    func testThatItShowsShowsEphemeralStringEvenWhenHidePreviewSettingIsTrue() {
        // given
        let note1 = textNotification(oneOnOneConversation, sender: sender, isEphemeral: true)
        XCTAssertNil(note1?.uiLocalNotification.alertTitle)
        XCTAssertEqual(note1?.uiLocalNotification.alertBody, "Someone sent you a message")
        
        // when
        let moc = oneOnOneConversation.managedObjectContext!
        let key = LocalNotificationDispatcher.ZMShouldHideNotificationContentKey
        moc.setPersistentStoreMetadata(true as NSNumber, key: key)
        let setting = moc.persistentStoreMetadata(forKey: key) as? NSNumber
        XCTAssertEqual(setting?.boolValue, true)
        let note2 = textNotification(oneOnOneConversation, sender: sender, isEphemeral: true)
        
        // then
        XCTAssertNil(note2?.uiLocalNotification.alertTitle)
        XCTAssertEqual(note2?.uiLocalNotification.alertBody, "Someone sent you a message")
    }
    
    func testItCreatesMessageNotificationsCorrectly(){
        
        //    "push.notification.add.message.oneonone" = "%1$@";
        //    "push.notification.add.message.group" = "%1$@: %2$@";
        //    "push.notification.add.message.group.noconversationname" = "%1$@ in a conversation: %2$@";
        
        XCTAssertEqual(bodyForNote(oneOnOneConversation, sender: sender), "Hello Hello!")
        XCTAssertEqual(bodyForNote(groupConversation, sender: sender), "Super User: Hello Hello!")
        XCTAssertEqual(bodyForNote(groupConversationWithoutUserDefinedName, sender: sender), "Super User: Hello Hello!")
        XCTAssertEqual(bodyForNote(groupConversationWithoutName, sender: sender), "Super User in a conversation: Hello Hello!")
    }
    
    func testThatObfuscatesNotificationsForEphemeralMessages(){
        XCTAssertEqual(bodyForNote(oneOnOneConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForNote(groupConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForNote(groupConversationWithoutUserDefinedName, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForNote(groupConversationWithoutName, sender: sender, isEphemeral: true), "Someone sent you a message")
    }
    
    func testThatItDuplicatesPercentageSignsInTextAndConversationName() {
        XCTAssertEqual(bodyForNote(groupConversation, sender: sender, text: "Today we grew by 100%"), "Super User: Today we grew by 100%%")
    }
    
    func testThatItSavesTheSenderOfANotification() {
        
        // given
        let note = textNotification(oneOnOneConversation, sender: sender)!
        
        // then
        XCTAssertEqual(note.senderID, sender.remoteIdentifier)
    }

    
    func testThatItSavesTheConversationOfANotification() {
        
        // given
        let note = textNotification(oneOnOneConversation, sender: sender)!
        
        // then
        XCTAssertEqual(note.conversationID, oneOnOneConversation.remoteIdentifier)
    }
    
    func testThatItSavesTheMessageNonce() {
        
        // given
        let message = oneOnOneConversation.appendMessage(withText: "Hello Hello!") as! ZMOTRMessage
        message.sender = sender
        
        let note = ZMLocalNotification(message: message)!
        
        // then
        XCTAssertEqual(note.messageNonce, message.nonce);
        XCTAssertEqual(note.selfUserID, self.selfUser.remoteIdentifier);
    }
    
    func testThatItDoesNotCreateANotificationWhenTheConversationIsSilenced(){
        
        // given
        groupConversation.isSilenced = true

        // when
        let note = textNotification(groupConversation, sender: sender)

        // then
        XCTAssertNil(note)
    }

    func testThatItCreatesPushNotificationForMessageOfUnknownType() {
        XCTAssertEqual(bodyForUnknownNote(oneOnOneConversation, sender: sender), "New message")
        XCTAssertEqual(bodyForUnknownNote(groupConversation, sender: sender), "Super User: new message")
        XCTAssertEqual(bodyForUnknownNote(groupConversationWithoutUserDefinedName, sender: sender), "Super User: new message")
        XCTAssertEqual(bodyForUnknownNote(groupConversationWithoutName, sender: sender), "Super User sent a message")
    }

    func testThatItAddsATitleIfTheUserIsPartOfATeam() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // given
            let team = Team.insertNewObject(in: self.syncMOC)
            team.name = "Wire Amazing Team"
            let user = ZMUser.selfUser(in: self.syncMOC)
            _ = Member.getOrCreateMember(for: user, in: team, context: self.syncMOC)
            self.syncMOC.saveOrRollback()
            XCTAssertNotNil(user.team)

            // when
            let note = self.textNotification(self.oneOnOneConversation, sender: self.sender)
            
            // then
            XCTAssertNotNil(note)
            XCTAssertEqual(note!.title, "Super User in \(team.name!)")
        }
    }

    func testThatItDoesNotAddATitleIfTheUserIsNotPartOfATeam() {
        
        // when
        let note = self.textNotification(oneOnOneConversation, sender: sender)

        // then
        XCTAssertNotNil(note)
        XCTAssertEqual(note!.title, "Super User")
    }
}


// MARK: - Image Asset Messages

extension ZMLocalNotificationTests_Message {

    // MARK: Helpers
    
    func imageNote(_ conversation: ZMConversation, sender: ZMUser, text: String? = nil, isEphemeral : Bool = false) -> ZMLocalNotification? {
        if isEphemeral { conversation.messageDestructionTimeout = 10 }
        let message = conversation.appendMessage(withImageData: verySmallJPEGData()) as! ZMAssetClientMessage
        message.sender = sender
        return ZMLocalNotification(message: message)
    }

    func bodyForImageNote(_ conversation: ZMConversation, sender: ZMUser, text: String? = nil, isEphemeral: Bool = false) -> String {
        let note = imageNote(conversation, sender: sender, text: text, isEphemeral: isEphemeral)
        XCTAssertNotNil(note)
        return note!.body
    }

    // MARK: Tests
    
    func testItCreatesImageNotificationsCorrectly(){
        //    "push.notification.add.image.oneonone" = "%1$@ shared a picture";
        //    "push.notification.add.image.group" = "%1$@ shared a picture";
        //    "push.notification.add.image.group.noconversationname" = "%1$@ shared a picture in a conversation";

        XCTAssertEqual(bodyForImageNote(oneOnOneConversation, sender: sender), "shared a picture")
        XCTAssertEqual(bodyForImageNote(groupConversation, sender: sender), "Super User shared a picture")
        XCTAssertEqual(bodyForImageNote(groupConversationWithoutUserDefinedName, sender: sender), "Super User shared a picture")
        XCTAssertEqual(bodyForImageNote(groupConversationWithoutName, sender: sender), "Super User shared a picture in a conversation")
    }

    func testThatObfuscatesNotificationsForEphemeralImageMessages(){
        XCTAssertEqual(bodyForImageNote(oneOnOneConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForImageNote(groupConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForImageNote(groupConversationWithoutUserDefinedName, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForImageNote(groupConversationWithoutName, sender: sender, isEphemeral: true), "Someone sent you a message")
    }
}

// MARK: - File Asset Messages

enum FileType {
    case txt, video, audio

    var testURL : URL {
        var name : String
        var fileExtension : String
        switch self {
        case .txt:
            name = "Lorem Ipsum"
            fileExtension = "txt"
        case .video:
            name = "video"
            fileExtension = "mp4"
        case  .audio:
            name = "audio"
            fileExtension = "m4a"
        }
        return Bundle(for: ZMLocalNotificationTests.self).url(forResource: name, withExtension: fileExtension)!
    }

    var testData : Data {
        return try! Data(contentsOf: testURL)
    }
}

extension ZMLocalNotificationTests_Message {
    
    // MARK: Helpers
    
    func messageForFile(_ mimeType: String, nonce: NSUUID){
        let dataBuilder = ZMAssetRemoteDataBuilder()
        dataBuilder.setSha256(Data.secureRandomData(length: 32))
        dataBuilder.setOtrKey(Data.secureRandomData(length: 32))

        let originalBuilder = ZMAssetOriginalBuilder()
        originalBuilder.setMimeType(mimeType)
        originalBuilder.setSize(0)

        let assetBuilder = ZMAssetBuilder()
        assetBuilder.setUploaded(dataBuilder.build())
        assetBuilder.setOriginal(originalBuilder.build())

        let genericAssetMessageBuilder = ZMGenericMessageBuilder()
        genericAssetMessageBuilder.setAsset(assetBuilder.build())
        genericAssetMessageBuilder.setMessageId(nonce.transportString())
    }

    func assetNote(_ fileType: FileType, conversation: ZMConversation, sender: ZMUser, isEphemeral: Bool = false) -> ZMLocalNotification? {
        let metadata = ZMFileMetadata(fileURL: fileType.testURL)
        if let message = ZMAssetClientMessage.assetClientMessage(with: metadata, nonce: UUID.create(), managedObjectContext: self.syncMOC, expiresAfter: isEphemeral ? 10 : 0) {
            message.sender = sender
            message.visibleInConversation = conversation
            return ZMLocalNotification(message: message)
        }
        else {
            return nil
        }
    }

    func bodyForAssetNote(_ fileType: FileType, conversation: ZMConversation, sender: ZMUser, isEphemeral: Bool = false) -> String {
        let note = assetNote(fileType, conversation: conversation, sender: sender, isEphemeral: isEphemeral)
        XCTAssertNotNil(note)
        return note!.body
    }

    // MARK: Tests
    
    func testThatItCreatesFileAddNotificationsCorrectly() {
        //    "push.notification.add.file.group" = "%1$@ shared a file"
        //    "push.notification.add.file.group.noconversationname" = "%1$@ shared a file"
        //    "push.notification.add.file.oneonone" = "%1$@ shared a file in a conversation"
        //

        XCTAssertEqual(bodyForAssetNote(.txt, conversation: oneOnOneConversation, sender: sender), "shared a file")
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: groupConversation, sender: sender), "Super User shared a file")
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: groupConversationWithoutUserDefinedName, sender: sender), "Super User shared a file")
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: groupConversationWithoutName, sender: sender), "Super User shared a file in a conversation")
    }

    func testThatItCreatesVideoAddNotificationsCorrectly() {
        //    "push.notification.add.video.group" = "%1$@ shared a video
        //    "push.notification.add.video.group.noconversationname" = "%1$@ shared a video"
        //    "push.notification.add.video.oneonone" = "%1$@ shared a video in a conversation"
        //

        XCTAssertEqual(bodyForAssetNote(.video, conversation: oneOnOneConversation, sender: sender), "shared a video")
        XCTAssertEqual(bodyForAssetNote(.video, conversation: groupConversation, sender: sender), "Super User shared a video")
        XCTAssertEqual(bodyForAssetNote(.video, conversation: groupConversationWithoutUserDefinedName, sender: sender), "Super User shared a video")
        XCTAssertEqual(bodyForAssetNote(.video, conversation: groupConversationWithoutName, sender: sender), "Super User shared a video in a conversation")
    }

    func testThatItCreatesEphemeralFileAddNotificationsCorrectly() {
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: oneOnOneConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: groupConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: groupConversationWithoutUserDefinedName, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForAssetNote(.txt, conversation: groupConversationWithoutName, sender: sender, isEphemeral: true), "Someone sent you a message")
    }

    func testThatItCreatesEphemeralVideoAddNotificationsCorrectly() {
        XCTAssertEqual(bodyForAssetNote(.video, conversation: oneOnOneConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForAssetNote(.video, conversation: groupConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForAssetNote(.video, conversation: groupConversationWithoutUserDefinedName, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForAssetNote(.video, conversation: groupConversationWithoutName, sender: sender, isEphemeral: true), "Someone sent you a message")
    }

    func testThatItCreatesAudioNotificationsCorrectly() {
        //    "push.notification.add.audio.group" = "%1$@ shared an audio message";
        //    "push.notification.add.audio.group.noconversationname" = "%1$@ shared an audio message";
        //    "push.notification.add.audio.oneonone" = "%1$@ shared an audio message in a conversation";

        XCTAssertEqual(bodyForAssetNote(.audio, conversation: oneOnOneConversation, sender: sender), "shared an audio message")
        XCTAssertEqual(bodyForAssetNote(.audio, conversation: groupConversation, sender: sender), "Super User shared an audio message")
        XCTAssertEqual(bodyForAssetNote(.audio, conversation: groupConversationWithoutUserDefinedName, sender: sender), "Super User shared an audio message")
        XCTAssertEqual(bodyForAssetNote(.audio, conversation: groupConversationWithoutName, sender: sender), "Super User shared an audio message in a conversation")
    }
}

// MARK: - Knock Messages

extension ZMLocalNotificationTests_Message {

    // MARK: Helpers
    
    func knockNote(_ conversation: ZMConversation, sender: ZMUser, isEphemeral : Bool = false) -> ZMLocalNotification? {
        if isEphemeral { conversation.messageDestructionTimeout = 10 }
        let message = conversation.appendKnock() as! ZMClientMessage
        message.sender = sender
        return ZMLocalNotification(message: message)
    }

    func bodyForKnockNote(_ conversation: ZMConversation, sender: ZMUser, isEphemeral: Bool = false) -> String {
        let note = knockNote(conversation, sender: sender, isEphemeral: isEphemeral)
        XCTAssertNotNil(note)
        return note!.body
    }

    // MARK: Tests
    
    func testThatItCreatesKnockNotificationsCorrectly() {
        XCTAssertEqual(bodyForKnockNote(oneOnOneConversation, sender: sender), "pinged")
        XCTAssertEqual(bodyForKnockNote(groupConversation, sender: sender), "Super User pinged")
        XCTAssertEqual(bodyForKnockNote(groupConversationWithoutUserDefinedName, sender: sender), "Super User pinged")
    }

    func testThatItCreatesEphemeralKnockNotificationsCorrectly() {
        XCTAssertEqual(bodyForKnockNote(oneOnOneConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForKnockNote(groupConversation, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForKnockNote(groupConversationWithoutUserDefinedName, sender: sender, isEphemeral: true), "Someone sent you a message")
        XCTAssertEqual(bodyForKnockNote(groupConversationWithoutName, sender: sender, isEphemeral: true), "Someone sent you a message")
    }
}

// MARK: - Editing Message

extension ZMLocalNotificationTests_Message {

    func editNote(_ message: ZMOTRMessage, sender: ZMUser, text: String) -> ZMLocalNotification? {
        let editMessage = ZMOTRMessage.edit(message, newText: text)
        editMessage!.sender = sender
        return ZMLocalNotification(message: editMessage as! ZMClientMessage)
    }

    func bodyForEditNote(_ conversation: ZMConversation, sender: ZMUser, text: String) -> String {
        let message = conversation.appendMessage(withText: "Foo") as! ZMClientMessage
        message.markAsSent()
        let note = editNote(message, sender: sender, text: text)
        XCTAssertNotNil(note)
        return note!.body
    }

    func testThatItCreatesANotificationForAnEditMessage(){
        //    "push.notification.add.message.oneonone" = "%1$@";
        //    "push.notification.add.message.group" = "%1$@: %2$@";
        //    "push.notification.add.message.group.noconversationname" = "%1$@ in a conversation: %2$@";

        XCTAssertEqual(bodyForEditNote(oneOnOneConversation, sender: sender, text: "Edited Text"), "Edited Text")
        XCTAssertEqual(bodyForEditNote(groupConversation, sender: sender, text: "Edited Text"), "Super User: Edited Text")
        XCTAssertEqual(bodyForEditNote(groupConversationWithoutUserDefinedName, sender: sender, text: "Edited Text"), "Super User: Edited Text")
        XCTAssertEqual(bodyForEditNote(groupConversationWithoutName, sender: sender, text: "Edited Text"), "Super User in a conversation: Edited Text")
    }
}
