import SwiftUI

/// Compact, themed action menus keep secondary and destructive actions off the main surface.
struct CockpitMenuAction: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var destructive = false
    var enabled = true
    var action: () -> Void
}

struct CockpitActionMenu: View {
    var title: String
    var symbol = "ellipsis"
    var showsTitle = false
    var actions: [CockpitMenuAction]
    @Environment(\.cockpitTheme) private var theme
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 16)
                if showsTitle { Text(title) }
            }.padding(.horizontal, showsTitle ? 10 : 8).frame(height: 30)
        }
        .buttonStyle(InteractiveButton(selected: expanded))
        .accessibilityLabel(title).help(title)
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(actions) { item in
                    if item.destructive { theme.border.frame(height: 0.5).padding(.vertical, 3) }
                    Button {
                        expanded = false
                        item.action()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 16)
                            Text(item.title)
                            Spacer(minLength: 8)
                        }
                        .font(CockpitTypography.body)
                        .foregroundStyle(item.destructive ? theme.emphasis : theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(InteractiveButton()).disabled(!item.enabled)
                }
            }.padding(6).frame(width: 200)
                .background(theme.canvas).foregroundStyle(theme.text)
                .onExitCommand { expanded = false }
        }
    }
}

struct CockpitTabs: View {
    @Binding var selection: String
    var options: [SelectOption]
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button { selection = option.id } label: {
                    Text(option.label)
                        .font(CockpitTypography.font(size: 12, weight: selection == option.id ? .medium : .regular))
                        .foregroundStyle(selection == option.id ? theme.emphasis : theme.muted)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(InteractiveButton())
                .background {
                    if selection == option.id {
                        RoundedRectangle(cornerRadius: 8).fill(theme.accentSoft)
                            .matchedGeometryEffect(id: "active-tab", in: indicator)
                    }
                }
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.selection, value: selection)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { theme.border.frame(height: 0.5) }
    }
}
