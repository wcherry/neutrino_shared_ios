// iOS-only for now: this target is UIKit/SwiftUI-for-iOS and is compiled out on macOS, where
// only NeutrinoCore, NeutrinoAuth, NeutrinoCrypto and NeutrinoOOXML are built. See Package.swift.
#if os(iOS)

import SwiftUI

// MARK: - PrintCoordinator

/// The print command's state for one screen: preparing the job, showing the dialog, and reporting a
/// failure.
///
/// Preparing is real work in most apps — a document's pictures have to be downloaded and decrypted
/// before they can go on paper — so the job is built by an async closure the coordinator runs, and
/// ``isPreparing`` is what the screen shows progress from and disables a second tap with.
///
/// Owned by the screen rather than by the menu item that triggers it: SwiftUI rebuilds a `Menu`'s
/// contents freely and cannot present an alert from inside one.
///
/// ```swift
/// @StateObject private var printer = PrintCoordinator()
///
/// Menu { PrintMenuButton(printer) { try await makePrintJob() } } label: { … }
///     .printCoordinator(printer)
/// ```
@MainActor
public final class PrintCoordinator: ObservableObject {

    /// True from the tap until the dialog is on screen.
    @Published public private(set) var isPreparing = false

    /// The last failure, for the alert. Cleared when the alert is dismissed.
    @Published public var failureMessage: String?

    private var task: Task<Void, Never>?

    public init() {}

    /// Builds the job and presents the print dialog. Ignored while a previous job is still being
    /// prepared.
    public func print(anchor: CGRect? = nil,
                      _ makeJob: @escaping @MainActor () async throws -> PrintJob) {
        guard !isPreparing else { return }
        isPreparing = true

        task = Task { [weak self] in
            do {
                let job = try await makeJob()
                try Task.checkCancellation()
                self?.isPreparing = false
                try await NeutrinoPrinter.present(job, anchor: anchor)
            } catch is CancellationError {
                self?.isPreparing = false
            } catch {
                self?.isPreparing = false
                self?.failureMessage = error.localizedDescription
            }
        }
    }

    /// Abandons a job still being prepared — the screen is going away.
    public func cancel() {
        task?.cancel()
        task = nil
        isPreparing = false
    }
}

// MARK: - PrintMenuButton

/// The "Print…" command, spelled once so it reads the same in every app's menu.
///
/// Disabled while a job is being prepared, and hidden entirely on a device that cannot print. A
/// second command for printing part of a document — Sheets' "Print Selection…" — passes its own
/// `title` and keeps the icon.
public struct PrintMenuButton: View {

    @ObservedObject private var coordinator: PrintCoordinator
    private let title: LocalizedStringKey
    private let makeJob: @MainActor () async throws -> PrintJob

    public init(_ coordinator: PrintCoordinator,
                title: LocalizedStringKey = "Print\u{2026}",
                makeJob: @escaping @MainActor () async throws -> PrintJob) {
        self.coordinator = coordinator
        self.title = title
        self.makeJob = makeJob
    }

    public var body: some View {
        if NeutrinoPrinter.isAvailable {
            Button {
                coordinator.print(makeJob)
            } label: {
                Label(title, systemImage: "printer")
            }
            .disabled(coordinator.isPreparing)
        }
    }
}

// MARK: - View modifier

public extension View {

    /// Shows a coordinator's progress while a job is prepared and its failures as an alert. Attach
    /// it to the screen that owns the coordinator, outside any `Menu`.
    func printCoordinator(_ coordinator: PrintCoordinator) -> some View {
        modifier(PrintCoordinatorModifier(coordinator: coordinator))
    }
}

private struct PrintCoordinatorModifier: ViewModifier {

    @ObservedObject var coordinator: PrintCoordinator

    func body(content: Content) -> some View {
        content
            .overlay {
                if coordinator.isPreparing {
                    ProgressView("Preparing to print…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Couldn't Print",
                   isPresented: Binding(
                       get: { coordinator.failureMessage != nil },
                       set: { if !$0 { coordinator.failureMessage = nil } }
                   )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coordinator.failureMessage ?? "")
            }
            .onDisappear { coordinator.cancel() }
    }
}

#endif
