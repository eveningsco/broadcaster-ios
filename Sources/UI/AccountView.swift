import SwiftUI

/// The account sheet, opened from the gear in the library card's header:
/// the station photo, the station name with its evenings.fm address, and a
/// Sign Out button. Sign-out is confirmed first because it stops anything
/// playing or recording and clears the device session (AppModel.logout).
struct AccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    private var station: AppModel.AccountStation { model.accountStation }
    private var stationName: String { station.name ?? "Your station" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                StationPhoto(url: station.imageURL)
                    .frame(width: 132, height: 132)

                Text(stationName)
                    .font(.custom("ETBembo-SemiBoldOSF", size: 34, relativeTo: .largeTitle))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 20)

                if let slug = station.slug {
                    Text("evenings.fm/\(slug)")
                        .font(.social(.body))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                Spacer(minLength: 0)

                Button {
                    confirmingSignOut = true
                } label: {
                    Text("Sign Out")
                        .font(.social(.body, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.primary.opacity(0.08))
                        .foregroundStyle(Color.eveningsRed)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sign out of \(stationName)?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    // Clearing the session swaps the root to the sign-in
                    // screen, which takes this sheet down with it.
                    model.logout()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Anything playing or recording on this phone will stop.")
            }
        }
        .presentationDetents([.medium])
        .modifier(OpaqueSheetBackground())
    }
}

/// Opaque sheet background: the system's translucent sheet lets the go-live
/// circle and the list rows bleed through behind the title. The modifier
/// arrived in iOS 16.4; earlier systems keep the default. Shared by the
/// account and track detail sheets.
struct OpaqueSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(Color(.secondarySystemBackground))
        } else {
            content
        }
    }
}

/// Station photo: a square with continuous rounded corners, the same shape
/// the website and the library's track artwork use (profile photos on
/// Evenings are square, not circular). While loading, or when the station
/// has none, a soft rounded square with the Evenings starburst stands in.
struct StationPhoto: View {
    let url: URL?
    /// 24pt on the sheet's 132pt photo keeps the 8pt-on-44pt proportion of
    /// TrackArtwork.
    var cornerRadius: CGFloat = 24

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape
                .fill(.quaternary)
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    case .failure:
                        placeholder
                    case .empty:
                        Color.clear
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(shape)
        .accessibilityLabel("Station photo")
    }

    private var placeholder: some View {
        GeometryReader { proxy in
            Image("EveningsLogo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: proxy.size.width * 0.5)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
