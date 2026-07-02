import Foundation
import Observation

@Observable
class MyManager: NSObject {
    var count = 0
    override init() {
        super.init()
        count = 1
    }
}
let m = MyManager()
print(m.count)
