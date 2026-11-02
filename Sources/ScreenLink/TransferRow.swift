import Foundation

struct TransferRow: Identifiable {
    let id: UUID
    var name: String
    var status: String
    var progress: Double = 0
    var finished = false
    var file: URL?
}
