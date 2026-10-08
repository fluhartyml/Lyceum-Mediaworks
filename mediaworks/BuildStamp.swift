//
//  BuildStamp.swift
//  mediaworks
//
//  ⚠️ THE VALUES BELOW ARE REWRITTEN BY `Scripts/stamp-build.sh`. Do not hand-edit them.
//  Installed 2026-10-06, before the first build: every build carries
//  CURRENT_PROJECT_VERSION = git rev-list --count HEAD, and the app shows it.
//

import Foundation

enum BuildStamp {
    /// Short SHA of HEAD when this build was stamped. "+" suffix = uncommitted changes.
    static let commit = "a529440"

    /// Branch HEAD was on when this build was stamped.
    static let branch = "main"

    /// Local time the stamp was generated — effectively the build time.
    static let built = "2026-10-08 08:38"

    /// True when this binary was never stamped. Not a missing answer — it IS the answer:
    /// this build predates stamping, so it is older than any stamped one.
    static var isStamped: Bool { commit != "unstamped" }

    /// The build number — `CURRENT_PROJECT_VERSION`, which is the git commit count.
    ///
    /// ⚠️ READ FROM THE BUNDLE, NOT STAMPED INTO THIS FILE. It is already written into
    /// the project by `Scripts/stamp-build.sh`, and a second copy here could disagree
    /// with the first. One source, so there is nothing to keep in step.
    static var number: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Marketing version, for the line that gets read out loud.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// One line, readable out loud off the screen by someone who cannot see Xcode.
    static var summary: String {
        isStamped
            ? "Version \(version)  ·  Build \(number)  ·  \(commit) (\(branch))  ·  built \(built)"
            : "Version \(version)  ·  Build \(number)  ·  unstamped build"
    }
}
