import SwiftUI
import VisionKit

// MARK: - QRScannerView

/// A live camera scanner that reports the first QR payload it recognises.
///
/// `DataScannerViewController` is unavailable on the Simulator and on devices without a Neural
/// Engine, so callers must check `DataScannerViewController.isSupported` before presenting this.
public struct QRScannerView: UIViewControllerRepresentable {
    public let onScan: (String) -> Void

    public init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    public func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    public func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    // MARK: - Coordinator

    public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        /// The delegate keeps firing while the code stays in frame, and a second callback would
        /// reset the PIN step the first one moved to.
        private var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        public func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didScan else { return }

            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue {
                    didScan = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
