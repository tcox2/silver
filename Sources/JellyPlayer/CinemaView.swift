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
                Text("home cinema")
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
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
            fputs("Playback engine attachment failed: \(error.localizedDescription)\n", stderr)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.preferredDynamicRange = hdr ? .high : .standard
    }
}
