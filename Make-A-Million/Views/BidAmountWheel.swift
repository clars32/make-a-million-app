//
//  BidAmountWheel.swift
//  Make-a-Million
//
//  Native wheel-style bid selector. This keeps the old wheel interaction but
//  avoids SwiftUI's `.pickerStyle(.wheel)` first-touch hitch with the full bid
//  ladder by driving `UIPickerView` directly.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct BidAmountWheel: View {
    let amounts: [Int]
    @Binding var selection: Int
    var width: CGFloat
    var height: CGFloat
    var rowHeight: CGFloat
    var textStyle: UIFont.TextStyle = .headline

    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TableStyle.panelFill)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TableStyle.panelStroke, lineWidth: 1)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TableStyle.tableGold.opacity(pulse ? 0.24 : 0.10))
                .frame(height: rowHeight + 4)
                .padding(.horizontal, 6)
                .scaleEffect(x: pulse ? 1.03 : 1.0, y: 1.0)
                .animation(.easeOut(duration: 0.12), value: pulse)

            #if canImport(UIKit)
            NativeBidPicker(amounts: amounts,
                            selection: $selection,
                            rowHeight: rowHeight,
                            textStyle: textStyle)
                .frame(width: width, height: height)
                .clipped()
            #else
            Text(currentLabel)
                .font(TableTypography.money(.headline))
                .foregroundStyle(.white)
            #endif
        }
        .frame(width: width, height: height)
        .onAppear { selection = clamped(selection) }
        .onChange(of: amounts.count) { _, _ in selection = clamped(selection) }
        .onChange(of: selection) { _, _ in pulseSelection() }
        .accessibilityLabel("Bid amount")
        .accessibilityValue(currentLabel)
    }

    private var currentLabel: String {
        guard amounts.indices.contains(selection) else { return "" }
        return "$\(amounts[selection] / 1000)k"
    }

    private func clamped(_ index: Int) -> Int {
        guard !amounts.isEmpty else { return 0 }
        return min(max(index, 0), amounts.count - 1)
    }

    private func pulseSelection() {
        pulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            pulse = false
        }
    }
}

#if canImport(UIKit)
private struct NativeBidPicker: UIViewRepresentable {
    let amounts: [Int]
    @Binding var selection: Int
    let rowHeight: CGFloat
    let textStyle: UIFont.TextStyle

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.backgroundColor = .clear
        picker.clipsToBounds = true
        picker.selectRow(clamped(selection), inComponent: 0, animated: false)
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.amounts != amounts {
            context.coordinator.amounts = amounts
            picker.reloadAllComponents()
        }

        let row = clamped(selection)
        if picker.selectedRow(inComponent: 0) != row {
            picker.selectRow(row, inComponent: 0, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func clamped(_ index: Int) -> Int {
        guard !amounts.isEmpty else { return 0 }
        return min(max(index, 0), amounts.count - 1)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: NativeBidPicker
        var amounts: [Int]
        private let feedback = UISelectionFeedbackGenerator()

        init(parent: NativeBidPicker) {
            self.parent = parent
            self.amounts = parent.amounts
            feedback.prepare()
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int {
            1
        }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            amounts.count
        }

        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
            parent.rowHeight
        }

        func pickerView(_ pickerView: UIPickerView,
                        viewForRow row: Int,
                        forComponent component: Int,
                        reusing view: UIView?) -> UIView {
            let label = (view as? UILabel) ?? UILabel()
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75
            label.textColor = .white
            label.font = Self.font(for: parent.textStyle)
            label.text = amounts.indices.contains(row) ? "$\(amounts[row] / 1000)k" : ""
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            guard parent.amounts.indices.contains(row) else { return }
            feedback.selectionChanged()
            feedback.prepare()
            parent.selection = row
        }

        private static func font(for textStyle: UIFont.TextStyle) -> UIFont {
            let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
            let serif = descriptor.withDesign(.serif) ?? descriptor
            let bold = serif.withSymbolicTraits(.traitBold) ?? serif
            return UIFont(descriptor: bold, size: 0)
        }
    }
}
#endif
