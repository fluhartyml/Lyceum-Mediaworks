//
//  AboutView.swift
//  mediaworks
//
//  The About panel. Its job is to say, out loud and off the screen, exactly which build
//  this is — the build-number standard.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Lyceum Mediaworks")
                .font(.lyceumTitle)
            Text(BuildStamp.summary)
                .font(.lyceumBody)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("Your folders, playlists and tags as the front door of your media library.")
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Free and open source. By Michael Fluharty, engineered with Claude.")
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(minWidth: 520)
    }
}

#Preview {
    AboutView()
}
