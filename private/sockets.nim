import zmq,json, threadpool,os, osproc,strutils, sequtils, base64
import messaging
#import compiler/nimeval as compiler # We can actually use the nim compiler at runtime! Woho

var execcount {.global.} = 0 # Monotonically increasing counter 

type Heartbeat* = object
  socket*: TConnection
  alive: bool

type IOPub* = object
  socket*: TConnection
  key*:string
  lastmsg*:WireMessage

type
  ShellObj = object
    socket*: TConnection
    key*: string # session key
    pub*: IOPub # keep a reference to pub so we can send status message
  Shell* = ref ShellObj

proc createHB*(ip:string,hbport:BiggestInt): Heartbeat =
  ## Create the heartbeat socket
  result.socket = zmq.listen("tcp://"&ip&":"& $hbport)
  result.alive = true
proc beat*(hb: Heartbeat) =
  ## Execute the heartbeat loop.
  ## Usually ``spawn``ed to avoid killing the kernel
  ## when it's busy
  debug "starting hb loop..."
  while hb.alive:
    var s :string
    try:
      s = hb.socket.receive() # Read from socket
    except:
      debug "broke Heartbeat Loop"
      break
      
    if s!=nil: 
      hb.socket.send(s) # Echo back what we read
    else:
      debug "broke Heartbeat Loop"
      break
proc close*(hb: var Heartbeat) = 
  hb.alive = false
  hb.socket.close()

proc createIOPub*(ip:string,port:BiggestInt , key:string): IOPub =
  ## Create the IOPub socket
# TODO: transport
  result.socket = zmq.listen("tcp://"&ip&":"& $port,zmq.PUB)
  result.key = key

proc send_state(pub:IOPub,state:string,) {.inline.}=
  pub.socket.send_wire_msg_no_parent("status", %* { "execution_state": state },pub.key)

proc receive*(pub:IOPub) =
  ## Receive a message on the IOPub socket
  let recvdmsg : WireMessage = pub.socket.receive_wire_msg()
  debug "pub received:\n", $recvdmsg
  
proc createShell*(ip:string,shellport:BiggestInt,key:string,pub:IOPub): Shell =
  ## Create a shell socket
  new result
  result.socket = zmq.listen("tcp://"&ip&":"& $shellport, zmq.ROUTER)
  result.key = key
  result.pub = pub

proc handleKernelInfo(s:Shell,m:WireMessage) =
  var content : JsonNode
  spawn s.pub.send_state("busy") # Tell the client we are busy
  #echo "sending: Kernelinfo sending busy"
  content = %* {
    "protocol_version": "5.0",
    "ipython_version": [1, 1, 0, ""],
    "language_version": [0, 15, 0], # TODO get compiler version from the compiler
    "language": "nim",
    "implementation": "nimpure",
    "implementation_version": "0.2",
    "language_info": {
      "name": "nim",
      "version": "0.2",
      "mimetype": "text/x-nimrod",
      "file_extension": ".nim",
      "pygments_lexer": "",
      "codemirror_mode": "nim",
      "nbconvert_exporter": "",
    },
    "banner": ""
  }
  
  s.socket.send_wire_msg("kernel_info_reply", m , content, s.key)
  #echo "sending kernel info reply and idle"
  spawn s.pub.send_state("idle") #move to thread

const inlineplot = "\nimport inim/pyplot\n"

## Ugly way of injecting
proc injectInclude*(blocknum:int):string = 
  if blocknum>0: result = "\ninclude imports \n"
  else: result=""

proc exportWrapper*(blocknum:int=0):string = """

when isMainModule:
  import strutils,sequtils, os
  proc wrapEchos(){.noconv.}=
    ## Wrap top level echos in isMainModule
    let code = readFile(currentSourcePath())
    var outcode = ""
    for ln in code.splitLines:
      if ln.startsWith("#"): 
        outcode &= ln&"\n"
        continue
      if ln.startsWith("echo"): outcode &= ln.replace("echo","when isMainModule:\n  echo")&"\n"
      else: outcode &= ln&"\n"
    writeFile(currentSourcePath(),outcode)
  
  proc appendExport(){.noconv.}=
    if fileExists("inimtemp/imports.nim"):
      var fs = open("inimtemp/imports.nim",fmAppend)
      fs.write("import "&currentSourcePath().extractFilename().changeFileExt("")&"\n")
      fs.write("export "&currentSourcePath().extractFilename().changeFileExt("")&"\n")
    else: writeFile("inimtemp/imports.nim", "import "&currentSourcePath().extractFilename().changeFileExt("")&"\nexport "&currentSourcePath().extractFilename().changeFileExt("")&"\n" )

  addQuitProc(appendExport)
  addQuitProc(wrapEchos)

"""

