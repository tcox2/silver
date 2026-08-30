import AppKit
import SwiftUI

struct CinemaView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(controller: model.mpv, hdr: model.isHDR)
                .ignoresSafeArea()
            if !model.hasPlayback {
                VStack(spacing: 18) {
                    Text("home cinema")
                        .font(.system(size: 68, weight: .light, design: .rounded))
                    Text("http://192.168.4.146:8099")
                        .font(.system(size: 32, weight: .light, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if model.catalogReady {
                        Text("CATALOGUE OUTPUT MODES")
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
                    } else {
                        VStack(spacing: 12) {
                            if let total = model.catalogTotalItems, total > 0 {
                                ProgressView(value: Double(model.catalogLoadedItems), total: Double(total))
                                    .frame(maxWidth: 700)
                            } else {
                                ProgressView()
                            }
                            Text(model.catalogLoadMessage)
                                .font(.system(size: 22, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 18)
                    }
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
        let view = MPVOpenGLView()
        do {
            try controller.attach(to: view)
        } catch {
            controller.recordAttachmentFailure(error)
            SilverLog.error("Playback engine attachment failed: \(error.localizedDescription)")
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.preferredDynamicRange = hdr ? .high : .standard
    }
}
