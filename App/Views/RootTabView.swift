import SwiftUI
import NurseTimerCore
import NurseTimerModels

/// Bottom tab bar: Board · Schedule · Log (spec §6.1). Hosts the centralized
/// Add/Edit/Repair task sheet and the non-fatal banner.
struct RootTabView: View {
    @Environment(NurseStore.self) private var store
    @Environment(AppModel.self) private var app
    @AppStorage("disclaimerAcknowledged") private var disclaimerAcknowledged = false
    @State private var selection = 0
    @State private var boardRoomFilter: String?
    /// The reduction detail to show in the one-time-per-change alert (feedback item 2).
    @State private var reductionAlert: ReductionState?

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
        // Action acknowledgment: haptic + brief bottom toast on every successful action,
        // across all tabs and surfaces (feedback micro-pass).
        .actionAcknowledgments()
        .safeAreaInset(edge: .top) { BannerView(banner: $store.banner) }
        // Reduction is non-blocking now (feedback item 2): a dismissible alert on app open and
        // when the reduction first becomes true or changes; a persistent nav-bar indicator
        // (BoardView) lets the nurse re-show details anytime. Cleared when reduction resolves.
        .onChange(of: store.reduction) { _, new in reductionAlert = new.isActive ? new : nil }
        .alert(reductionAlert?.headline ?? "Reminders adjusted",
               isPresented: Binding(get: { reductionAlert != nil },
                                    set: { if !$0 { reductionAlert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reductionAlert?.detail ?? "")
        }
        // Fixed-times "which dose was given?" chooser (feedback pass 4, item 2b).
        .confirmationDialog("Which dose was given?",
                            isPresented: Binding(get: { store.givenChoice != nil },
                                                 set: { if !$0 { store.givenChoice = nil } }),
                            titleVisibility: .visible,
                            presenting: store.givenChoice) { choice in
            ForEach(choice.candidates, id: \.time) { candidate in
                Button(candidateLabel(candidate)) { store.resolveGiven(choice, chosen: candidate) }
            }
            Button("Cancel", role: .cancel) { store.givenChoice = nil }
        } message: { _ in
            Text("An earlier dose is still overdue. Choose which one you just gave — the other stays on the schedule or is logged as missed.")
        }
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

    /// "9:00 AM (overdue)" / "5:00 PM" for the dose chooser (item 2b).
    private func candidateLabel(_ c: SchedulingEngine.GivenCandidate) -> String {
        AppTime.short(c.time) + (c.isOverdue ? " (overdue)" : "")
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
