import SwiftUI
import UIKit

/// Shared feedback generators so they stay warm across gesture updates.
private enum SheetHaptics {
    static let tick = UIImpactFeedbackGenerator(style: .light)
    static let snap = UIImpactFeedbackGenerator(style: .medium)

    static func prepare() {
        tick.prepare()
        snap.prepare()
    }
}

/// Home layout: the livestream stage (BroadcastView) sits at the back, with the
/// library floating over it as a custom draggable sheet. Pulling the sheet down
/// reveals the stage — that's how you enter livestream mode; pulling it back up
/// returns to the library. When a broadcast ends the sheet springs back up to
/// show the new recording.
struct HomeView: View {
    enum SheetTab: String, CaseIterable {
        case library = "Library"
        case explore = "Explore"
    }

    @EnvironmentObject private var model: AppModel
    @State private var libraryExpanded = true
    @State private var listAtTop = true
    @State private var sheetTab: SheetTab = .library
    @GestureState private var dragTranslation: CGFloat = 0

    /// How much of the stage stays visible above the expanded sheet.
    private let expandedTopInset: CGFloat = 72
    /// Height of the collapsed sheet's peek bar.
    private let peekHeight: CGFloat = 76

    var body: some View {
        GeometryReader { geometry in
            let collapsedOffset = geometry.size.height - peekHeight
            let baseOffset = libraryExpanded ? expandedTopInset : collapsedOffset
            let offset = min(max(baseOffset + dragTranslation, expandedTopInset), collapsedOffset)
            let isCollapsedLook = offset > (expandedTopInset + collapsedOffset) / 2

            ZStack(alignment: .top) {
                BroadcastView(
                    broadcast: model.broadcast,
                    title: isCollapsedLook ? "Go Live" : sheetTab.rawValue
                )
                    .padding(.bottom, peekHeight)
                    .background(Color(.systemGray5).ignoresSafeArea())

                librarySheet(
                    collapsed: isCollapsedLook,
                    bottomInset: expandedTopInset + geometry.safeAreaInsets.bottom
                )
                    .offset(y: offset)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: offset)
            }
            .ignoresSafeArea(edges: .bottom)
            .onPreferenceChange(LibraryScrollOffsetKey.self) { minY in
                listAtTop = minY >= -1
            }
            // Light tick as the drag crosses the commit point (either direction)...
            .onChange(of: isCollapsedLook) { _ in
                SheetHaptics.tick.impactOccurred()
            }
            // ...and a firmer thump when the sheet snaps into place.
            .onChange(of: libraryExpanded) { expanded in
                SheetHaptics.snap.impactOccurred(intensity: 0.9)
                // Live level meter while the stage is showing (mic check
                // before going live); release the mic when browsing.
                if expanded {
                    model.broadcast.stopMonitoring()
                } else {
                    model.player.stop()
                    model.broadcast.startMonitoring()
                }
            }
            .onChange(of: model.broadcast.state.isActive) { active in
                if !active {
                    libraryExpanded = true
                    Task { await model.refreshLibraryAfterBroadcast() }
                }
            }
        }
    }

    private func librarySheet(collapsed: Bool, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $sheetTab) {
                ForEach(SheetTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if sheetTab == .library {
                LibraryListView()
            } else {
                ExploreListView()
            }
        }
            // The sheet is a full-height surface offset downward, so give the
            // list back the space that hangs below the screen edge — otherwise
            // the end of the library can never scroll into view.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: bottomInset)
            }
            .opacity(collapsed ? 0 : 1)
            .overlay(alignment: .top) {
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
                    .padding(.top, 30)
                    .opacity(collapsed ? 1 : 0)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 28, topTrailing: 28))
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.12), radius: 16, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
        .simultaneousGesture(sheetDrag)
        .onTapGesture {
            if !libraryExpanded {
                libraryExpanded = true
            }
        }
    }

    /// Whole-sheet drag. When the sheet is expanded it engages only while the
    /// list is scrolled to the top and the pull is downward, so normal list
    /// scrolling is untouched; when collapsed any drag moves the sheet.
    private var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                let pullingDown = value.translation.height > 0
                if !libraryExpanded || (listAtTop && pullingDown) {
                    if state == 0 {
                        SheetHaptics.prepare()
                    }
                    state = value.translation.height
                }
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                if libraryExpanded, listAtTop, projected > 60 {
                    libraryExpanded = false
                } else if !libraryExpanded, projected < -60 {
                    libraryExpanded = true
                }
            }
    }
}

/// Reports the library scroll content's top edge so HomeView knows when the
/// list is at the top (and a downward pull should move the sheet instead).
struct LibraryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
