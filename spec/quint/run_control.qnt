// One Build per repository, the lock of a dead Build, interruption and exit
// codes (chapters 03 and 09). Abstraction: one repository; at most one tool command
// is active at a time, and the process groups it started are counted as `groupAlive`
// (a background server outlives the command that started it). Detached processes are
// outside the contract and are not modelled. The Build's own endings are listed in
// chapter 04; here a Build ends normally with exit 0 (committed) or 1, 3, 4 (not
// committed), by a signal (130, 143, 129), or by an internal error (70).
module run_control {
  type Status = Idle | Running | Stopping | Ended
  type Lock = Free | LiveHolder | DeadHolder
  type Signal = NoSignal | SigInt | SigTerm | SigHup | InternalError

  var status: Status
  var lock: Lock
  var running: int            // Builds running in this repository
  var signal: Signal
  var active: bool            // a tool command is running now
  var groupAlive: int         // live processes in the process groups the Build's commands started
  var committed: bool
  var exitCode: int           // -1 while running
  var refusal: str

  action setAll(s, l, r, sg, ac, ga, cm, ec, rf) = all {
    status' = s, lock' = l, running' = r, signal' = sg, active' = ac, groupAlive' = ga,
    committed' = cm, exitCode' = ec, refusal' = rf,
  }

  action init = all {
    nondet l = Set(Free, DeadHolder, LiveHolder).oneOf()
    setAll(Idle, l, if (l == LiveHolder) 1 else 0, NoSignal, false, 0, false, -1, ""),
  }

  // AUT-4: `kogen intent build <slug>`.
  action start = all {
    status == Idle,
    if (lock == LiveHolder)
      setAll(Ended, lock, running, signal, false, groupAlive, committed, 3, "build_running")
    else
      // Free, or its process is no longer running: take the lock.
      setAll(Running, LiveHolder, running + 1, NoSignal, false, 0, false, -1, ""),
  }

  // LOOP-5: a tool command starts (only while running, never after a cancel request).
  action runCommand = all {
    status == Running,
    not(active),
    nondet g = 1.to(3).oneOf()
    setAll(status, lock, running, signal, true, groupAlive + g, committed, exitCode, refusal),
  }

  // The command returns; background processes it started may stay alive.
  action commandEnds = all {
    status == Running,
    active,
    nondet survivors = 0.to(groupAlive).oneOf()
    setAll(status, lock, running, signal, false, survivors, committed, exitCode, refusal),
  }

  // LOOP-5: the builder stops a background process with a later command.
  action builderKillsBackground = all {
    status == Running,
    not(active),
    groupAlive > 0,
    setAll(status, lock, running, signal, false, 0, committed, exitCode, refusal),
  }

  // CLI-7 / CLI-8: SIGINT, SIGTERM, SIGHUP, or an internal error in kogen.
  action interrupt = all {
    status == Running,
    nondet sg = Set(SigInt, SigTerm, SigHup, InternalError).oneOf()
    setAll(Stopping, lock, running, sg, active, groupAlive, committed, exitCode, refusal),
  }

  // The Build finishes by itself and cleans up: landed (0), or not committed: answer no (1),
  // environment (3) or provider (4) (chapter 04's endings, CLI-5). The exit code is decided now.
  action finish = all {
    status == Running,
    not(active),
    nondet code = Set(0, 1, 3, 4).oneOf()
    setAll(Stopping, lock, running, signal, false, groupAlive, code == 0, code, ""),
  }

  // LOOP-5 / CLI-7: every process group the Build started gets TERM, then KILL after the grace period.
  action terminate = all {
    status == Stopping,
    active or groupAlive > 0,
    setAll(status, lock, running, signal, false, 0, committed, exitCode, refusal),
  }

  // The stop completes once nothing is left: lock released. A signal stop makes no commit; an
  // internal error may end with or without the Build's commit (CLI-8).
  action stopDone = all {
    status == Stopping,
    not(active),
    groupAlive == 0,
    nondet c = Set(true, false).oneOf()
    val code = if (signal == SigInt) 130 else if (signal == SigHup) 129 else if (signal == InternalError) 70
               else if (signal == SigTerm) 143 else exitCode
    setAll(Ended, Free, running - 1, signal, false, 0,
           if (signal == NoSignal) committed else (signal == InternalError and c), code, ""),
  }

  // LOOP-10: an explicit resumed attempt acquires the same ordinary lock.
  // Checkpoint authority/candidate validation is modelled in build.qnt.
  action resume = all {
    status == Ended, lock == Free, running == 0, not(committed),
    setAll(Running, LiveHolder, 1, NoSignal, false, 0, false, -1, ""),
  }

  run explicitResumeTest = setAll(Ended, Free, 0, SigInt, false, 0, false, 130, "")
    .then(resume).expect(status == Running and lock == LiveHolder and running == 1)

  action step = any { resume, start, runCommand, commandEnds, builderKillsBackground, interrupt, finish, terminate, stopDone }

  // ---- Invariants ----
  // LOOP-5 / CLI-7: when a Build ends, normally or interrupted, no recorded process group has a live process.
  val NothingSurvivesTheBuild = status == Ended implies (groupAlive == 0 and not(active))
  // CLI-7: an interrupted Build (SIGINT, SIGTERM, SIGHUP) never commits.
  val InterruptNeverCommits =
    (status == Ended and Set(SigInt, SigTerm, SigHup).contains(signal)) implies not(committed)
  // CLI-5/7/8: exit codes follow the cause.
  val ExitCodes = status == Ended implies (
    (signal == SigInt implies exitCode == 130) and
    (signal == SigTerm implies exitCode == 143) and
    (signal == SigHup implies exitCode == 129) and
    (signal == InternalError implies exitCode == 70) and
    (signal == NoSignal implies Set(0, 1, 3, 4).contains(exitCode)))
  // AUT-4: a second Build is refused while the first runs.
  val RunningBuildRefusesSecond = (refusal == "build_running") implies (lock == LiveHolder and running == 1 and exitCode == 3)
  val Safety = NothingSurvivesTheBuild and InterruptNeverCommits and ExitCodes and RunningBuildRefusesSecond

  // ---- Tests ----
  run sigintStopsWithoutCommitTest =
    setAll(Running, LiveHolder, 1, NoSignal, true, 2, false, -1, "")
      .then(setAll(Stopping, LiveHolder, 1, SigInt, true, 2, false, -1, ""))
      .then(terminate)
      .then(stopDone)
      .expect(status == Ended and not(committed) and lock == Free and groupAlive == 0)

  run sighupExitsLikeSigtermTest =
    setAll(Stopping, LiveHolder, 1, SigHup, false, 0, false, -1, "")
      .then(stopDone)
      .expect(status == Ended and exitCode == 129 and not(committed) and lock == Free)

  run backgroundServerIsStoppedAtTheEndTest =
    setAll(Running, LiveHolder, 1, NoSignal, false, 1, false, -1, "")
      .then(finish)
      .then(terminate)
      .then(stopDone)
      .expect(status == Ended and groupAlive == 0 and exitCode >= 0)

  run liveLockRefusesSecondBuildTest =
    setAll(Idle, LiveHolder, 1, NoSignal, false, 0, false, -1, "")
      .then(start)
      .expect(running == 1 and refusal == "build_running" and exitCode == 3)

  run deadHolderIsReplacedTest =
    setAll(Idle, DeadHolder, 0, NoSignal, false, 0, false, -1, "")
      .then(start)
      .expect(status == Running and running == 1)
}
