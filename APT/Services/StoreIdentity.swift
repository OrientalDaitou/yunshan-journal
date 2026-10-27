import Foundation
import SwiftData

/// “按数据库缓存”的钥匙：每个数据库（ModelContainer）一把，整个进程里不会重复。
///
/// 以前各处缓存直接拿 `ObjectIdentifier(context.container)`（容器的内存地址）当钥匙，却不持有容器。
/// 自检、离屏截图里的内存库用完就释放，下一个新建的库常常正好落在同一个地址上：缓存会把旧库的结果当成新库的交出去；
/// 修为模型更糟，交出去的模型里那个 context 属于已经销毁的数据库，一读就崩（自检偶发的 SIGTRAP，
/// 崩在 ModelContext.all ← CultivationModel.refresh ← CourierService.refreshSnapshot）。
/// 数据库的主 context（container.mainContext）并不持有它的容器，所以“模型留着 context”也留不住数据库。
///
/// 这里给每个领过钥匙的数据库编一个序号，并把容器强引用住：被引用着的容器不会释放，它的地址也就不会被别的库复用，
/// 钥匙与数据库一一对应；之前登记过的缓存（修为模型手里的 context）也一直有效。
/// 正式应用只有一个数据库，本来就开到退出；自检与离屏截图的内存库多留几个也无妨，进程结束一并释放。
/// 只有真的按库缓存的地方才领钥匙（修为模型、长期摘要、修行录摘要、记录镜像与数据戳、快照里记下的整表结果、账簿解码缓存）；
/// 保存通知里判断“是不是我那个库”用 `existingKey`，只查不领，不会因此留住别的库。
/// 加锁：RecordCollector 的镜像在后台 context 上也会用，保存通知也可能来自别的线程。
enum StoreIdentity {
    struct Key: Hashable, CustomStringConvertible {
        /// 第几个领钥匙的数据库（从 1 起）
        let serial: Int
        var description: String { "库\(serial)" }
    }

    private static let lock = NSLock()
    private static var held: [ObjectIdentifier: (container: ModelContainer, key: Key)] = [:]
    private static var issued = 0

    /// 这个数据库的钥匙：第一次问时编号并留住容器，之后一直是同一把
    static func key(for container: ModelContainer) -> Key {
        lock.lock()
        defer { lock.unlock() }
        let address = ObjectIdentifier(container)
        // 登记过的容器一直被留着，同一地址上不会是别的库；=== 只是再核对一次
        if let hit = held[address], hit.container === container { return hit.key }
        issued += 1
        let key = Key(serial: issued)
        held[address] = (container, key)
        return key
    }

    static func key(for context: ModelContext) -> Key { key(for: context.container) }

    /// 只查不领：这个数据库领过钥匙就返回那一把，没领过返回 nil（也不留住它）
    static func existingKey(for container: ModelContainer) -> Key? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = held[ObjectIdentifier(container)], hit.container === container else { return nil }
        return hit.key
    }

    /// 领过钥匙（被留住）的数据库个数（自检用）
    static var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }
}
