discard """
output: '''
event triggered!
'''
"""

import asyncDispatch

proc main() {.async.} =
  let ev = newVirtualAsyncEvent()
  addEvent(ev, proc(fd: AsyncFD): bool {.gcsafe.} = echo "event triggered!"; true)
  ev.trigger()

waitFor main()
drain()
