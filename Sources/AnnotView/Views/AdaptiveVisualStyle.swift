import SwiftUI

extension View {
    func glassControlSurface(in shape: some Shape) -> some View {
        glassEffect(.regular.interactive(), in: shape)
    }
}
