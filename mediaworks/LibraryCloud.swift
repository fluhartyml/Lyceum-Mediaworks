//
//  LibraryCloud.swift
//  mediaworks
//
//  The iCloud half of the hybrid: the Mac keeps a copy of the library cache in the user's private iCloud; a device that
//  cannot reach the Mac reads it from there.
//
// REM  HIS RULING, 2026-10-10 (platforms 002a, LOCKED): "can it be a hybrid?" → home network when the Mac is reachable,
// REM  otherwise the last copy the Mac saved to iCloud — "icloud can be considered as secure if not more secure than the
// REM  users home network." The copy lives in the PRIVATE database, in ENCRYPTED fields (end-to-end: only his devices can
// REM  read it). He added the iCloud capability + container iCloud.com.lyceum.mediaworks in Xcode, 12:47 that day.
// REM  A record holds at most 1 MB, so the cache goes up compressed and in pieces, with a small manifest naming them.
//

import Foundation
import CloudKit

nonisolated enum LibraryCloud {
    static let container = CKContainer(identifier: "iCloud.com.lyceum.mediaworks")
    private static var database: CKDatabase { container.privateCloudDatabase }
    private static let manifestID = CKRecord.ID(recordName: "library-manifest")
    private static let piece = 700_000

    /// Saves the cache to iCloud (Mac). Errors — no iCloud account, offline — are returned as words, never thrown.
    static func upload(_ payload: Data, made: Date) async -> String? {
        guard let packed = try? (payload as NSData).compressed(using: .zlib) as Data else { return "could not compress" }
        var records: [CKRecord] = []
        var count = 0
        var offset = 0
        while offset < packed.count {
            let record = CKRecord(recordType: "LibraryPiece", recordID: CKRecord.ID(recordName: "library-piece-\(count)"))
            record.encryptedValues["data"] = packed.subdata(in: offset..<min(offset + piece, packed.count))
            records.append(record)
            offset += piece
            count += 1
        }
        let manifest = CKRecord(recordType: "LibraryManifest", recordID: manifestID)
        manifest.encryptedValues["pieces"] = count
        manifest.encryptedValues["made"] = made
        records.append(manifest)
        do {
            // REM  Pieces first, manifest last: a reader never sees a manifest that names pieces not yet saved.
            for batch in stride(from: 0, to: records.count, by: 4) {
                _ = try await database.modifyRecords(saving: Array(records[batch..<min(batch + 4, records.count)]),
                                                     deleting: [], savePolicy: .allKeys)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reads the cache from iCloud (phone, iPad, TV) — nil if there is none or iCloud cannot be reached.
    static func download() async -> (data: Data, made: Date)? {
        guard let manifest = try? await database.record(for: manifestID),
              let count = manifest.encryptedValues["pieces"] as? Int, count > 0,
              let made = manifest.encryptedValues["made"] as? Date else { return nil }
        var packed = Data()
        for n in 0..<count {
            guard let record = try? await database.record(for: CKRecord.ID(recordName: "library-piece-\(n)")),
                  let data = record.encryptedValues["data"] as? Data else { return nil }
            packed.append(data)
        }
        guard let payload = try? (packed as NSData).decompressed(using: .zlib) as Data else { return nil }
        return (payload, made)
    }

    // REM  THE MASTER, CHOSEN ONCE FOR EVERY MAC — his ask, 2026-10-18: "is there a way to toggle on one computer and the
    // REM  change take effect on all computers? can we somehow use icloud preferences to know which computer name was chosen
    // REM  to be leader? and automatically tell the group of macs to listen to the master?" · "every mac is on my apple id".
    // REM  One small record in the same private database: the chosen Mac's name (empty = no master) and a fresh id per
    // REM  choice, so a Mac acts on each choice once without trusting any Mac's clock.
    private static let masterID = CKRecord.ID(recordName: "master-choice")

    struct MasterChoice: Sendable {
        /// The chosen Mac, nil when the master was unticked.
        var name: String?
        /// New with every choice.
        var id: String
    }

    /// Saves the choice (Mac). Errors come back as words.
    static func saveMaster(_ name: String?, id: String) async -> String? {
        let record = CKRecord(recordType: "MasterChoice", recordID: masterID)
        record.encryptedValues["name"] = name ?? ""
        record.encryptedValues["id"] = id
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The choice in iCloud. `.some(nil)` = no Mac has ever chosen through iCloud; nil = iCloud out of reach.
    static func loadMaster() async -> MasterChoice?? {
        do {
            let record = try await database.record(for: masterID)
            let name = record.encryptedValues["name"] as? String ?? ""
            return .some(MasterChoice(name: name.isEmpty ? nil : name, id: record.encryptedValues["id"] as? String ?? ""))
        } catch let error as CKError where error.code == .unknownItem {
            return .some(nil)
        } catch {
            return nil
        }
    }
}
