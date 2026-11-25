import Foundation
import CoreWLAN
import CoreLocation

/// Reads Wi-Fi radio/link state via CoreWLAN.
enum WiFiCollector {
    static func snapshot() -> Sample {
        var s = Sample()
        guard let i = CWWiFiClient.shared().interface() else { return s }
        s.interface = i.interfaceName
        s.powerOn = i.powerOn()
        s.mac = i.hardwareAddress()
        let rssi = i.rssiValue()
        let channel = i.wlanChannel()
        s.connected = s.powerOn && rssi != 0 && channel != nil
        guard s.connected else { return s }
        s.ssid = i.ssid()
        s.bssid = i.bssid().map(NetUtil.normalizeMAC)
        s.rssi = rssi
        s.noise = i.noiseMeasurement()
        s.channel = channel?.channelNumber
        s.band = bandName(channel)
        s.width = widthName(channel)
        s.phy = phyName(i.activePHYMode())
        s.txRate = i.transmitRate()
        s.txPower = i.transmitPower()
        s.security = securityName(i.security())
        s.country = i.countryCode()
        return s
    }

    static func scan() throws -> [ScanResult] {
        guard let i = CWWiFiClient.shared().interface() else { return [] }
        let now = Date()
        let nets = try i.scanForNetworks(withName: nil, includeHidden: true)
        return nets.map { n in
            ScanResult(
                ts: now, ssid: n.ssid, bssid: n.bssid.map(NetUtil.normalizeMAC),
                rssi: n.rssiValue, noise: n.noiseMeasurement,
                channel: n.wlanChannel?.channelNumber, band: bandName(n.wlanChannel), width: widthName(n.wlanChannel),
                security: networkSecurity(n), beaconInterval: n.beaconInterval, country: n.countryCode)
        }.sorted { $0.rssi > $1.rssi }
    }

    static func bandName(_ c: CWChannel?) -> String? {
        guard let c else { return nil }
        switch c.channelBand.rawValue {
        case 1: return "2.4 GHz"
        case 2: return "5 GHz"
        case 3: return "6 GHz"
        default: return nil
        }
    }

    static func widthName(_ c: CWChannel?) -> String? {
        guard let c else { return nil }
        switch c.channelWidth.rawValue {
        case 1: return "20 MHz"
        case 2: return "40 MHz"
        case 3: return "80 MHz"
        case 4: return "160 MHz"
        case 5: return "320 MHz"
        default: return nil
        }
    }

    static func phyName(_ m: CWPHYMode) -> String? {
        switch m.rawValue {
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "802.11n (Wi-Fi 4)"
        case 5: return "802.11ac (Wi-Fi 5)"
        case 6: return "802.11ax (Wi-Fi 6/6E)"
        case 7: return "802.11be (Wi-Fi 7)"
        default: return nil
        }
    }

    private static let securityNames: [Int: String] = [
        0: "Open", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal",
        5: "Personal", 6: "Dynamic WEP", 7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise",
        9: "WPA2 Enterprise", 10: "Enterprise", 11: "WPA3 Personal", 12: "WPA3 Enterprise",
        13: "WPA2/WPA3 Personal", 14: "OWE", 15: "OWE Transition",
    ]

    static func securityName(_ s: CWSecurity) -> String { securityNames[s.rawValue] ?? "Unknown" }

    static func networkSecurity(_ n: CWNetwork) -> String {
        // Strongest first.
        for raw in [12, 11, 13, 9, 4, 10, 8, 3, 7, 2, 5, 14, 15, 6, 1, 0] {
            if let s = CWSecurity(rawValue: raw), n.supportsSecurity(s) { return securityName(s) }
        }
        return "Unknown"
    }
}

/// macOS hides SSID/BSSID unless the app has Location Services permission.
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: ((Bool) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedAlways || s.rawValue == 4 // authorizedWhenInUse
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation() // nudges the prompt on macOS
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if authorized { m.stopUpdatingLocation() }
        let a = authorized
        DispatchQueue.main.async { self.onChange?(a) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
