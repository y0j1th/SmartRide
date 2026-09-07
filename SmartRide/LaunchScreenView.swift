//
//  LaunchScreenView.swift
//  SmartRide
//
//  Custom in-app launch screen — logo, wordmark, and a progress indicator, shown
//  while real startup work (seeding demo history data) runs. The OS-level launch
//  screen (shown before any of our code even runs) is a static image with no way
//  to show progress; this is the layer that actually can.
//

import SwiftUI

struct LaunchScreenView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.35, blue: 0.98), Color(red: 0.04, green: 0.10, blue: 0.28)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("LogoMark")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)

                VStack(spacing: 4) {
                    Text("SmartRide")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Smarter Commutes, Less Traffic")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(.top, 16)
            }
        }
    }
}

#Preview {
    LaunchScreenView()
}
