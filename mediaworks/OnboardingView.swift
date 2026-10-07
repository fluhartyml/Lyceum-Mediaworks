//
//  OnboardingView.swift
//  mediaworks
//
//  First launch only: choose the parent folder that houses the media library.
//  Michael: "right now i only want this finder workflow in the onboarding and for
//  onboarding i want to pick a parent folder that houses my media library."
//

import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library
    @State private var choosingFolder = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Welcome to Lyceum Mediaworks")
                .font(.lyceumTitle)
            Text(library.needsWriteAccess
                 ? "Lyceum Mediaworks can now organize your files. Choose your library folder once more to give it permission to move, rename and trash."
                 : "Choose the parent folder that houses your media library — on this device, a drive, or a network share.")
                .font(.lyceumBody)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Button { choosingFolder = true } label: { Text("Choose Library Folder…").font(.lyceumBody) }
                .font(.lyceumBody)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("In the window that opens, click the folder once to highlight it, then click Open.")
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text(BuildStamp.summary)
                .font(.lyceumBody)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
    }
}

#Preview {
    OnboardingView()
        .environment(LibraryStore())
}
