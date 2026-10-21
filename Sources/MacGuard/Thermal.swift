import Foundation
import Darwin

struct TempSensor: Identifiable {
    let id: Int
    let name: String
    let value: Double
}

struct TempReading {
    var sensors: [TempSensor]
    var cpuAvg: Double?
    var cpuMax: Double?
}

func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "Nominal"
    case .fair: return "Fair"
    case .serious: return "Serious"
    case .critical: return "Critical"
    @unknown default: return "Unknown"
    }
}

/// SoC temperatures through the private IOHIDEventSystem API (same route macmon / Stats use on Apple Silicon).
/// All symbols are resolved at runtime with dlsym, so if Apple changes or removes them the app keeps running
/// and simply reports "n/a" (the public ProcessInfo.thermalState is always shown as a fallback).
/// Note: there is no separate "motherboard" sensor on Apple Silicon; the SoC is one package.
final class TempReader {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

    private var client: UnsafeMutableRawPointer?
    private var serviceArray: CFArray?
    private var services: [UnsafeMutableRawPointer] = []
    private var names: [String] = []
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    var available: Bool { copyEvent != nil && getFloat != nil && !services.isEmpty }

    init() { setup() }

    private func setup() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProp = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let ce = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let gf = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        else { return }

        guard let c = create(nil) else { return }
        client = c

        // AppleVendor usage page 0xff00, usage 5 = temperature sensors
        let match: CFDictionary = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(c, Unmanaged.passUnretained(match).toOpaque())

        guard let arrPtr = copyServices(c) else { return }
        let arr = Unmanaged<CFArray>.fromOpaque(arrPtr).takeRetainedValue()
        serviceArray = arr

        let productKey: CFString = "Product" as CFString
        let n = CFArrayGetCount(arr)
        for i in 0..<n {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let svc = UnsafeMutableRawPointer(mutating: raw)
            var name = "sensor \(i)"
            if let propPtr = copyProp(svc, Unmanaged.passUnretained(productKey).toOpaque()) {
                let obj = Unmanaged<AnyObject>.fromOpaque(propPtr).takeRetainedValue()
                if let s = obj as? String { name = s }
            }
            services.append(svc)
            names.append(name)
        }
        copyEvent = ce
        getFloat = gf
    }

    func read() -> TempReading? {
        guard let ce = copyEvent, let gf = getFloat, !services.isEmpty else { return nil }
        let kIOHIDEventTypeTemperature: Int64 = 15
        let field: Int32 = 15 << 16
        var sensors: [TempSensor] = []
        for (i, svc) in services.enumerated() {
            guard let ev = ce(svc, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let v = gf(ev, field)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            if v.isFinite, v > 0, v < 150 {
                sensors.append(TempSensor(id: i, name: names[i], value: v))
            }
        }
        guard !sensors.isEmpty else { return nil }
        let cpu = sensors.filter { $0.name.lowercased().contains("tdie") }.map { $0.value }
        let avg: Double? = cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count)
        return TempReading(sensors: sensors, cpuAvg: avg, cpuMax: cpu.max())
    }
}
