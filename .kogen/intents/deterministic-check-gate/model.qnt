module gate_model {
  var owner: bool
  var child: bool
  var custody: bool
  var removed: bool
  var unrelated: bool

  action init = all {
    owner' = true,
    child' = true,
    custody' = true,
    removed' = false,
    unrelated' = true,
  }

  action ownerExits = all {
    owner,
    owner' = false,
    child' = child,
    custody' = custody,
    removed' = removed,
    unrelated' = unrelated,
  }

  action stopOwned = all {
    custody,
    owner' = owner,
    child' = false,
    custody' = custody,
    removed' = removed,
    unrelated' = unrelated,
  }

  action removeWorkspace = all {
    not(child),
    owner' = owner,
    child' = child,
    custody' = false,
    removed' = true,
    unrelated' = unrelated,
  }

  action step = any { ownerExits, stopOwned, removeWorkspace }
  val SafeRemoval = removed implies not(child)
  val ScopedCleanup = unrelated and (child implies custody)
}
