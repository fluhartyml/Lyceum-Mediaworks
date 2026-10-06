//
//  ContentView.swift
//  mediaworks
//
//  Created by Michael Fluharty on 10/6/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Lyceum Mediaworks")
                .font(.system(size: 28, weight: .semibold))
            // The build stamp, readable out loud off the screen — the build-number standard.
            Text(BuildStamp.summary)
                .font(.system(size: 18))
                .textSelection(.enabled)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
