import SwiftUI

// PARITY-2C C3: the session's server-owned controls, as the shared
// mobile/desktop composer surface renders them.
//
// The chips show exactly the state the store already owns - the selected
// session's `permissions` and `plan` projections - plus the two facts that
// block a click: this store's open full-access question, and this store's
// own control action in flight. Nothing else: a click awaiting its answer,
// the composer draft, the staged menu choice never appear here as the
// accepted state. The server's projection frame is the only writer of that
// state, so the chip's label is the projection's current value - or, when
// the projection no longer offers that value, the value itself - and the
// checkmark sits on the row the projection names, never on a row the user
// was about to choose.
//
// The chips are the DSH composer's: the Native harness has no host commands
// behind them, and a disconnected store has no session to switch. The chips
// never touch the draft and never call session/prompt: a click is a request
// to the Host's own commands, and the projection is the fact.

/// One row of the composer's permission menu, as the projection's own
/// options serve it.
struct PermissionControlRow: Identifiable, Equatable {
    let value: String
    let name: String
    /// `custom` is the projection's display row: the current value the Host
    /// does not switch. The menu shows it and never sends it, so the row is
    /// rendered - not a button.
    let selectable: Bool
    var id: String { value }
}

/// The composer's session controls, derived from one store's state.
///
/// One derivation point between the store and the chips: the view renders
/// this value and nothing else, and the offline checks drive the same store
/// state and read this same derived value back.
@MainActor
struct SessionControlSurface: Equatable {
    struct Permission: Equatable {
        /// The menu's rows, in the projection's own order.
        var rows: [PermissionControlRow]
        /// The server-owned current value, verbatim.
        var currentValue: String
        /// The row the current value names - or nil: the label then falls
        /// back to the raw value and no row carries the checkmark.
        var currentRow: PermissionControlRow?
        /// The display-only `custom` row, when the projection offers one.
        var customRow: PermissionControlRow?
        /// What the chip's label shows: the server's value by its own name,
        /// falling back to the value when the projection does not offer it.
        var label: String { currentRow?.name ?? currentValue }
    }
    struct Plan: Equatable {
        var active: Bool
        /// A transition the Host already accepted toward the opposite state:
        /// the chip blocks re-toggling while it is in flight.
        var pending: Bool
    }
    /// The chips are the DSH composer's: connected, DSH-backed, and a session
    /// is selected.
    var visible: Bool
    /// A full-access question is open on this store - the chip's own, or the
    /// approval and composer questions on the same shared gate. The chips
    /// render the asking state, and a click refused because the gate already
    /// shows another question can never read back as a new escalation of
    /// their own.
    var asking: Bool
    /// This store's control seat is taken: a click is in flight until its
    /// answer settles, in either direction (the seat is shared with the plan
    /// toggle, so an in-flight plan toggle reads as busy here too).
    var busy: Bool
    /// This store's own plan toggle is the action in flight on the wire.
    var planInFlight: Bool
    /// The session's `permissions` projection - or nil: the Host stopped
    /// serving it, and the chip renders the neutral state.
    var permission: Permission?
    /// The session's `plan` projection - or nil: the neutral state.
    var plan: Plan?
}

extension SessionControlSurface {
    /// Derive the chips' state from the store. The reads are the same ones
    /// the store's own dispatch freezes at the click: the selected session's
    /// fold, the gate's open question, the seat's occupant - never a copy of
    /// them.
    init(store: PocketStore) {
        let id = store.selectedID
        let fold = id.flatMap { store.projectionStores[$0] }
        var permission: Permission?
        if let select = fold?.permissions {
            let rows = select.options.map {
                PermissionControlRow(value: $0.value, name: $0.name,
                                     selectable: $0.value != "custom")
            }
            let current = rows.first { $0.value == select.currentValue }
            permission = Permission(rows: rows,
                                    currentValue: select.currentValue,
                                    currentRow: current,
                                    customRow: rows.first { !$0.selectable })
        }
        self.permission = permission
        plan = fold?.plan.map { Plan(active: $0.active, pending: $0.pending) }
        visible = store.connected && !store.usesNativeHarness && id != nil
        asking = store.accessConfirmation != nil
        busy = store.activeControl != nil
        planInFlight = store.activeControl?.intent == .plan
    }
}

/// The composer's session control chips: the permission preset menu and the
/// plan-mode toggle, side by side on the shared mobile/desktop composer
/// surface. The view renders one derived value (`SessionControlSurface`) and
/// dispatches into the store's own control paths - nothing in between.
struct SessionControlChips: View {
    @ObservedObject var store: PocketStore
    @Environment(\.harnessTheme) private var theme

    @MainActor
    private var surface: SessionControlSurface { SessionControlSurface(store: store) }

    var body: some View {
        if surface.visible {
            HStack(spacing: 10) {
                if let permission = surface.permission {
                    permissionChip(permission)
                } else {
                    neutralChip("Permission", systemImage: "lock.shield")
                }
                if let plan = surface.plan {
                    planChip(plan)
                } else {
                    neutralChip("Plan", systemImage: "checklist")
                }
            }
        }
    }

    /// The permission preset menu: the projection's own options, the
    /// `custom` row rendered display-only, the checkmark on the row the
    /// projection names. While the click is in flight the chip shows the
    /// spinner and the server's value - never the staged choice.
    private func permissionChip(_ permission: SessionControlSurface.Permission) -> some View {
        Menu {
            ForEach(permission.rows) { row in
                if row.selectable {
                    Button {
                        Task { await store.selectPermission(row.value) }
                    } label: {
                        if row == permission.currentRow { Label(row.name, systemImage: "checkmark") } else { Text(row.name) }
                    }
                    .disabled(surface.asking || surface.busy || row == permission.currentRow)
                } else {
                    if row == permission.currentRow { Label(row.name, systemImage: "checkmark") } else { Text(row.name) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if surface.busy { ProgressView().controlSize(.small) } else { Image(systemName: "lock.shield") }
                Text(permission.label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .disabled(surface.asking || surface.busy)
        .accessibilityLabel(Text("Permission: " + permission.label))
        .accessibilityIdentifier("permissionControl")
        .help("Permission preset")
    }

    /// The plan-mode toggle: the projection's own active/pending state. The
    /// pending transition and the in-flight toggle block re-toggling, and the
    /// toggle asks no full-access question of its own.
    private func planChip(_ plan: SessionControlSurface.Plan) -> some View {
        Button {
            Task { await store.togglePlan() }
        } label: {
            HStack(spacing: 5) {
                if surface.planInFlight || plan.pending { ProgressView().controlSize(.small) }
                else { Image(systemName: plan.active ? "checklist.checked" : "checklist") }
                Text("Plan").lineLimit(1)
            }.font(.caption).foregroundStyle(plan.active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
        }
        .disabled(surface.asking || surface.planInFlight || plan.pending)
        .accessibilityLabel(Text("Plan mode: \(plan.active ? "on" : "off")"))
        .accessibilityIdentifier("planControl")
        .help("Toggle plan mode")
    }

    /// A capability the Host stopped serving: the chip stays, neutral.
    private func neutralChip(_ label: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(label).lineLimit(1)
        }.font(.caption).foregroundStyle(.tertiary)
    }
}
