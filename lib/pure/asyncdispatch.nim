#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements asynchronous IO. This includes a dispatcher,
## a ``Future`` type implementation, and an ``async`` macro which allows
## asynchronous code to be written in a synchronous style with the ``await``
## keyword.
##
## The dispatcher acts as a kind of event loop. You must call ``poll`` on it
## (or a function which does so for you such as ``waitFor`` or ``runForever``)
## in order to poll for any outstanding events. The underlying implementation
## is based on epoll on Linux, IO Completion Ports on Windows and select on
## other operating systems.
##
## The ``poll`` function will not, on its own, return any events. Instead
## an appropriate ``Future`` object will be completed. A ``Future`` is a
## type which holds a value which is not yet available, but which *may* be
## available in the future. You can check whether a future is finished
## by using the ``finished`` function. When a future is finished it means that
## either the value that it holds is now available or it holds an error instead.
## The latter situation occurs when the operation to complete a future fails
## with an exception. You can distinguish between the two situations with the
## ``failed`` function.
##
## Future objects can also store a callback procedure which will be called
## automatically once the future completes.
##
## Futures therefore can be thought of as an implementation of the proactor
## pattern. In this
## pattern you make a request for an action, and once that action is fulfilled
## a future is completed with the result of that action. Requests can be
## made by calling the appropriate functions. For example: calling the ``recv``
## function will create a request for some data to be read from a socket. The
## future which the ``recv`` function returns will then complete once the
## requested amount of data is read **or** an exception occurs.
##
## Code to read some data from a socket may look something like this:
##
##   .. code-block::nim
##      var future = socket.recv(100)
##      future.addCallback(
##        proc () =
##          echo(future.read)
##      )
##
## All asynchronous functions returning a ``Future`` will not block. They
## will not however return immediately. An asynchronous function will have
## code which will be executed before an asynchronous request is made, in most
## cases this code sets up the request.
##
## In the above example, the ``recv`` function will return a brand new
## ``Future`` instance once the request for data to be read from the socket
## is made. This ``Future`` instance will complete once the requested amount
## of data is read, in this case it is 100 bytes. The second line sets a
## callback on this future which will be called once the future completes.
## All the callback does is write the data stored in the future to ``stdout``.
## The ``read`` function is used for this and it checks whether the future
## completes with an error for you (if it did it will simply raise the
## error), if there is no error however it returns the value of the future.
##
## Asynchronous procedures
## =======================
##
## Asynchronous procedures remove the pain of working with callbacks. They do
## this by allowing you to write asynchronous code the same way as you would
## write synchronous code.
##
## An asynchronous procedure is marked using the ``{.async.}`` pragma.
## When marking a procedure with the ``{.async.}`` pragma it must have a
## ``Future[T]`` return type or no return type at all. If you do not specify
## a return type then ``Future[void]`` is assumed.
##
## Inside asynchronous procedures ``await`` can be used to call any
## procedures which return a
## ``Future``; this includes asynchronous procedures. When a procedure is
## "awaited", the asynchronous procedure it is awaited in will
## suspend its execution
## until the awaited procedure's Future completes. At which point the
## asynchronous procedure will resume its execution. During the period
## when an asynchronous procedure is suspended other asynchronous procedures
## will be run by the dispatcher.
##
## The ``await`` call may be used in many contexts. It can be used on the right
## hand side of a variable declaration: ``var data = await socket.recv(100)``,
## in which case the variable will be set to the value of the future
## automatically. It can be used to await a ``Future`` object, and it can
## be used to await a procedure returning a ``Future[void]``:
## ``await socket.send("foobar")``.
##
## If an awaited future completes with an error, then ``await`` will re-raise
## this error. To avoid this, you can use the ``yield`` keyword instead of
## ``await``. The following section shows different ways that you can handle
## exceptions in async procs.
##
## Handling Exceptions
## -------------------
##
## The most reliable way to handle exceptions is to use ``yield`` on a future
## then check the future's ``failed`` property. For example:
##
##   .. code-block:: Nim
##     var future = sock.recv(100)
##     yield future
##     if future.failed:
##       # Handle exception
##
## The ``async`` procedures also offer limited support for the try statement.
##
##    .. code-block:: Nim
##      try:
##        let data = await sock.recv(100)
##        echo("Received ", data)
##      except:
##        # Handle exception
##
## Unfortunately the semantics of the try statement may not always be correct,
## and occasionally the compilation may fail altogether.
## As such it is better to use the former style when possible.
##
##
## Discarding futures
## ==================
##
## Futures should **never** be discarded. This is because they may contain
## errors. If you do not care for the result of a Future then you should
## use the ``asyncCheck`` procedure instead of the ``discard`` keyword. Note
## however that this does not wait for completion, and you should use
## ``waitFor`` for that purpose.
##
## Examples
## ========
##
## For examples take a look at the documentation for the modules implementing
## asynchronous IO. A good place to start is the
## `asyncnet module <asyncnet.html>`_.
##
## Investigating pending futures
## =============================
##
## It's possible to get into a situation where an async proc, or more accurately
## a ``Future[T]`` gets stuck and
## never completes. This can happen for various reasons and can cause serious
## memory leaks. When this occurs it's hard to identify the procedure that is
## stuck.
##
## Thankfully there is a mechanism which tracks the count of each pending future.
## All you need to do to enable it is compile with ``-d:futureLogging`` and
## use the ``getFuturesInProgress`` procedure to get the list of pending futures
## together with the stack traces to the moment of their creation.
##
## You may also find it useful to use this
## `prometheus package <https://github.com/dom96/prometheus>`_ which will log
## the pending futures into prometheus, allowing you to analyse them via a nice
## graph.
##
##
##
## Limitations/Bugs
## ================
##
## * The effect system (``raises: []``) does not work with async procedures.

include "system/inclrtl"

import os, tables, strutils, times, heapqueue, lists, options, asyncstreams
import options, math, std/monotimes, hashes
import asyncfutures except callSoon

import nativesockets, net, deques

when compileOption("threads"):
  import rlocks

export Port, SocketFlag
export asyncfutures except callSoon
export asyncstreams

#{.injectStmt: newGcInvariant().}

template withLockIfThreads(lock, code: untyped) =
  when compileOption("threads"):
    withRLock lock:
      code
  else:
    code

# TODO: Check if yielded future is nil and throw a more meaningful exception

type
  PDispatcherBase = ref object of RootRef
    timers*: HeapQueue[tuple[finishAt: MonoTime, fut: Future[void]]]
    callbacks*: Deque[proc () {.gcsafe.}]

proc processTimers(
  p: PDispatcherBase, didSomeWork: var bool
): Option[int] {.inline.} =
  # Pop the timers in the order in which they will expire (smaller `finishAt`).
  var count = p.timers.len
  let t = getMonoTime()
  while count > 0 and t >= p.timers[0].finishAt:
    p.timers.pop().fut.complete()
    dec count
    didSomeWork = true

  # Return the number of milliseconds in which the next timer will expire.
  if p.timers.len == 0: return

  let millisecs = (p.timers[0].finishAt - getMonoTime()).inMilliseconds
  return some(millisecs.int + 1)

proc processPendingCallbacks(p: PDispatcherBase; didSomeWork: var bool) =
  while p.callbacks.len > 0:
    var cb = p.callbacks.popFirst()
    cb()
    didSomeWork = true

proc adjustTimeout(
  p: PDispatcherBase, pollTimeout: int, nextTimer: Option[int]
): int {.inline.} =
  if p.callbacks.len != 0:
    return 0

  if nextTimer.isNone() or pollTimeout == -1:
    return pollTimeout

  result = max(nextTimer.get(), 0)
  result = min(pollTimeout, result)

proc callSoon*(cbproc: proc () {.gcsafe.}) {.gcsafe.}
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event loop.

proc initCallSoonProc =
  if asyncfutures.getCallSoonProc().isNil:
    asyncfutures.setCallSoonProc(callSoon)

