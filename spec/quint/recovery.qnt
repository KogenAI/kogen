// Explicit preservation, correction, new approval and fresh final-tree proof.
module recovery {
  var s: { phase: str, archived: bool, candidate: int, archive: int, originalApproval: bool, freshApproval: bool, green: bool, reviewed: bool, committed: bool }
  action init = s' = {phase: "blocked", archived: false, candidate: 1, archive: 0, originalApproval: true, freshApproval: false, green: false, reviewed: false, committed: false}
  action preserve = all {s.phase == "blocked", s' = {...s, phase: "preserved", archived: true, archive: s.candidate}}
  action clean = all {s.phase == "preserved", s.archived, s.archive == s.candidate, s' = {...s, phase: "clean", candidate: 0}}
  action refuse = s' = s
  action correct = all {s.phase == "clean", s' = {...s, phase: "corrected", originalApproval: false}}
  action approve = all {s.phase == "corrected", s' = {...s, phase: "approved", freshApproval: true}}
  action build = all {s.phase == "approved", s.freshApproval, s' = {...s, phase: "building", candidate: 2}}
  action verify = all {s.phase == "building", s' = {...s, green: true}}
  action review = all {s.phase == "building", s.green, s' = {...s, reviewed: true}}
  action edit = all {s.phase == "building", s' = {...s, candidate: s.candidate + 1, green: false, reviewed: false}}
  action commit = all {s.phase == "building", s.green, s.reviewed, s.freshApproval, s' = {...s, phase: "landed", committed: true}}
  action step = any {preserve, clean, refuse, correct, approve, build, verify, review, edit, commit}
  val Preserved = Set("clean", "corrected", "approved", "building", "landed").contains(s.phase) implies (s.archived and s.archive == 1)
  val NoReapproval = Set("blocked", "preserved", "clean").contains(s.phase) implies (s.originalApproval and not(s.freshApproval) and not(s.committed))
  val SafeCommit = s.committed implies (s.freshApproval and s.green and s.reviewed and not(s.originalApproval))
  val Safety = Preserved and NoReapproval and SafeCommit

}
