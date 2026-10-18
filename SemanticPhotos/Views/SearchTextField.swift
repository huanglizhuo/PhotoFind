import SwiftUI
import UIKit

/// UITextField exposes marked text so unfinished IME composition never starts inference.
struct SearchTextField: UIViewRepresentable {
    static let debounceDelay: Duration = .milliseconds(500)
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var onEdit: () -> Void
    var onSearch: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.accessibilityIdentifier = "searchTextField"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        if field.placeholder != placeholder { field.placeholder = placeholder }
        if field.text != text {
            coordinator.cancelPendingSearch()
            field.text = text
            coordinator.lastText = text
            coordinator.wasComposing = false
        }
        coordinator.synchronizeFocus(field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: uiView.intrinsicContentSize.height)
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.cancelPendingSearch()
        coordinator.cancelPendingFocus()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField
        var updating = false
        var lastText: String
        var wasComposing = false
        private var pending: Task<Void, Never>?
        private var pendingFocus: Task<Void, Never>?

        init(_ parent: SearchTextField) {
            self.parent = parent
            lastText = parent.text
        }

        func cancelPendingSearch() { pending?.cancel(); pending = nil }
        func cancelPendingFocus() { pendingFocus?.cancel(); pendingFocus = nil }

        func synchronizeFocus(_ field: UITextField) {
            guard parent.isFocused != field.isFirstResponder else {
                cancelPendingFocus()
                return
            }
            guard pendingFocus == nil else { return }
            // Keyboard layout and delegate callbacks must run outside SwiftUI's update pass.
            pendingFocus = Task { @MainActor [weak self, weak field] in
                guard !Task.isCancelled, let self else { return }
                self.pendingFocus = nil
                guard let field, field.window != nil else { return }
                if self.parent.isFocused, !field.isFirstResponder { field.becomeFirstResponder() }
                else if !self.parent.isFocused, field.isFirstResponder { field.resignFirstResponder() }
            }
        }

        @objc func textChanged(_ field: UITextField) {
            guard !updating, parent.isFocused || field.isFirstResponder else { return }
            let value = field.text ?? ""
            let composing = field.markedTextRange != nil
            guard value != lastText || composing != wasComposing else { return }
            let sameQuery = TextSearchScheduler.normalized(value) == TextSearchScheduler.normalized(lastText)
                && composing == wasComposing
            lastText = value
            wasComposing = composing
            parent.text = value
            guard !sameQuery else { return }
            cancelPendingSearch()
            parent.onEdit()
            guard !composing else { return }
            guard !value.isEmpty else { parent.onSearch(); return }
            pending = Task { [weak self, weak field] in
                try? await Task.sleep(for: SearchTextField.debounceDelay)
                guard !Task.isCancelled, let self, let field,
                      field.markedTextRange == nil,
                      TextSearchScheduler.normalized(field.text ?? "") == TextSearchScheduler.normalized(value) else { return }
                self.parent.onSearch()
            }
        }

        func textFieldDidChangeSelection(_ textField: UITextField) { textChanged(textField) }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            cancelPendingSearch()
            // A resign can commit IME text. Keep that text, but never schedule a new search.
            let shouldCancel = parent.isFocused
            if updating {
                Task { [weak self, weak textField] in
                    guard let self, let textField, !textField.isFirstResponder else { return }
                    self.finishEditing(textField, cancel: shouldCancel)
                }
            } else {
                finishEditing(textField, cancel: shouldCancel)
            }
        }

        private func finishEditing(_ field: UITextField, cancel: Bool) {
            lastText = field.text ?? ""
            wasComposing = false
            parent.text = lastText
            parent.isFocused = false
            // Return/history already set focus false and submitted an explicit request.
            if cancel { parent.onCancel() }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField.markedTextRange == nil else { return false }
            textChanged(textField)
            cancelPendingSearch()
            parent.isFocused = false
            parent.onSubmit()
            return false
        }
    }
}
