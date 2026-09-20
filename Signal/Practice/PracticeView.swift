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
    enum Pane: String, CaseIterable, Identifiable {
        case type, recall, write, progress, web
        var id: String { rawValue }
        var label: String {
            switch self {
            case .type: "type"
            case .recall: "recall"
            case .write: "write"
            case .progress: "progress"
            case .web: "web"
            }
        }
        var symbol: String {
            switch self {
            case .type: "keyboard"
            case .recall: "eye"
            case .write: "square.and.pencil"
            case .progress: "chart.xyaxis.line"
            case .web: "safari"
            }
        }
    }

    @AppStorage("Practice.section") private var sectionRaw = Pane.type.rawValue
    private var section: Binding<Pane> {
        Binding(get: { Pane(rawValue: sectionRaw) ?? .type }, set: { sectionRaw = $0.rawValue })
    }
    @StateObject private var race = RaceModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            PracticeTheme.paper.ignoresSafeArea()

            Group {
                switch section.wrappedValue {
                case .type: TypeView(model: race)
                case .recall: RecallView()
                case .write: WriteView()
                case .progress: ProgressTabView()
                case .web: ReadWebView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.bottom, 72)

            sectionBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .opacity(race.isTyping ? 0.15 : 1)
                .animation(.easeOut(duration: 0.25), value: race.isTyping)
        }
        .tint(PracticeTheme.accent)
    }

    /// The trainer's tabs, floating at the bottom in glass.
    private var sectionBar: some View {
        HStack(spacing: 0) {
            ForEach(Pane.allCases) { s in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { section.wrappedValue = s }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: s.symbol).font(.system(size: 17, weight: .medium))
                        Text(s.label).font(.system(size: 10, weight: .semibold, design: .monospaced)).kerning(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(section.wrappedValue == s ? PracticeTheme.accent : PracticeTheme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(s.label))
            }
        }
        .padding(.horizontal, 6)
        .practiceGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - Header shared by the sections

@available(iOS 16, *)
struct PracticeHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Qiuling").font(.system(size: 15, weight: .bold, design: .monospaced)).kerning(2.4).textCase(.uppercase)
                    .foregroundStyle(PracticeTheme.ink)
                Text(title).practiceLabel()
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(PracticeTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}
