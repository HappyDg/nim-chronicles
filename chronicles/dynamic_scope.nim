import
  macros, log_output, scope_helpers, options

type
  ScopeBindingBase[LogRecord] = object of RootObj
    name: string
    appender: LogAppender[LogRecord]

  LogAppender[LogRecord] = proc(x: var LogRecord,
                                valueAddr: ptr ScopeBindingBase[LogRecord])

  ScopeBinding[LogRecord, T] = object of ScopeBindingBase[LogRecord]
    value: T

  BindingsArray[LogRecord] = ptr UncheckedArray[ptr ScopeBindingBase[LogRecord]]

  BindingsFrame[LogRecord] = object
    prev: ptr BindingsFrame[LogRecord]
    bindings: BindingsArray[LogRecord]
    bindingsCount: int

proc appenderIMPL[LogRecord, PropertyType](log: var LogRecord,
                                           keyValuePair: ptr ScopeBindingBase[LogRecord]) =
  type ActualType = ptr ScopeBinding[LogRecord, PropertyType]
  # XXX: The use of `cast` here shouldn't be necessary. This is a normal explicit upcast.
  let v = cast[ActualType](keyValuePair)
  log.setProperty v.name, v.value

proc topBindingFrame[LogRecord](topPtr: var ptr BindingsFrame[LogRecord],
                                setValue = false) {.inline.} =
  var tlsSlot {.threadvar.}: ptr BindingsFrame[LogRecord]
  if setValue:
    tlsSlot = topPtr
  else:
    topPtr = tlsSlot

template setTopBindingFrame(LogRecord: typedesc, val: untyped) =
  var p: ptr BindingsFrame[LogRecord] = val
  topBindingFrame p, true

template getTopBindingFrame(LogRecord: typedesc): untyped =
  var p: ptr BindingsFrame[LogRecord]
  topBindingFrame p, false
  p

proc logAllDynamicProperties*[LogRecord](log: var LogRecord) =
  # This proc is intended for internal use only
  var frame = getTopBindingFrame LogRecord
  while frame != nil:
    for i in 0 ..< frame.bindingsCount:
      let binding = frame.bindings[i]
      binding.appender(log, binding)
    frame = frame.prev

proc makeScopeBinding[T](LogRecord: typedesc,
                         name: string,
                         value: T): ScopeBinding[LogRecord, T] =
  result.name = name
  result.appender = appenderIMPL[LogRecord, T]
  result.value = value

macro dynamicLogScopeIMPL*(lexicalScopes: typed,
                           args: varargs[untyped]): untyped =
  # XXX: open question: should we support overriding of dynamic props
  # inside inner scopes. This will have some run-time overhead.
  let body = args[^1]
  args.del(args.len - 1)

  if body.kind != nnkStmtList:
    error "dynamicLogScope expects a block", body

  var stream = config.streams[0]
  for k, v in assignments(lexicalScopes.finalLexicalBindings, skip = 1):
    if k == "stream":
      stream = handleUserStreamChoice(v)

  var
    makeScopeBinding = bindSym"makeScopeBinding"
    logRecordType = newIdentNode(stream.recordTypeName)
    bindingsVars = newTree(nnkStmtList)
    bindingsArray = newTree(nnkBracket)
    bindingsArraySym = genSym(nskLet, "bindings")

  for name, value in assignments(args):
    var bindingVar = genSym(nskLet, name)

    bindingsVars.add quote do:
      let `bindingVar` = `makeScopeBinding`(`logRecordType`, `name`, `value`)

    bindingsArray.add newCall("unsafeAddr", bindingVar)

  let totalBindingVars = bindingsVars.len

  result = quote:
    var prevBindingFrame = getTopBindingFrame `logRecordType`

    try:
      # All of the dynamic binding pairs are placed on the stack.
      `bindingsVars`

      # An array is created to hold pointers to them.
      # This works, because of the common base type `ScopeBindingBase[LogRecord]`.
      let `bindingsArraySym` = `bindingsArray`

      # A `BindingFrame` object is also placed on the stack, holding
      # meta-data about the array and a link to the previous BindingFrame.
      let bindingFrame = BindingsFrame[`logRecordType`](
        prev: prevBindingFrame,
        bindings: cast[BindingsArray[`logRecordType`]](unsafeAddr `bindingsArraySym`),
        bindingsCount: `totalBindingVars`)

      # The address of the new BindingFrame is written to a TLS location.
      setTopBindingFrame `logRecordType`, unsafeAddr(bindingFrame)

      `body`

    finally:
      # After the scope block has been executed, we restore the previous
      # top BindingFrame.
      setTopBindingFrame `logRecordType`, prevBindingFrame

