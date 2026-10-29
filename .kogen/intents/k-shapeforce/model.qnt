module shapeforce {
  var invalid: int
  var noTool: int
  var force: bool
  action init = all { invalid' = 0, noTool' = 0, force' = false }
  action prose = all { noTool < 3, noTool' = noTool + 1, invalid' = invalid, force' = true }
  action refused = all { invalid < 3, invalid' = invalid + 1, noTool' = noTool, force' = false }
  action tool = all { invalid' = invalid, noTool' = noTool, force' = false }
  action step = any { prose, refused, tool }
  val bounded = invalid >= 0 and invalid <= 3 and noTool >= 0 and noTool <= 3
  val forcedHasCause = force implies noTool > 0
}
