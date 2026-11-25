import SwiftUI

/// Global filter bar shown on every historical dashboard. Changes apply to all dashboards at once.
struct FilterBar: View {
    @EnvironmentObject var m: Monitor
    var showNetworkFilters = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconBadge(icon: "line.3.horizontal.decrease", color: .indigo, size: 24)
                Picker("Range", selection: $m.filter.preset) {
                    ForEach(RangePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 210)

                if m.filter.preset == .custom {
                    DatePicker("From", selection: $m.filter.customFrom).labelsHidden()
                    Text("→").foregroundStyle(.secondary)
                    DatePicker("To", selection: $m.filter.customTo).labelsHidden()
                }

                if showNetworkFilters {
                    Picker("Network", selection: $m.filter.ssid) {
                        Text("All networks").tag(String?.none)
                        ForEach(m.filterOptions.ssids, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .frame(width: 210)

                    Picker("Access point", selection: $m.filter.bssid) {
                        Text("All APs").tag(String?.none)
                        ForEach(apChoices, id: \.bssid) { ap in
                            Text("\(ap.ssid ?? "?") · \(ap.bssid)").tag(String?.some(ap.bssid))
                        }
                    }
                    .frame(width: 290)

                    Picker("Band", selection: $m.filter.band) {
                        Text("All bands").tag(String?.none)
                        ForEach(m.filterOptions.bands, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .frame(width: 160)
                }

                Spacer()

                if m.filter != DashFilter() {
                    Button("Reset") { m.filter = DashFilter() }.buttonStyle(.appSecondary(.indigo))
                }
                Button {
                    m.dataVersion += 1
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.appSecondary(.indigo))
                .help("Refresh now")
            }
            Text(rangeText).font(.caption).foregroundStyle(.secondary)
        }
        .glassCard(tint: .indigo, padding: 12)
    }

    private var apChoices: [(bssid: String, ssid: String?)] {
        guard let ssid = m.filter.ssid else { return m.filterOptions.aps }
        return m.filterOptions.aps.filter { $0.ssid == ssid }
    }

    private var rangeText: String {
        let (f, t) = m.filter.interval
        var s = m.filter.preset == .all ? "All recorded data" : "\(Fmt.dateTime.string(from: f)) → \(Fmt.dateTime.string(from: t))"
        if let ssid = m.filter.ssid { s += " · network \(ssid)" }
        if let b = m.filter.bssid { s += " · AP \(b)" }
        if let band = m.filter.band { s += " · \(band)" }
        return s
    }
}

/// Key that changes whenever a dashboard should reload.
struct ReloadKey: Hashable {
    let filter: DashFilter
    let version: Int
}
