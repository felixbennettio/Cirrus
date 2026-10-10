import CirrusKit
import SwiftUI

/// A readable message for any error the app shows.
func describe(_ error: Error) -> String {
    if let e = error as? CFAPIError { return e.summary }
    if let e = error as? OAuthError { return e.description }
    if let e = error as? URLError {
        switch e.code {
        case .notConnectedToInternet: return L("You are offline.", "当前没有网络连接。")
        case .timedOut: return L("The request timed out.", "请求超时。")
        default: break
        }
    }
    return error.localizedDescription
}

/// Short messages after actions, shown as a floating glass capsule.
@MainActor @Observable
final class Feedback {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    var toast: Toast?

    func show(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        withAnimation(.snappy) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(error ? 5 : 2.5))
            if toast?.id == t.id { withAnimation(.snappy) { toast = nil } }
        }
    }

    func error(_ error: Error) {
        if error is CancellationError { return }
        show(describe(error), error: true)
    }
}

struct ToastOverlay: ViewModifier {
    let feedback: Feedback

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = feedback.toast {
                Label(t.text, systemImage: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(t.isError ? Color.red : Color.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { withAnimation(.snappy) { feedback.toast = nil } }
                    .id(t.id)
            }
        }
    }
}
