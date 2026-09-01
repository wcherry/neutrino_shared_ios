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

            Spacer()
        }
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
