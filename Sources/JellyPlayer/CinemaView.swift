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
