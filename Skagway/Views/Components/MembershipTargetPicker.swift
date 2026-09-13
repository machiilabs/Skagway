import SwiftUI

/// Picker for Membership rule values: smart libraries and albums (not saved smart collections).
struct MembershipTargetPicker: View {
    @Binding var storageToken: String
    var collections: [VideoCollection]

    private var selectedLabel: String {
        guard let target = MembershipTarget(storageToken: storageToken) else {
            return "Choose…"
        }
        return target.displayLabel(collections: collections)
    }

    private var albums: [VideoCollection] {
        collections.filter(\.isAlbum).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu {
            Section("Smart Libraries") {
                ForEach(SmartLibraryKind.allCases) { kind in
                    Button(kind.label) {
                        storageToken = MembershipTarget.smartLibrary(kind).storageToken
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        if let id = album.id {
                            Button(album.name) {
                                storageToken = MembershipTarget.album(id).storageToken
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.appSurface.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { ensureDefaultSelection() }
    }

    private func ensureDefaultSelection() {
        guard MembershipTarget(storageToken: storageToken) == nil else { return }
        storageToken = MembershipTarget.smartLibrary(.recentlyAdded).storageToken
    }
}