when defined(windows) or defined(nimdoc):
  import winlean, sets, hashes
  type
    CompletionKey = ULONG_PTR

    CompletionData* = object
      fd*: AsyncFD       # TODO: Rename this.
      cb*: owned(proc (fd: AsyncFD, bytesTransferred: DWORD,
                errcode: OSErrorCode) {.closure, gcsafe.})
      cell*: ForeignCell # we need this `cell` to protect our `cb` environment,
                         # when using RegisterWaitForSingleObject, because
                         # waiting is done in different thread.

    PDispatcher* = ref object of PDispatcherBase
      ioPort: Handle
      handles: HashSet[AsyncFD]
      vd: VirtualEventDispatcher

    VirtualEventDispatcher = object
      virtualHandles: Table[VirtualFD, VirtualAsyncEvent] # pseudo handles for custom AsyncEvents.
      nextVirtualHandle: VirtualFD
      virtualMuxHandle: AsyncEvent # all the virtual handles get multiplexed through a single real handle.

    CustomOverlapped = object of OVERLAPPED
      data*: CompletionData

    PCustomOverlapped* = ref CustomOverlapped

    AsyncFD* = distinct int

    PostCallbackData = object
      ioPort: Handle
      handleFd: AsyncFD
      waitFd: Handle
      ovl: owned PCustomOverlapped
    PostCallbackDataPtr = ptr PostCallbackData

    AsyncEventImpl = object
      hEvent: Handle
      hWaiter: Handle
      pcd: PostCallbackDataPtr
    AsyncEvent* = ptr AsyncEventImpl

    VirtualFD* = distinct int

    VirtualAsyncEventImpl = object
      triggered: bool
      when compileOption("threads"):
        eventLock: RLock
      p: PDispatcher
      vFD: VirtualFD
      cb: Callback
    VirtualAsyncEvent* = ptr VirtualAsyncEventImpl

    Callback = proc (fd: AsyncFD): bool {.closure, gcsafe.}
    NativeCallback = proc(fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) {.closure,gcsafe.}

  proc hash(x: AsyncFD): Hash {.borrow.}
  proc `==`*(x: AsyncFD, y: AsyncFD): bool {.borrow.}
  proc hash(x: VirtualFD): Hash {.borrow.}
  proc `==`*(x: VirtualFD, y: VirtualFD): bool {.borrow.}

  const InvalidVirtualFD = VirtualFD(-1)

  proc newDispatcher*(): owned PDispatcher =
    ## Creates a new Dispatcher instance.
    new result
    result.ioPort = createIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 1)
    result.handles = initSet[AsyncFD]()
    result.timers.newHeapQueue()
    result.callbacks = initDeque[proc ()](64)
    result.vd.virtualHandles = initTable[VirtualFD, VirtualAsyncEvent]()

  var gDisp{.threadvar.}: owned PDispatcher ## Global dispatcher

  proc setGlobalDispatcher*(disp: owned PDispatcher) =
    if not gDisp.isNil:
      assert gDisp.callbacks.len == 0
    gDisp = disp
    initCallSoonProc()

  proc getGlobalDispatcher*(): PDispatcher =
    if gDisp.isNil:
      setGlobalDispatcher(newDispatcher())
    result = gDisp

  proc getIoHandler*(disp: PDispatcher): Handle =
    ## Returns the underlying IO Completion Port handle (Windows) or selector
    ## (Unix) for the specified dispatcher.
    return disp.ioPort

  proc register*(fd: AsyncFD) =
    ## Registers ``fd`` with the dispatcher.
    let p = getGlobalDispatcher()

    if createIoCompletionPort(fd.Handle, p.ioPort,
                              cast[CompletionKey](fd), 1) == 0:
      raiseOSError(osLastError())
    p.handles.incl(fd)

  proc verifyPresence(fd: AsyncFD) =
    ## Ensures that file descriptor has been registered with the dispatcher.
    ## Raises ValueError if `fd` has not been registered.
    let p = getGlobalDispatcher()
    if fd notin p.handles:
      raise newException(ValueError,
        "Operation performed on a socket which has not been registered with" &
        " the dispatcher yet.")

  proc hasPendingOperations*(): bool =
    ## Returns `true` if the global dispatcher has pending operations.
    let p = getGlobalDispatcher()
    p.handles.len != 0 or p.timers.len != 0 or p.callbacks.len != 0

  proc runOnce(timeout = 500): bool =
    let p = getGlobalDispatcher()
    if p.handles.len == 0 and p.timers.len == 0 and p.callbacks.len == 0:
      raise newException(ValueError,
        "No handles or timers registered in dispatcher.")

    result = false
    let nextTimer = processTimers(p, result)
    let at = adjustTimeout(p, timeout, nextTimer)
    var llTimeout =
      if at == -1: winlean.INFINITE
      else: at.int32

    var lpNumberOfBytesTransferred: DWORD
    var lpCompletionKey: ULONG_PTR
    var customOverlapped: PCustomOverlapped
    let res = getQueuedCompletionStatus(p.ioPort,
        addr lpNumberOfBytesTransferred, addr lpCompletionKey,
        cast[ptr POVERLAPPED](addr customOverlapped), llTimeout).bool
    result = true

    # http://stackoverflow.com/a/12277264/492186
    # TODO: http://www.serverframework.com/handling-multiple-pending-socket-read-and-write-operations.html
    if res:
      # This is useful for ensuring the reliability of the overlapped struct.
      assert customOverlapped.data.fd == lpCompletionKey.AsyncFD

      customOverlapped.data.cb(customOverlapped.data.fd,
          lpNumberOfBytesTransferred, OSErrorCode(-1))

      # If cell.data != nil, then system.protect(rawEnv(cb)) was called,
      # so we need to dispose our `cb` environment, because it is not needed
      # anymore.
      if customOverlapped.data.cell.data != nil:
        system.dispose(customOverlapped.data.cell)

      GC_unref(customOverlapped)
    else:
      let errCode = osLastError()
      if customOverlapped != nil:
        assert customOverlapped.data.fd == lpCompletionKey.AsyncFD
        customOverlapped.data.cb(customOverlapped.data.fd,
            lpNumberOfBytesTransferred, errCode)
        if customOverlapped.data.cell.data != nil:
          system.dispose(customOverlapped.data.cell)
        GC_unref(customOverlapped)
      else:
        if errCode.int32 == WAIT_TIMEOUT:
          # Timed out
          result = false
        else: raiseOSError(errCode)

    # Timer processing.
    discard processTimers(p, result)
    # Callback queue processing
    processPendingCallbacks(p, result)


  var acceptEx: WSAPROC_ACCEPTEX
  var connectEx: WSAPROC_CONNECTEX
  var getAcceptExSockAddrs: WSAPROC_GETACCEPTEXSOCKADDRS

  proc initPointer(s: SocketHandle, fun: var pointer, guid: var GUID): bool =
    # Ref: https://github.com/powdahound/twisted/blob/master/twisted/internet/iocpreactor/iocpsupport/winsock_pointers.c
    var bytesRet: DWORD
    fun = nil
    result = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, addr guid,
                      sizeof(GUID).DWORD, addr fun, sizeof(pointer).DWORD,
                      addr bytesRet, nil, nil) == 0

  proc initAll() =
    let dummySock = newNativeSocket()
    if dummySock == INVALID_SOCKET:
      raiseOSError(osLastError())
    var fun: pointer = nil
    if not initPointer(dummySock, fun, WSAID_CONNECTEX):
      raiseOSError(osLastError())
    connectEx = cast[WSAPROC_CONNECTEX](fun)
    if not initPointer(dummySock, fun, WSAID_ACCEPTEX):
      raiseOSError(osLastError())
    acceptEx = cast[WSAPROC_ACCEPTEX](fun)
    if not initPointer(dummySock, fun, WSAID_GETACCEPTEXSOCKADDRS):
      raiseOSError(osLastError())
    getAcceptExSockAddrs = cast[WSAPROC_GETACCEPTEXSOCKADDRS](fun)
    close(dummySock)

  proc recv*(socket: AsyncFD, size: int,
             flags = {SocketFlag.SafeDisconn}): owned(Future[string]) =
    ## Reads **up to** ``size`` bytes from ``socket``. Returned future will
    ## complete once all the data requested is read, a part of the data has been
    ## read, or the socket has disconnected in which case the future will
    ## complete with a value of ``""``.
    ##
    ## **Warning**: The ``Peek`` socket flag is not supported on Windows.


    # Things to note:
    #   * When WSARecv completes immediately then ``bytesReceived`` is very
    #     unreliable.
    #   * Still need to implement message-oriented socket disconnection,
    #     '\0' in the message currently signifies a socket disconnect. Who
    #     knows what will happen when someone sends that to our socket.
    verifyPresence(socket)
    assert SocketFlag.Peek notin flags, "Peek not supported on Windows."

    var retFuture = newFuture[string]("recv")
    var dataBuf: TWSABuf
    dataBuf.buf = cast[cstring](alloc0(size))
    dataBuf.len = size.ULONG

    var bytesReceived: DWORD
    var flagsio = flags.toOSFlags().DWORD
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            if bytesCount == 0 and dataBuf.buf[0] == '\0':
              retFuture.complete("")
            else:
              var data = newString(bytesCount)
              assert bytesCount <= size
              copyMem(addr data[0], addr dataBuf.buf[0], bytesCount)
              retFuture.complete($data)
          else:
            if flags.isDisconnectionError(errcode):
              retFuture.complete("")
            else:
              retFuture.fail(newException(OSError, osErrorMsg(errcode)))
        if dataBuf.buf != nil:
          dealloc dataBuf.buf
          dataBuf.buf = nil
    )

    let ret = WSARecv(socket.SocketHandle, addr dataBuf, 1, addr bytesReceived,
                      addr flagsio, cast[POVERLAPPED](ol), nil)
    if ret == -1:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        if dataBuf.buf != nil:
          dealloc dataBuf.buf
          dataBuf.buf = nil
        GC_unref(ol)
        if flags.isDisconnectionError(err):
          retFuture.complete("")
        else:
          retFuture.fail(newException(OSError, osErrorMsg(err)))
    elif ret == 0:
      # Request completed immediately.
      if bytesReceived != 0:
        var data = newString(bytesReceived)
        assert bytesReceived <= size
        copyMem(addr data[0], addr dataBuf.buf[0], bytesReceived)
        retFuture.complete($data)
      else:
        if hasOverlappedIoCompleted(cast[POVERLAPPED](ol)):
          retFuture.complete("")
    return retFuture

  proc recvInto*(socket: AsyncFD, buf: pointer, size: int,
                 flags = {SocketFlag.SafeDisconn}): owned(Future[int]) =
    ## Reads **up to** ``size`` bytes from ``socket`` into ``buf``, which must
    ## at least be of that size. Returned future will complete once all the
    ## data requested is read, a part of the data has been read, or the socket
    ## has disconnected in which case the future will complete with a value of
    ## ``0``.
    ##
    ## **Warning**: The ``Peek`` socket flag is not supported on Windows.


    # Things to note:
    #   * When WSARecv completes immediately then ``bytesReceived`` is very
    #     unreliable.
    #   * Still need to implement message-oriented socket disconnection,
    #     '\0' in the message currently signifies a socket disconnect. Who
    #     knows what will happen when someone sends that to our socket.
    verifyPresence(socket)
    assert SocketFlag.Peek notin flags, "Peek not supported on Windows."

    var retFuture = newFuture[int]("recvInto")

    #buf[] = '\0'
    var dataBuf: TWSABuf
    dataBuf.buf = cast[cstring](buf)
    dataBuf.len = size.ULONG

    var bytesReceived: DWORD
    var flagsio = flags.toOSFlags().DWORD
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            retFuture.complete(bytesCount)
          else:
            if flags.isDisconnectionError(errcode):
              retFuture.complete(0)
            else:
              retFuture.fail(newException(OSError, osErrorMsg(errcode)))
        if dataBuf.buf != nil:
          dataBuf.buf = nil
    )

    let ret = WSARecv(socket.SocketHandle, addr dataBuf, 1, addr bytesReceived,
                      addr flagsio, cast[POVERLAPPED](ol), nil)
    if ret == -1:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        if dataBuf.buf != nil:
          dataBuf.buf = nil
        GC_unref(ol)
        if flags.isDisconnectionError(err):
          retFuture.complete(0)
        else:
          retFuture.fail(newException(OSError, osErrorMsg(err)))
    elif ret == 0:
      # Request completed immediately.
      if bytesReceived != 0:
        assert bytesReceived <= size
        retFuture.complete(bytesReceived)
      else:
        if hasOverlappedIoCompleted(cast[POVERLAPPED](ol)):
          retFuture.complete(bytesReceived)
    return retFuture

  proc send*(socket: AsyncFD, buf: pointer, size: int,
             flags = {SocketFlag.SafeDisconn}): owned(Future[void]) =
    ## Sends ``size`` bytes from ``buf`` to ``socket``. The returned future
    ## will complete once all data has been sent.
    ##
    ## **WARNING**: Use it with caution. If ``buf`` refers to GC'ed object,
    ## you must use GC_ref/GC_unref calls to avoid early freeing of the buffer.
    verifyPresence(socket)
    var retFuture = newFuture[void]("send")

    var dataBuf: TWSABuf
    dataBuf.buf = cast[cstring](buf)
    dataBuf.len = size.ULONG

    var bytesReceived, lowFlags: DWORD
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            retFuture.complete()
          else:
            if flags.isDisconnectionError(errcode):
              retFuture.complete()
            else:
              retFuture.fail(newOSError(errcode))
    )

    let ret = WSASend(socket.SocketHandle, addr dataBuf, 1, addr bytesReceived,
                      lowFlags, cast[POVERLAPPED](ol), nil)
    if ret == -1:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        if flags.isDisconnectionError(err):
          retFuture.complete()
        else:
          retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      retFuture.complete()
      # We don't deallocate ``ol`` here because even though this completed
      # immediately poll will still be notified about its completion and it will
      # free ``ol``.
    return retFuture

  proc sendTo*(socket: AsyncFD, data: pointer, size: int, saddr: ptr SockAddr,
               saddrLen: SockLen,
               flags = {SocketFlag.SafeDisconn}): owned(Future[void]) =
    ## Sends ``data`` to specified destination ``saddr``, using
    ## socket ``socket``. The returned future will complete once all data
    ## has been sent.
    verifyPresence(socket)
    var retFuture = newFuture[void]("sendTo")
    var dataBuf: TWSABuf
    dataBuf.buf = cast[cstring](data)
    dataBuf.len = size.ULONG
    var bytesSent = 0.DWORD
    var lowFlags = 0.DWORD

    # we will preserve address in our stack
    var staddr: array[128, char] # SOCKADDR_STORAGE size is 128 bytes
    var stalen: cint = cint(saddrLen)
    zeroMem(addr(staddr[0]), 128)
    copyMem(addr(staddr[0]), saddr, saddrLen)

    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )

    let ret = WSASendTo(socket.SocketHandle, addr dataBuf, 1, addr bytesSent,
                        lowFlags, cast[ptr SockAddr](addr(staddr[0])),
                        stalen, cast[POVERLAPPED](ol), nil)
    if ret == -1:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      retFuture.complete()
      # We don't deallocate ``ol`` here because even though this completed
      # immediately poll will still be notified about its completion and it will
      # free ``ol``.
    return retFuture

  proc recvFromInto*(socket: AsyncFD, data: pointer, size: int,
                     saddr: ptr SockAddr, saddrLen: ptr SockLen,
                     flags = {SocketFlag.SafeDisconn}): owned(Future[int]) =
    ## Receives a datagram data from ``socket`` into ``buf``, which must
    ## be at least of size ``size``, address of datagram's sender will be
    ## stored into ``saddr`` and ``saddrLen``. Returned future will complete
    ## once one datagram has been received, and will return size of packet
    ## received.
    verifyPresence(socket)
    var retFuture = newFuture[int]("recvFromInto")

    var dataBuf = TWSABuf(buf: cast[cstring](data), len: size.ULONG)

    var bytesReceived = 0.DWORD
    var lowFlags = 0.DWORD

    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert bytesCount <= size
            retFuture.complete(bytesCount)
          else:
            # datagram sockets don't have disconnection,
            # so we can just raise an exception
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )

    let res = WSARecvFrom(socket.SocketHandle, addr dataBuf, 1,
                          addr bytesReceived, addr lowFlags,
                          saddr, cast[ptr cint](saddrLen),
                          cast[POVERLAPPED](ol), nil)
    if res == -1:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      # Request completed immediately.
      if bytesReceived != 0:
        assert bytesReceived <= size
        retFuture.complete(bytesReceived)
      else:
        if hasOverlappedIoCompleted(cast[POVERLAPPED](ol)):
          retFuture.complete(bytesReceived)
    return retFuture

  proc acceptAddr*(socket: AsyncFD, flags = {SocketFlag.SafeDisconn}):
      owned(Future[tuple[address: string, client: AsyncFD]]) =
    ## Accepts a new connection. Returns a future containing the client socket
    ## corresponding to that connection and the remote address of the client.
    ## The future will complete when the connection is successfully accepted.
    ##
    ## The resulting client socket is automatically registered to the
    ## dispatcher.
    ##
    ## The ``accept`` call may result in an error if the connecting socket
    ## disconnects during the duration of the ``accept``. If the ``SafeDisconn``
    ## flag is specified then this error will not be raised and instead
    ## accept will be called again.
    verifyPresence(socket)
    var retFuture = newFuture[tuple[address: string, client: AsyncFD]]("acceptAddr")

    var clientSock = newNativeSocket()
    if clientSock == osInvalidSocket: raiseOSError(osLastError())

    const lpOutputLen = 1024
    var lpOutputBuf = newString(lpOutputLen)
    var dwBytesReceived: DWORD
    let dwReceiveDataLength = 0.DWORD # We don't want any data to be read.
    let dwLocalAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)
    let dwRemoteAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)

    template failAccept(errcode) =
      if flags.isDisconnectionError(errcode):
        var newAcceptFut = acceptAddr(socket, flags)
        newAcceptFut.callback =
          proc () =
            if newAcceptFut.failed:
              retFuture.fail(newAcceptFut.readError)
            else:
              retFuture.complete(newAcceptFut.read)
      else:
        retFuture.fail(newException(OSError, osErrorMsg(errcode)))

    template completeAccept() {.dirty.} =
      var listenSock = socket
      let setoptRet = setsockopt(clientSock, SOL_SOCKET,
          SO_UPDATE_ACCEPT_CONTEXT, addr listenSock,
          sizeof(listenSock).SockLen)
      if setoptRet != 0:
        let errcode = osLastError()
        discard clientSock.closesocket()
        failAccept(errcode)
      else:
        var localSockaddr, remoteSockaddr: ptr SockAddr
        var localLen, remoteLen: int32
        getAcceptExSockAddrs(addr lpOutputBuf[0], dwReceiveDataLength,
                             dwLocalAddressLength, dwRemoteAddressLength,
                             addr localSockaddr, addr localLen,
                             addr remoteSockaddr, addr remoteLen)
        try:
          let address = getAddrString(remoteSockaddr)
          register(clientSock.AsyncFD)
          retFuture.complete((address: address, client: clientSock.AsyncFD))
        except:
          # getAddrString may raise
          clientSock.close()
          retFuture.fail(getCurrentException())

    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            completeAccept()
          else:
            failAccept(errcode)
    )

    # http://msdn.microsoft.com/en-us/library/windows/desktop/ms737524%28v=vs.85%29.aspx
    let ret = acceptEx(socket.SocketHandle, clientSock, addr lpOutputBuf[0],
                       dwReceiveDataLength,
                       dwLocalAddressLength,
                       dwRemoteAddressLength,
                       addr dwBytesReceived, cast[POVERLAPPED](ol))

    if not ret:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        failAccept(err)
        GC_unref(ol)
    else:
      completeAccept()
      # We don't deallocate ``ol`` here because even though this completed
      # immediately poll will still be notified about its completion and it will
      # free ``ol``.

    return retFuture

  proc closeSocket*(socket: AsyncFD) =
    ## Closes a socket and ensures that it is unregistered.
    socket.SocketHandle.close()
    getGlobalDispatcher().handles.excl(socket)

  proc unregister*(fd: AsyncFD) =
    ## Unregisters ``fd``.
    getGlobalDispatcher().handles.excl(fd)

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool =
    return fd in disp.handles

  {.push stackTrace: off.}
  proc waitableCallback(param: pointer,
                        timerOrWaitFired: WINBOOL): void {.stdcall.} =
    var p = cast[PostCallbackDataPtr](param)
    discard postQueuedCompletionStatus(p.ioPort, timerOrWaitFired.DWORD,
                                       ULONG_PTR(p.handleFd),
                                       cast[pointer](p.ovl))
  {.pop.}

  proc registerWaitableEvent(fd: AsyncFD, cb: Callback; mask: DWORD) =
    let p = getGlobalDispatcher()
    var flags = (WT_EXECUTEINWAITTHREAD or WT_EXECUTEONLYONCE).DWORD
    var hEvent = wsaCreateEvent()
    if hEvent == 0:
      raiseOSError(osLastError())
    var pcd = cast[PostCallbackDataPtr](allocShared0(sizeof(PostCallbackData)))
    pcd.ioPort = p.ioPort
    pcd.handleFd = fd
    var ol = PCustomOverlapped()
    GC_ref(ol)

    ol.data = CompletionData(fd: fd, cb:
      proc(fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) {.gcsafe.} =
        # we excluding our `fd` because cb(fd) can register own handler
        # for this `fd`
        p.handles.excl(fd)
        # unregisterWait() is called before callback, because appropriate
        # winsockets function can re-enable event.
        # https://msdn.microsoft.com/en-us/library/windows/desktop/ms741576(v=vs.85).aspx
        if unregisterWait(pcd.waitFd) == 0:
          let err = osLastError()
          if err.int32 != ERROR_IO_PENDING:
            deallocShared(cast[pointer](pcd))
            discard wsaCloseEvent(hEvent)
            raiseOSError(err)
        if cb(fd):
          # callback returned `true`, so we free all allocated resources
          deallocShared(cast[pointer](pcd))
          if not wsaCloseEvent(hEvent):
            raiseOSError(osLastError())
          # pcd.ovl will be unrefed in poll().
        else:
          # callback returned `false` we need to continue
          if p.handles.contains(fd):
            # new callback was already registered with `fd`, so we free all
            # allocated resources. This happens because in callback `cb`
            # addRead/addWrite was called with same `fd`.
            deallocShared(cast[pointer](pcd))
            if not wsaCloseEvent(hEvent):
              raiseOSError(osLastError())
          else:
            # we need to include `fd` again
            p.handles.incl(fd)
            # and register WaitForSingleObject again
            if not registerWaitForSingleObject(addr(pcd.waitFd), hEvent,
                                    cast[WAITORTIMERCALLBACK](waitableCallback),
                                       cast[pointer](pcd), INFINITE, flags):
              # pcd.ovl will be unrefed in poll()
              let err = osLastError()
              deallocShared(cast[pointer](pcd))
              discard wsaCloseEvent(hEvent)
              raiseOSError(err)
            else:
              # we incref `pcd.ovl` and `protect` callback one more time,
              # because it will be unrefed and disposed in `poll()` after
              # callback finishes.
              GC_ref(pcd.ovl)
              pcd.ovl.data.cell = system.protect(rawEnv(pcd.ovl.data.cb))
    )
    # We need to protect our callback environment value, so GC will not free it
    # accidentally.
    ol.data.cell = system.protect(rawEnv(ol.data.cb))

    # This is main part of `hacky way` is using WSAEventSelect, so `hEvent`
    # will be signaled when appropriate `mask` events will be triggered.
    if wsaEventSelect(fd.SocketHandle, hEvent, mask) != 0:
      let err = osLastError()
      GC_unref(ol)
      deallocShared(cast[pointer](pcd))
      discard wsaCloseEvent(hEvent)
      raiseOSError(err)

    pcd.ovl = ol
    if not registerWaitForSingleObject(addr(pcd.waitFd), hEvent,
                                    cast[WAITORTIMERCALLBACK](waitableCallback),
                                       cast[pointer](pcd), INFINITE, flags):
      let err = osLastError()
      GC_unref(ol)
      deallocShared(cast[pointer](pcd))
      discard wsaCloseEvent(hEvent)
      raiseOSError(err)
    p.handles.incl(fd)

  proc addRead*(fd: AsyncFD, cb: Callback) =
    ## Start watching the file descriptor for read availability and then call
    ## the callback ``cb``.
    ##
    ## This is not ``pure`` mechanism for Windows Completion Ports (IOCP),
    ## so if you can avoid it, please do it. Use `addRead` only if really
    ## need it (main usecase is adaptation of unix-like libraries to be
    ## asynchronous on Windows).
    ##
    ## If you use this function, you don't need to use asyncdispatch.recv()
    ## or asyncdispatch.accept(), because they are using IOCP, please use
    ## nativesockets.recv() and nativesockets.accept() instead.
    ##
    ## Be sure your callback ``cb`` returns ``true``, if you want to remove
    ## watch of `read` notifications, and ``false``, if you want to continue
    ## receiving notifications.
    registerWaitableEvent(fd, cb, FD_READ or FD_ACCEPT or FD_OOB or FD_CLOSE)

  proc addWrite*(fd: AsyncFD, cb: Callback) =
    ## Start watching the file descriptor for write availability and then call
    ## the callback ``cb``.
    ##
    ## This is not ``pure`` mechanism for Windows Completion Ports (IOCP),
    ## so if you can avoid it, please do it. Use `addWrite` only if really
    ## need it (main usecase is adaptation of unix-like libraries to be
    ## asynchronous on Windows).
    ##
    ## If you use this function, you don't need to use asyncdispatch.send()
    ## or asyncdispatch.connect(), because they are using IOCP, please use
    ## nativesockets.send() and nativesockets.connect() instead.
    ##
    ## Be sure your callback ``cb`` returns ``true``, if you want to remove
    ## watch of `write` notifications, and ``false``, if you want to continue
    ## receiving notifications.
    registerWaitableEvent(fd, cb, FD_WRITE or FD_CONNECT or FD_CLOSE)

  proc registerWaitableHandle(p: PDispatcher, hEvent: Handle, flags: DWORD, pcd: PostCallbackDataPtr, timeout: int,
                                  handleCallback: NativeCallback) =
    let handleFD = AsyncFD(hEvent)
    pcd.ioPort = p.ioPort
    pcd.handleFd = handleFD
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data.fd = handleFD
    ol.data.cb = handleCallback
    # We need to protect our callback environment value, so GC will not free it
    # accidentally.
    ol.data.cell = system.protect(rawEnv(ol.data.cb))

    pcd.ovl = ol
    if not registerWaitForSingleObject(addr(pcd.waitFd), hEvent,
                                    cast[WAITORTIMERCALLBACK](waitableCallback),
                                    cast[pointer](pcd), timeout.DWORD, flags):
      let err = osLastError()
      GC_unref(ol)
      deallocShared(cast[pointer](pcd))
      discard closeHandle(hEvent)
      raiseOSError(err)
    p.handles.incl(handleFD)

  template closeWaitable(handle: untyped) =
    let waitFd = pcd.waitFd
    deallocShared(cast[pointer](pcd))
    p.handles.excl(fd)
    if unregisterWait(waitFd) == 0:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        discard closeHandle(handle)
        raiseOSError(err)
    if closeHandle(handle) == 0:
      raiseOSError(osLastError())

  proc addTimer*(timeout: int, oneshot: bool, cb: Callback) =
    ## Registers callback ``cb`` to be called when timer expired.
    ##
    ## Parameters:
    ##
    ## * ``timeout`` - timeout value in milliseconds.
    ## * ``oneshot``
    ##   * `true` - generate only one timeout event
    ##   * `false` - generate timeout events periodically

    doAssert(timeout > 0)
    let p = getGlobalDispatcher()

    var hEvent = createEvent(nil, 1, 0, nil)
    if hEvent == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError())

    var pcd = cast[PostCallbackDataPtr](allocShared0(sizeof(PostCallbackData)))
    var flags = WT_EXECUTEINWAITTHREAD.DWORD
    if oneshot: flags = flags or WT_EXECUTEONLYONCE

    proc timercb(fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
      let res = cb(fd)
      if res or oneshot:
        closeWaitable(hEvent)
      else:
        # if callback returned `false`, then it wants to be called again, so
        # we need to ref and protect `pcd.ovl` again, because it will be
        # unrefed and disposed in `poll()`.
        GC_ref(pcd.ovl)
        pcd.ovl.data.cell = system.protect(rawEnv(pcd.ovl.data.cb))

    registerWaitableHandle(p, hEvent, flags, pcd, timeout, timercb)

  proc addProcess*(pid: int, cb: Callback) =
    ## Registers callback ``cb`` to be called when process with process ID
    ## ``pid`` exited.
    let p = getGlobalDispatcher()
    let procFlags = SYNCHRONIZE
    var hProcess = openProcess(procFlags, 0, pid.DWORD)
    if hProcess == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError())

    var pcd = cast[PostCallbackDataPtr](allocShared0(sizeof(PostCallbackData)))
    var flags = WT_EXECUTEINWAITTHREAD.DWORD

    proc proccb(fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
      closeWaitable(hProcess)
      discard cb(fd)

    registerWaitableHandle(p, hProcess, flags, pcd, INFINITE, proccb)

  proc newAsyncEvent*(): AsyncEvent =
    ## Creates a new thread-safe ``AsyncEvent`` object.
    ##
    ## New ``AsyncEvent`` object is not automatically registered with
    ## dispatcher like ``AsyncSocket``.
    var sa = SECURITY_ATTRIBUTES(
      nLength: sizeof(SECURITY_ATTRIBUTES).cint,
      bInheritHandle: 1
    )
    var event = createEvent(addr(sa), 0'i32, 0'i32, nil)
    if event == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError())
    result = cast[AsyncEvent](allocShared0(sizeof(AsyncEventImpl)))
    result.hEvent = event

  proc trigger*(ev: AsyncEvent) =
    ## Set event ``ev`` to signaled state.
    if setEvent(ev.hEvent) == 0:
      raiseOSError(osLastError())

  proc unregister*(ev: AsyncEvent) =
    ## Unregisters event ``ev``.
    doAssert(ev.hWaiter != 0, "Event is not registered in the queue!")
    let p = getGlobalDispatcher()
    p.handles.excl(AsyncFD(ev.hEvent))
    if unregisterWait(ev.hWaiter) == 0:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        raiseOSError(err)
    ev.hWaiter = 0

  proc close*(ev: AsyncEvent) =
    ## Closes event ``ev``.
    let res = closeHandle(ev.hEvent)
    deallocShared(cast[pointer](ev))
    if res == 0:
      raiseOSError(osLastError())

  proc addEvent*(ev: AsyncEvent, cb: Callback) =
    ## Registers callback ``cb`` to be called when ``ev`` will be signaled
    doAssert(ev.hWaiter == 0, "Event is already registered in the queue!")

    let p = getGlobalDispatcher()
    let hEvent = ev.hEvent

    var pcd = cast[PostCallbackDataPtr](allocShared0(sizeof(PostCallbackData)))
    var flags = WT_EXECUTEINWAITTHREAD.DWORD

    proc eventcb(fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
      if ev.hWaiter != 0:
        if cb(fd):
          # we need this check to avoid exception, if `unregister(event)` was
          # called in callback.
          deallocShared(cast[pointer](pcd))
          if ev.hWaiter != 0:
            unregister(ev)
        else:
          # if callback returned `false`, then it wants to be called again, so
          # we need to ref and protect `pcd.ovl` again, because it will be
          # unrefed and disposed in `poll()`.
          GC_ref(pcd.ovl)
          pcd.ovl.data.cell = system.protect(rawEnv(pcd.ovl.data.cb))
      else:
        # if ev.hWaiter == 0, then event was unregistered before `poll()` call.
        deallocShared(cast[pointer](pcd))

    registerWaitableHandle(p, hEvent, flags, pcd, INFINITE, eventcb)
    ev.hWaiter = pcd.waitFd

  initAll()
else:
  import selectors
  from posix import EINTR, EAGAIN, EINPROGRESS, EWOULDBLOCK, MSG_PEEK,
                    MSG_NOSIGNAL
  const
    InitCallbackListSize = 4         # initial size of callbacks sequence,
                                     # associated with file/socket descriptor.
    InitDelayedCallbackListSize = 64 # initial size of delayed callbacks
                                     # queue.
  type
    AsyncFD* = distinct cint
    Callback = proc (fd: AsyncFD): bool {.closure, gcsafe.}

    AsyncData = object
      readList: seq[Callback]
      writeList: seq[Callback]

    AsyncEvent* = distinct SelectEvent

    VirtualFD* = distinct int

    VirtualAsyncEventImpl = object
      triggered: bool
      when compileOption("threads"):
        eventLock: RLock
      p: PDispatcher
      vFD: VirtualFD
      cb: Callback
    VirtualAsyncEvent* = ptr VirtualAsyncEventImpl

    PDispatcher* = ref object of PDispatcherBase
      selector: Selector[AsyncData]
      vd: VirtualEventDispatcher

    VirtualEventDispatcher = object
      virtualHandles: Table[VirtualFD, VirtualAsyncEvent] # pseudo handles for custom AsyncEvents.
      nextVirtualHandle: VirtualFD
      virtualMuxHandle: AsyncEvent # all the virtual handles get multiplexed through a single real handle.

  proc `==`*(x, y: AsyncFD): bool {.borrow.}
  proc `==`*(x, y: AsyncEvent): bool {.borrow.}

  proc hash(x: VirtualFD): Hash {.borrow.}
  proc `==`*(x: VirtualFD, y: VirtualFD): bool {.borrow.}

  const InvalidVirtualFD = VirtualFD(-1)

  template newAsyncData(): AsyncData =
    AsyncData(
      readList: newSeqOfCap[Callback](InitCallbackListSize),
      writeList: newSeqOfCap[Callback](InitCallbackListSize)
    )

  proc newDispatcher*(): owned(PDispatcher) =
    new result
    result.selector = newSelector[AsyncData]()
    result.timers.newHeapQueue()
    result.callbacks = initDeque[proc ()](InitDelayedCallbackListSize)
    result.vd.virtualHandles = initTable[VirtualFD, VirtualAsyncEvent]()

  var gDisp{.threadvar.}: owned PDispatcher ## Global dispatcher

  proc setGlobalDispatcher*(disp: owned PDispatcher) =
    if not gDisp.isNil:
      assert gDisp.callbacks.len == 0
    gDisp = disp
    initCallSoonProc()

  proc getGlobalDispatcher*(): PDispatcher =
    if gDisp.isNil:
      setGlobalDispatcher(newDispatcher())
    result = gDisp

  proc getIoHandler*(disp: PDispatcher): Selector[AsyncData] =
    return disp.selector

  proc register*(fd: AsyncFD) =
    let p = getGlobalDispatcher()
    var data = newAsyncData()
    p.selector.registerHandle(fd.SocketHandle, {}, data)

  proc unregister*(fd: AsyncFD) =
    getGlobalDispatcher().selector.unregister(fd.SocketHandle)

  proc unregister*(ev: AsyncEvent) =
    getGlobalDispatcher().selector.unregister(SelectEvent(ev))

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool =
    return fd.SocketHandle in disp.selector

  proc addRead*(fd: AsyncFD, cb: Callback) =
    let p = getGlobalDispatcher()
    var newEvents = {Event.Read}
    withData(p.selector, fd.SocketHandle, adata) do:
      adata.readList.add(cb)
      newEvents.incl(Event.Read)
      if len(adata.writeList) != 0: newEvents.incl(Event.Write)
    do:
      raise newException(ValueError, "File descriptor not registered.")
    p.selector.updateHandle(fd.SocketHandle, newEvents)

  proc addWrite*(fd: AsyncFD, cb: Callback) =
    let p = getGlobalDispatcher()
    var newEvents = {Event.Write}
    withData(p.selector, fd.SocketHandle, adata) do:
      adata.writeList.add(cb)
      newEvents.incl(Event.Write)
      if len(adata.readList) != 0: newEvents.incl(Event.Read)
    do:
      raise newException(ValueError, "File descriptor not registered.")
    p.selector.updateHandle(fd.SocketHandle, newEvents)

  proc hasPendingOperations*(): bool =
    let p = getGlobalDispatcher()
    not p.selector.isEmpty() or p.timers.len != 0 or p.callbacks.len != 0

  proc processBasicCallbacks(
    fd: AsyncFD, event: Event
  ): tuple[readCbListCount, writeCbListCount: int] =
    # Process pending descriptor and AsyncEvent callbacks.
    #
    # Invoke every callback stored in `rwlist`, until one
    # returns `false` (which means callback wants to stay
    # alive). In such case all remaining callbacks will be added
    # to `rwlist` again, in the order they have been inserted.
    #
    # `rwlist` associated with file descriptor MUST BE emptied before
    # dispatching callback (See https://github.com/nim-lang/Nim/issues/5128),
    # or it can be possible to fall into endless cycle.
    var curList: seq[Callback]

    let selector = getGlobalDispatcher().selector
    withData(selector, fd.int, fdData):
      case event
      of Event.Read:
        shallowCopy(curList, fdData.readList)
        fdData.readList = newSeqOfCap[Callback](InitCallbackListSize)
      of Event.Write:
        shallowCopy(curList, fdData.writeList)
        fdData.writeList = newSeqOfCap[Callback](InitCallbackListSize)
      else:
        assert false, "Cannot process callbacks for " & $event

    let newLength = max(len(curList), InitCallbackListSize)
    var newList = newSeqOfCap[Callback](newLength)

    for cb in curList:
      if not cb(fd):
        # Callback wants to be called again.
        newList.add(cb)
        # This callback has returned with EAGAIN, so we don't need to
        # call any other callbacks as they are all waiting for the same event
        # on the same fd.
        break

    withData(selector, fd.int, fdData) do:
      # Descriptor is still present in the queue.
      case event
      of Event.Read:
        fdData.readList = newList & fdData.readList
      of Event.Write:
        fdData.writeList = newList & fdData.writeList
      else:
        assert false, "Cannot process callbacks for " & $event

      result.readCbListCount = len(fdData.readList)
      result.writeCbListCount = len(fdData.writeList)
    do:
      # Descriptor was unregistered in callback via `unregister()`.
      result.readCbListCount = -1
      result.writeCbListCount = -1

  template processCustomCallbacks(ident: untyped) =
    # Process pending custom event callbacks. Custom events are
    # {Event.Timer, Event.Signal, Event.Process, Event.Vnode}.
    # There can be only one callback registered with one descriptor,
    # so there is no need to iterate over list.
    var curList: seq[Callback]

    withData(p.selector, ident.int, adata) do:
      shallowCopy(curList, adata.readList)
      adata.readList = newSeqOfCap[Callback](InitCallbackListSize)

    let newLength = len(curList)
    var newList = newSeqOfCap[Callback](newLength)

    var cb = curList[0]
    if not cb(fd.AsyncFD):
      newList.add(cb)

    withData(p.selector, ident.int, adata) do:
      # descriptor still present in queue.
      adata.readList = newList & adata.readList
      if len(adata.readList) == 0:
        # if no callbacks registered with descriptor, unregister it.
        p.selector.unregister(fd.int)
    do:
      # descriptor was unregistered in callback via `unregister()`.
      discard

  proc closeSocket*(sock: AsyncFD) =
    let selector = getGlobalDispatcher().selector
    if sock.SocketHandle notin selector:
      raise newException(ValueError, "File descriptor not registered.")

    let data = selector.getData(sock.SocketHandle)
    sock.unregister()
    sock.SocketHandle.close()
    # We need to unblock the read and write callbacks which could still be
    # waiting for the socket to become readable and/or writeable.
    for cb in data.readList & data.writeList:
      if not cb(sock):
        raise newException(
          ValueError, "Expecting async operations to stop when fd has closed."
        )


  proc runOnce(timeout = 500): bool =
    let p = getGlobalDispatcher()
    when ioselSupportedPlatform:
      let customSet = {Event.Timer, Event.Signal, Event.Process,
                       Event.Vnode}

    if p.selector.isEmpty() and p.timers.len == 0 and p.callbacks.len == 0:
      raise newException(ValueError,
        "No handles or timers registered in dispatcher.")

    result = false
    var keys: array[64, ReadyKey]
    let nextTimer = processTimers(p, result)
    var count =
      p.selector.selectInto(adjustTimeout(p, timeout, nextTimer), keys)
    for i in 0..<count:
      let fd = keys[i].fd.AsyncFD
      let events = keys[i].events
      var (readCbListCount, writeCbListCount) = (0, 0)

      if Event.Read in events or events == {Event.Error}:
        (readCbListCount, writeCbListCount) =
          processBasicCallbacks(fd, Event.Read)
        result = true

      if Event.Write in events or events == {Event.Error}:
        (readCbListCount, writeCbListCount) =
          processBasicCallbacks(fd, Event.Write)
        result = true

      var isCustomEvent = false
      if Event.User in events:
        (readCbListCount, writeCbListCount) =
          processBasicCallbacks(fd, Event.Read)
        isCustomEvent = true
        if readCbListCount == 0:
          p.selector.unregister(fd.int)
        result = true

      when ioselSupportedPlatform:
        if (customSet * events) != {}:
          isCustomEvent = true
          processCustomCallbacks(fd)
          result = true

      # because state `data` can be modified in callback we need to update
      # descriptor events with currently registered callbacks.
      if not isCustomEvent and (readCbListCount != -1 and writeCbListCount != -1):
        var newEvents: set[Event] = {}
        if readCbListCount > 0: incl(newEvents, Event.Read)
        if writeCbListCount > 0: incl(newEvents, Event.Write)
        p.selector.updateHandle(SocketHandle(fd), newEvents)

    # Timer processing.
    discard processTimers(p, result)
    # Callback queue processing
    processPendingCallbacks(p, result)

  proc recv*(socket: AsyncFD, size: int,
             flags = {SocketFlag.SafeDisconn}): owned(Future[string]) =
    var retFuture = newFuture[string]("recv")

    var readBuffer = newString(size)

    proc cb(sock: AsyncFD): bool =
      result = true
      let res = recv(sock.SocketHandle, addr readBuffer[0], size.cint,
                     flags.toOSFlags())
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 notin {EINTR, EWOULDBLOCK, EAGAIN}:
          if flags.isDisconnectionError(lastError):
            retFuture.complete("")
          else:
            retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      elif res == 0:
        # Disconnected
        retFuture.complete("")
      else:
        readBuffer.setLen(res)
        retFuture.complete(readBuffer)
    # TODO: The following causes a massive slowdown.
    #if not cb(socket):
    addRead(socket, cb)
    return retFuture

  proc recvInto*(socket: AsyncFD, buf: pointer, size: int,
                 flags = {SocketFlag.SafeDisconn}): owned(Future[int]) =
    var retFuture = newFuture[int]("recvInto")

    proc cb(sock: AsyncFD): bool =
      result = true
      let res = recv(sock.SocketHandle, buf, size.cint,
                     flags.toOSFlags())
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 notin {EINTR, EWOULDBLOCK, EAGAIN}:
          if flags.isDisconnectionError(lastError):
            retFuture.complete(0)
          else:
            retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      else:
        retFuture.complete(res)
    # TODO: The following causes a massive slowdown.
    #if not cb(socket):
    addRead(socket, cb)
    return retFuture

  proc send*(socket: AsyncFD, buf: pointer, size: int,
             flags = {SocketFlag.SafeDisconn}): owned(Future[void]) =
    var retFuture = newFuture[void]("send")

    var written = 0

    proc cb(sock: AsyncFD): bool =
      result = true
      let netSize = size-written
      var d = cast[cstring](buf)
      let res = send(sock.SocketHandle, addr d[written], netSize.cint,
                     MSG_NOSIGNAL)
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 notin {EINTR, EWOULDBLOCK, EAGAIN}:
          if flags.isDisconnectionError(lastError):
            retFuture.complete()
          else:
            retFuture.fail(newOSError(lastError))
        else:
          result = false # We still want this callback to be called.
      else:
        written.inc(res)
        if res != netSize:
          result = false # We still have data to send.
        else:
          retFuture.complete()
    # TODO: The following causes crashes.
    #if not cb(socket):
    addWrite(socket, cb)
    return retFuture

  proc sendTo*(socket: AsyncFD, data: pointer, size: int, saddr: ptr SockAddr,
               saddrLen: SockLen,
               flags = {SocketFlag.SafeDisconn}): owned(Future[void]) =
    ## Sends ``data`` of size ``size`` in bytes to specified destination
    ## (``saddr`` of size ``saddrLen`` in bytes, using socket ``socket``.
    ## The returned future will complete once all data has been sent.
    var retFuture = newFuture[void]("sendTo")

    # we will preserve address in our stack
    var staddr: array[128, char] # SOCKADDR_STORAGE size is 128 bytes
    var stalen = saddrLen
    zeroMem(addr(staddr[0]), 128)
    copyMem(addr(staddr[0]), saddr, saddrLen)

    proc cb(sock: AsyncFD): bool =
      result = true
      let res = sendto(sock.SocketHandle, data, size, MSG_NOSIGNAL,
                       cast[ptr SockAddr](addr(staddr[0])), stalen)
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 notin {EINTR, EWOULDBLOCK, EAGAIN}:
          retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      else:
        retFuture.complete()

    addWrite(socket, cb)
    return retFuture

  proc recvFromInto*(socket: AsyncFD, data: pointer, size: int,
                     saddr: ptr SockAddr, saddrLen: ptr SockLen,
                     flags = {SocketFlag.SafeDisconn}): owned(Future[int]) =
    ## Receives a datagram data from ``socket`` into ``data``, which must
    ## be at least of size ``size`` in bytes, address of datagram's sender
    ## will be stored into ``saddr`` and ``saddrLen``. Returned future will
    ## complete once one datagram has been received, and will return size
    ## of packet received.
    var retFuture = newFuture[int]("recvFromInto")
    proc cb(sock: AsyncFD): bool =
      result = true
      let res = recvfrom(sock.SocketHandle, data, size.cint, flags.toOSFlags(),
                         saddr, saddrLen)
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 notin {EINTR, EWOULDBLOCK, EAGAIN}:
          retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false
      else:
        retFuture.complete(res)
    addRead(socket, cb)
    return retFuture

  proc acceptAddr*(socket: AsyncFD, flags = {SocketFlag.SafeDisconn}):
      owned(Future[tuple[address: string, client: AsyncFD]]) =
    var retFuture = newFuture[tuple[address: string,
        client: AsyncFD]]("acceptAddr")
    proc cb(sock: AsyncFD): bool =
      result = true
      var sockAddress: Sockaddr_storage
      var addrLen = sizeof(sockAddress).SockLen
      var client = accept(sock.SocketHandle,
                          cast[ptr SockAddr](addr(sockAddress)), addr(addrLen))
      if client == osInvalidSocket:
        let lastError = osLastError()
        assert lastError.int32 notin {EWOULDBLOCK, EAGAIN}
        if lastError.int32 == EINTR:
          return false
        else:
          if flags.isDisconnectionError(lastError):
            return false
          else:
            retFuture.fail(newException(OSError, osErrorMsg(lastError)))
      else:
        try:
          let address = getAddrString(cast[ptr SockAddr](addr sockAddress))
          register(client.AsyncFD)
          retFuture.complete((address, client.AsyncFD))
        except:
          # getAddrString may raise
          client.close()
          retFuture.fail(getCurrentException())
    addRead(socket, cb)
    return retFuture

  when ioselSupportedPlatform:

    proc addTimer*(timeout: int, oneshot: bool, cb: Callback) =
      ## Start watching for timeout expiration, and then call the
      ## callback ``cb``.
      ## ``timeout`` - time in milliseconds,
      ## ``oneshot`` - if ``true`` only one event will be dispatched,
      ## if ``false`` continuous events every ``timeout`` milliseconds.
      let p = getGlobalDispatcher()
      var data = newAsyncData()
      data.readList.add(cb)
      p.selector.registerTimer(timeout, oneshot, data)

    proc addSignal*(signal: int, cb: Callback) =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb``.
      let p = getGlobalDispatcher()
      var data = newAsyncData()
      data.readList.add(cb)
      p.selector.registerSignal(signal, data)

    proc addProcess*(pid: int, cb: Callback) =
      ## Start watching for process exit with pid ``pid``, and then call
      ## the callback ``cb``.
      let p = getGlobalDispatcher()
      var data = newAsyncData()
      data.readList.add(cb)
      p.selector.registerProcess(pid, data)

  proc newAsyncEvent*(): AsyncEvent =
    ## Creates new ``AsyncEvent``.
    result = AsyncEvent(newSelectEvent())

  proc trigger*(ev: AsyncEvent) =
    ## Sets new ``AsyncEvent`` to signaled state.
    trigger(SelectEvent(ev))

  proc close*(ev: AsyncEvent) =
    ## Closes ``AsyncEvent``
    close(SelectEvent(ev))

  proc addEvent*(ev: AsyncEvent, cb: Callback) =
    ## Start watching for event ``ev``, and call callback ``cb``, when
    ## ev will be set to signaled state.
    let p = getGlobalDispatcher()
    var data = newAsyncData()
    data.readList.add(cb)
    p.selector.registerEvent(SelectEvent(ev), data)

proc drain*(timeout = 500) =
  ## Waits for completion events and processes them. Raises ``ValueError``
  ## if there are no pending operations. In contrast to ``poll`` this
  ## processes as many events as are available.
  if runOnce(timeout) or hasPendingOperations():
    while hasPendingOperations() and runOnce(timeout): discard

proc poll*(timeout = 500) =
  ## Waits for completion events and processes them. Raises ``ValueError``
  ## if there are no pending operations. This runs the underlying OS
  ## `epoll`:idx: or `kqueue`:idx: primitive only once.
  discard runOnce(timeout)

template createAsyncNativeSocketImpl(domain, sockType, protocol) =
  let handle = newNativeSocket(domain, sockType, protocol)
  if handle == osInvalidSocket:
    return osInvalidSocket.AsyncFD
  handle.setBlocking(false)
  when defined(macosx) and not defined(nimdoc):
    handle.setSockOptInt(SOL_SOCKET, SO_NOSIGPIPE, 1)
  result = handle.AsyncFD
  register(result)

proc createAsyncNativeSocket*(domain: cint, sockType: cint,
                           protocol: cint): AsyncFD =
  createAsyncNativeSocketImpl(domain, sockType, protocol)

proc createAsyncNativeSocket*(domain: Domain = Domain.AF_INET,
                           sockType: SockType = SOCK_STREAM,
                           protocol: Protocol = IPPROTO_TCP): AsyncFD =
  createAsyncNativeSocketImpl(domain, sockType, protocol)

proc newAsyncNativeSocket*(domain: cint, sockType: cint,
    protocol: cint): AsyncFD {.deprecated: "use createAsyncNativeSocket instead".} =
  createAsyncNativeSocketImpl(domain, sockType, protocol)

proc newAsyncNativeSocket*(domain: Domain = Domain.AF_INET,
                           sockType: SockType = SOCK_STREAM,
                           protocol: Protocol = IPPROTO_TCP): AsyncFD
                           {.deprecated: "use createAsyncNativeSocket instead".} =
  createAsyncNativeSocketImpl(domain, sockType, protocol)

when defined(windows) or defined(nimdoc):
  proc bindToDomain(handle: SocketHandle, domain: Domain) =
    # Extracted into a separate proc, because connect() on Windows requires
    # the socket to be initially bound.
    template doBind(saddr) =
      if bindAddr(handle, cast[ptr SockAddr](addr(saddr)),
                  sizeof(saddr).SockLen) < 0'i32:
        raiseOSError(osLastError())

    if domain == Domain.AF_INET6:
      var saddr: Sockaddr_in6
      saddr.sin6_family = uint16(toInt(domain))
      doBind(saddr)
    else:
      var saddr: Sockaddr_in
      saddr.sin_family = uint16(toInt(domain))
      doBind(saddr)

  proc doConnect(socket: AsyncFD, addrInfo: ptr AddrInfo): owned(Future[void]) =
    let retFuture = newFuture[void]("doConnect")
    result = retFuture

    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: socket, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )

    let ret = connectEx(socket.SocketHandle, addrInfo.ai_addr,
                        cint(addrInfo.ai_addrlen), nil, 0, nil,
                        cast[POVERLAPPED](ol))
    if ret:
      # Request to connect completed immediately.
      retFuture.complete()
      # We don't deallocate ``ol`` here because even though this completed
      # immediately poll will still be notified about its completion and it
      # will free ``ol``.
    else:
      let lastError = osLastError()
      if lastError.int32 != ERROR_IO_PENDING:
        # With ERROR_IO_PENDING ``ol`` will be deallocated in ``poll``,
        # and the future will be completed/failed there, too.
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
else:
  proc doConnect(socket: AsyncFD, addrInfo: ptr AddrInfo): owned(Future[void]) =
    let retFuture = newFuture[void]("doConnect")
    result = retFuture

    proc cb(fd: AsyncFD): bool =
      let ret = SocketHandle(fd).getSockOptInt(
        cint(SOL_SOCKET), cint(SO_ERROR))
      if ret == 0:
        # We have connected.
        retFuture.complete()
        return true
      elif ret == EINTR:
        # interrupted, keep waiting
        return false
      else:
        retFuture.fail(newException(OSError, osErrorMsg(OSErrorCode(ret))))
        return true

    let ret = connect(socket.SocketHandle,
                      addrInfo.ai_addr,
                      addrInfo.ai_addrlen.SockLen)
    if ret == 0:
      # Request to connect completed immediately.
      retFuture.complete()
    else:
      let lastError = osLastError()
      if lastError.int32 == EINTR or lastError.int32 == EINPROGRESS:
        addWrite(socket, cb)
      else:
        retFuture.fail(newException(OSError, osErrorMsg(lastError)))

