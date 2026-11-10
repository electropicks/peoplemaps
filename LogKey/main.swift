import Foundation
import PeoplemapsCore

// The owner's half of sealed trip logs (Docs/REPORTS.md 4.8), run on the owner's Mac; never shipped.
//   peoplemaps-logkey keygen             makes the key, keeps the private half in the login Keychain, prints the public half
//   peoplemaps-logkey public             prints the public half (what Core/LogUpload.swift ships as `LogSeal.publicKey`)
//   peoplemaps-logkey open IN OUT NAME   decrypts a sent log; NAME is the file name it was sent under, without `.enc`
//   peoplemaps-logkey export             prints the private half, to put in a password manager. Without it sent logs can't be read.
//   peoplemaps-logkey import             reads a private half from standard input into the Keychain (a new Mac)

#if canImport(CryptoKit) && os(macOS)
let service = "peoplemaps-log-key", account = "owner"

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

@discardableResult func security(_ arguments: [String]) -> (status: Int32, out: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = arguments
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { fail("could not run /usr/bin/security") }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

func stored() -> Data? {
    let found = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    return found.status == 0 ? Data(base64Encoded: found.out) : nil
}
func store(_ key: Data) {
    if security(["add-generic-password", "-s", service, "-a", account, "-l", "PeopleMaps log key", "-w", key.base64EncodedString()]).status != 0 {
        fail("could not save the key in the Keychain")
    }
}
func privateKey() -> Data {
    guard let key = stored() else { fail("no log key in the Keychain; run keygen, or import on a new Mac") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    if stored() != nil { fail("a log key already exists; logs sealed to it would be unreadable with a new one") }
    let key = SealedBox.newKey()
    store(key.privateKey)
    print(key.publicKey.base64EncodedString())
case "public":
    guard let key = try? SealedBox.publicKey(of: privateKey()) else { fail("the stored key is damaged") }
    print(key.base64EncodedString())
case "export":
    print(privateKey().base64EncodedString())
case "import":
    if stored() != nil { fail("a log key already exists") }
    let line = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = Data(base64Encoded: line), (try? SealedBox.publicKey(of: key)) != nil else { fail("not a log key") }
    store(key)
case "open" where args.count == 4:
    guard let box = FileManager.default.contents(atPath: args[1]) else { fail("cannot read \(args[1])") }
    guard let plain = try? SealedBox.open(box, with: privateKey(), info: LogSeal.info, context: args[3]) else { fail("cannot open \(args[1]) as \(args[3])") }
    do { try plain.write(to: URL(fileURLWithPath: args[2]), options: .atomic) } catch { fail("cannot write \(args[2])") }
default:
    fail("usage: peoplemaps-logkey keygen | public | export | import | open IN OUT NAME")
}
#else
print("peoplemaps-logkey runs on macOS only.")
#endif
