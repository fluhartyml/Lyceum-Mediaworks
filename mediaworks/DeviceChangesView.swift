//
//  DeviceChangesView.swift
//  mediaworks
//
//  Mac only: every change a phone or iPad made, newest first, each with Undo.
//
// REM  HIS RULE, 2026-10-10 (platforms 002e/f, LOCKED): "since the mac is the gate keeper and you change something on another
// REM  device the change should need to be able to be reversed if the mac (user) disaproves." The Mac applies a device's
// REM  change at once (nobody waits) and lists it here — which device, what, when, before → after — with Undo, which puts
// REM  the old value back and passes the reversal to every device.
//

#if os(macOS)
import SwiftUI

struct DeviceChangesView: View {
    private let catalog = LibraryCatalog.shared

    var body: some View {
        Group {
            if catalog.deviceChanges.isEmpty {
                ContentUnavailableView("No changes from other devices yet", systemImage: "iphone",
                                       description: Text("Checkmarks, thumbs up and thumbs down made on an iPhone or iPad show here, each with Undo."))
            } else {
                List(catalog.deviceChanges) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(change.when.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .leading)
                        Text(change.device).frame(width: 160, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.what(change.op)) · \((change.path as NSString).lastPathComponent)")
                            Text(Self.before(change)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let undone = change.undone {
                            Text("Undone \(undone.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                        } else {
                            Button("Undo") { catalog.undo(change) }
                                .lyceumHelp("Undo — put this file back the way it was before, on every device")
                        }
                    }
                    .opacity(change.undone == nil ? 1 : 0.55)
                }
            }
        }
        .font(.lyceumBody)
        .frame(minWidth: 820, minHeight: 420)
    }

    private static func before(_ change: DeviceChange) -> String {
        if let trashedTo = change.trashedTo { return "Now in the Trash: \(trashedTo)" }
        if let old = change.beforeTags, let new = change.tags {
            return old.keys.sorted().map { key in
                let label = TagField(rawValue: key).map { "\($0.number) \($0.label)" } ?? key
                return "\(label): “\(old[key] ?? "")” → “\(new[key] ?? "")”"
            }.joined(separator: " · ") + (change.beforePicture != nil ? " · picture replaced" : "")
        }
        return "Before: \(change.wasChecked ? "checked" : "unchecked")\(change.wasThumbedUp ? ", in Thumbs Up" : "")"
    }

    private static func what(_ op: CacheRequest.Op) -> String {
        switch op {
        case .get: "Looked"
        case .check: "Checked"
        case .uncheck: "Unchecked"
        case .thumbsUp: "👍 Thumbs up"
        case .thumbsDown: "👎 Thumbs down"
        case .file: "Copied"
        case .setTags: "Changed tags"
        case .trash: "Moved to Trash"
        }
    }
}
#endif