template asyncAddrInfoLoop(addrInfo: ptr AddrInfo, fd: untyped,
                           protocol: Protocol = IPPROTO_RAW) =
  ## Iterates through the AddrInfo linked list asynchronously
  ## until the connection can be established.
  const shouldCreateFd = not declared(fd)

  when shouldCreateFd:
    let sockType = protocol.toSockType()

    var fdPerDomain: array[low(Domain).ord..high(Domain).ord, AsyncFD]
    for i in low(fdPerDomain)..high(fdPerDomain):
      fdPerDomain[i] = osInvalidSocket.AsyncFD
    template closeUnusedFds(domainToKeep = -1) {.dirty.} =
      for i, fd in fdPerDomain:
        if fd != osInvalidSocket.AsyncFD and i != domainToKeep:
          fd.closeSocket()

  var lastException: ref Exception
  var curAddrInfo = addrInfo
  var domain: Domain
  when shouldCreateFd:
    var curFd: AsyncFD
  else:
    var curFd = fd
  proc tryNextAddrInfo(fut: Future[void]) {.gcsafe.} =
    if fut == nil or fut.failed:
      if fut != nil:
        lastException = fut.readError()

      while curAddrInfo != nil:
        let domainOpt = curAddrInfo.ai_family.toKnownDomain()
        if domainOpt.isSome:
          domain = domainOpt.unsafeGet()
          break
        curAddrInfo = curAddrInfo.ai_next

      if curAddrInfo == nil:
        freeaddrinfo(addrInfo)
        when shouldCreateFd:
          closeUnusedFds()
        if lastException != nil:
          retFuture.fail(lastException)
        else:
          retFuture.fail(newException(
            IOError, "Couldn't resolve address: " & address))
        return

      when shouldCreateFd:
        curFd = fdPerDomain[ord(domain)]
        if curFd == osInvalidSocket.AsyncFD:
          try:
            curFd = createAsyncNativeSocket(domain, sockType, protocol)
          except:
            freeaddrinfo(addrInfo)
            closeUnusedFds()
            raise getCurrentException()
          when defined(windows):
            curFd.SocketHandle.bindToDomain(domain)
          fdPerDomain[ord(domain)] = curFd

      doConnect(curFd, curAddrInfo).callback = tryNextAddrInfo
      curAddrInfo = curAddrInfo.ai_next
    else:
      freeaddrinfo(addrInfo)
      when shouldCreateFd:
        closeUnusedFds(ord(domain))
        retFuture.complete(curFd)
      else:
        retFuture.complete()

  tryNextAddrInfo(nil)

