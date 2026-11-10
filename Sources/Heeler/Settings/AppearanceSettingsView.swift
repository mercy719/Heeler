import SwiftUI

/// Settings › Appearance: the app's light or dark theme, then the
/// terminal's and Chat's own font and text size, each surface in its
/// section. Pushed from the settings root, which owns the NavigationStack.
struct AppearanceSettingsView: View {
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    @AppStorage(AppAccentColor.defaultsKey) private var accentColor = AppAccentColor.defaultRawValue

    var body: some View {
        Form {
            Section {
                themePicker
            }
            Section {
                accentPicker
                accentSample
            } header: {
                Text("Accent Color")
            }
            TerminalAppearanceSection(terminal: terminal)
            ChatAppearanceSection()
        }
        .readableColumnPage()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Three live-looking thumbnails, wired to the existing appearance store.
    private var themePicker: some View {
        HStack(spacing: 12) {
            ForEach(AppAppearanceOption.allCases) { @Sendable option in
                MainActorContent {
                    Button {
                        appearance.select(option)
                    } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 0) {
                                thumbnailColors(option).0
                                thumbnailColors(option).1
                            }
                            .frame(width: 92, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if appearance.selection == option {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(.tint, lineWidth: 2.5)
                                        .frame(width: 98, height: 64)
                                }
                            }
                            Text(option.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: option.title))
                    .accessibilityAddTraits(appearance.selection == option ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func thumbnailColors(_ option: AppAppearanceOption) -> (Color, Color) {
        let light = Color(red: 0.91, green: 0.93, blue: 0.96)
        let dark = Color(red: 0.16, green: 0.16, blue: 0.17)
        switch option {
        case .system: return (light, dark)
        case .light: return (light, Color(red: 0.97, green: 0.97, blue: 0.98))
        case .dark: return (dark, Color(red: 0.1, green: 0.1, blue: 0.11))
        }
    }

    private var accentPicker: some View {
        HStack(spacing: 9) {
            ForEach(AppAccentColor.allCases) { @Sendable option in
                MainActorContent {
                    Button {
                        accentColor = option.rawValue
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if accentColor == option.rawValue {
                                    Circle()
                                        .stroke(.primary, lineWidth: 2)
                                        .frame(width: 31, height: 31)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: option.rawValue))
                    .accessibilityAddTraits(accentColor == option.rawValue ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var accentSample: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Text("Is it done?")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(AppAccentColor.color(for: accentColor), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(alignment: .bottom, spacing: 10) {
                OBPlushAvatar(seed: "appearance-preview", size: 34)
                    .clipShape(Circle())
                    .accessibilityLabel("Appearance")
                Text("Done. The load test is running.")
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 32)
            }
        }
        .padding(.top, 8)
    }
}

/// The terminal's font, text size, and per-appearance theme slots, each
/// slot opening a picker with its own live preview.
private struct TerminalAppearanceSection: View {
    let terminal: TerminalSettings

    var body: some View {
        Section {
            Picker(
                "Font",
                selection: Binding(
                    get: { terminal.fonts.selection },
                    set: { terminal.fonts.select($0) })
            ) {
                ForEach(terminal.fonts.availableOptions) { @Sendable option in
                    Text(option.title).tag(option)
                }
            }
            Stepper(
                value: Binding(
                    get: { terminal.zoom.fontSize },
                    set: { terminal.zoom.setFontSize($0) }),
                in: TerminalZoomSettings.range,
                step: 1
            ) {
                LabeledContent("Text Size") {
                    Text("\(Int(terminal.zoom.fontSize)) pt")
                        .monospacedDigit()
                }
            }
            .accessibilityValue("\(Int(terminal.zoom.fontSize)) points")
            themePickerLink(for: .light)
            themePickerLink(for: .dark)
        } header: {
            Text("Terminal")
        } footer: {
            Text(
                String(localized: "Pinching a terminal to zoom changes its text size too, and it sticks. Each appearance has its own theme: a dark theme for Light Mode keeps the terminal dark under a light system."))
        }
    }

    private func themePickerLink(for scheme: ColorScheme) -> some View {
        NavigationLink {
            TerminalThemePickerView(terminal: terminal, scheme: scheme)
        } label: {
            HStack(spacing: 12) {
                TerminalThemeSwatchCard(
                    option: terminal.themes.selection(for: scheme),
                    scheme: scheme, compact: true
                )
                .frame(width: 54, height: 38)
                .accessibilityHidden(true)
                Text(scheme == .dark ? String(localized: "Dark Mode") : String(localized: "Light Mode"))
                Spacer(minLength: 12)
                Text(terminal.themes.selection(for: scheme).title)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(terminal.themes.selection(for: scheme).title)
    }
}

/// Where Fold Finished Turns is kept. On by default.
enum ChatFoldSettings {
    static let defaultsKey = "chat.fold-finished-turns"
}

/// The conversation's font and text size with a sample in them, and Fold
/// Finished Turns, which is how a turn reads once it ends.
private struct ChatAppearanceSection: View {
    @AppStorage(ChatTextSettings.sizeOffsetKey) private var textSizeOffset = ChatTextSettings.defaultSizeOffset
    @AppStorage(ChatTextSettings.fontKey) private var font = ChatFontOption.system
    @AppStorage(ChatFoldSettings.defaultsKey) private var foldsFinishedTurns = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            Picker("Font", selection: $font) {
                ForEach(ChatFontOption.allCases) { @Sendable option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityIdentifier("settings.chat.font")
            Stepper(value: $textSizeOffset, in: ChatTextSettings.sizeOffsetRange) {
                LabeledContent("Text Size") {
                    Text("\(bodyPoints) pt")
                        .monospacedDigit()
                }
            }
            .accessibilityValue("\(bodyPoints) points")
            .accessibilityIdentifier("settings.chat.textSize")
            Text("Agents reply here as they would in Chat.")
                .dynamicTypeSize(textSize)
                .fontDesign(font.design)
                .padding(.vertical, 4)
                .accessibilityIdentifier("settings.chat.textSample")
            Toggle("Fold Finished Turns", isOn: $foldsFinishedTurns)
                .accessibilityIdentifier("settings.chat.foldFinishedTurns")
        } header: {
            Text("Chat")
        } footer: {
            Text(
                String(localized: "Code stays monospaced, and the text size follows the system's from there. A finished turn's steps fold behind one line above its answer; a turn stays open while it runs or while its background work does."))
        }
    }

    private var textSize: DynamicTypeSize {
        ChatTextSettings.size(system: dynamicTypeSize, offset: textSizeOffset)
    }

    private var bodyPoints: Int {
        Int(ChatTextSettings.bodyPointSize(at: textSize).rounded())
    }
}
