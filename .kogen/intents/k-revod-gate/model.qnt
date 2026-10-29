module revod {
  var read: bool
  var invalid: bool
  var landed: bool
  action init = all { read' = false, invalid' = false, landed' = false }
  action step = any {
    all { read' = true, invalid' = invalid, landed' = landed },
    all { invalid' = true, read' = read, landed' = landed },
    all { read, landed' = true, read' = read, invalid' = false }
  }
  val Safe = landed implies read
}