proc dial*(address: string, port: Port,
           protocol: Protocol = IPPROTO_TCP): owned(Future[AsyncFD]) =
  ## Establishes connection to the specified ``address``:``port`` pair via the
  ## specified protocol. The procedure iterates through possible
  ## resolutions of the ``address`` until it succeeds, meaning that it
  ## seamlessly works with both IPv4 and IPv6.
  ## Returns the async file descriptor, registered in the dispatcher of
  ## the current thread, ready to send or receive data.
  let retFuture = newFuture[AsyncFD]("dial")
  result = retFuture
  let sockType = protocol.toSockType()

  let aiList = getAddrInfo(address, port, Domain.AF_UNSPEC, sockType, protocol)
  asyncAddrInfoLoop(aiList, noFD, protocol)

proc connect*(socket: AsyncFD, address: string, port: Port,
              domain = Domain.AF_INET): owned(Future[void]) =
  let retFuture = newFuture[void]("connect")
  result = retFuture

  when defined(windows):
    verifyPresence(socket)
  else:
    assert getSockDomain(socket.SocketHandle) == domain

  let aiList = getAddrInfo(address, port, domain)
  when defined(windows):
    socket.SocketHandle.bindToDomain(domain)
  asyncAddrInfoLoop(aiList, socket)

proc sleepAsync*(ms: int | float): owned(Future[void]) =
  ## Suspends the execution of the current async procedure for the next
  ## ``ms`` milliseconds.
  var retFuture = newFuture[void]("sleepAsync")
  let p = getGlobalDispatcher()
  when ms is int:
    p.timers.push((getMonoTime() + initDuration(milliseconds = ms), retFuture))
  elif ms is float:
    let ns = (ms * 1_000_000).int64
    p.timers.push((getMonoTime() + initDuration(nanoseconds = ns), retFuture))
  return retFuture

