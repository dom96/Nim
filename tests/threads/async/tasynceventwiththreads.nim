discard """
output: '''
triggerCount: 1000
'''
"""

import asyncDispatch, threadpool, os, random

var triggerCount = 0
var evs = newSeq[AsyncEvent]()

proc threadTask(ev: AsyncEvent): bool =
  sleep(rand(1000))
  ev.trigger()

var flows: seq[FlowVar[bool]]
for i in 0 ..< 1000:
  var ev = newAsyncEvent()
  evs.add ev
  addEvent(ev, proc(fd: AsyncFD): bool {.gcsafe,closure.} = triggerCount += 1; true)
  flows.add spawn(threadTask(ev))

for f in flows:
  discard ^f
drain()
echo "triggerCount: ", triggerCount
