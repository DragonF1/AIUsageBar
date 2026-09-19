import AppKit
import SwiftUI

/// The popover's Claude Code / Antigravity switch: a native segmented control with each
/// product's mark next to its name. SwiftUI's segmented `Picker` shows a `Label`'s text only
/// on macOS, so this wraps `NSSegmentedControl`, which draws image and label together.
struct ProviderPicker: NSViewRepresentable {
    @Binding var tab: UsageTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: UsageTab.allCases.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed))
        for (index, tab) in UsageTab.allCases.enumerated() {
            control.setImage(tab.icon, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Provider")
        // Fill the popover's width like the SwiftUI picker did, rather than hugging the labels.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let index = UsageTab.allCases.firstIndex(of: tab) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ProviderPicker
        init(_ parent: ProviderPicker) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            let tabs = UsageTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            parent.tab = tabs[sender.selectedSegment]
        }
    }
}