proc withTimeout*[T](fut: Future[T], timeout: int): owned(Future[bool]) =
  ## Returns a future which will complete once ``fut`` completes or after
  ## ``timeout`` milliseconds has elapsed.
  ##
  ## If ``fut`` completes first the returned future will hold true,
  ## otherwise, if ``timeout`` milliseconds has elapsed first, the returned
  ## future will hold false.

  var retFuture = newFuture[bool]("asyncdispatch.`withTimeout`")
  var timeoutFuture = sleepAsync(timeout)
  fut.callback =
    proc () =
      if not retFuture.finished:
        if fut.failed:
          retFuture.fail(fut.error)
        else:
          retFuture.complete(true)
  timeoutFuture.callback =
    proc () =
      if not retFuture.finished: retFuture.complete(false)
  return retFuture

proc accept*(socket: AsyncFD,
    flags = {SocketFlag.SafeDisconn}): owned(Future[AsyncFD]) =
  ## Accepts a new connection. Returns a future containing the client socket
  ## corresponding to that connection.
  ## The future will complete when the connection is successfully accepted.
  var retFut = newFuture[AsyncFD]("accept")
  var fut = acceptAddr(socket, flags)
  fut.callback =
    proc (future: Future[tuple[address: string, client: AsyncFD]]) =
      assert future.finished
      if future.failed:
        retFut.fail(future.error)
      else:
        retFut.complete(future.read.client)
  return retFut

