// Kogen's managed Claude Code runtime: one pinned, tested version per Kogen release, installed
// atomically into its own version directory, never replaced in place, removed only by uninstall.
module managed_claude_runtime {
  pure val Tested = Set("2.1.300", "2.1.312")
  pure val Untested = "2.1.314"
  pure val Served = Set("2.1.300", "2.1.312", "2.1.314")

  // The version the running Kogen pins (an earlier release pinned 2.1.300).
  var pin: str
  // Complete version directories: directory version -> the version its binary reports.
  var installed: str -> str
  // An unfinished installation directory (in progress, failed or interrupted).
  var partial: bool
  // Versions used by Claude Code runs that are still active.
  var active: Set[str]
  // The version of the last Claude Code child Kogen started ("" before any).
  var ran: str
  var uninstalled: bool

  action init = all {
    pin' = "2.1.300", installed' = Map(), partial' = false, active' = Set(), ran' = "", uninstalled' = false,
  }

  // Under the install lock: leftovers of interrupted installations are removed and a fresh
  // partial directory starts.
  action startInstall = all {
    not(installed.keys().contains(pin)),
    partial' = true,
    pin' = pin, installed' = installed, active' = active, ran' = ran, uninstalled' = uninstalled,
  }

  // The download ends: only verified bytes reporting the pinned version are renamed into place;
  // any failure removes the partial directory and installs nothing.
  action finishInstall = {
    nondet served = Served.oneOf()
    nondet checksumOk = Set(true, false).oneOf()
    all {
      partial,
      partial' = false,
      installed' = if (checksumOk and served == pin) installed.put(pin, served) else installed,
      pin' = pin, active' = active, ran' = ran, uninstalled' = uninstalled,
    }
  }

  // Something outside Kogen replaces the installed binary with another version.
  action tamper = all {
    installed.keys().contains(pin),
    installed' = installed.set(pin, Untested),
    pin' = pin, partial' = partial, active' = active, ran' = ran, uninstalled' = uninstalled,
  }

  // A role starts only on the installed pinned version that reports exactly that version.
  action startRun = all {
    installed.keys().contains(pin),
    installed.get(pin) == pin,
    active' = active.union(Set(pin)), ran' = installed.get(pin),
    pin' = pin, installed' = installed, partial' = partial, uninstalled' = uninstalled,
  }

  action endRuns = all {
    active != Set(),
    active' = Set(),
    pin' = pin, installed' = installed, partial' = partial, ran' = ran, uninstalled' = uninstalled,
  }

  // A newer Kogen release pins a newer tested version; older version directories stay.
  action upgradeKogen = all {
    pin == "2.1.300",
    pin' = "2.1.312",
    installed' = installed, partial' = partial, active' = active, ran' = ran, uninstalled' = uninstalled,
  }

  action uninstall = all {
    installed' = Map(), partial' = false, uninstalled' = true,
    pin' = pin, active' = active, ran' = ran,
  }

  action stutter = all {
    pin' = pin, installed' = installed, partial' = partial, active' = active, ran' = ran, uninstalled' = uninstalled,
  }

  action step = any { startInstall, finishInstall, tamper, startRun, endRuns, upgradeKogen, uninstall, stutter }

  val NeverRunsUntested = ran == "" or Tested.contains(ran)
  val InstallsOnlyTested = installed.keys().forall(v => Tested.contains(v))
  val ActiveVersionsStayInstalled = not(uninstalled) implies active.forall(v => installed.keys().contains(v))
}
