import SwiftUI
import Testing
import UIKit
@testable import SemanticPhotos

@MainActor
struct SearchInputTests {
    private final class FocusField: UITextField {
        var hasFocus = false
        var begins = 0
        var ends = 0
        override var isFirstResponder: Bool { hasFocus }
        override func becomeFirstResponder() -> Bool { begins += 1; hasFocus = true; return true }
        override func resignFirstResponder() -> Bool { ends += 1; hasFocus = false; return true }
    }

    @MainActor private final class Input {
        var text = ""
        var focused = true
        var searches: [String] = []
        var submits: [String] = []
        var edits = 0

        func coordinator() -> SearchTextField.Coordinator {
            SearchTextField(text: Binding(get: { self.text }, set: { self.text = $0 }),
                            isFocused: Binding(get: { self.focused }, set: { self.focused = $0 }),
                            placeholder: "搜索", onEdit: { self.edits += 1 },
                            onSearch: { self.searches.append(self.text) },
                            onSubmit: { self.submits.append(self.text) }).makeCoordinator()
        }
    }

    @Test func preparationRunsOnlyLatestCommittedInput() {
        var preparation = SearchPreparation()
        let firstCanSearch = preparation.request("海边")
        #expect(!firstCanSearch)
        preparation.inputChanged()
        let latestCanSearch = preparation.request("朋友合照")
        #expect(!latestCanSearch)
        let resumed = preparation.finish()
        #expect(resumed == "朋友合照")
        let duplicate = preparation.finish()
        #expect(duplicate == nil)
        let readyCanSearch = preparation.request("生日蛋糕")
        #expect(readyCanSearch)
    }

    @Test func preparationDoesNotSearchUncommittedEdit() {
        var preparation = SearchPreparation()
        _ = preparation.request("海边")
        preparation.inputChanged() // IME is composing or the debounce hasn't fired.
        let resumed = preparation.finish()
        #expect(resumed == nil)
        let committedCanSearch = preparation.request("海边日落")
        #expect(committedCanSearch)
    }

    @Test func cancellingPreparationRejectsLateDebounceAndRetry() {
        var preparation = SearchPreparation()
        _ = preparation.request("海边")
        preparation.cancel()
        let lateCanSearch = preparation.request("海边")
        #expect(!lateCanSearch)
        let resumed = preparation.finish()
        #expect(resumed == nil)
        let cancelledCanSearch = preparation.request("海边")
        #expect(!cancelledCanSearch)
        preparation.inputChanged()
        let newCanSearch = preparation.request("新的输入")
        #expect(newCanSearch)
    }

    @Test func preparationFailureKeepsLatestQueryForExplicitRetry() {
        var preparation = SearchPreparation()
        _ = preparation.request("海边")
        let failed = preparation.finish(error: "模型无法加载")
        #expect(failed == nil)
        #expect(preparation.state == .failed("模型无法加载"))
        preparation.inputChanged()
        let failedCanSearch = preparation.request("朋友")
        #expect(!failedCanSearch)
        preparation.state = .preparing
        let resumed = preparation.finish()
        #expect(resumed == "朋友")
    }

    @Test func debounceIsFiveHundredMilliseconds() {
        #expect(SearchTextField.debounceDelay == .milliseconds(500))
    }

    @Test func focusChangesWaitUntilViewUpdateFinishes() async throws {
        let input = Input(), field = FocusField(), window = UIWindow()
        let coordinator = input.coordinator()
        field.delegate = coordinator
        window.addSubview(field)
        defer { field.removeFromSuperview(); window.isHidden = true }
        coordinator.updating = true
        coordinator.synchronizeFocus(field)
        #expect(field.begins == 0)
        coordinator.updating = false
        try await Task.sleep(for: .milliseconds(30))
        #expect(field.begins == 1)
        input.focused = false
        coordinator.updating = true
        coordinator.synchronizeFocus(field)
        #expect(field.ends == 0)
        coordinator.updating = false
        try await Task.sleep(for: .milliseconds(30))
        #expect(field.ends == 1)
    }

    @Test func obsoleteFocusRequestsCannotReopenKeyboard() async throws {
        let input = Input(), field = FocusField(), window = UIWindow()
        let coordinator = input.coordinator()
        field.delegate = coordinator
        window.addSubview(field)
        defer { field.removeFromSuperview(); window.isHidden = true }
        coordinator.synchronizeFocus(field)
        input.focused = false
        coordinator.synchronizeFocus(field)
        try await Task.sleep(for: .milliseconds(30))
        #expect(field.begins == 0)
        #expect(!field.hasFocus)
        input.focused = true
        coordinator.synchronizeFocus(field)
        SearchTextField.dismantleUIView(field, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(30))
        #expect(field.begins == 0)
    }

    @Test func markedTextWaitsForCommitEvenAfterLongPause() async throws {
        let input = Input(), field = UITextField()
        let coordinator = input.coordinator()
        field.setMarkedText("peng", selectedRange: NSRange(location: 4, length: 0))
        try #require(field.markedTextRange != nil)
        coordinator.textChanged(field)
        try await Task.sleep(for: .milliseconds(750))
        #expect(input.searches.isEmpty)
        #expect(!coordinator.textFieldShouldReturn(field))
        #expect(input.submits.isEmpty)
        field.setMarkedText("朋友", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textChanged(field)
        field.unmarkText()
        coordinator.textChanged(field)
        #expect(input.searches.isEmpty)
        try await Task.sleep(for: .milliseconds(750))
        #expect(input.searches == ["朋友"])
    }

    @Test func rapidChangesOnlySearchFinalTextAndSelectionDoesNotRepeat() async throws {
        let input = Input(), field = UITextField()
        let coordinator = input.coordinator()
        field.text = "朋友"
        coordinator.textChanged(field)
        try await Task.sleep(for: .milliseconds(350))
        field.text = "朋友合照"
        coordinator.textChanged(field)
        try await Task.sleep(for: .milliseconds(350))
        #expect(input.searches.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(input.searches == ["朋友合照"])
        coordinator.textFieldDidChangeSelection(field)
        try await Task.sleep(for: .milliseconds(750))
        #expect(input.searches.count == 1)
    }

    @Test func submitIsImmediateAndCancelsDebounce() async throws {
        let input = Input(), field = UITextField()
        let coordinator = input.coordinator()
        field.text = "生日蛋糕"
        coordinator.textChanged(field)
        _ = coordinator.textFieldShouldReturn(field)
        #expect(input.submits == ["生日蛋糕"])
        #expect(!input.focused)
        try await Task.sleep(for: .milliseconds(750))
        #expect(input.searches.isEmpty)
    }

    @Test func clearAndCancellationCannotPublishOldQuery() async throws {
        let input = Input(), field = UITextField()
        let coordinator = input.coordinator()
        field.text = "海边"
        coordinator.textChanged(field)
        field.text = ""
        coordinator.textChanged(field)
        #expect(input.searches == [""])
        field.text = "海边日落"
        coordinator.textChanged(field)
        coordinator.cancelPendingSearch()
        try await Task.sleep(for: .milliseconds(750))
        #expect(input.searches == [""])
    }

    @Test func endingEditingPublishesFinalCompositionAfterViewUpdate() async throws {
        let input = Input(), field = UITextField()
        let coordinator = input.coordinator()
        field.setMarkedText("朋友", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textChanged(field)
        field.unmarkText()
        coordinator.updating = true
        coordinator.textFieldDidEndEditing(field)
        coordinator.updating = false
        try await Task.sleep(for: .milliseconds(750))
        #expect(input.searches == ["朋友"])
    }
}