proc send*(socket: AsyncFD, data: string,
           flags = {SocketFlag.SafeDisconn}): owned(Future[void]) =
  ## Sends ``data`` to ``socket``. The returned future will complete once all
  ## data has been sent.
  var retFuture = newFuture[void]("send")

  var copiedData = data
  GC_ref(copiedData) # we need to protect data until send operation is completed
                     # or failed.

  let sendFut = socket.send(addr copiedData[0], data.len, flags)
  sendFut.callback =
    proc () =
      GC_unref(copiedData)
      if sendFut.failed:
        retFuture.fail(sendFut.error)
      else:
        retFuture.complete()

  return retFuture

proc deInitVirtualEventDispatcher(p: PDispatcher) =
  assert p.vd.virtualHandles.len == 0, "Cannot de-Init Virtual Event Dispacter. There are still Pending Events."
  p.vd.virtualMuxHandle.unregister()
  p.vd.virtualMuxHandle.close()
  p.vd.virtualMuxHandle = nil
  p.vd.nextVirtualHandle = 0.VirtualFD

proc unregister*(ev: VirtualAsyncEvent) =
  ## Unregisters event ``ev``.
  doAssert(ev.vFD != InvalidVirtualFD, "Event is not registered in the queue!")

  let oldP = ev.p
  withLockIfThreads ev.eventLock:
    ev.p.vd.virtualHandles.del ev.vFD
    ev.p = nil
    ev.cb = nil
    ev.vFD = InvalidVirtualFD

  if oldP.vd.virtualHandles.len == 0:
    # lazy de-init the physical event with the Dispatcher
    # The main reason we need this is to make
    # hasPendingOperations still work
    # without modifying the ioselector code.
    deInitVirtualEventDispatcher(oldP)

