import SwiftUI

/// Full-screen lock overlay shown while `AppLockController.state == .locked`.
struct AppLockView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 44))
            Text("NurseTimer is locked").font(.headline)
            Text("Authenticate to view patient reminders.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                Task { await app.lock.authenticate() }
            } label: {
                Label("Unlock", systemImage: "faceid").padding(.horizontal)
            }
            .buttonStyle(.borderedProminent)
            if let error = app.lock.lastError {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .task { await app.lock.authenticate() }   // auto-prompt on appear
    }
}
