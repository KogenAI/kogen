module task_completion {
  type Task = { id: int, title: str, status: str }
  pure val initial = [
    { id: 1, title: "first", status: "open" },
    { id: 2, title: "second", status: "open" },
    { id: 3, title: "third", status: "open" },
  ]
  var tasks: List[Task]
  var before: List[Task]
  var target: int
  var outcome: str

  action init = all {
    tasks' = initial,
    before' = initial,
    target' = 0,
    outcome' = "initial",
  }

  action complete = {
    nondet i = tasks.indices().oneOf()
    val task = tasks[i]
    all {
      task.status == "open",
      before' = tasks,
      target' = task.id,
      outcome' = "completed",
      tasks' = tasks.replaceAt(i, { ...task, status: "done" }),
    }
  }

  action miss = all {
    tasks.indices().forall(i => tasks[i].id != 4),
    before' = tasks,
    target' = 4,
    outcome' = "unknown",
    tasks' = tasks,
  }

  // Already-done and malformed arguments are outside the modeled contract.
  action step = any { complete, miss }

  val StableIdentitiesAndOrder = tasks.length() == initial.length() and initial.indices().forall(i =>
    tasks[i].id == initial[i].id and tasks[i].title == initial[i].title)
  val OnlySelectedTaskChanges = outcome == "completed" implies before.indices().forall(i =>
    if (before[i].id == target) before[i].status == "open" and tasks[i].status == "done"
    else tasks[i] == before[i])
  val UnknownPreservesState = outcome == "unknown" implies tasks == before
}
