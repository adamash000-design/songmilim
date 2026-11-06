import SwiftUI
import AVKit

/// תמונת אלבום עם מחליף כשאין תמונה
struct CoverArt: View {
    let url: URL?
    var size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color(.tertiarySystemFill)
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.12))
        .accessibilityHidden(true)
    }
}

/// שורה של שיר / פלייליסט
struct MediaRow: View {
    let title: String
    let subtitle: String
    let artURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            CoverArt(url: artURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// כפתור AirPlay – שולח את הצליל לרמקולי Sonos (AirPlay 2) או לכל רמקול אחר
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct StatusRow: View {
    let title: String
    let ok: Bool
    var detail: String?

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(ok ? "מחובר" : "לא מחובר")
    }
}
