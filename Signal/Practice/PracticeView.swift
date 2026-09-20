//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// The reading trainer, as a tab: race sentences in the script, test recall
/// of single marks, write something to send as a picture, watch progress,
/// and take the script to Safari. Native throughout; the engine is a port of
/// the web trainer's.
@available(iOS 16, *)
struct PracticeView: View {
    enum Page: Hashable { case recall, write, progress, web }

    @StateObject private var race = RaceModel()
    @State private var path: [Page] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                PracticeTheme.paper.ignoresSafeArea()
                TypeView(model: race)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Page.self) { page in
                ZStack {
                    PracticeTheme.paper.ignoresSafeArea()
                    switch page {
                    case .recall: RecallView()
                    case .write: WriteView()
                    case .progress: ProgressTabView()
                    case .web: ReadWebView()
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .environment(\.practiceNavigate, PracticeNavigate { path.append($0) })
        .tint(PracticeTheme.accent)
    }
}

/// How the landing screen's header opens the other sections.
@available(iOS 16, *)
struct PracticeNavigate {
    let go: (PracticeView.Page) -> Void
    func callAsFunction(_ page: PracticeView.Page) { go(page) }
}

@available(iOS 16, *)
private struct PracticeNavigateKey: EnvironmentKey {
    static let defaultValue = PracticeNavigate { _ in }
}

@available(iOS 16, *)
extension EnvironmentValues {
    var practiceNavigate: PracticeNavigate {
        get { self[PracticeNavigateKey.self] }
        set { self[PracticeNavigateKey.self] = newValue }
    }
}

// MARK: - Header shared by the sections

@available(iOS 16, *)
struct PracticeHeader: View {
    let title: String
    var subtitle: String? = nil
    var showsActions = false
    @Environment(\.practiceNavigate) private var navigate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Qiuling").font(.system(size: 15, weight: .bold, design: .monospaced)).kerning(2.4).textCase(.uppercase)
                    .foregroundStyle(PracticeTheme.ink)
                Text(title).practiceLabel()
                if showsActions {
                    Spacer()
                    HStack(spacing: 4) {
                        action("eye", "Recall") { navigate(.recall) }
                        action("chart.xyaxis.line", "Progress") { navigate(.progress) }
                        Menu {
                            Button { navigate(.write) } label: { Label("Write a message", systemImage: "square.and.pencil") }
                            Button { navigate(.web) } label: { Label("Read the web in Qiuling", systemImage: "safari") }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                                .frame(width: 34, height: 34).contentShape(Rectangle())
                        }
                        .accessibilityLabel("More")
                    }
                    .foregroundStyle(PracticeTheme.ink)
                    .practiceGlass()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                }
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(PracticeTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func action(_ symbol: String, _ label: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
