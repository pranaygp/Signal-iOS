//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Charts
import SignalUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Write

/// Type English, see it in the script, send it as a picture: the messaging
/// apps draw everything in the system font, so a message travels as an image.
@available(iOS 16, *)
struct WriteView: View {
    @AppStorage("Practice.draft") private var draft = ""
    @State private var rendered: UIImage?
    @State private var status = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Type here, then share the picture into any chat.")
                    .font(.footnote).foregroundStyle(PracticeTheme.muted).padding(.horizontal, 20).padding(.top, 8)
                PracticeEditor(text: $draft).padding(.horizontal, 16)
                Group {
                    if draft.isEmpty {
                        Text("what you type appears here in the script").font(.system(size: 13)).foregroundStyle(PracticeTheme.faint)
                    } else {
                        Text(draft).font(PracticeTheme.script(44)).lineSpacing(8)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .practiceCard()
                    .padding(.horizontal, 16)
                HStack(spacing: 10) {
                    if let rendered {
                        ShareLink(item: Image(uiImage: rendered), preview: SharePreview("Qiuling", image: Image(uiImage: rendered)))
                            .practicePrimaryButton()
                    }
                    Button("Copy", systemImage: "doc.on.doc") {
                        if let img = render() { UIPasteboard.general.image = img; status = "copied — paste it into the chat" }
                    }.practiceSecondaryButton()
                    Text(status).font(.system(size: 11, design: .monospaced)).foregroundStyle(PracticeTheme.muted)
                }
                .padding(.horizontal, 20)
            }
        }
        .onChange(of: draft) { _ in rendered = render() }
        .onAppear { rendered = render() }
    }

    /// The message as a PNG at 2×, in the theme's colours, wrapped to a chat's width.
    @MainActor
    private func render() -> UIImage? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let view = Text(text)
            .font(PracticeTheme.script(56)).lineSpacing(10)
            .foregroundStyle(PracticeTheme.ink)
            .padding(40)
            .frame(width: 900, alignment: .leading)
            .background(PracticeTheme.paper)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }
}

// MARK: - Progress

@available(iOS 16, *)
struct ProgressTabView: View {
    @ObservedObject private var store = PracticeStore.shared
    @State private var confirmReset = false

    var body: some View {
        let sessions = store.book.sessions
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(sessions.isEmpty ? "Race once and this fills in." : "\(sessions.count) runs · best \(store.best) wpm")
                    .font(.footnote).foregroundStyle(PracticeTheme.muted).padding(.horizontal, 20).padding(.top, 8)
                if !sessions.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 28) {
                        big("\(sessions.last!.wpm)", "last wpm")
                        big("\(store.best)", "best")
                        big("\(Int(Double(sessions.suffix(10).map(\.accuracy).reduce(0, +)) / Double(min(10, sessions.count)).rounded()))", "accuracy, last 10", small: true)
                    }
                    .padding(.horizontal, 20)

