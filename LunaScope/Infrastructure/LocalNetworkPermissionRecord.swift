import Foundation
import OpenCineCore

/// 系统没有查询本地网络权限的接口。这里记下系统是否询问过，以及上次核实的结论，供权限检查页再次进入时使用。
enum LocalNetworkPermissionRecord {
    private static let key = "permissions.localNetwork.state"

    /// 从未触发过系统询问时为 nil。
    static var state: CameraNetworkPermissionState? {
        get { UserDefaults.standard.string(forKey: key).flatMap(CameraNetworkPermissionState.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: key) }
    }

    /// 即将触发系统询问时调用。已有结论时保留原结论。
    static func noteRequested() {
        if state == nil { state = .requested }
    }
}
