//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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


#import "ZMSyncStrategy+Internal.h"
#import "ZMSyncStrategy+ManagedObjectChanges.h"
#import "ZMessagingLogs.h"

@implementation ZMSyncStrategy (ManagedObjectChanges)

- (void)logDidSaveNotification:(NSNotification *)note;
{
    NSManagedObjectContext * ZM_UNUSED moc = note.object;
    ZMLogWithLevelAndTag(ZMLogLevelDebug, ZMTAG_CORE_DATA, @"<%@: %p> did save. Context type = %@",
                         moc.class, moc,
                         moc.zm_isUserInterfaceContext ? @"UI" : moc.zm_isSyncContext ? @"Sync" : @"");
    NSSet *inserted = note.userInfo[NSInsertedObjectsKey];
    if (inserted.count > 0) {
        NSString * ZM_UNUSED description = [[inserted.allObjects mapWithBlock:^id(NSManagedObject *mo) {
            return mo.objectID.URIRepresentation;
        }] componentsJoinedByString:@", "];
        ZMLogWithLevelAndTag(ZMLogLevelDebug, ZMTAG_CORE_DATA, @"    Inserted: %@", description);
    }
    NSSet *updated = note.userInfo[NSUpdatedObjectsKey];
    if (updated.count > 0) {
        NSString * ZM_UNUSED description = [[updated.allObjects mapWithBlock:^id(NSManagedObject *mo) {
            return mo.objectID.URIRepresentation;
        }] componentsJoinedByString:@", "];
        ZMLogWithLevelAndTag(ZMLogLevelDebug, ZMTAG_CORE_DATA, @"    Updated: %@", description);
    }
    NSSet *deleted = note.userInfo[NSDeletedObjectsKey];
    if (deleted.count > 0) {
        NSString * ZM_UNUSED description = [[deleted.allObjects mapWithBlock:^id(NSManagedObject *mo) {
            return mo.objectID.URIRepresentation;
        }] componentsJoinedByString:@", "];
        ZMLogWithLevelAndTag(ZMLogLevelDebug, ZMTAG_CORE_DATA, @"    Deleted: %@", description);
    }
}

- (void)managedObjectContextDidSave:(NSNotification *)note;
{
    if(self.tornDown || self.contextMergingDisabled) {
        return;
    }
    
    if([ZMSLog getLevelWithTag:ZMTAG_CORE_DATA] == ZMLogLevelDebug) {
        [self logDidSaveNotification:note];
    }
    
    NSManagedObjectContext *mocThatSaved = note.object;
    NSManagedObjectContext *strongUiMoc = self.uiMOC;
    ZMCallState *callStateChanges = mocThatSaved.zm_callState.createCopyAndResetHasChanges;
    NSDictionary *userInfo = [mocThatSaved.userInfo copy];
    
    if (mocThatSaved.zm_isUserInterfaceContext && strongUiMoc != nil) {
        if(mocThatSaved != strongUiMoc) {
            RequireString(mocThatSaved == strongUiMoc, "Not the right MOC!");
        }
        
        NSSet *conversationsWithCallChanges = [callStateChanges allContainedConversationsInContext:strongUiMoc];
        if (conversationsWithCallChanges != nil) {
            [strongUiMoc.wireCallCenterV2 callStateDidChangeWithConversations:conversationsWithCallChanges];
        }
        
        ZM_WEAK(self);
        [self.syncMOC performGroupedBlock:^{
            ZM_STRONG(self);
            if(self == nil || self.tornDown) {
                return;
            }
            [self.syncMOC mergeUserInfoFromUserInfo:userInfo];
            NSSet *changedConversations = [self.syncMOC mergeCallStateChanges:callStateChanges];
            [self.syncMOC mergeChangesFromContextDidSaveNotification:note];
            [self processSaveWithInsertedObjects:[NSSet set] updateObjects:changedConversations];
            [self.syncMOC processPendingChanges]; // We need this because merging sometimes leaves the MOC in a 'dirty' state
        }];
    } else if (mocThatSaved.zm_isSyncContext) {
        RequireString(mocThatSaved == self.syncMOC, "Not the right MOC!");
        
        NSSet<NSManagedObjectID*>* changedObjectsIDs = [self extractManagedObjectIDsFrom:note];
        
        ZM_WEAK(self);
        [strongUiMoc performGroupedBlock:^{
            ZM_STRONG(self);
            if(self == nil || self.tornDown) {
                return;
            }
            
            [strongUiMoc mergeUserInfoFromUserInfo:userInfo];
            NSSet *changedConversations = [strongUiMoc mergeCallStateChanges:callStateChanges];
            if (changedConversations != nil) {
                [strongUiMoc.wireCallCenterV2 callStateDidChangeWithConversations: changedConversations];
            }
            
            [strongUiMoc mergeChangesFromContextDidSaveNotification:note];
            
            [strongUiMoc processPendingChanges]; // We need this because merging sometimes leaves the MOC in a 'dirty' state
            [self.notificationDispatcher didMergeChanges:changedObjectsIDs];
        }];
    }
}

- (NSSet<NSManagedObjectID*>*)extractManagedObjectIDsFrom:(NSNotification *)note
{
    NSSet<NSManagedObjectID*>* changedObjectsIDs;
    if (note.userInfo[NSUpdatedObjectsKey] != nil) {
        NSSet<NSManagedObject *>* changedObjects = note.userInfo[NSUpdatedObjectsKey];
        changedObjectsIDs = [changedObjects mapWithBlock:^id(NSManagedObject* obj) {
            return obj.objectID;
        }];
    } else {
        changedObjectsIDs = [NSSet set];
    }
    return changedObjectsIDs;
}

- (BOOL)shouldForwardCallStateChangeDirectlyForNote:(NSNotification *)note
{
    if ([(NSSet *)note.userInfo[NSInsertedObjectsKey] count] == 0 &&
        [(NSSet *)note.userInfo[NSDeletedObjectsKey] count] == 0 &&
        [(NSSet *)note.userInfo[NSUpdatedObjectsKey] count] == 0 &&
        [(NSSet *)note.userInfo[NSRefreshedObjectsKey] count] == 0) {
        return YES;
    }
    return NO;
}

- (BOOL)processSaveWithInsertedObjects:(NSSet *)insertedObjects updateObjects:(NSSet *)updatedObjects
{
    NSSet *allObjects = [NSSet zmSetByCompiningSets:insertedObjects, updatedObjects, nil];
    
    for(id<ZMContextChangeTracker> tracker in self.allChangeTrackers)
    {
        [tracker objectsDidChange:allObjects];
    }
    
    return YES;
}

@end
