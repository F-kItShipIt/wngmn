import CoreAudio
import Foundation
import WngmnAudio
import WngmnCore

/// `wngmn devices` — a read-only inventory.
///
/// Exists to answer two questions that documentation cannot. First, which bundle ID
/// actually carries Meet audio: Chrome renders it from a helper process, not from the
/// browser process, and tapping the wrong one captures nothing while still reporting
/// success. Play audio in a Meet tab and look at which entry says `output=yes`.
/// Second, whether a previous run leaked a private aggregate device.
enum Devices {
    /// `String(format:)` bridges through NSString, where `%s` expects a C string and a
    /// Swift `String` argument segfaults. Padding by hand avoids the whole class of bug.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func print(options: Options) {
        let processes = AudioCatalog.processes()
            .filter { !$0.bundleID.isEmpty }
            .sorted { $0.bundleID.lowercased() < $1.bundleID.lowercased() }

        Swift.print("AUDIO PROCESSES  (\(processes.count) with a bundle ID)")
        Swift.print("  " + pad("objID", 8) + pad("pid", 8) + pad("output", 8) + "bundle ID")
        for process in processes {
            Swift.print("  "
                + pad("\(process.objectID)", 8)
                + pad("\(process.pid)", 8)
                + pad(process.isRunningOutput ? "yes" : "no", 8)
                + process.bundleID)
        }

        let wanted = Set(options.bundleIDs.map { $0.lowercased() })
        let matched = processes.filter { wanted.contains($0.bundleID.lowercased()) }
        Swift.print("")
        if options.globalTap {
            Swift.print("TAP SCOPE: global — every process, including notification sounds.")
        } else if matched.isEmpty {
            Swift.print("TAP SCOPE: \(options.bundleIDs.joined(separator: ", "))")
            Swift.print("  none of these are currently rendering audio.")
            Swift.print("  A tap still creates successfully for apps that are not even installed,")
            Swift.print("  so this is the only place that tells you whether scoping will capture anything.")
        } else {
            Swift.print("TAP SCOPE: \(options.bundleIDs.joined(separator: ", "))")
            for process in matched {
                Swift.print("  matched \(process.bundleID) (pid \(process.pid), output=\(process.isRunningOutput ? "yes" : "no"))")
            }
        }

        let devices = AudioCatalog.devices()
        Swift.print("")
        Swift.print("DEVICES  (\(devices.count))")
        for device in devices {
            var tags: [String] = []
            if device.isDefaultOutput { tags.append("default-output") }
            if device.isDefaultInput { tags.append("default-input") }
            if device.isAggregate { tags.append("AGGREGATE") }
            if !device.isAlive { tags.append("DEAD") }
            Swift.print("  "
                + pad("\(device.objectID)", 7)
                + pad("in=\(device.inputChannels)", 6)
                + pad("out=\(device.outputChannels)", 8)
                + pad(device.name, 26)
                + device.uid
                + (tags.isEmpty ? "" : "  [\(tags.joined(separator: " "))]"))
        }

        let aggregates = devices.filter(\.isAggregate)
        Swift.print("")
        if aggregates.isEmpty {
            Swift.print("No aggregate devices. Nothing leaked from a previous run.")
        } else {
            Swift.print("\(aggregates.count) aggregate device(s) present. Any named 'wngmn' that")
            Swift.print("outlived its process is a leak from an abnormal exit; the HAL also caches")
            Swift.print("the device list for about a second, so re-run before concluding.")
        }

        let taps = AudioCatalog.liveTaps()
        Swift.print("Live taps owned by this client: \(taps.count)")

        // Last, so it is the thing left on screen: this route removes the caller from the
        // transcript with no error anywhere else to notice.
        if let headset = AudioRoute.conflict() {
            Swift.print("")
            Swift.print("ROUTE PROBLEM")
            Swift.print("  '\(headset)' is both the default output and the default input.")
            Swift.print("  A Bluetooth headset's microphone puts the link into duplex mode, and")
            Swift.print("  the tap captures nothing while it is there — the caller will be absent")
            Swift.print("  from the transcript, with no error. Use a different microphone; you")
            Swift.print("  can keep listening through the headset.")
        }
    }

}