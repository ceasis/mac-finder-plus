import AppKit
import SwiftUI

/// First-run welcome flow. Walks a new user through the one folder grant Workbench
/// needs to browse their files. Optional capture permissions are deferred until
/// the user explicitly enables Pro Tools.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    @State private var permissions = PermissionsManager()
    @State private var step = 0

    private let totalSteps = 2

    private var progress: Double {
        Double(step + 1) / Double(totalSteps)
    }

    private var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private var homeName: String {
        FileManager.default.displayName(atPath: homeURL.path)
    }

    private var abbreviatedHomePath: String {
        (homeURL.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

            Divider()

            content
                .id(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 42)
                .padding(.vertical, 30)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            Divider()
            footer
        }
        .frame(width: 620, height: 540)
        .background(.regularMaterial)
        .onAppear { permissions.refresh() }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("QUICK SETUP")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Step \(step + 1) of \(totalSteps)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")

                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        default: folderStep
        }
    }

    private var welcomeStep: some View {
        stepLayout(
            icon: "square.split.2x1",
            showsAppIcon: true,
            title: "Your files, at working speed",
            message: "Workbench brings dual-pane browsing, fast previews, and everyday media tools into one focused Mac workspace."
        ) {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    featureCard("Dual-pane", systemImage: "square.split.2x1")
                    featureCard("Quick previews", systemImage: "eye")
                    featureCard("Media tools", systemImage: "wand.and.stars")
                }

                Label("No account required. Your files stay on your Mac.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var folderStep: some View {
        stepLayout(
            icon: "folder.badge.person.crop",
            title: permissions.hasGrantedFolderAccess ? "Your workspace is ready" : "Choose your starting folder",
            message: permissions.hasGrantedFolderAccess
                ? "Workbench can now open your chosen folders. You can pin more locations from the sidebar anytime."
                : "macOS asks you to approve folders before Workbench can remember them. Home is the most useful starting point for most people."
        ) {
            folderAccessCard
        }
    }

    private func stepLayout(
        icon: String,
        showsAppIcon: Bool = false,
        title: String,
        message: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            if showsAppIcon {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 7)
            } else {
                heroIcon(icon)
            }

            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 490)
                .padding(.top, 8)

            action()
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
    }

    private func heroIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 31, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 72, height: 72)
            .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            }
    }

    private func featureCard(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 20)

            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var folderAccessCard: some View {
        if permissions.hasGrantedFolderAccess {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder access granted")
                        .font(.callout.weight(.semibold))
                    Text("\(BookmarkStore.shared.grantedURLs.count) saved \(BookmarkStore.shared.grantedURLs.count == 1 ? "location" : "locations")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Add Another Folder…") {
                    requestFolderAccess(startingAt: appState.activePane.currentURL)
                }
            }
            .padding(17)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 13) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(homeName)
                            .font(.callout.weight(.semibold))
                        Text(abbreviatedHomePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("RECOMMENDED")
                        .font(.caption2.weight(.bold))
                        .tracking(0.45)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                }

                Divider()

                HStack(alignment: .center, spacing: 16) {
                    Text("The folder picker opens on Home. You can choose a different folder there instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Select Home Folder…") {
                        requestFolderAccess(startingAt: homeURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(17)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button("Back", action: goBack)
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if advanceIsPrimary {
                Button(advanceButtonTitle, action: advance)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(advanceButtonTitle, action: advance)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private var currentStepIsReady: Bool {
        switch step {
        case 0: true
        default: permissions.hasGrantedFolderAccess
        }
    }

    private var advanceIsPrimary: Bool {
        step == 0 || currentStepIsReady
    }

    private var advanceButtonTitle: String {
        switch step {
        case 0:
            "Set Up Workbench"
        default:
            currentStepIsReady ? "Finish" : "Finish for Now"
        }
    }

    private func requestFolderAccess(startingAt url: URL?) {
        if let granted = BookmarkStore.shared.requestAccess(startingAt: url) {
            appState.activePane.navigate(to: granted)
        }
        permissions.refresh()
    }

    private func goBack() {
        withAnimation(.snappy(duration: 0.28)) {
            step -= 1
        }
    }

    private func advance() {
        permissions.refresh()

        guard step < totalSteps - 1 else {
            finish()
            return
        }

        withAnimation(.snappy(duration: 0.28)) {
            step += 1
        }
    }

    private func finish() {
        isPresented = false
    }
}
