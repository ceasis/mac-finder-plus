import SwiftUI

struct CompareMarkerBadge: View {
    let marker: FolderCompareMarker

    var body: some View {
        Label(marker.title, systemImage: marker.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(marker.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(marker.color.opacity(0.12), in: Capsule())
    }
}

extension FolderCompareMarker {
    var color: Color {
        switch self {
        case .onlyHere:
            Color.blue
        case .newerHere:
            Color.green
        case .olderHere:
            Color.orange
        case .different:
            Color.red
        }
    }

    var systemImage: String {
        switch self {
        case .onlyHere:
            "plus.circle.fill"
        case .newerHere:
            "arrow.up.circle.fill"
        case .olderHere:
            "arrow.down.circle.fill"
        case .different:
            "exclamationmark.circle.fill"
        }
    }
}
