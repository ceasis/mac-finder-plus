import SwiftUI

struct RatingStarsView: View {
    let rating: Int
    var size: CGFloat = 9
    var showEmpty = true

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(value <= rating ? Color.yellow : Color.secondary.opacity(0.45))
                    .opacity(showEmpty || value <= rating ? 1 : 0)
            }
        }
        .accessibilityLabel(rating == 0 ? "Unrated" : "\(rating) stars")
    }
}
