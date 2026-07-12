import SwiftUI

struct DiskSpaceAnalyzerPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = DiskSpaceAnalyzerStore.shared
    @State private var selectedCandidateKind: DiskSpaceContentKind = .documents

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .alert("Disk Space Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Disk Space", systemImage: "chart.pie")
                .font(.headline)

            Spacer()

            if store.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing Disk Space")
                        .font(.subheadline.weight(.medium))
                }
                Button {
                    store.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .help("Stop disk scan")
            } else {
                Button {
                    store.startScan(containing: appState.activePane.currentURL, force: true)
                } label: {
                    Label("Analyze Disk Space", systemImage: "chart.pie.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Analyze the disk containing the active folder")
            }

            Button {
                appState.hideDiskSpaceAnalyzer()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide Disk Space")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let analysis = store.analysis {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary(analysis)
                    if store.isScanning {
                        scanStatus
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                        spacing: 14
                    ) {
                        DiskSpacePieCard(
                            title: "By Type",
                            systemImage: "square.stack.3d.up",
                            slices: analysis.typeSlices
                        )
                        DiskSpacePieCard(
                            title: "By Modified Date",
                            systemImage: "calendar",
                            slices: analysis.dateSlices
                        )
                        DiskSpacePieCard(
                            title: "By Size",
                            systemImage: "arrow.up.left.and.arrow.down.right",
                            slices: analysis.sizeSlices
                        )
                        DiskSpacePieCard(
                            title: "Largest Apps",
                            systemImage: "app.badge",
                            slices: analysis.applicationSlices
                        )
                    }
                    DiskSpaceDeletionCandidatesSection(
                        analysis: analysis,
                        selectedKind: $selectedCandidateKind,
                        destinations: externalDriveDestinations(excluding: analysis.volumePath),
                        reveal: { candidate in
                            appState.revealInFinder([candidate.url])
                        },
                        move: { candidate, destination in
                            appState.moveItemsToExternalDrive([candidate.url], destination: destination.url)
                        }
                    )
                }
                .padding(12)
            }
        } else if store.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Analyzing Disk")
                    .font(.headline)
                Text(store.scanDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "No Disk Analysis Yet",
                    systemImage: "chart.pie",
                    description: Text("Analyze the disk containing the active folder to see where its files are using space.")
                )

                Button {
                    store.startScan(containing: appState.activePane.currentURL, force: true)
                } label: {
                    Label("Analyze Disk Space", systemImage: "chart.pie.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ analysis: DiskSpaceAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(analysis.volumeName, systemImage: "internaldrive")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(lastScanText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(analysis.volumePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                DiskSpaceMetric(label: "Analyzed Files", value: analysis.totalBytesText)
                if let used = analysis.usedCapacity {
                    DiskSpaceMetric(
                        label: "Volume Used",
                        value: ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
                    )
                }
                if let available = analysis.availableCapacity {
                    DiskSpaceMetric(
                        label: "Available",
                        value: ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                    )
                }
            }

            if let capacity = analysis.volumeCapacity,
               let used = analysis.usedCapacity,
               capacity > 0 {
                let usedFraction = min(max(Double(used) / Double(capacity), 0), 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Capacity")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(Int((usedFraction * 100).rounded()))% used")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: usedFraction)
                        .tint(capacityColor(for: usedFraction))
                        .controlSize(.small)
                }
            }

            Text(store.scanDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(.quaternary.opacity(0.32))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var scanStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(store.scanDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 2)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private var lastScanText: String {
        guard let lastScannedAt = store.lastScannedAt else { return "Scanning" }
        return "Last analyzed \(lastScannedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func capacityColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.9...: .red
        case 0.75...: .orange
        default: .green
        }
    }

    private func externalDriveDestinations(excluding volumePath: String) -> [DiskSpaceExternalDrive] {
        DiskSpaceExternalDrive.available(excludingVolumePath: volumePath)
    }
}

private struct DiskSpaceMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DiskSpaceDeletionCandidatesSection: View {
    let analysis: DiskSpaceAnalysis
    @Binding var selectedKind: DiskSpaceContentKind
    let destinations: [DiskSpaceExternalDrive]
    let reveal: (DiskSpaceDeletionCandidate) -> Void
    let move: (DiskSpaceDeletionCandidate, DiskSpaceExternalDrive) -> Void