proc initVirtualEventDispatcher(p: PDispatcher) =
  p.vd.virtualMuxHandle = newAsyncEvent()

  proc virtualMuxCB(fd: AsyncFD): bool {.closure,gcsafe.} =
    # find the virtual events that triggered the physical event and
    # add them to the callback list.
    # Not very efficient, but requires the least coordination between threads.
    
    proc vcbFactory(vfd: VirtualFD) : proc() {.closure, gcsafe.} =
      let ev = p.vd.virtualHandles[vfd]
      result = proc() {.closure,gcSafe.} =
        if ev.cb(vfd.AsyncFD):
          # the convention is that if the callback returns true, we unregister the event.
          ev.unregister

    for vfd, ev in p.vd.virtualHandles:
      withLockIfThreads ev.eventLock:
        if ev.triggered:
          ev.triggered = false
          p.callbacks.addLast(vcbFactory(vfd))

    # always return false b/c we never want to unregister this event
    return false

  p.vd.virtualMuxHandle.addEvent(virtualMuxCB)

proc newVirtualAsyncEvent*(): VirtualAsyncEvent =
  ## Creates a new thread-safe ``VirtualAsyncEvent`` object.
  ##
  ## New ``VirtualAsyncEvent`` object is not automatically registered with
  ## dispatcher like ``AsyncSocket``.
  result = cast[VirtualAsyncEvent](allocShared0(sizeof(VirtualAsyncEventImpl)))
  result.cb = nil
  result.vFD = InvalidVirtualFD
  when compileOption("threads"):
    initRLock result.eventLock

