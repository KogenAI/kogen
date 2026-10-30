module hooks {
  var changed: bool
  var checked: bool
  var refused: bool
  var ran: bool
  action init = all { changed' = false, checked' = false, refused' = false, ran' = false }
  action shape = {
    nondet mutation = Set(false, true).oneOf()
    all { not(checked), changed' = mutation, checked' = false, refused' = false, ran' = false }
  }
  action compare = all { not(checked), changed' = changed, checked' = true, refused' = changed, ran' = false }
  action trusted = all { checked, not(refused), changed' = changed, checked' = checked, refused' = refused, ran' = true }
  action stay = all { changed' = changed, checked' = checked, refused' = refused, ran' = ran }
  action step = any { shape, compare, trusted, stay }
  val Safe = (ran implies (checked and not(changed) and not(refused))) and (refused implies not(ran))
}