    private var candidates: [DiskSpaceDeletionCandidate] {
        analysis.deletionCandidates(for: selectedKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Deletion Candidates", systemImage: "trash.slash")
                    .font(.headline)
                Text("Largest items in the latest analysis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Top \(candidates.count) of 50")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(DiskSpaceContentKind.allCases) { kind in
                        Button {
                            selectedKind = kind
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: kind.systemImage)
                                Text(kind.title)
                                Text(analysis.deletionCandidates(for: kind).count.formatted())
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(selectedKind == kind ? .white.opacity(0.9) : .secondary)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(selectedKind == kind ? .white : .primary)
                            .background(
                                selectedKind == kind ? Color.accentColor : Color.secondary.opacity(0.10),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Show the largest \(kind.title.lowercased())")
                    }
                }
                .padding(.vertical, 1)
            }

            Divider()

            if candidates.isEmpty {
                ContentUnavailableView(
                    "No \(selectedKind.title) Candidates",
                    systemImage: selectedKind.systemImage,
                    description: Text("No eligible \(selectedKind.title.lowercased()) were found in this analysis.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        DiskSpaceDeletionCandidateRow(
                            candidate: candidate,
                            rank: index + 1,
                            destinations: destinations,
                            reveal: { reveal(candidate) },
                            move: { destination in move(candidate, destination) }
                        )
                        if index < candidates.count - 1 {
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
            }

            Text("Reanalyze after moving or deleting items to refresh this snapshot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct DiskSpaceDeletionCandidateRow: View {
    let candidate: DiskSpaceDeletionCandidate
    let rank: Int
    let destinations: [DiskSpaceExternalDrive]
    let reveal: () -> Void
    let move: (DiskSpaceExternalDrive) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(rank.formatted())
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            Image(systemName: candidate.isDirectory ? "app.dashed" : candidate.kind.systemImage)
                .foregroundStyle(candidate.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if candidate.isSystemItem {
                        Text("System")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12), in: Capsule())
                            .help("System-managed item. Avoid moving or deleting it.")
                    }
                    Text(candidate.parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Text(candidate.sizeText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Button(action: reveal) {
                        Label("Reveal", systemImage: "finder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Menu {
                        if destinations.isEmpty {
                            Text("Connect an external drive to move this item.")
                        } else {
                            ForEach(destinations) { destination in
                                Button {
                                    move(destination)
                                } label: {
                                    Label(destination.menuTitle, systemImage: "externaldrive")
                                }
                            }
                        }
                    } label: {
                        Label("Move to SSD", systemImage: "externaldrive.badge.plus")
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .disabled(destinations.isEmpty || candidate.isSystemItem)
                    .help(moveHelp)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 10)
    }

    private var moveHelp: String {
        if candidate.isSystemItem {
            return "System-managed items should not be moved or deleted"
        }
        if destinations.isEmpty {
            return "Connect an external drive to move this item"
        }
        return "Move this item to an external drive"
    }
}

private struct DiskSpaceExternalDrive: Identifiable {
    let url: URL
    let name: String
    let availableCapacity: Int64?

    var id: String { url.path }

    var menuTitle: String {
        guard let availableCapacity else { return name }
        let available = ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
        return "\(name) · \(available) available"
    }

    static func available(excludingVolumePath: String) -> [DiskSpaceExternalDrive] {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsBrowsableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeLocalizedNameKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard standardized.path != excludingVolumePath,
                  let values = try? standardized.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable != false,
                  values.volumeIsInternal != true,
                  values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
            else { return nil }

            let name = values.volumeLocalizedName
                ?? (standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent)
            return DiskSpaceExternalDrive(
                url: standardized,
                name: name,
                availableCapacity: values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct DiskSpacePieCard: View {
    let title: String
    let systemImage: String
    let slices: [DiskSpaceSlice]

    private var visibleSlices: [DiskSpaceSlice] {
        slices.filter { $0.bytes > 0 }
    }

    private var totalBytes: Int64 {
        visibleSlices.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(totalSizeText)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            chartAndLegend
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var chartAndLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                DiskSpacePieChart(slices: visibleSlices)
                    .frame(width: 124, height: 124)
                legend
            }
            VStack(alignment: .leading, spacing: 10) {
                DiskSpacePieChart(slices: visibleSlices)
                    .frame(height: 132)
                    .frame(maxWidth: .infinity)
                legend
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        if visibleSlices.isEmpty {
            Text("No data found")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(visibleSlices.enumerated()), id: \.element.id) { index, slice in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(DiskSpaceChartPalette.color(at: index))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slice.title)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(slice.itemCount.formatted()) items")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(slice.sizeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(percentageText(for: slice))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help("\(slice.itemCount.formatted()) items · \(slice.sizeText) · \(percentageText(for: slice))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private func percentageText(for slice: DiskSpaceSlice) -> String {
        guard totalBytes > 0 else { return "0%" }
        return "\(Int((Double(slice.bytes) / Double(totalBytes) * 100).rounded()))%"
    }
}

private struct DiskSpacePieChart: View {
    let slices: [DiskSpaceSlice]

    var body: some View {
        Canvas { context, size in
            let total = slices.reduce(Int64(0)) { $0 + $1.bytes }
            let diameter = min(size.width, size.height)
            let rect = CGRect(
                x: (size.width - diameter) / 2 + 2,
                y: (size.height - diameter) / 2 + 2,
                width: max(diameter - 4, 0),
                height: max(diameter - 4, 0)
            )

            guard total > 0 else {
                context.fill(Path(ellipseIn: rect), with: .color(Color.secondary.opacity(0.14)))
                return
            }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            var startAngle = -90.0
            for (index, slice) in slices.enumerated() {
                let sweep = Double(slice.bytes) / Double(total) * 360
                var segment = Path()
                segment.move(to: center)
                segment.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(startAngle),
                    endAngle: .degrees(startAngle + sweep),
                    clockwise: false
                )
                segment.closeSubpath()
                context.fill(segment, with: .color(DiskSpaceChartPalette.color(at: index)))
                startAngle += sweep
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private enum DiskSpaceChartPalette {
    private static let colors: [Color] = [
        Color(red: 0.16, green: 0.45, blue: 0.84),
        Color(red: 0.10, green: 0.56, blue: 0.38),
        Color(red: 0.88, green: 0.39, blue: 0.12),
        Color(red: 0.76, green: 0.25, blue: 0.46),
        Color(red: 0.10, green: 0.59, blue: 0.63),
        Color(red: 0.69, green: 0.53, blue: 0.07),
        Color(red: 0.39, green: 0.32, blue: 0.72),
    ]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}