var last_sucess_block: int = 0 # This variable maintains the last succesfully compiled block in this session.
var flags: seq[string] = @["--hints:off","--verbosity:0","--d:release"] # Default flags, will be overwritten if others are passed
var hasPlot: bool = false
var ploth = 480
var plotw = 640
var use_tcc = false
var tcc_path = ""

proc flatten(flags:seq[string]):string =
  result = " "
  for f in flags: result.add(f&" ")

proc handleExecute(shell:Shell,msg:WireMessage) =
  inc execcount
  
  spawn shell.pub.send_state("busy") #move to thread

  let code = msg.content["code"].str # The code to be executed
  
  if code.contains("#>inlineplot"):
    hasPlot =  true 
  if hasPlot:
    let plotstart = code.find("#>inlineplot")+"#>inlineplot".len+1
    let defplot = code[plotstart..code.find('\u000A',plotstart)].split()
    if defplot.len > 0 :
      plotw = if defplot[0].isDigit: defplot[0].parseInt else: plotw
      ploth = if defplot[1].isDigit: defplot[1].parseInt else: ploth

  let hasFlags = if code.contains("#>flags"): true else: false
  if hasFlags:
    let flagstart = code.find("#>flags")+"#>flags".len+1
    let nwline = code.find('\u000A',flagstart)
    let flagend = if nwline != -1: nwline else: code.len
    flags = code[flagstart..flagend].split()
  
  debug "With flags:",flags.flatten
  
  if code.contains("#>clear all") and existsDir("inimtemp"):
    debug "Cleaning up..."
    flags = @["--hints:off","--verbosity:0","--d:release"]
    hasPlot = false
    ploth = 480
    plotw = 640
    use_tcc = false
    tcc_path = ""
    removeDir("inimtemp")
    createDir("inimtemp")
    writeFile("inimtemp/imports.nim","") #reset imports file

  if code.contains("#>tinycc"): 
    use_tcc = true
    tcc_path = " --cc:tcc"
    let tccstart = code.find("#>tinycc")+"#>tinycc".len+1
    let nwline = code.find('\u000A',tccstart)
    let tccend = if nwline != -1: nwline else: code.len
    if code[tccstart..tccend].len>3: # 3 is arbitrary, C:\ is already 3 chars
      tcc_path&=" -L:"&code[tccstart..tccend]&" "
    debug tcc_path
  let srcfile = "inimtemp/block" & $execcount & ".nim"

  
  if hasPlot: writeFile(srcfile,inlineplot&injectInclude(last_sucess_block)&code&exportWrapper()) # write the block to a temp ``block[num].nim`` file
  else: writeFile(srcfile,injectInclude(last_sucess_block)&code&exportWrapper()) # write the block to a temp ``block[num].nim`` file
  
  

  # Send via iopub the block about to be executed
  var content = %* {
      "execution_count": execcount,
      "code": code,
  }
  shell.pub.socket.send_wire_msg( "execute_input", msg, content, shell.key)

  # Compile and send compilation messages to stdout
  # TODO: handle flags
  var compiler_out = execProcess("nim c "&tcc_path&flatten(flags)&" -d:jupyter -o:inimtemp/compiled.out "&srcfile) # compile block
  debug "nim c "&tcc_path&flatten(flags)&" -d:jupyter -o:inimtemp/compiled.out "&srcfile 

  var status = "ok" # OR 'error' OR 'abort'
  var std_type = "stdout"
  if compiler_out.contains("Error:"):
    status = "error"
    std_type = "stderr" 
  else: last_sucess_block = execcount # This block compiled succesfully

  # clean out empty lines from compilation messages
  var compiler_lines = compiler_out.splitLines()
  
  compiler_out = ""
  for ln in compiler_lines : 
    if ln!="": compiler_out&= (ln & "\n")

  content = %*{ "name": std_type, "text": compiler_out }
  
  # Send compiler messages
  shell.pub.socket.send_wire_msg( "stream", msg, content, shell.key)

  if status == "error" or status == "abort" :
    content = %* {
      "status" : status,
      "ename" : "Compile error",   # Exception name, as a string
      "evalue" : "Error",  # Exception value, as a string
      "traceback" : nil, # traceback frames as strings
    }
    shell.pub.socket.send_wire_msg( "error", msg, content, shell.key)
  else:
    # Send results to frontend
    let exec_out = execprocess("inimtemp/compiled.out") # execute compiled block

    let plotfile = "inimtemp/block" & $execcount & ".png"
    if hasPlot and existsFile(plotfile):
      let plotdata = readFile(plotfile)
      content = %*{
          "data": {"image/png": encode(plotdata) }, # TODO: handle other mimetypes
          "metadata": %*{ "image/png" : { "width": plotw, "height": ploth } }
      }
      shell.pub.socket.send_wire_msg( "display_data", msg, content, shell.key)
    elif hasPlot and existsFile(plotfile)==false : debug("plotting: ",plotfile," - no such file, false positive?")

    content = %*{
        "execution_count": execcount,
        "data": {"text/plain": exec_out }, # TODO: handle other mimetypes
        "metadata": "{}"
    }
    shell.pub.socket.send_wire_msg( "execute_result", msg, content, shell.key)
    
  # Tell the frontend execution was ok, or not
  if status == "error" or status == "abort" :
    content = %* {
      "status" : status,
      "execution_count" : execcount,
    }
  else:
    content = %* {
      "status" : status,
      "execution_count" : execcount,
      "payload" : {},
      "user_expressions" : {},
    }
  shell.socket.send_wire_msg("execution_reply", msg , content, shell.key)
  
  spawn shell.pub.send_state("idle")
  #compiler.execute(code)

