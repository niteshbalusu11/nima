import SwiftUI

extension View {
    @ViewBuilder func liquidGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }

    @ViewBuilder func liquidGlassCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 26, *) {
            if let tint { glassEffect(.regular.tint(tint).interactive(), in: Capsule()) }
            else { glassEffect(.regular.interactive(), in: Capsule()) }
        } else {
            if let tint { background(tint, in: Capsule()) }
            else { background(.ultraThinMaterial, in: Capsule()) }
        }
    }

    @ViewBuilder func liquidGlassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26, *) {
            if let tint {
                glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: Circle())
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: Circle())
            }
        } else {
            if let tint { background(tint, in: Circle()) }
            else { background(.ultraThinMaterial, in: Circle()) }
        }
    }

    @ViewBuilder func liquidGlassRoundedRectangle(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
