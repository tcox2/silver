import AppKit
import SwiftUI

struct CinemaView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.hasPlayback {
                PlayerSurface(controller: model.mpv, hdr: model.isHDR)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 18) {
                    Text("home cinema")
                        .font(.system(size: 68, weight: .light, design: .rounded))
                    Text("http://192.168.4.146:8099")
                        .font(.system(size: 32, weight: .light, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("AVAILABLE PROJECTOR MODES")
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 13) {
                        ForEach(model.configuredOutputModeDescriptions, id: \.self) { mode in
                            Text(mode)
                                .font(.system(size: 21, weight: .regular, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                    }
                    .frame(maxWidth: 2200)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 70)
                Rectangle()
                    .stroke(.white, lineWidth: 8)
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
    }

}

private struct PlayerSurface: NSViewRepresentable {
    let controller: MPVController
    let hdr: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        do {
            try controller.attach(to: view)
        } catch {
            SilverLog.error("Playback engine attachment failed: \(error.localizedDescription)")
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.preferredDynamicRange = hdr ? .high : .standard
    }
}