proc parseNimsuggest(nims:string):tuple[found:bool,data:JsonNode] =
  # nimsuggest output is \t separated
  # http://nim-lang.org/docs/nimsuggest.html#parsing-nimsuggest-output
  discard

proc handleIntrospection(shell:Shell,msg:WireMessage) =
  let code = msg.content["code"].str
  let cpos = msg.content["cursor_pos"].num.int
  if code[cpos] == '.' :
    discard # make a call to sug in nimsuggest sug <file> <line>:<pos>
  elif code[cpos] == '(':
    discard # make a call to con in nimsuggest con <file> <line>:<pos>
  # TODO: ask nimsuggest about the code
  var content = %* {
    "status" : "ok", #or "error"
    "found" : false, # found should be true if an object was found, false otherwise
    "data" : {}, #TODO nimsuggest??
    "metadata" : {},
  }
  shell.socket.send_wire_msg("inspect_reply", msg , content, shell.key)

proc filter*[T](seq1: openarray[T], pred: proc(item: T): bool {.closure.}): seq[T] {.inline.} =
  ## Returns a new sequence with all the items that fulfilled the predicate.
  ## Copied from sequtils, modified to work with openarray
  result = newSeq[T]()
  for i in 0..<seq1.len:
    if pred(seq1[i]):
      result.add(seq1[i])

