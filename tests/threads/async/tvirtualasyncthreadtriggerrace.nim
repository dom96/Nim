discard """
output:'''
Trigger 1
Wait 2
Wait 1
Trigger 2
'''
"""

import os, asyncdispatch

type
  ThreadArg = object
    event1: VirtualAsyncEvent
    event2: VirtualAsyncEvent

when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

proc wait(event: VirtualAsyncEvent): Future[void] =
  var retFuture = newFuture[void]("AsyncEvent.wait")
  proc continuation(ev: VirtualAsyncEvent): bool {.gcsafe.} =
    if not retFuture.finished:
      retFuture.complete()
    result = true
  addEvent(event, continuation)
  return retFuture

proc asyncProcSecond(args: ThreadArg) {.async.} =
  echo("Wait 1")
  await args.event1.wait()
  echo("Trigger 2")
  args.event2.trigger()

proc asyncProcFirst(args: ThreadArg) {.async.} =
  echo("Trigger 1")
  args.event1.trigger()
  echo("Wait 2")
  await args.event2.wait()

proc threadProcSecond(args: ThreadArg) {.thread.} =
  waitFor asyncProcSecond(args)

proc threadProcFirst(args: ThreadArg) {.thread.} =
  waitFor asyncProcFirst(args)

proc main() =
  var
    args: ThreadArg
    thread1: Thread[ThreadArg]
    thread2: Thread[ThreadArg]

  args.event1 = newVirtualAsyncEvent()
  args.event2 = newVirtualAsyncEvent()
  thread1.createThread(threadProcFirst, args)
  # make sure the threads startup in order, or we will either deadlock or error.
  sleep(1000)
  thread2.createThread(threadProcSecond, args)
  joinThreads(thread1, thread2)

when isMainModule:
  main()
