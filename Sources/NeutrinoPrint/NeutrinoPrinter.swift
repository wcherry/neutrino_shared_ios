import UIKit

// MARK: - NeutrinoPrinter

/// Presents the system print dialog for a ``PrintJob``.
///
/// The dialog is AirPrint's own: printer choice, copies, page range, paper and orientation are all
/// the system's, and so is the preview, which is drawn by ``NeutrinoPrintPageRenderer``.
@MainActor
public enum NeutrinoPrinter {

    /// Whether this device can print at all. Apps hide or disable their Print command when it
    /// cannot, rather than offering a dialog that fails to open.
    public static var isAvailable: Bool { UIPrintInteractionController.isPrintingAvailable }

    /// How a print dialog ended.
    public enum Outcome: Equatable {
        /// The job was handed to the printer.
        case printed
        /// The user closed the dialog without printing.
        case cancelled
    }

    /// Shows the print dialog and waits for it to close.
    ///
    /// - Parameter anchor: On iPad the dialog is a popover, and this is the rect in window
    ///   coordinates it points at — the control that asked to print. Without one it points at the
    ///   top trailing corner, where a navigation bar keeps its actions. Ignored on iPhone, where
    ///   the dialog is a sheet.
    @discardableResult
    public static func present(_ job: PrintJob, anchor: CGRect? = nil) async throws -> Outcome {
        guard isAvailable else { throw PrintError.unavailable }

        let controller = UIPrintInteractionController.shared
        configure(controller, for: job)

        return try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)
            let completion: UIPrintInteractionController.CompletionHandler = { _, completed, error in
                if let error {
                    resume(.failure(PrintError.failed(error.localizedDescription)))
                } else {
                    resume(.success(completed ? .printed : .cancelled))
                }
            }

            let presented: Bool
            if UIDevice.current.userInterfaceIdiom == .pad, let window = keyWindow {
                let rect = anchor ?? CGRect(x: window.bounds.maxX - 44,
                                            y: window.safeAreaInsets.top,
                                            width: 44, height: 44)
                presented = controller.present(from: rect, in: window, animated: true,
                                               completionHandler: completion)
            } else {
                presented = controller.present(animated: true, completionHandler: completion)
            }

            if !presented {
                resume(.failure(PrintError.unavailable))
            }
        }
    }

    /// Points the shared controller at this job, clearing whatever the previous job left on it —
    /// the controller is a singleton, and a stale `printingItem` beside a new renderer is an error.
    static func configure(_ controller: UIPrintInteractionController, for job: PrintJob) {
        let info = UIPrintInfo.printInfo()
        info.jobName = job.name
        info.outputType = job.outputType
        info.orientation = job.orientation
        info.duplex = job.duplex
        controller.printInfo = info

        controller.printPageRenderer = nil
        controller.printFormatter = nil
        controller.printingItem = nil
        controller.printingItems = nil
        controller.showsNumberOfCopies = true
        controller.showsPaperOrientation = true

        switch job.content {
        case .pdf(let data):
            controller.printingItem = data
        case .images(let images):
            controller.printingItems = images
        case .attributedText, .pages, .markup:
            controller.printPageRenderer = NeutrinoPrintPageRenderer(job: job)
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

// MARK: - ResumeOnce

/// Guards a continuation against the print system calling back after `present` has already
/// reported that it could not show the dialog.
private final class ResumeOnce {
    private var continuation: CheckedContinuation<NeutrinoPrinter.Outcome, Error>?

    init(_ continuation: CheckedContinuation<NeutrinoPrinter.Outcome, Error>) {
        self.continuation = continuation
    }

    func callAsFunction(_ result: Result<NeutrinoPrinter.Outcome, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
