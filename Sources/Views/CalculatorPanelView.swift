import Charts
import SwiftUI

struct CalculatorPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = CalculatorStore.shared
    @State private var showsHistory = false
    @State private var usesInverseFunctions = false
    @FocusState private var expressionIsFocused: Bool

    private let graphColors: [Color] = [.blue, .orange, .green, .purple, .pink]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modePicker
            Divider()

            switch store.mode {
            case .standard:
                calculatorScrollView { standardCalculator }
            case .scientific:
                calculatorScrollView { scientificCalculator }
            case .graphing:
                graphingCalculator
            }
        }
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 680, maxHeight: .infinity)
        .background(.bar)
        .task {
            await focusExpressionAfterPresentation()
        }
        .onChange(of: store.mode) { _, mode in
            if mode == .graphing {
                expressionIsFocused = false
            } else {
                Task { @MainActor in
                    await focusExpressionAfterPresentation()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Calculator", systemImage: "function")
                .font(.headline)

            Spacer()

            if let memoryText = store.memoryText {
                Text("M")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Memory: \(memoryText)")
            }

            PanelIconButton(systemName: "xmark", help: "Hide Calculator") {
                appState.hideCalculatorTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modePicker: some View {
        Picker("Calculator mode", selection: $store.mode) {
            ForEach(CalculatorMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityLabel("Calculator mode")
    }

    private func calculatorScrollView<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                display
                content()
                historySection
            }
            .padding(12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 7) {
                TextField("Enter an expression", text: $store.expression)
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .focused($expressionIsFocused)
                    .onSubmit { store.evaluate() }
                    .accessibilityLabel("Expression")

                Button {
                    store.deleteBackward()
                    expressionIsFocused = true
                } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete last character")
                .accessibilityLabel("Delete last character")
            }

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 8) {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        ScrollView(.horizontal) {
                            Text(store.resultText)
                                .font(.system(size: 30, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: geometry.size.width, alignment: .trailing)
                                .textSelection(.enabled)
                                .id("calculator-result")
                                .accessibilityLabel("Result \(store.resultText)")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 39)
                    .onAppear {
                        proxy.scrollTo("calculator-result", anchor: .trailing)
                    }
                    .onChange(of: store.resultText) {
                        proxy.scrollTo("calculator-result", anchor: .trailing)
                    }
                }

                Button {
                    store.copyResult()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.resultText == "Error" || store.resultText == "—")
                .help("Copy result")
                .accessibilityLabel("Copy result")
            }

            if store.expression.count >= 80 {
                Text("\(store.expression.count) / \(CalculatorStore.maximumExpressionLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Expression length \(store.expression.count) of \(CalculatorStore.maximumExpressionLength)")
            }
        }
        .padding(12)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private var standardCalculator: some View {
        VStack(spacing: 8) {
            memoryStrip

            calculatorGrid(columns: 4) {
                key("C", role: .destructive) { store.clear() }
                key("±", role: .function) { store.toggleSign() }
                key("%", role: .function) { store.insert("%") }
                key("÷", role: .operation) { store.insert("÷") }

                digitKey("7")
                digitKey("8")
                digitKey("9")
                key("×", role: .operation) { store.insert("×") }

                digitKey("4")
                digitKey("5")
                digitKey("6")
                key("−", role: .operation) { store.insert("−") }

                digitKey("1")
                digitKey("2")
                digitKey("3")
                key("+", role: .operation) { store.insert("+") }

                key("( )", role: .function) { store.insertParenthesis() }
                digitKey("0")
                key(".", role: .digit) { store.insertDecimal() }
                key("=", role: .equals) { store.evaluate() }
            }
        }
    }

    private var scientificCalculator: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    usesInverseFunctions.toggle()
                } label: {
                    Label("2nd", systemImage: usesInverseFunctions ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(usesInverseFunctions ? .accentColor : nil)
                .help("Switch between trigonometric and inverse trigonometric functions")

                Picker("Angle unit", selection: $store.angleUnit) {
                    ForEach(CalculatorAngleUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 150)
                .accessibilityLabel("Angle unit")
            }

            memoryStrip

            calculatorGrid(columns: 5) {
                functionKey(usesInverseFunctions ? "sin⁻¹" : "sin", function: usesInverseFunctions ? "asin" : "sin")
                functionKey(usesInverseFunctions ? "cos⁻¹" : "cos", function: usesInverseFunctions ? "acos" : "cos")
                functionKey(usesInverseFunctions ? "tan⁻¹" : "tan", function: usesInverseFunctions ? "atan" : "tan")
                key("π", role: .function) { store.insert("π") }
                key("e", role: .function) { store.insert("e") }

                functionKey("ln", function: "ln")
                functionKey("log", function: "log")
                functionKey("√", function: "sqrt")
                key("x²", role: .function) { store.applySquare() }
                key("xʸ", role: .function) { store.insert("^") }

                functionKey("sinh", function: "sinh")
                functionKey("cosh", function: "cosh")
                functionKey("tanh", function: "tanh")
                functionKey("|x|", function: "abs")
                key("n!", role: .function) { store.insert("!") }

                key("eˣ", role: .function) { store.applyPower(base: "e") }
                key("10ˣ", role: .function) { store.applyPower(base: "10") }
                functionKey("∛", function: "cbrt")
                functionKey("floor", function: "floor")
                functionKey("ceil", function: "ceil")

                key("C", role: .destructive) { store.clear() }
                key("( )", role: .function) { store.insertParenthesis() }
                key("%", role: .function) { store.insert("%") }
                key("ANS", role: .function) { store.insert("ans") }
                key("÷", role: .operation) { store.insert("÷") }

                digitKey("7")
                digitKey("8")
                digitKey("9")
                key("1/x", role: .function) { store.applyReciprocal() }
                key("×", role: .operation) { store.insert("×") }

                digitKey("4")
                digitKey("5")
                digitKey("6")
                key("±", role: .function) { store.toggleSign() }
                key("−", role: .operation) { store.insert("−") }

                digitKey("1")
                digitKey("2")
                digitKey("3")
                key(".", role: .digit) { store.insertDecimal() }
                key("+", role: .operation) { store.insert("+") }

                key("0", role: .digit) { store.insert("0") }
                key(",", role: .function) { store.insert(",") }
                key("mod", role: .function) { store.applyBinaryFunction("mod") }
                key("⌫", role: .function) { store.deleteBackward() }
                key("=", role: .equals) { store.evaluate() }
            }
        }
    }

    private var memoryStrip: some View {
        HStack(spacing: 6) {
            key("MC", role: .memory, compact: true) { store.clearMemory() }
                .disabled(store.memoryValue == nil)
            key("MR", role: .memory, compact: true) { store.recallMemory() }
                .disabled(store.memoryValue == nil)
            key("M+", role: .memory, compact: true) { store.addToMemory() }
            key("M−", role: .memory, compact: true) { store.subtractFromMemory() }
        }
    }

    private var historySection: some View {
        DisclosureGroup(isExpanded: $showsHistory) {
            if store.history.isEmpty {
                Text("Completed calculations appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.history.prefix(12)) { item in
                        Button {
                            store.useHistoryItem(item)
                            expressionIsFocused = true
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.expression)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 6)
                                Text("= \(item.result)")
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .help("Reuse this calculation")
                    }

                    Button(role: .destructive) {
                        store.clearHistory()
                    } label: {
                        Label("Clear History", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 3)
                }
                .padding(.top, 7)
            }
        } label: {
            Label(
                store.history.isEmpty ? "History" : "History (\(store.history.count))",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.subheadline.weight(.medium))
        }
        .padding(10)
        .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
    }

    private var graphingCalculator: some View {
        ScrollView {
            VStack(spacing: 12) {
                graphEquationEditor
                graphCard
                graphViewportControls
            }
            .padding(12)
        }
    }

    private var graphEquationEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Equations")
                    .font(.subheadline.weight(.semibold))
                Spacer()

                Menu {
                    Button("sin(x)") { applyGraphPreset("sin(x)") }
                    Button("x²") { applyGraphPreset("x^2") }
                    Button("1/x") { applyGraphPreset("1/x") }
                    Button("√|x|") { applyGraphPreset("sqrt(abs(x))") }
                    Button("tan(x)") { applyGraphPreset("tan(x)") }
                } label: {
                    Label("Preset", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    store.addGraphEquation()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.graphEquations.count >= 5)
                .help("Add another equation")
            }

            ForEach(store.graphEquations) { equation in
                graphEquationRow(equation)
            }

            HStack {
                Text("Use x as the graph variable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Angle unit", selection: $store.angleUnit) {
                    ForEach(CalculatorAngleUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)
                .accessibilityLabel("Graph angle unit")
            }
        }
        .padding(11)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func graphEquationRow(_ equation: CalculatorGraphEquation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Toggle("Show equation", isOn: equationEnabledBinding(equation.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Show equation \(equation.expression)")

                Circle()
                    .fill(graphColor(equation.colorIndex))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text("y =")
                    .font(.system(.body, design: .rounded).weight(.medium))

                TextField("sin(x)", text: equationExpressionBinding(equation.id))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Equation")

                Button {
                    store.removeGraphEquation(equation.id)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.graphEquations.count == 1)
                .help("Remove equation")
                .accessibilityLabel("Remove equation")
            }

            if let error = store.graphError(for: equation) {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 45)
            }
        }
    }

    private var graphCard: some View {
        let series = store.graphSeries()
        let plottedPoints = graphPoints(from: series)
        let xDomain = store.normalizedXDomain
        let yDomain = store.yDomain(for: series)

        return VStack(alignment: .leading, spacing: 6) {
            if series.isEmpty {
                ContentUnavailableView {
                    Label("No Graph to Show", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Enable a valid equation to draw it here.")
                }
                .frame(maxWidth: .infinity, minHeight: 270)
            } else {
                Chart {
                    if xDomain.contains(0) {
                        RuleMark(x: .value("Y axis", 0))
                            .foregroundStyle(.secondary.opacity(0.65))
                    }
                    if yDomain.contains(0) {
                        RuleMark(y: .value("X axis", 0))
                            .foregroundStyle(.secondary.opacity(0.65))
                    }

                    ForEach(plottedPoints) { point in
                        LineMark(
                            x: .value("x", point.x),
                            y: .value("y", point.y),
                            series: .value("Series", point.seriesKey)
                        )
                        .foregroundStyle(graphColor(point.colorIndex))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: yDomain)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(position: .bottom, values: .automatic(desiredCount: 7)) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.secondary.opacity(0.25))
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.secondary.opacity(0.25))
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .frame(minHeight: 280, idealHeight: 330)
                .accessibilityLabel("Function graph")
            }
        }
        .padding(10)
        .background(.background.opacity(0.74), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        }
    }

    private var graphViewportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Viewport")
                    .font(.subheadline.weight(.semibold))
                Spacer()

                graphControlButton("arrow.left", help: "Pan left") { store.panGraph(by: -0.2) }
                graphControlButton("arrow.right", help: "Pan right") { store.panGraph(by: 0.2) }
                graphControlButton("minus.magnifyingglass", help: "Zoom out") { store.zoomGraph(by: 2) }
                graphControlButton("plus.magnifyingglass", help: "Zoom in") { store.zoomGraph(by: 0.5) }
                graphControlButton("arrow.counterclockwise", help: "Reset graph") { store.resetGraph() }
            }

            HStack(spacing: 10) {
                domainField("X min", value: $store.graphXMinimum)
                domainField("X max", value: $store.graphXMaximum)
            }

            Toggle("Automatically fit the vertical range", isOn: $store.graphUsesAutomaticY)
                .toggleStyle(.checkbox)

            if !store.graphUsesAutomaticY {
                HStack(spacing: 10) {
                    domainField("Y min", value: $store.graphYMinimum)
                    domainField("Y max", value: $store.graphYMaximum)
                }
            }
        }
        .padding(11)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func calculatorGrid<Content: View>(
        columns: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 42), spacing: 6), count: columns),
            spacing: 6
        ) {
            content()
        }
    }

    private func digitKey(_ value: String) -> some View {
        key(value, role: .digit) { store.insert(value) }
    }

    private func functionKey(_ title: String, function: String) -> some View {
        key(title, role: .function) { store.applyFunction(function) }
    }

    private func key(
        _ title: String,
        role: CalculatorKeyRole,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        CalculatorKeyButton(title: title, role: role, compact: compact) {
            action()
            if store.mode != .graphing { expressionIsFocused = true }
        }
    }

    private func graphControlButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 25, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }

    private func domainField(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func equationExpressionBinding(_ id: CalculatorGraphEquation.ID) -> Binding<String> {
        Binding {
            store.graphEquations.first(where: { $0.id == id })?.expression ?? ""
        } set: { value in
            guard let index = store.graphEquations.firstIndex(where: { $0.id == id }) else { return }
            store.graphEquations[index].expression = value
        }
    }

    private func equationEnabledBinding(_ id: CalculatorGraphEquation.ID) -> Binding<Bool> {
        Binding {
            store.graphEquations.first(where: { $0.id == id })?.isEnabled ?? false
        } set: { value in
            guard let index = store.graphEquations.firstIndex(where: { $0.id == id }) else { return }
            store.graphEquations[index].isEnabled = value
        }
    }

    private func applyGraphPreset(_ expression: String) {
        if let index = store.graphEquations.firstIndex(where: {
            $0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            store.graphEquations[index].expression = expression
            store.graphEquations[index].isEnabled = true
        } else if store.graphEquations.count < 5 {
            store.addGraphEquation()
            guard let index = store.graphEquations.indices.last else { return }
            store.graphEquations[index].expression = expression
        } else if let index = store.graphEquations.firstIndex(where: { !$0.isEnabled }) {
            store.graphEquations[index].expression = expression
            store.graphEquations[index].isEnabled = true
        }
    }

    private func graphColor(_ index: Int) -> Color {
        graphColors[index.modulo(graphColors.count)]
    }

    @MainActor
    private func focusExpressionAfterPresentation() async {
        guard store.mode != .graphing else {
            expressionIsFocused = false
            return
        }

        // Let the click that opened the docked panel finish before assigning
        // first responder to the newly inserted expression field.
        expressionIsFocused = false
        await Task.yield()
        expressionIsFocused = true
    }

    private func graphPoints(
        from series: [CalculatorGraphSeries]
    ) -> [CalculatorPlottedPoint] {
        series.flatMap { graphSeries in
            graphSeries.points.map { point in
                CalculatorPlottedPoint(
                    id: "\(graphSeries.id.uuidString)-\(point.id)",
                    x: point.x,
                    y: point.y,
                    seriesKey: "\(graphSeries.id.uuidString)-\(point.segment)",
                    colorIndex: graphSeries.colorIndex
                )
            }
        }
    }
}

private struct CalculatorPlottedPoint: Identifiable {
    let id: String
    let x: Double
    let y: Double
    let seriesKey: String
    let colorIndex: Int
}

private enum CalculatorKeyRole {
    case digit
    case function
    case operation
    case equals
    case destructive
    case memory
}

private struct CalculatorKeyButton: View {
    let title: String
    let role: CalculatorKeyRole
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 12 : 14, weight: role == .digit ? .medium : .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 26 : 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 6 : 8)
                .stroke(borderStyle, lineWidth: role == .equals ? 0 : 0.6)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var foregroundStyle: Color {
        role == .equals ? .white : .primary
    }

    private var backgroundStyle: Color {
        switch role {
        case .digit:
            Color(nsColor: .controlBackgroundColor)
        case .function, .memory:
            Color.secondary.opacity(0.13)
        case .operation:
            Color.accentColor.opacity(0.18)
        case .equals:
            Color.accentColor
        case .destructive:
            Color.red.opacity(0.16)
        }
    }

    private var borderStyle: Color {
        role == .operation ? .accentColor.opacity(0.25) : .secondary.opacity(0.18)
    }

    private var accessibilityLabel: String {
        switch title {
        case "÷": "Divide"
        case "×": "Multiply"
        case "−": "Subtract"
        case "+": "Add"
        case "=": "Equals"
        case "±": "Change sign"
        case "⌫": "Delete last character"
        case "( )": "Parenthesis"
        default: title
        }
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        guard divisor > 0 else { return 0 }
        let result = self % divisor
        return result >= 0 ? result : result + divisor
    }
}
