import Foundation
import OpenDirectory

enum LocalPasswordVerifier {
    static let nodeName = "/Local/Default"
    static func verify(_ password: String) throws {
        let node = try ODNode(session: ODSession.default(), name: nodeName)
        let user = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        try user.verifyPassword(password)
    }
}
