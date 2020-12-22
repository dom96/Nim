discard """
output: '''
triggerCount: 100
'''
"""

import asyncDispatch

var triggerCount = 0
var evs = newSeq[VirtualAsyncEvent]()

for i in 0 ..< 100:
  var ev = newVirtualAsyncEvent()
  evs.add(ev)
  addEvent(ev, proc(ev: VirtualAsyncEvent): bool {.gcsafe,closure.} = triggerCount += 1; true)

proc main() {.async.} =
  for ev in evs:
    await sleepAsync(10)
    ev.trigger()

waitFor main()
drain()
echo "triggerCount: ", triggerCount
