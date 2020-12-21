discard """
output: '''
hasPendingOperations: false
triggerCount: 100
'''
disabled: "windows"
"""

import asyncDispatch

var triggerCount = 0
proc main() {.async.} =
  var evs = newSeq[AsyncEvent]()

  for i in 0 ..< 100: # has to be lower than the typical physical fd limit
    var ev = newAsyncEvent()
    evs.add(ev)
    addEvent(ev, proc(fd: AsyncFD): bool {.gcsafe,closure.} = triggerCount += 1; true)

  for ev in evs:
    ev.trigger()

waitFor main()
drain()
echo "hasPendingOperations: ", hasPendingOperations()
echo "triggerCount: ", triggerCount
