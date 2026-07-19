#if os(iOS)
import SwiftUI
import VisionKit
import VigilKit

/// Camera sheet for vigil1 QR codes: accepts chunks in any order, shows
/// "captured N of M", refuses to mix link sessions (sid-validated), decodes
/// via VigilKit's QRDecoder (docs/qr-protocol.md).
struct ScanView: View {
    let onDecoded: (LinkPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chunks: [Int: QRChunk] = [:]
    @State private var sid: String?
    @State private var total: Int?
    @State private var message: String?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    scannerBody
                } else {
                    ContentUnavailableView(
                        "Camera unavailable",
                        systemImage: "video.slash",
                        description: Text("Use the paste-code path instead. Run `npx vigil-link --json --yes`, paste its output only into Vigil, then clear your terminal scrollback.")
                    )
                }
            }
            .navigationTitle("Scan link codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var scannerBody: some View {
        ZStack(alignment: .bottom) {
            QRScannerRepresentable(onCode: ingest(code:))
                .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 8) {
                if let total, total > 1 {
                    Text("Captured \(chunks.count) of \(total)")
                        .font(.headline)
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                if message == nil && total == nil {
                    Text("Point the camera at the QR code in your terminal.")
                        .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
    }

    private func ingest(code: String) {
        guard !finished else { return }
        let chunk: QRChunk
        do {
            chunk = try QRDecoder.parseChunk(code)
        } catch QRDecodeError.unsupportedVariant {
            message = "This code needs a newer Vigil — update the app."
            return
        } catch {
            // Not a vigil code — ignore quietly (people have QR codes around).
            return
        }

        if let sid, chunk.sid != sid {
            message = "That code is from a different link session — re-run vigil-link and scan one session only."
            return
        }
        sid = chunk.sid
        total = chunk.total
        guard chunks[chunk.index] == nil else { return }
        chunks[chunk.index] = chunk
        message = nil

        guard chunks.count == chunk.total else { return }
        finished = true
        do {
            let strings = chunks.values
                .sorted { $0.index < $1.index }
                .map { "\(QRDecoder.protocolToken):\($0.index)/\($0.total):\($0.sid):\($0.data)" }
            let payload = try QRDecoder.decodePayload(strings, now: Date())
            onDecoded(payload)
            dismiss()
        } catch QRDecodeError.expired {
            message = "This link code expired (older than 10 minutes). Re-run vigil-link for a fresh one."
            reset()
        } catch {
            message = "Couldn't decode — re-run vigil-link and try again."
            reset()
        }
    }

    private func reset() {
        finished = false
        chunks = [:]
        sid = nil
        total = nil
    }
}

/// Thin VisionKit wrapper: emits every recognized QR payload string.
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in added {
                if let value = barcode.payloadStringValue {
                    onCode(value)
                }
            }
        }
    }
}
#endif
