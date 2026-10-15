import SwiftUI

/// All product forms use these themed controls. Native text editing semantics remain intact.
struct CockpitField: View {
    var title: String
    @Binding var text: String
    var placeholder = ""
    var symbol: String? = nil
    var showsLabel = true
    var focusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    @FocusState private var focused: Bool
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel { Text(title).font(CockpitTypography.font(size: 12, weight: .medium)).foregroundStyle(theme.text) }
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).foregroundStyle(focused ? theme.accent : theme.muted) }
                TextField("", text: $text)
                    .overlay(alignment: .leading) {
                        if text.isEmpty && !focused { Text(placeholder.isEmpty ? title : placeholder).foregroundStyle(theme.muted).allowsHitTesting(false).accessibilityHidden(true) }
                    }
                    .textFieldStyle(.plain).font(CockpitTypography.body)
                    .focused($focused).tint(theme.accent).accessibilityLabel(title)
                    .onChange(of: focusRequest) { _, _ in focused = true }
                    .onAppear { if focusRequest > 0 { focused = true } }
            }
            .padding(.horizontal, 13).frame(minHeight: 40)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? theme.accent : hovered ? theme.muted.opacity(theme.opacity(0.5)) : theme.border, lineWidth: 1))
            .onHover { hovered = $0 }
            .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: focused)
            .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: hovered)
        }
    }
}
struct CockpitEditor: View {
    var title: String
    var height: CGFloat = 200
    var showsLabel = true
    @Binding var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel { Text(title).font(CockpitTypography.font(size: 12, weight: .medium)) }
            TextEditor(text: $text).font(CockpitTypography.body).lineSpacing(5)
                .scrollContentBackground(.hidden).focused($focused).tint(theme.accent)
                .padding(10).frame(height: height)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? theme.accent : theme.border, lineWidth: 1))
                .accessibilityLabel(title)
                .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: focused)
        }
    }
}
struct SelectOption: Identifiable {
    let id: String
    let label: String
    var symbol: String? = nil
}
struct CockpitSelect: View {
    var title: String
    @Binding var selection: String
    var options: [SelectOption]
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel { Text(title).font(CockpitTypography.font(size: 12, weight: .medium)) }
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    if let symbol = options.first(where: { $0.id == selection })?.symbol { Image(systemName: symbol).foregroundStyle(theme.accent) }
                    Text(options.first(where: { $0.id == selection })?.label ?? "请选择").lineLimit(1)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.down").font(CockpitTypography.font(size: 10, weight: .semibold)).foregroundStyle(theme.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.feedback, value: expanded)
                }.padding(.horizontal, 13).frame(minHeight: 40)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(expanded ? theme.accent : theme.border, lineWidth: 1))
            }.buttonStyle(InteractiveButton()).accessibilityLabel(title)
                .accessibilityValue(options.first(where: { $0.id == selection })?.label ?? "请选择")
                .popover(isPresented: $expanded, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(options) { option in
                                Button { selection = option.id; expanded = false } label: {
                                    HStack(spacing: 10) {
                                        if let symbol = option.symbol { Image(systemName: symbol).frame(width: 18) }
                                        Text(option.label).lineLimit(2)
                                        Spacer()
                                        if selection == option.id { Image(systemName: "checkmark").font(CockpitTypography.font(size: 11, weight: .semibold)) }
                                    }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(InteractiveButton(selected: selection == option.id))
                                    .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                            }
                        }.padding(8)
                    }.frame(width: 270, height: min(300, CGFloat(options.count * 42 + 16)))
                        .background(theme.canvas).foregroundStyle(theme.text)
                        .onExitCommand { expanded = false }
                }
        }
    }
}
struct CockpitSegments: View {
    @Namespace private var selectionMotion
    var title: String
    @Binding var selection: String
    var options: [SelectOption]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(CockpitTypography.font(size: 12, weight: .medium))
            HStack(spacing: 4) {
                ForEach(options) { option in
                    Button { selection = option.id } label: {
                        HStack(spacing: 7) {
                            if let symbol = option.symbol { Image(systemName: symbol) }
                            Text(option.label)
                        }.foregroundStyle(theme.binary && selection == option.id ? Color.white : theme.text).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(InteractiveButton(selected: theme.binary && selection == option.id))
                        .background {
                            if selection == option.id {
                                RoundedRectangle(cornerRadius: 8).fill(theme.binary ? theme.text : theme.accentSoft)
                                    .matchedGeometryEffect(id: "selection", in: selectionMotion)
                            }
                        }
                        .foregroundStyle(selection == option.id ? theme.emphasis : theme.text)
                        .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                }
            }.padding(4).background(theme.sidebar, in: RoundedRectangle(cornerRadius: 11))
                .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.selection, value: selection)
        }
    }
}
struct CockpitToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                Capsule().fill(configuration.isOn ? theme.accent : theme.binary ? theme.canvas : theme.border)
                    .overlay(Capsule().stroke(theme.border, lineWidth: theme.binary ? 1 : 0))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(theme.binary && !configuration.isOn ? theme.text : theme.surface).frame(width: 14, height: 14).padding(2)
                    }
                configuration.label.font(CockpitTypography.font(size: 12))
            }.padding(.vertical, 5).padding(.horizontal, 4).contentShape(Rectangle())
        }.buttonStyle(InteractiveButton())
            .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.selection, value: configuration.isOn)
            .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
    }
}
struct CockpitProgressStyle: ProgressViewStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            GeometryReader { geo in
                Capsule().fill(theme.binary ? theme.canvas : theme.border).overlay(Capsule().stroke(theme.border, lineWidth: theme.binary ? 1 : 0)).overlay(alignment: .leading) {
                    Capsule().fill(theme.accent).frame(width: geo.size.width * max(0, min(1, fraction)))
                }
            }.frame(height: 4).animation((reduceMotion || theme.binary) ? nil : CockpitMotion.navigation, value: fraction)
        } else {
            HStack(spacing: 9) {
                CockpitSpinner()
                configuration.label.font(CockpitTypography.font(size: 12)).foregroundStyle(theme.muted)
            }.accessibilityLabel("正在加载")
        }
    }
}


/// One dismissal contract for all in-window dialogs: backdrop, Escape and close button.
/// The background page cannot receive clicks or accessibility focus while presented.
struct CockpitModal<Content: View>: View {
    var width: CGFloat
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.cockpitTheme) private var theme
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Button(action: dismiss) {
                    Rectangle().fill(.black.opacity(theme.binary ? 1 : theme.dark ? 0.45 : 0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("关闭弹窗遮罩")
                    .keyboardShortcut(.cancelAction)
                ViewThatFits(in: .vertical) {
                    content().fixedSize(horizontal: false, vertical: true)
                    ScrollView { content() }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: width)
                .frame(maxHeight: max(100, geometry.size.height - 48))
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    RoundedRectangle(cornerRadius: 16).fill(theme.canvas)
                        .onTapGesture { /* Interior whitespace never dismisses the dialog. */ }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border.opacity(theme.opacity(0.7)), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(theme.binary ? 0 : 0.16), radius: 28, y: 12)
                .accessibilityElement(children: .contain)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
