import Foundation

/// A line-level three-way merge (diff3), for when the same page changed on this device and on
/// the server since they last agreed (neutrino-atlas.md, Phase 1 "Conflict handling").
///
/// Lines unchanged on one side take the other side's version; identical changes on both sides
/// are taken once. A region both sides changed differently is a conflict, and the merge fails:
/// the caller then keeps both versions rather than writing conflict markers into the page.
public enum ThreeWayMerge {
    /// The merged text, or nil if both sides changed the same lines differently.
    public static func merge(base: String, local: String, remote: String) -> String? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        let b = lines(base), l = lines(local), r = lines(remote)
        guard let merged = merge(base: b, local: l, remote: r) else { return nil }
        return merged.joined()
    }

    /// Splits text into lines that keep their line endings, so joining them gives the text back.
    static func lines(_ text: String) -> [String] {
        SourcePreprocessor.splitLines(text).map { $0.content + $0.ending }
    }

    static func merge(base: [String], local: [String], remote: [String]) -> [String]? {
        // For each base line, its matching line in local and in remote, if any.
        let toLocal = matches(base, local)
        let toRemote = matches(base, remote)

        var out: [String] = []
        var bi = 0, li = 0, ri = 0
        while bi <= base.count {
            // The next base line kept by both sides is a stable anchor.
            var anchor = bi
            while anchor < base.count, !(toLocal[anchor] != nil && toRemote[anchor] != nil) { anchor += 1 }
            let lEnd = anchor < base.count ? toLocal[anchor]! : local.count
            let rEnd = anchor < base.count ? toRemote[anchor]! : remote.count
            guard lEnd >= li, rEnd >= ri else { return nil }

            let baseChunk = Array(base[bi..<anchor])
            let localChunk = Array(local[li..<lEnd])
            let remoteChunk = Array(remote[ri..<rEnd])
            if localChunk == baseChunk { out += remoteChunk }
            else if remoteChunk == baseChunk { out += localChunk }
            else if localChunk == remoteChunk { out += localChunk }
            else { return nil }

            guard anchor < base.count else { break }
            out.append(base[anchor])
            bi = anchor + 1
            li = lEnd + 1
            ri = rEnd + 1
        }
        return out
    }

    /// For each element of `a`, the index of the element of `b` it is matched with in a longest
    /// common subsequence, or nil. Myers' O(ND) diff, so typical edits to long pages stay cheap.
    static func matches(_ a: [String], _ b: [String]) -> [Int?] {
        let n = a.count, m = b.count
        var result = [Int?](repeating: nil, count: n)
        // Trim a common prefix and suffix first: most edits touch a small middle.
        var start = 0
        while start < n, start < m, a[start] == b[start] { result[start] = start; start += 1 }
        var endA = n, endB = m
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1; result[endA] = endB }
        let a2 = Array(a[start..<endA]), b2 = Array(b[start..<endB])
        for (i, j) in myers(a2, b2) { result[start + i] = start + j }
        return result
    }

    /// Matched index pairs of a shortest edit script between `a` and `b` (Myers 1986).
    private static func myers(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        let max = n + m
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        var found = false
        for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max]) { x = v[k + 1 + max] } else { x = v[k - 1 + max] + 1 }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[k + max] = x
                if x >= n && y >= m { found = true; break }
            }
            if found { break }
        }
        // Walk the trace back to recover the diagonal moves (the matches).
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max])) ? k + 1 : k - 1
            let prevX = v[prevK + max]
            let prevY = prevX - prevK
            while x > prevX, y > prevY { x -= 1; y -= 1; pairs.append((x, y)) }
            if d > 0 { x = prevX; y = prevY }
        }
        return pairs.reversed()
    }
}
