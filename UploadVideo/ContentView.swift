import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "camera")
                    .font(.system(size: 44, weight: .light))
                    .accessibilityHidden(true)

                Text("Camera setup")
                    .font(.headline)
            }
            .foregroundStyle(.white)
        }
    }
}

#Preview {
    ContentView()
}
