import Foundation

/// 長方形のコスト行列に対する最小コスト割り当て（ハンガリアン法、O(n³)）。
/// `cost[i][j]` が `threshold` 以上の組は割り当てない。戻り値は (行, 列) の組。
public func hungarianAssignment(_ cost: [[Double]], threshold: Double) -> [(row: Int, col: Int)] {
    let rows = cost.count
    guard rows > 0 else { return [] }
    let cols = cost[0].count
    guard cols > 0 else { return [] }
    let n = max(rows, cols)
    let big = threshold * 2 + 1
    // 正方化してパディング。閾値以上は big に丸める。
    var a = [[Double]](repeating: [Double](repeating: big, count: n + 1), count: n + 1)
    for i in 0..<rows {
        for j in 0..<cols {
            a[i + 1][j + 1] = min(cost[i][j], big)
        }
    }
    var u = [Double](repeating: 0, count: n + 1)
    var v = [Double](repeating: 0, count: n + 1)
    var p = [Int](repeating: 0, count: n + 1)
    var way = [Int](repeating: 0, count: n + 1)
    for i in 1...n {
        p[0] = i
        var j0 = 0
        var minv = [Double](repeating: .infinity, count: n + 1)
        var used = [Bool](repeating: false, count: n + 1)
        repeat {
            used[j0] = true
            let i0 = p[j0]
            var delta = Double.infinity
            var j1 = 0
            for j in 1...n where !used[j] {
                let cur = a[i0][j] - u[i0] - v[j]
                if cur < minv[j] {
                    minv[j] = cur
                    way[j] = j0
                }
                if minv[j] < delta {
                    delta = minv[j]
                    j1 = j
                }
            }
            for j in 0...n {
                if used[j] {
                    u[p[j]] += delta
                    v[j] -= delta
                } else {
                    minv[j] -= delta
                }
            }
            j0 = j1
        } while p[j0] != 0
        repeat {
            let j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        } while j0 != 0
    }
    var result: [(Int, Int)] = []
    for j in 1...n {
        let i = p[j]
        guard i >= 1, i <= rows, j <= cols else { continue }
        if cost[i - 1][j - 1] < threshold {
            result.append((i - 1, j - 1))
        }
    }
    return result.sorted { $0.0 < $1.0 }
}
