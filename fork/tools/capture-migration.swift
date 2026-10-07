import Darwin
import CryptoKit
import Foundation

func code(_ value: String) -> FourCharCode { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
struct CaptureFailure: Error { let message: String }
struct SurfaceSnapshot: Codable, Equatable {
    let surfaceID: UUID
    let foregroundGroup: Int
    let tty: String
    let cwd: String
}
struct BindingEvidence: Codable {
    let surface: SurfaceSnapshot
    let binding: AgentSessionBinding?
    let observedBinding: AgentSessionBinding?
    let ownerPID: Int32?
    let ownerStartSeconds: UInt64?
    let ownerStartMicroseconds: UInt64?
    let reason: String?
}
struct Capture: Codable {
    let schema: Int
    let capturedAt: Date
    let appPath: String
    let appPID: Int32
    let appStartSeconds: UInt64
    let appStartMicroseconds: UInt64
    let surfaces: [BindingEvidence]
}

let args = CommandLine.arguments
if args.count != 4 { fputs("Usage: capture-migration PID /exact/active/Ghostty.app /new/staging-output\n", stderr); exit(2) }
let pid = Int32(args[1]) ?? 0
let appPath = URL(fileURLWithPath: args[2]).standardizedFileURL.path
let output = URL(fileURLWithPath: args[3])
let target = NSAppleEventDescriptor(processIdentifier: pid)
func verifyApp(_ expected: AgentSessionProcessIdentity? = nil) throws -> AgentSessionProcessIdentity {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
          String(cString: buffer) == appPath + "/Contents/MacOS/ghostty",
          let identity = AgentSessionResume.processIdentity(pid), expected == nil || expected == identity else {
        throw CaptureFailure(message: "Active PID/path/birth changed; capture aborted without targeting another app")
    }
    return identity
}
func specifier(want: String, form: String, selection: NSAppleEventDescriptor, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
    record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
    record.setDescriptor(selection, forKeyword: code("seld"))
    record.setDescriptor(container, forKeyword: code("from"))
    guard let result = record.coerce(toDescriptorType: code("obj ")) else { throw CaptureFailure(message: "Could not encode read-only object specifier") }
    return result
}
func get(_ object: NSAppleEventDescriptor, label: String = "all terminals") throws -> NSAppleEventDescriptor {
    _ = try verifyApp()
    let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"), targetDescriptor: target, returnID: -1, transactionID: 0)
    event.setParam(object, forKeyword: code("----"))
    // Direct PID addressing cannot launch a missing app or redirect to another bundle.
    // NeverInteract prevents a capture operation from prompting for/granting permissions.
    let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 10)
    if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
        throw CaptureFailure(message: "Read-only AppleEvent \(label) failed with status \(error.int32Value)")
    }
    guard let value = reply.paramDescriptor(forKeyword: code("----")) else { throw CaptureFailure(message: "AppleEvent returned no readable terminal data") }
    return value
}
func property(_ name: String, of object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
    try get(specifier(want: "prop", form: "prop", selection: NSAppleEventDescriptor(typeCode: code(name)), container: object), label: name)
}
func snapshot() throws -> [SurfaceSnapshot] {
    guard let all = NSAppleEventDescriptor(descriptorType: code("abso"), data: NSAppleEventDescriptor(enumCode: code("all ")).data) else {
        throw CaptureFailure(message: "Could not encode all-terminals absolute ordinal")
    }
    let terminals = try get(specifier(want: "Gtrm", form: "indx", selection: all, container: NSAppleEventDescriptor.null()))
    var result: [SurfaceSnapshot] = []
    guard terminals.numberOfItems <= 512 else { throw CaptureFailure(message: "Terminal count exceeds capture limit") }
    for index in 1...max(1, terminals.numberOfItems) where index <= terminals.numberOfItems {
        guard let terminal = terminals.atIndex(index), let idText = try property("ID  ", of: terminal).stringValue,
              let id = UUID(uuidString: idText) else { throw CaptureFailure(message: "A terminal has no valid stable UUID") }
        let group = Int(try property("Gpid", of: terminal).int32Value)
        let tty = try property("Gtty", of: terminal).stringValue ?? ""
        let cwd = try property("Gwdr", of: terminal).stringValue ?? ""
        result.append(.init(surfaceID: id, foregroundGroup: group, tty: tty, cwd: cwd))
    }
    guard Set(result.map(\.surfaceID)).count == result.count else { throw CaptureFailure(message: "Duplicate surface UUIDs; capture aborted") }
    return result.sorted { $0.surfaceID.uuidString < $1.surfaceID.uuidString }
}
do {
    let appIdentity = try verifyApp()
    let before = try snapshot()
    var evidence: [BindingEvidence] = []
    for surface in before {
        var binding: AgentSessionBinding?
        var observed: AgentSessionBinding?
        var owner: AgentSessionProcessIdentity?
        var reason: String?
        if surface.foregroundGroup <= 0 || surface.tty.isEmpty {
            reason = "No verifiable live foreground group and TTY; left unbound"
        } else {
            switch AgentSessionResume.observe(foregroundGroup: surface.foregroundGroup, tty: surface.tty, cwd: surface.cwd.isEmpty ? nil : surface.cwd) {
            case .found(let candidate, let foundPID):
                observed = candidate
                binding = candidate
                owner = AgentSessionResume.processIdentity(foundPID)
                let owners = AgentSessionResume.liveOwners(of: candidate)
                if let owners, owners.count == 1,
                   let identity = AgentSessionResume.processIdentity(foundPID), owners.first == identity {
                    owner = identity
                } else if owners == nil {
                    reason = "Global live session ownership could not be verified; exact observed binding retained with recovery paused"
                } else if let owners, owners.count > 1 {
                    reason = "Multiple globally live owners of this exact session; binding retained with recovery paused"
                } else { reason = "Live owner exited or changed during capture; binding retained with recovery paused" }
            case .absent: reason = "No live agent binding; left unbound"
            case .unavailable(let error): reason = error
            }
        }
        evidence.append(.init(surface: surface, binding: binding, observedBinding: observed, ownerPID: owner?.pid,
                              ownerStartSeconds: owner?.startSeconds, ownerStartMicroseconds: owner?.startMicroseconds,
                              reason: reason))
    }
    guard before == (try snapshot()) else { throw CaptureFailure(message: "Terminal UUID/PID/TTY/cwd changed during capture; retry immediately before quit") }
    _ = try verifyApp(appIdentity)
    let duplicateBindings = Set(Dictionary(grouping: evidence.compactMap { $0.binding?.key }, by: { $0 }).filter { $0.value.count > 1 }.keys)
    evidence = evidence.map { item in
        guard let binding = item.binding, duplicateBindings.contains(binding.key) else { return item }
        return .init(surface: item.surface, binding: item.binding, observedBinding: item.observedBinding, ownerPID: item.ownerPID, ownerStartSeconds: item.ownerStartSeconds, ownerStartMicroseconds: item.ownerStartMicroseconds,
                     reason: "Same live session appears on multiple surfaces; exact binding retained with recovery paused")
    }
    let now = Date()
    let capture = Capture(schema: 1, capturedAt: now, appPath: appPath, appPID: pid,
                          appStartSeconds: appIdentity.startSeconds, appStartMicroseconds: appIdentity.startMicroseconds,
                          surfaces: evidence)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let records = Dictionary(uniqueKeysWithValues: evidence.map { item in
        (item.surface.surfaceID, AgentSessionRecoveryRecord(binding: item.binding,
            phase: item.binding == nil || item.reason != nil ? .failed : .pending,
            reason: item.reason ?? "Verified pre-install live binding; require same restored surface UUID", updatedAt: now))
    })
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try encoder.encode(capture).write(to: output.appendingPathComponent("surface-bindings.json"), options: .atomic)
    try encoder.encode(records).write(to: output.appendingPathComponent("agent-recovery.json"), options: .atomic)
    let migration = AgentSessionRecoveryMigration(version: 1, surfaceIDs: evidence.map { $0.surface.surfaceID })
    try encoder.encode(migration).write(to: output.appendingPathComponent("agent-recovery-migration.json"), options: .atomic)
    let files = ["surface-bindings.json", "agent-recovery.json", "agent-recovery-migration.json"]
    let digests = try Dictionary(uniqueKeysWithValues: files.map { name in
        let data = try Data(contentsOf: output.appendingPathComponent(name))
        return (name, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    })
    try JSONSerialization.data(withJSONObject: ["schema": 1, "files_sha256": digests], options: [.sortedKeys])
        .write(to: output.appendingPathComponent("CAPTURE-COMPLETE"), options: .atomic)
    print("Captured \(evidence.count) exact surfaces; \(evidence.filter { $0.binding != nil }.count) known bindings (\(evidence.filter { $0.binding != nil && $0.reason != nil }.count) paused); \(evidence.filter { $0.binding == nil }.count) unbound. Staging only.")
} catch {
    fputs("Migration capture failed: \(error)\n", stderr)
    exit(1)
}
