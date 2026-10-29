#if LUMEN_HUB
import LumenAssistant
import LumenLook
import SwiftUI

/// "Check on camera" — inside the Assistant pane. Per device: an area drawn on
/// one camera, travel time, a test button and the last result with its proof.
struct LookSection: View {
    @Bindable var look: LookService
    let devices: [Device]
    @State private var editing: Device?
    @State private var visionURL = ""

    private var checkable: [Device] { devices.filter { $0.exposed && LookService.lookKind(for: $0.kind) != nil } }

    var body: some View {
        Section {
            Toggle(LL("Check on camera after each action"), isOn: Binding(get: { look.prefs.enabled },
                                                                          set: { on in look.update { $0.enabled = on } }))
            if checkable.isEmpty {
                Text(LL("Allow lights, TVs, shutters or doors above to check them on a camera.")).foregroundStyle(.secondary)
            }
            ForEach(checkable) { device in
                row(device)
            }
        } header: {
            Text(LL("Check on camera"))
        } footer: {
            Text(LL("Draw a box around the device on one camera. After a command, Lumen looks once the device has had time to move. It says “checked” only when it sees it."))
        }
        .sheet(item: $editing) { device in
            LookAreaEditor(look: look, device: device) { editing = nil }
        }
        Section {
            Toggle(LL("Ask the vision model when unsure"), isOn: Binding(get: { look.prefs.useModel },
                                                                         set: { on in look.update { $0.useModel = on } }))
            HStack {
                TextField(LL("Vision model address"), text: $visionURL, prompt: Text(verbatim: "http://127.0.0.1:8012"))
                    .onSubmit { look.update { $0.visionURL = visionURL } }
                Button(LL("Test")) {
                    look.update { $0.visionURL = visionURL }
                    Task { await look.testVision() }
                }
            }
            switch look.vision {
            case .ok: Label(LL("Vision model ready"), systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let why): Label(why, systemImage: "xmark.circle").foregroundStyle(.secondary)
            case .checking: ProgressView().controlSize(.small)
            case .unknown: EmptyView()
            }
            Picker(LL("Keep proof pictures"), selection: Binding(get: { look.prefs.proofHours },
                                                                 set: { h in look.update { $0.proofHours = h } })) {
                Text(LL("1 hour")).tag(1.0)
                Text(LL("24 hours")).tag(24.0)
                Text(LL("7 days")).tag(168.0)
            }
        } footer: {
            Text(LL("llama-server with Qwen3-VL. Only the cropped box is sent, on this Mac. Proof pictures stay on this Mac and are never in notifications."))
        }
        .onAppear { visionURL = look.prefs.visionURL }
    }

