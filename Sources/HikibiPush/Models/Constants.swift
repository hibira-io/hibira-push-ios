import Foundation

struct Constants {
    struct DispatchQueue {
        static let preIISOperationQueue = "io.hikibi.push.pre.iis.operation.queue"
        static let persistenceStorageOperationQueue = "io.hikibi.push.persistence.storage.operation.queue"
    }

    struct ReportEventType {
        static let open = "Open"
        static let delivery = "Delivery"
    }
}
