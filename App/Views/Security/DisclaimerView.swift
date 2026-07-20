import SwiftUI

/// The exact §1.2 disclaimer wording. Makes no claim of medical judgment, dose
/// calculation, drug guidance, or clinical decision support.
let disclaimerText = "This app is a personal organizational tool. It is not a medical device and does not replace your facility's medication administration record or clinical judgment."

/// First-launch disclaimer, acknowledged once (spec §1.2). The only interstitial.
struct DisclaimerView: View {
    @Binding var acknowledged: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "cross.case").font(.system(size: 44))
            Text("Before you start").font(.title2.bold())
            Text(disclaimerText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                acknowledged = true
            } label: {
                Text("I understand").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding()
        .interactiveDismissDisabled(true)
    }
}

/// Read-only disclaimer shown from Settings › About.
struct DisclaimerText: View {
    var body: some View {
        ScrollView { Text(disclaimerText).padding() }
            .navigationTitle("Disclaimer")
    }
}
