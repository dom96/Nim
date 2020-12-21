discard """
output: '''
event triggered!
'''
"""

import asyncDispatch

proc main() {.async.} =
  let ev = newVirtualAsyncEvent()
  addEvent(ev, proc(ev: VirtualAsyncEvent): bool {.gcsafe.} = echo "event triggered!"; true)
  ev.trigger()

waitFor main()
drain()
