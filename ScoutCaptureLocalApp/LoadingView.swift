import SwiftUI

struct LoadingView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var logoName: String {
        colorScheme == .dark ? "ScoutCaptureLogoWhite" : "ScoutCaptureLogoBlue"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(logoName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width)

                    ProgressView()
                        .tint(colorScheme == .dark ? .white : .black)
                }
            }
        }
    }
}
