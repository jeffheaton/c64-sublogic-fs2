// swift-tools-version: 6.0
// The Swift runtime alone, built for WebAssembly exactly as fs2.wasm is (`make web-audit`): fs2.wasm
// links the standard library statically, and the audits tell the runtime's own data (its Unicode
// character-name table holds plenty of English words) from the port's by comparing with this.
import PackageDescription

let package = Package(
    name: "WasmBaseline",
    targets: [.executableTarget(name: "WasmBaseline")]
)
