import SwiftUI

private func buildDate(of executableURL: URL?) -> String {
    guard let url = executableURL,
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let date = attrs[.modificationDate] as? Date else { return "unknown" }
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .short
    return fmt.string(from: date)
}

struct ContentView: View {
    private let supportedTypes = [
        ".nii",
        ".nii.gz",
        ".mgh",
        ".mgz",
        ".mgh.gz",
        ".mif",
        ".mif.gz"
    ]

    private let cardWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Text("MIQ - Medical Image Quick Look")
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Text("Supported File Types")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(supportedTypes, id: \.self) { fileType in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(fileType)
                            .font(.body.monospaced())
                    }
                }
            }
            .frame(width: cardWidth, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(minWidth: 380, minHeight: 260, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #if DEBUG
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let appDate = buildDate(of: Bundle.main.executableURL)
            let extExec = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("MIQQuickLookExtension.appex/Contents/MacOS/MIQQuickLookExtension")
            let extDate = buildDate(of: extExec)
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("App built: \(appDate)")
                    Spacer()
                    Text("Extension built: \(extDate)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
        #endif
    }
}