    @ViewBuilder
    private func row(_ device: Device) -> some View {
        let target = look.target(device.entityID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    if let target {
                        Text(String(format: LL("%@ camera · %@"), LookPhrases.cameraName(target.camera), kindName(target.kind)))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(LL("No area yet")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(target == nil ? LL("Draw area on camera") : LL("Redraw")) { editing = device }
                    .accessibilityLabel(String(format: LL(target == nil ? "Draw area for %@" : "Redraw area for %@"), device.name))
                if target != nil {
                    Button(LL("Test")) { Task { await look.test(device.entityID) } }
                        .disabled(look.testing.contains(device.entityID))
                        .accessibilityLabel(String(format: LL("Test %@ now"), device.name))
                }
            }
            if let target {
                Stepper(value: Binding(get: { target.travelSeconds },
                                       set: { s in Task { await look.setTravel(device.entityID, seconds: s) } }),
                        in: 0.5...120, step: target.travelSeconds < 10 ? 0.5 : 5) {
                    Text(String(format: LL("Look after %@ s"), format(target.travelSeconds)))
                }
                if let result = look.lastResults[device.entityID] {
                    LookResultRow(look: look, result: result, kind: target.kind)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func format(_ s: Double) -> String { s.rounded() == s ? String(Int(s)) : String(format: "%.1f", s) }

    func kindName(_ k: LookDeviceKind) -> String { Self.kindName(k) }

    static func kindName(_ k: LookDeviceKind) -> String {
        switch k {
        case .light: LL("Light")
        case .tv: LL("TV")
        case .shutter: LL("Shutters")
        case .door: LL("Door")
        }
    }
}

/// Last result: outcome, sentence, time, proof thumbnail.
struct LookResultRow: View {
    let look: LookService
    let result: LookResult
    let kind: LookDeviceKind
    @State private var proof: CGImage?

    /// The stored sentence is in the language of the command; the row follows the app.
    private var sentence: String {
        let lang = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? "fr" : "en"
        return LookPhrases.message(for: result.outcome, kind: kind, expected: result.expected, camera: result.camera,
                                   source: result.source, retried: result.retried, language: lang,
                                   commandSent: result.manualTest != true)
    }

    private var sourceName: String {
        switch result.source {
        case .pixels: LL("picture")
        case .frigateClassifier: LL("Frigate model")
        case .visionModel: LL("vision model")
        case .device: LL("device")
        case .scene: LL("scene")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let proof {
                Image(decorative: proof, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(LL("Proof picture"))
            }
            VStack(alignment: .leading, spacing: 2) {
                Label(sentence, systemImage: icon)
                    .foregroundStyle(color)
                Text(result.checkedAt, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: LL("%@ ms · %@"), String(Int(result.timing.totalMs)), sourceName))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .task(id: result.proofFile) {
            proof = nil
            if let name = result.proofFile { proof = await look.proof(name) }
        }
    }

    private var icon: String {
        switch result.outcome {
        case .confirmed: "checkmark.circle.fill"
        case .contradicted: "exclamationmark.triangle.fill"
        case .unknown: "eye.slash"
        }
    }

    private var color: Color {
        switch result.outcome {
        case .confirmed: .green
        case .contradicted: .orange
        case .unknown: .secondary
        }
    }
}

/// Draw the device's box on a fresh snapshot.
struct LookAreaEditor: View {
    let look: LookService
    let device: Device
    let close: () -> Void
    @State private var cameras: [String] = []
    @State private var camera = ""
    @State private var kind: LookDeviceKind = .light
    @State private var travel = 2.0
    @State private var frame: CGImage?
    @State private var loadError: String?
    @State private var rect: LookRect?
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: LL("Area for %@"), device.name)).font(.headline)
            HStack {
                Picker(LL("Camera"), selection: $camera) {
                    ForEach(cameras, id: \.self) { Text(LookPhrases.cameraName($0)).tag($0) }
                }
                .fixedSize()
                Picker(LL("Check as"), selection: $kind) {
                    ForEach(LookDeviceKind.allCases, id: \.self) { Text(LookSection.kindName($0)).tag($0) }
                }
                .fixedSize()
                .padding(.leading, 12)
                Spacer()
                Button(LL("New snapshot")) { Task { await load() } }
            }
            ZStack {
                if let frame {
                    GeometryReader { geo in
                        let size = fitted(frame, in: geo.size)
                        let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
                        ZStack(alignment: .topLeading) {
                            Image(decorative: frame, scale: 1).resizable().frame(width: size.width, height: size.height)
                            if let rect {
                                Rectangle()
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .frame(width: rect.width * size.width, height: rect.height * size.height)
                                    .offset(x: rect.x * size.width, y: rect.y * size.height)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { g in
                            let start = dragStart ?? g.startLocation
                            dragStart = start
                            let x0 = min(start.x, g.location.x) / size.width, y0 = min(start.y, g.location.y) / size.height
                            let x1 = max(start.x, g.location.x) / size.width, y1 = max(start.y, g.location.y) / size.height
                            rect = LookRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).clamped
                        }.onEnded { _ in dragStart = nil })
                        .offset(x: origin.x, y: origin.y)
                        .accessibilityLabel(LL("Camera snapshot. Drag to draw the box."))
                        .accessibilityValue(rect == nil ? LL("No box yet") : LL("Box drawn"))
                    }
                } else if let loadError {
                    Label(loadError, systemImage: "video.slash").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 640, minHeight: 360)
            Text(LL("Drag a box around the device itself: the lamp shade, the TV screen, the window, the door.")).font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $travel, in: 0.5...120, step: travel < 10 ? 0.5 : 5) {
                Text(String(format: LL("Look after %@ s"), travel.rounded() == travel ? String(Int(travel)) : String(format: "%.1f", travel)))
            }
            HStack {
                if look.target(device.entityID) != nil {
                    Button(LL("Remove area"), role: .destructive) {
                        Task { await look.remove(device.entityID); close() }
                    }
                }
                Spacer()
                Button(LL("Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(LL("Save")) {
                    guard let rect else { return }
                    Task {
                        await look.save(entityID: device.entityID, name: device.name, kind: kind, camera: camera, area: rect,
                                        travelSeconds: travel, frame: frame)
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rect == nil || camera.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 700)
        .task {
            let existing = look.target(device.entityID)
            kind = existing?.kind ?? LookService.lookKind(for: device.kind) ?? .light
            travel = existing?.travelSeconds ?? kind.defaultTravelSeconds
            rect = existing?.area
            cameras = await look.cameras()
            let room = AssistantService.shared.registry.room(named: device.room ?? "")?.cameras.first
            camera = existing?.camera ?? device.verificationCamera ?? room ?? cameras.first ?? ""
            await load()
        }
        .onChange(of: camera) { _, _ in Task { await load() } }
        .onChange(of: kind) { old, new in if travel == old.defaultTravelSeconds { travel = new.defaultTravelSeconds } }
    }

    private func load() async {
        guard !camera.isEmpty else { return }
        loadError = nil
        do { frame = try await look.snapshot(camera: camera) } catch {
            frame = nil
            loadError = LL("No picture from this camera.")
        }
    }

    private func fitted(_ image: CGImage, in box: CGSize) -> CGSize {
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}
#endif