proc trigger*(ev: VirtualAsyncEvent) =
  ## Sets new ``VirtualAsyncEvent`` to signaled state.
  withLockIfThreads ev.eventLock:
    if ev.vFD == InvalidVirtualFD:
      # triggering on an event that is not registered is a noop.
      return
    ev.triggered = true

    # send the signal to wake up the dispatcher thread.
    trigger(ev.p.vd.virtualMuxHandle)

proc addEvent*(ev: VirtualAsyncEvent, cb: Callback) =
  ## Registers callback ``cb`` to be called when ``ev`` will be signaled
  doAssert(ev.vFD == InvalidVirtualFD, "Event is already registered in the queue!")

  let p = getGlobalDispatcher()

  if p.vd.virtualMuxHandle == nil:
    # lazy register the physical event with the Dispatcher
    # The main reason we need this is to make hasPendingOperations still work
    # without modifying the ioselector code.
    initVirtualEventDispatcher(p)

  withLockIfThreads ev.eventLock:
    ev.cb = cb
    ev.vFD = p.vd.nextVirtualHandle
    p.vd.nextVirtualHandle = VirtualFD(int(p.vd.nextVirtualHandle) + 1)
    p.vd.virtualHandles[ev.vFD] = ev
    ev.p = p

proc close*(ev: VirtualAsyncEvent) =
  ## Closes event ``ev``.
  doAssert(ev.vFD != InvalidVirtualFD, "Must unregister Event before you close it!")
  when compileOption("threads"):
    deinitRLock(ev.eventLock)
  deallocShared(cast[pointer](ev))

# -- Await Macro
include asyncmacro

proc readAll*(future: FutureStream[string]): owned(Future[string]) {.async.} =
  ## Returns a future that will complete when all the string data from the
  ## specified future stream is retrieved.
  result = ""
  while true:
    let (hasValue, value) = await future.read()
    if hasValue:
      result.add(value)
    else:
      break

proc callSoon(cbproc: proc () {.gcsafe.}) =
  getGlobalDispatcher().callbacks.addLast(cbproc)

proc runForever*() =
  ## Begins a never ending global dispatcher poll loop.
  while true:
    poll()

proc waitFor*[T](fut: Future[T]): T =
  ## **Blocks** the current thread until the specified future completes.
  while not fut.finished:
    poll()

  fut.read
