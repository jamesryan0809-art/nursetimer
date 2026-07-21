import SwiftUI
import NurseTimerModels

/// Bottom tab bar: Board · Schedule · Log (spec §6.1). Hosts the centralized
/// Add/Edit/Repair task sheet and the non-fatal banner.
struct RootTabView: View {
    @Environment(NurseStore.self) private var store
    @Environment(AppModel.self) private var app
    @AppStorage("disclaimerAcknowledged") private var disclaimerAcknowledged = false
    @State private var selection = 0
    @State private var boardRoomFilter: String?

    var body: some View {
        @Bindable var store = store
        TabView(selection: $selection) {
            BoardView(roomFilter: $boardRoomFilter)
                .tabItem { Label("Board", systemImage: "square.grid.2x2") }
                .tag(0)
            ScheduleView()
                .tabItem { Label("Schedule", systemImage: "calendar.day.timeline.left") }
                .tag(1)
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                .tag(2)
        }
        .safeAreaInset(edge: .top) { BannerView(banner: $store.banner) }
        .onChange(of: store.route) { _, route in handle(route) }
        .sheet(item: $store.editRequest) { target in
            NavigationStack { TaskEditView(target: target) }
        }
        .sheet(item: $store.taskDetailRequest) { target in
            TaskDetailSheet(task: target.task)
        }
        // First-launch disclaimer (§1.2), acknowledged once.
        .fullScreenCover(isPresented: Binding(get: { !disclaimerAcknowledged }, set: { _ in })) {
            DisclaimerView(acknowledged: $disclaimerAcknowledged)
        }
        // App lock overlay (§6.3).
        .overlay {
            if app.lock.state == .locked { AppLockView() }
        }
    }

    private func handle(_ route: AppRoute?) {
        guard let route else { return }
        switch route {
        case .board(let room):
            selection = 0
            boardRoomFilter = room
        case .repairTask(let id):
            selection = 0
            if let task = store.task(withID: id) { store.editRequest = .repair(task) }
        }
        store.route = nil
    }
}

/// Non-fatal problems the app must show rather than swallow.
struct BannerView: View {
    @Binding var banner: AppBanner?

    var body: some View {
        if let banner {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(banner.level))
                Text(banner.message).font(.footnote)
                Spacer(minLength: 0)
                Button { self.banner = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(color(banner.level))
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func icon(_ l: AppBanner.Level) -> String {
        switch l { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" }
    }
    private func color(_ l: AppBanner.Level) -> Color {
        switch l { case .info: .secondary; case .warning: .orange; case .error: .red }
    }
}
