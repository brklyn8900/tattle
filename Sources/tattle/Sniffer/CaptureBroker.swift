import CPacketCapture
import Foundation

/// The packet-access broker (ADR-0003): a root launch daemon that opens a capture device
/// for this app and nothing else. This is what the app knows about it: where it lives,
/// and how to ask it for a descriptor. Installing and removing it is in
/// CaptureBrokerInstall.swift.
enum CaptureBroker {
    static let label = "io.github.eladefrati.tattle.capture-broker"
    static let socketPath = "/var/run/tattle-capture-broker.sock"
    static var helperPath: String { Layout.system.helperPath }
    static var plistPath: String { Layout.system.plistPath }

    enum RequestError: Error, Equatable {
        /// The broker did not accept this app: a rebuilt ad-hoc app, or someone else's.
        case refused
        case badRequest
        case openFailed(errno: Int32)
        /// The broker could not be reached.
        case transport(errno: Int32)

        var text: String {
            switch self {
            case .refused: "the packet-access broker does not recognise this build of Tattle; remove and install it again"
            case .badRequest: "the packet-access broker rejected the request"
            case .openFailed(let code): "the packet-access broker could not open a capture device: \(String(cString: strerror(code)))"
            case .transport(let code): "the packet-access broker did not answer: \(String(cString: strerror(code)))"
            }
        }
    }

    static var isReachable: Bool { FileManager.default.fileExists(atPath: socketPath) }

    // MARK: Request

    /// Asks the installed broker for a capture descriptor bound to `interface`.
    static func request(interface: String, socket: String = socketPath) throws -> Int32 {
        var status: Int32 = -1
        var code: Int32 = 0
        let fd = tattle_broker_request(socket, interface, &status, &code)
        if fd >= 0 { return fd }
        switch status {
        case 1: throw RequestError.refused
        case 2: throw RequestError.badRequest
        case 3: throw RequestError.openFailed(errno: code)
        default: throw RequestError.transport(errno: code)
        }
    }
}