                    if #available(iOS 16, *) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("words per minute").practiceLabel()
                            Chart(Array(sessions.suffix(60).enumerated()), id: \.offset) { i, s in
                                PointMark(x: .value("run", i), y: .value("wpm", s.wpm)).foregroundStyle(s.wpm >= store.best ? PracticeTheme.good : PracticeTheme.faint).symbolSize(28)
                                LineMark(x: .value("run", i), y: .value("wpm", trend(sessions.suffix(60), at: i))).foregroundStyle(PracticeTheme.ink).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(PracticeTheme.line); AxisValueLabel().font(.system(size: 9, design: .monospaced)).foregroundStyle(PracticeTheme.muted) } }
                            .frame(height: 160)
                        }
                        .padding(18).practiceCard().padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("recent runs").practiceLabel()
                        ForEach(sessions.suffix(8).reversed()) { s in
                            HStack {
                                Text(s.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.muted)
                                Text(s.mode).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.faint)
                                Spacer()
                                Text("\(s.seconds)s").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.muted)
                                Text("\(s.wpm) wpm").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.ink).frame(width: 64, alignment: .trailing)
                                Text("\(s.accuracy)%").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.muted).frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(18).practiceCard().padding(.horizontal, 16)

                    let hard = store.hardest()
                    if !hard.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("marks you get wrong most").practiceLabel()
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                                ForEach(hard.prefix(12), id: \.text) { m in
                                    VStack(spacing: 4) {
                                        Text(m.text).font(PracticeTheme.script(30))
                                        Text(m.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(PracticeTheme.muted)
                                        Text("\(m.record.wrong)/\(m.record.seen)").font(.system(size: 10, design: .monospaced)).foregroundStyle(PracticeTheme.accent)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(PracticeTheme.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                        .padding(18).practiceCard().padding(.horizontal, 16)
                    }
                }

                RecallProgressSection(book: store.book)

                if !sessions.isEmpty || !store.book.recall.isEmpty {
                    Button("Reset this alphabet", systemImage: "trash", role: .destructive) { confirmReset = true }.practiceSecondaryButton().padding(.horizontal, 20)
                        .confirmationDialog("Forget every run, mark and recall box for \(QiulingFonts.buildId)?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) { store.reset() }
                        }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func trend(_ s: ArraySlice<PracticeStore.Session>, at i: Int) -> Double {
        let arr = Array(s); let lo = max(0, i - 4), hi = min(arr.count - 1, i + 4)
        let w = arr[lo...hi].map(\.wpm); return Double(w.reduce(0, +)) / Double(w.count)
    }

    private func big(_ value: String, _ label: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: small ? 24 : 44, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(small ? PracticeTheme.muted : PracticeTheme.ink)
            Text(label).practiceLabel()
        }
    }
}

// MARK: - Read the web

/// The Safari bookmark that sets any page in the script, with the current
/// font carried inside it. A port of the trainer's `reader.js`.
@available(iOS 16, *)
struct ReadWebView: View {
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A Safari bookmark that sets any page in the script, at twice its size. Tap it again to put the page back.")
                    .font(.footnote).foregroundStyle(PracticeTheme.muted).padding(.horizontal, 20).padding(.top, 8)
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Copy the bookmark link below.\n2. In Safari, bookmark any page (share sheet → Add Bookmark).\n3. Bookmarks → Edit → choose it → paste the link over its address.\n4. From then on, tap it in Bookmarks while on any page.")
                        .font(.system(size: 14)).foregroundStyle(PracticeTheme.ink).lineSpacing(4)
                    Text("The font travels inside the bookmark, so nothing is installed or fetched, and it carries whatever alphabet this app currently has.")
                        .font(.system(size: 13)).foregroundStyle(PracticeTheme.muted)
                    HStack {
                        Button("Copy bookmark link", systemImage: "link") {
                            if let link = Self.bookmarklet() {
                                UIPasteboard.general.setValue(link, forPasteboardType: UTType.plainText.identifier)
                                status = "copied (\(link.count / 1024) KB)"
                            } else { status = "no font available" }
                        }.practicePrimaryButton()
                        Text(status).font(.system(size: 11, design: .monospaced)).foregroundStyle(PracticeTheme.muted)
                    }
                }
                .padding(18).practiceCard().padding(.horizontal, 16)
            }
        }
    }

    private static let keep = ":is(svg, code, pre, kbd, samp, tt, input, textarea, select, option, [contenteditable], .material-icons, .material-icons-outlined, .material-symbols-outlined, [class^=\"fa-\"], [class*=\" fa-\"], .fa, .fas, .far, .fab, .glyphicon, .icon, i[class*=\"icon\"], span[class*=\"icon\"])"

    // The in-page routine, verbatim from web/reader.js.
    private static let apply = """
    function qiulingApply(id, css, keep, scale, on) {
      var W = window, style = document.getElementById(id);
      if (!on) {
        if (style) style.remove();
        var undo = W.__qiulingUndo || [];
        for (var i = 0; i < undo.length; i++) {
          var u = undo[i];
          for (var p in u.prev) {
            if (u.prev[p][0]) u.el.style.setProperty(p, u.prev[p][0], u.prev[p][1]);
            else u.el.style.removeProperty(p);
          }
          if (!u.el.getAttribute('style')) u.el.removeAttribute('style');
        }
        delete W.__qiulingUndo;
        return false;
      }
      if (style) return true;
      var els = document.querySelectorAll('body, body *'), snap = [];
      for (var j = 0; j < els.length; j++) {
        var e = els[j];
        if (e.closest(keep)) continue;
        var cs = getComputedStyle(e);
        snap.push([e, parseFloat(cs.fontSize), cs.lineHeight]);
      }
      var log = [];
      for (var k = 0; k < snap.length; k++) {
        var el = snap[k][0], prev = {};
        var set = function (prop, value) {
          prev[prop] = [el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)];
          el.style.setProperty(prop, value, 'important');
        };
        if (snap[k][1] > 0) set('font-size', snap[k][1] * scale + 'px');
        if (/px$/.test(snap[k][2])) set('line-height', parseFloat(snap[k][2]) * scale + 'px');
        log.push({ el: el, prev: prev });
      }
      W.__qiulingUndo = log;
      style = document.createElement('style');
      style.id = id;
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
      return true;
    }
    """

    static func bookmarklet() -> String? {
        guard let data = QiulingFonts.shared.currentFontData() else { return nil }
        let css = """
        @font-face { font-family: "Qiuling Reader"; src: url("data:font/ttf;base64,\(data.base64EncodedString())") format("truetype"); font-display: block; }
        html body, html body *:not(\(keep)):not(\(keep) *) { font-family: "Qiuling Reader", system-ui, sans-serif !important; letter-spacing: normal !important; }
        """
        func js(_ s: String) -> String { String(data: try! JSONEncoder().encode(s), encoding: .utf8)! }
        let id = "qiuling-reader-style"
        let src = "(\(apply))(\(js(id)), \(js(css)), \(js(keep)), 2, !document.getElementById(\(js(id))));"
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return "javascript:" + (src.addingPercentEncoding(withAllowedCharacters: allowed) ?? src)
    }
}
