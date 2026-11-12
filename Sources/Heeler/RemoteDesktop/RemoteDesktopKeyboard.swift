import SwiftUI
import UIKit

/// What a change of the keyboard field's text means for the computer: a
/// Backspace for each character the change removed, then the new text. The
/// phone's keyboard can replace a whole word, so a change is not always one
/// character (OpenBot's `typedChange`, `model/remote-keys.ts`).
enum RemoteDesktopTyped {
    /// Only what a US keyboard types reaches a Mac (Sunshine types no other
    /// text there), so only those characters count: deleting an emoji or a
    /// Chinese character on the phone sends no Backspace for it.
    static func change(before: String, after: String) -> (backspaces: Int, text: String) {
        let old = Array(before.filter(isTypable))
        let next = Array(after.filter(isTypable))
        var common = 0
        while common < old.count, common < next.count, old[common] == next[common] { common += 1 }
        return (old.count - common, next[common...].map(String.init).joined())
    }

    static func isTypable(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (0x20...0x7E).contains(ascii) || character == "\n" || character == "\t"
    }
}

/// The hidden field the phone's keyboard types into. What changes in it goes
/// to the page as key presses of a US keyboard; nothing here is logged or
/// kept once it has been sent.
struct RemoteDesktopKeyboard: UIViewRepresentable {
    /// Whether the field holds the keyboard. The screen's keyboard button and
    /// the bar's dismiss key drive it.
    @Binding var isShown: Bool
    let isEnabled: Bool
    let onChange: @MainActor (String, String) -> Void
    let onBackspaceOnEmpty: @MainActor () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.spellCheckingType = .no
        field.keyboardType = .asciiCapable
        field.textContentType = .none
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged)
        // One point and nearly clear: a keyboard's target, not a control.
        field.alpha = 0.01
        field.isAccessibilityElement = false
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onBackspaceOnEmpty = onBackspaceOnEmpty
        field.isUserInteractionEnabled = isEnabled
        if isShown, !field.isFirstResponder, isEnabled {
            field.becomeFirstResponder()
        } else if !isShown, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onBackspaceOnEmpty: onBackspaceOnEmpty)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var onChange: @MainActor (String, String) -> Void
        var onBackspaceOnEmpty: @MainActor () -> Void
        private var typed = ""
        /// The field is emptied past this length, so it never grows with a
        /// long session.
        private static let maxLength = 256

        init(
            onChange: @escaping @MainActor (String, String) -> Void,
            onBackspaceOnEmpty: @escaping @MainActor () -> Void
        ) {
            self.onChange = onChange
            self.onBackspaceOnEmpty = onBackspaceOnEmpty
        }

        @objc func editingChanged(_ field: UITextField) {
            // Pinyin still being composed is not text yet; the committed word is.
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            onChange(typed, text)
            typed = text
            if text.count > Self.maxLength {
                field.text = ""
                typed = ""
            }
        }

        /// Return is Enter on the computer; the field itself stays one line.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onChange(typed, typed + "\n")
            return false
        }

        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Backspace in an empty field changes no text, so `editingChanged`
            // never hears it.
            if string.isEmpty, typed.isEmpty { onBackspaceOnEmpty() }
            return true
        }
    }
}
