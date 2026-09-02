import SwiftUI
import NeutrinoCore

// MARK: - BrandLogo

/// The gradient tile with the app's mark in it.
///
/// The one place the apps genuinely differ, and the reason it is a view rather than an inline
/// `ZStack`: login and register both show it, at different sizes, and they must not drift apart.
public struct BrandLogo: View {

    private let brand: NeutrinoBrand
    private let size: CGFloat

    public init(brand: NeutrinoBrand = .current, size: CGFloat = 96) {
        self.brand = brand
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(
                    LinearGradient(colors: brand.gradient,
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .frame(width: size, height: size)
                .shadow(color: brand.accent.opacity(0.35), radius: size * 0.21, x: 0, y: size * 0.083)

            if let imageName = brand.logoImageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                Image(systemName: brand.logoSymbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - TrustRowView

/// One reassurance line above the credential fields.
public struct TrustRowView: View {

    private let row: NeutrinoBrand.TrustRow

    public init(_ row: NeutrinoBrand.TrustRow) {
        self.row = row
    }

    public var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(row.color.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: row.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(row.color)
            }

            Text(row.title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color(.label))
                // Held to one line so every row is the same height. The carousel shows them in a
                // fixed frame, and a title that wrapped on a narrow device would be clipped by it.
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()
        }
    }
}

// MARK: - TrustRowCarousel

/// The reassurance lines, shown one at a time in a single slot rather than stacked.
///
/// Each row rises into place, holds, and is replaced by the next. It buys back the vertical space
/// three stacked rows cost on the sign-in screen, and a line that arrives on its own is read rather
/// than skimmed past as a block.
///
/// Two accessibility properties, both deliberate:
///
/// - **Reduce Motion** drops the movement and cross-fades in place. The rows still cycle — the
///   setting asks for less motion, not less information.
/// - **VoiceOver** is given all three rows at once as a single static element. A carousel that
///   rotates under the cursor is unusable with a screen reader, and the content is the point, not
///   the animation.
public struct TrustRowCarousel: View {

    private let rows: [NeutrinoBrand.TrustRow]
    private let dwell: Duration

    /// One row's natural height. Fixed so the surrounding layout does not shift as rows swap.
    private static let rowHeight: CGFloat = 36

    /// How far a row travels as it arrives and leaves. Small on purpose: this sits above the
    /// credential fields and should not pull the eye away from them.
    private static let travel: CGFloat = 10

    @State private var index = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(rows: [NeutrinoBrand.TrustRow], dwell: Duration = .seconds(2.6)) {
        self.rows = rows
        self.dwell = dwell
    }

    public var body: some View {
        ZStack {
            if let row = rows.indices.contains(index) ? rows[index] : rows.first {
                TrustRowView(row)
                    .id(row.id)
                    .transition(transition)
            }
        }
        .frame(height: Self.rowHeight)
        // The rows leave through the top and bottom edges of that frame; without this they are
        // drawn over whatever sits above and below during the swap.
        .clipped()
        .animation(.easeInOut(duration: 0.45), value: index)
        .task(id: rows.count) { await cycle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rows.map(\.title).joined(separator: ", "))
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: RowPhase(offset: Self.travel, opacity: 0),
                                 identity: RowPhase(offset: 0, opacity: 1)),
            removal: .modifier(active: RowPhase(offset: -Self.travel, opacity: 0),
                               identity: RowPhase(offset: 0, opacity: 1))
        )
    }

    /// Advances forever, until the view goes away and `.task` cancels it.
    ///
    /// A single row has nothing to cycle to, and rotating it would be a pointless animation on a
    /// screen the user is trying to type into.
    private func cycle() async {
        guard rows.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            index = (index + 1) % rows.count
        }
    }
}

// MARK: - RowPhase

/// The offset-and-fade a row is in on either side of a swap.
///
/// A `ViewModifier` rather than `.move(edge:)`, which slides the whole way out of the frame — far
/// too much travel for a 36-point row.
private struct RowPhase: ViewModifier, Animatable {

    var offset: CGFloat
    var opacity: Double

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(offset, opacity) }
        set {
            offset = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .opacity(opacity)
    }
}

// MARK: - BrandField

/// The rounded, filled text field the hero screens use.
///
/// A `ViewModifier` rather than a wrapper view, because the caller has to own the `TextField` /
/// `SecureField` distinction, the content type, and the focus binding.
public struct BrandFieldStyle: ViewModifier {

    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

public extension View {
    func brandFieldStyle() -> some View { modifier(BrandFieldStyle()) }
}

// MARK: - BrandPasswordField

/// A password field with a reveal toggle, in the rounded filled style the hero screens use.
///
/// Sign-up had this and sign-in did not, which is backwards: a mistyped password on the sign-in
/// screen is the one that produces a rejection with nothing to look at. One component now, so the
/// two screens cannot drift again.
///
/// Generic over the focus value so each screen keeps its own `Field` enum — the alternative is a
/// shared enum that has to name every field on every screen.
public struct BrandPasswordField<Field: Hashable>: View {

    private let placeholder: String
    @Binding private var text: String
    private let focus: FocusState<Field?>.Binding
    private let field: Field
    private let contentType: UITextContentType
    private let submitLabel: SubmitLabel
    private let onSubmit: () -> Void

    /// Revealed state is owned here and starts hidden every time the field is built. A password
    /// left visible across a re-presented sheet is not something the user asked for.
    @State private var isRevealed = false

    public init(_ placeholder: String,
                text: Binding<String>,
                focus: FocusState<Field?>.Binding,
                field: Field,
                contentType: UITextContentType = .password,
                submitLabel: SubmitLabel = .go,
                onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        self._text = text
        self.focus = focus
        self.field = field
        self.contentType = contentType
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(focus, equals: field)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)

            Button {
                let wasFocused = focus.wrappedValue == field
                isRevealed.toggle()
                // Swapping SecureField for TextField replaces the view, and the replacement is not
                // the one that held focus — so the keyboard drops and the caret disappears mid-typing
                // unless focus is handed back. Only re-asserted when this field actually had it, or
                // tapping the eye would steal focus from wherever the user was.
                if wasFocused {
                    DispatchQueue.main.async { focus.wrappedValue = field }
                }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    // The glyphs differ in width, so the field's text would shift as it toggles.
                    .frame(width: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
        .brandFieldStyle()
    }
}

// MARK: - BrandButton

/// The gradient primary button, with its own progress state.
///
/// Disabled styling is a 50% gradient and no shadow rather than a grey fill: the button stays
/// legible as the same control, which matters on a screen where it is the only one.
public struct BrandButton: View {

    private let title: String
    private let icon: String?
    private let isBusy: Bool
    private let isEnabled: Bool
    private let brand: NeutrinoBrand
    private let action: () -> Void

    public init(_ title: String,
                icon: String? = nil,
                isBusy: Bool = false,
                isEnabled: Bool = true,
                brand: NeutrinoBrand = .current,
                action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.brand = brand
        self.action = action
    }

    public var body: some View {
        if isBusy {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.1)
                .tint(brand.accent)
                .frame(height: 52)
                .frame(maxWidth: .infinity)
        } else {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    LinearGradient(colors: brand.gradient, startPoint: .leading, endPoint: .trailing)
                        .opacity(isEnabled ? 1 : 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: brand.accent.opacity(isEnabled ? 0.3 : 0), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }
}

// MARK: - InlineError

/// The red warning line the credential screens show under their fields.
public struct InlineError: View {

    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(.systemRed))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color(.systemRed))
                .multilineTextAlignment(.center)
        }
        .transition(.opacity)
    }
}
