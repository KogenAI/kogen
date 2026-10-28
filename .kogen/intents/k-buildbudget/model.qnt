module budget {
 var count: int
 var limit: int
 var stopped: bool
 action init = all { count' = 0, limit' = 4, stopped' = false }
 action step = any {
 all { count < limit, not(stopped), count' = count + 1, limit' = limit, stopped' = false },
 all { count == limit, count' = count, limit' = limit, stopped' = true },
 all { count' = count, limit' = limit, stopped' = stopped }
 }
 val bounded = count >= 0 and count <= limit
 val stopAtLimit = stopped implies count == limit
}