proc handleCompletion(shell:Shell, msg:WireMessage) =
  
  let code : string = msg.content["code"].str
  let cpos : int = msg.content["cursor_pos"].num.int

  let ws = "\n\r\t "
  let lf = "\n\r"
  var sw = cpos
  while sw > 0 and (not ws.contains(code[sw - 1])):
      sw -= 1
  var sl = sw
  while sl > 0 and (not lf.contains(code[sl - 1])):
      sl -= 1
  let wrd = code[sw..cpos]

  var matches : seq[string] = @[] # list of all matches

  # Snippets
  if "proc".startswith(wrd):
      matches &= ("proc name(arg:type):returnType = \n    #proc")
  elif "if".startswith(wrd):
      matches &= ("if (expression):\n    #then")
  elif "method".startswith(wrd):
      matches &= ("method name(arg:type): returnType = \n    #method")
  elif "iterator".startswith(wrd):
      matches &= ("iterator name(arg:type): returnType = \n    #iterator")
  elif "array".startswith(wrd):
      matches &= ("array[length, type]")
  elif "seq".startswith(wrd):
      matches &= ("seq[type]")
  elif "for".startswith(wrd):
      matches &= ("for index in iterable):\n  #for loop")
  elif "while".startswith(wrd):
      matches &= ("while(condition):\n  #while loop")
  elif "block".startswith(wrd):
      matches &= ("block name:\n  #block")
  elif "case".startswith(wrd):
      matches &= ("case variable:\nof value:\n  #then\nelse:\n  #else")
  elif "try".startswith(wrd):
      matches &= ("try:\n  #something\nexcept exception:\n  #handle exception")
  elif "template".startswith(wrd):
      matches &= ("template name (arg:type): returnType =\n  #template")
  elif "macro".startswith(wrd):
      matches &= ("macro name (arg:type): returnType =\n  #macro")
          
  # Single word matches
  let single = ["int", "float", "string", "addr", "and", "as", "asm", "atomic", "bind", "break", "cast",
                "concept", "const", "continue", "converter", "defer", "discard", "distinct", "div", "do",
                "elif", "else", "end", "enum", "except", "export", "finally", "for", "from", "func",
                "generic", "import", "in", "include", "interface", "is", "isnot", "let", "mixin", "mod",
                "nil", "not", "notin", "object", "of", "or", "out", "ptr", "raise", "ref", "return", "shl",
                "shr", "static", "tuple", "type", "using", "var", "when", "with", "without", "xor", "yield"]

  #magics = ['#>loadblock ','#>passflag ']
  
  # Add all matches to our list
  matches = matches & ( filter(single) do (x: string) -> bool : x.startsWith(wrd) )

  # TODO completion+nimsuggest

  var content = %* {
    # The list of all matches to the completion request
    "matches" : matches,
    # The range of text that should be replaced by the above matches when a completion is accepted.
    # typically cursor_end is the same as cursor_pos in the request.
    "cursor_start": sw,
    "cursor_end" : cpos,

    # Information that frontend plugins might use for extra display information about completions.
    "metadata" : {},

    # status should be 'ok' unless an exception was raised during the request,
    # in which case it should be 'error', along with the usual error message content
    # in other messages. Currently assuming it won't error.
    "status" : "ok"
  }
 # debug msg
  shell.socket.send_wire_msg("complete_reply", msg , content, shell.key)

proc handleHistory(shell:Shell, msg:WireMessage) =
  debug "Unhandled history"
  var content = %* {
    # A list of 3 tuples, either:
    # (session, line_number, input) or
    # (session, line_number, (input, output)),
    # depending on whether output was False or True, respectively.
    "history" : [],
  }

proc handle(s:Shell,m:WireMessage) =
  if m.msg_type == Kernel_Info:
    handleKernelInfo(s,m)
  elif m.msg_type == Execute:
    handleExecute(s,m)
  elif m.msg_type == Shutdown :
    debug "kernel wants to shutdown"
    quit()
  elif m.msg_type == Introspection : handleIntrospection(s,m)
  elif m.msg_type == Completion : handleCompletion(s,m)
  elif m.msg_type == History : handleHistory(s,m)
  elif m.msg_type == Complete : discard # TODO
  else:
    debug "unhandled message: ", m.msg_type

proc receive*(shell:Shell) =
  ## Receive a message on the shell socket, decode it and handle operations
  let recvdmsg : WireMessage = shell.socket.receive_wire_msg()
  debug "sending: ", $recvdmsg.msg_type
  debug recvdmsg.content
  debug "end sending"
  shell.handle(recvdmsg)

type Control* = object
    socket*: TConnection
    key*:string

proc createControl*(ip:string,port:BiggestInt,key:string): Control =
  ## Create the control socket
  result.socket = zmq.listen("tcp://"&ip&":"& $port, zmq.ROUTER)
  result.key = key

proc handle(c:Control,m:WireMessage) =
  if m.msg_type == Shutdown:
    #var content : JsonNode
    debug "shutdown requested"
    #content = %* { "restart": false }    
    c.socket.send_wire_msg("shutdown_reply", m , m.content, c.key)
    quit()
  #if m.msg_type ==

proc receive*(cont:Control) =
  ## Receive a message on the control socket and handle operations
  let recvdmsg : WireMessage = cont.socket.receive_wire_msg()
  debug "received: ", $recvdmsg.msg_type
  cont.handle(recvdmsg)
