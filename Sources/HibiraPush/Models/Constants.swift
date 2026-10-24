import Foundation

struct Constants {
    struct DispatchQueue {
        static let preIISOperationQueue = "io.hibira.push.pre.iis.operation.queue"
        static let persistenceStorageOperationQueue = "io.hibira.push.persistence.storage.operation.queue"
    }

    struct ReportEventType {
        static let open = "Open"
        static let delivery = "Delivery"
    }
}
