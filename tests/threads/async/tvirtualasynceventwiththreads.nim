discard """
output: '''
triggerCount: 1000
'''
"""

import asyncDispatch, threadpool, os, random

var triggerCount = 0
var evs = newSeq[VirtualAsyncEvent]()

proc threadTask(ev: VirtualAsyncEvent): bool =
  sleep(rand(1000))
  ev.trigger()

var flows: seq[FlowVar[bool]]
for i in 0 ..< 1000:
  var ev = newVirtualAsyncEvent()
  evs.add ev
  addEvent(ev, proc(ev: VirtualAsyncEvent): bool {.gcsafe,closure.} = triggerCount += 1; true)
  flows.add spawn(threadTask(ev))

for f in flows:
  discard ^f
drain()
echo "triggerCount: ", triggerCount
