import strutils, macros, sequtils, parseutils, os
import nwtTokenizer

type
  NwtNodeKind = enum
    NStr, NComment, NIf, NElif, NElse, NWhile, NFor,
    NVariable, NEval, NImport, NBlock, NExtends
  NwtNode = object
    case kind: NwtNodeKind
    of NStr:
      strBody: string
    of NComment:
      commentBody: string
    of NIf:
      ifStmt: string
      nnThen: seq[NwtNode]
      nnElif: seq[NwtNode]
      nnElse: seq[NwtNode]
    of NElif:
      elifStmt: string
      elifBody: seq[NwtNode]
    of NWhile:
      whileStmt: string
      whileBody: seq[NwtNode]
    of NFor:
      forStmt: string
      forBody: seq[NwtNode]
    of NVariable:
      variableBody: string
    of NEval:
      evalBody: string
    of NImport:
      importBody: string
    of NBlock:
      blockName: string
      blockBody: seq[NwtNode]
    of NExtends:
      extendsPath: string
    else: discard

type IfState {.pure.} = enum
  InThen, InElif, InElse

# First step nodes
type
  FsNodeKind = enum
    FsIf, FsStr, FsEval, FsElse, FsElif, FsEndif, FsFor,
    FsEndfor, FsVariable, FsWhile, FsEndWhile, FsImport, FsBlock, FsEndBlock, FsExtends
  FSNode = object
    kind: FsNodeKind
    value: string

when defined(dumpNwtAstPretty):
  import json
  proc pretty*(nwtNodes: seq[NwtNode]): string {.compileTime.} =
    (%* nwtNodes).pretty()

template getScriptDir*(): string =
  ## Helper for staticRead.
  ##
  ## returns the absolute path to your project, on compile time.
  getProjectPath()

# Forward decleration
proc parseSecondStep(fsTokens: seq[FSNode], pos: var int): seq[NwtNode]
proc parseSecondStepOne(fsTokens: seq[FSNode], pos: var int): seq[NwtNode]
proc astAst(tokens: seq[NwtNode]): seq[NimNode]


func splitStmt(str: string): tuple[pref: string, suf: string] {.inline.} =
  ## the prefix is normalized (transformed to lowercase)
  var pref = ""
  var pos = parseIdent(str, pref, 0)
  pos += str.skipWhitespace(pos)
  result.pref = toLowerAscii(pref)
  result.suf = str[pos..^1]

proc parseFirstStep(tokens: seq[Token]): seq[FSNode] =
  result = @[]
  for token in tokens:
    if token.tokenType == NwtEval:
      let (pref, suf) = splitStmt(token.value)
      case pref
      of "if": result.add FSNode(kind: FsIf, value: suf)
      of "elif": result.add FSNode(kind: FsElif, value: suf)
      of "else": result.add FSNode(kind: FsElse, value: suf)
      of "endif": result.add FSNode(kind: FsEndif, value: suf)
      of "for": result.add FSNode(kind: FsFor, value: suf)
      of "endfor": result.add FSNode(kind: FsEndfor, value: suf)
      of "while": result.add FSNode(kind: FsWhile, value: suf)
      of "endwhile": result.add FSNode(kind: FsEndWhile, value: suf)
      of "importnwt": result.add FSNode(kind: FsImport, value: suf)
      of "block": result.add FSNode(kind: FsBlock, value: suf)
      of "endblock": result.add FSNode(kind: FsEndBlock, value: suf)
      of "extends": result.add FSNode(kind: FsExtends, value: suf)
      else:
        result.add FSNode(kind: FsEval, value: token.value)
    elif token.tokenType == NwtString:
      result.add FSNode(kind: FsStr, value: token.value)
    elif token.tokenType == NwtVariable:
      result.add FSNode(kind: FsVariable, value: token.value)
    elif token.tokenType == NwtComment:
      discard # ignore comments
    else:
      echo "[FS] Not catched:", token


proc parseSsIf(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos] # first is the if that we got called about
  result = NwtNode(kind: NwtNodeKind.NIf)
  result.ifStmt = elem.value
  pos.inc # skip the if
  var ifstate = IfState.InThen
  while pos < fsTokens.len:
    elem = fsTokens[pos]
    case elem.kind
    of FsIf:
      case ifState
      of IfState.InThen:
        result.nnThen.add parseSecondStep(fsTokens, pos)
      of IfState.InElse:
        result.nnElse.add parseSecondStep(fsTokens, pos)
      of IfState.InElif:
        result.nnElif[^1].elifBody.add parseSecondStep(fsTokens, pos)
    of FsElif:
      ifstate = IfState.InElif
      result.nnElif.add NwtNode(kind: NElif, elifStmt: elem.value)
    of FsElse:
      ifstate = IfState.InElse
    of FsEndif:
      break
    else:
      case ifState
      of IfState.InThen:
        result.nnThen &= parseSecondStepOne(fsTokens, pos)
      of IfState.InElse:
        result.nnElse &= parseSecondStepOne(fsTokens, pos)
      of IfState.InElif:
        result.nnElif[^1].elifBody &= parseSecondStepOne(fsTokens, pos)
    pos.inc


proc parseSsWhile(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos] # first is the while that we got called about
  result = NwtNode(kind: NwtNodeKind.NWhile)
  result.whileStmt = elem.value
  while pos < fsTokens.len:
    pos.inc # skip the while
    elem = fsTokens[pos]
    if elem.kind == FsEndWhile:
      break
    else:
      result.whileBody &= parseSecondStepOne(fsTokens, pos)

proc parseSsFor(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos] # first is the for that we got called about
  result = NwtNode(kind: NwtNodeKind.NFor)
  result.forStmt = elem.value
  while pos < fsTokens.len:
    pos.inc # skip the for
    elem = fsTokens[pos]
    if elem.kind == FsEndFor:
      break
    else:
      result.forBody &= parseSecondStepOne(fsTokens, pos)

proc parseSsBlock(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos]
  let blockName = elem.value
  result = NwtNode(kind: NwtNodeKind.NBlock, blockName: blockName)
  while pos < fsTokens.len:
    pos.inc # skip the block
    elem = fsTokens[pos]
    if elem.kind == FsEndBlock:
      break
    else:
      result.blockBody &= parseSecondStepOne(fsTokens, pos)

proc parseSsExtends(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos]
  let extendsPath = elem.value.strip(true, true, {'"'})
  return NwtNode(kind: NExtends, extendsPath: extendsPath)

converter singleNwtNodeToSeq(nwtNode: NwtNode): seq[NwtNode] =
  return @[nwtNode]

proc includeNwt(nodes: var seq[NwtNode], path: string) {.compileTime.} =
  const basePath = getProjectPath()
  var str = staticRead( basePath  / path.strip(true, true, {'"'}) )
  var lexerTokens = toSeq(nwtTokenize(str))
  var firstStepTokens = parseFirstStep(lexerTokens)
  var pos = 0
  var secondsStepTokens = parseSecondStep(firstStepTokens, pos)
  for secondStepToken in secondsStepTokens:
    nodes.add secondStepToken

proc parseSecondStepOne(fsTokens: seq[FSNode], pos: var int): seq[NwtNode] =
    let fsToken = fsTokens[pos]

    case fsToken.kind
    # Complex Types
    of FSif: return parseSsIf(fsTokens, pos)
    of FsWhile: return parseSsWhile(fsTokens, pos)
    of FsFor: return parseSsFor(fsTokens, pos)
    of FsBlock: return parseSsBlock(fsTokens, pos)

    # Simple Types
    of FsStr: return NwtNode(kind: NStr, strBody: fsToken.value)
    of FsVariable: return NwtNode(kind: NVariable, variableBody: fsToken.value)
    of FsEval: return NwtNode(kind: NEval, evalBody: fsToken.value)
    of FsExtends: return parseSsExtends(fsTokens, pos)
    of FsImport: includeNwt(result, fsToken.value)
    else: echo "[SS] NOT IMPL: ", fsToken

proc parseSecondStep(fsTokens: seq[FSNode], pos: var int): seq[NwtNode] =
  while pos < fsTokens.len:
    result &= parseSecondStepOne(fsTokens, pos)
    pos.inc # skip the current elem

func astVariable(token: NwtNode): NimNode =
  return nnkStmtList.newTree(
    nnkInfix.newTree(
      newIdentNode("&="),
      newIdentNode("result"),
      newCall(
        "$",
        parseStmt(token.variableBody)
      )
    )
  )

func astStr(token: NwtNode): NimNode =
  return nnkStmtList.newTree(
    nnkInfix.newTree(
      newIdentNode("&="),
      newIdentNode("result"),
      newStrLitNode(token.strBody)
    )
  )

func astEval(token: NwtNode): NimNode =
  return parseStmt(token.evalBody)

func astComment(token: NwtNode): NimNode =
  return newCommentStmtNode(token.commentBody)

proc astFor(token: NwtNode): NimNode =
  let easyFor = "for " & token.forStmt & ": discard" # `discard` to make a parsable construct
  result = parseStmt(easyFor)
  result[0][2] = newStmtList(astAst(token.forBody)) # overwrite discard with real `for` body

proc astWhile(token: NwtNode): NimNode =
  nnkStmtList.newTree(
    nnkWhileStmt.newTree(
      parseStmt(token.whileStmt),
      nnkStmtList.newTree(
        astAst(token.whileBody)
      )
    )
  )


proc astIf(token: NwtNode): NimNode =
  result = nnkIfStmt.newTree()

  # Add the then node
  result.add:
    nnkElifBranch.newTree(
      parseStmt(token.ifStmt),
      nnkStmtList.newTree(
        astAst(token.nnThen)
      )
    )

  ## Add the elif nodes
  for elifToken in token.nnElif:
    result.add:
      nnkElifBranch.newTree(
        parseStmt(elifToken.elifStmt),
        nnkStmtList.newTree(
          astAst(elifToken.elifBody)
        )
      )

  # Add the else node
  if token.nnElse.len > 0:
    result.add:
      nnkElse.newTree(
        nnkStmtList.newTree(
          astAst(token.nnElse)
        )
      )


proc astAstOne(token: NwtNode): NimNode =
  case token.kind
  of NVariable: return astVariable(token)
  of NStr: return astStr(token)
  of NEval: return astEval(token)
  of NComment: return astComment(token)
  of NIf: return astIf(token)
  of NFor: return astFor(token)
  of NWhile: return astWhile(token)
  of NExtends: return parseStmt("discard")
  of NBlock: return parseStmt("discard")
  else: raise newException(ValueError, "cannot convert to ast:" & $token.kind)

proc astAst(tokens: seq[NwtNode]): seq[NimNode] =
  for token in tokens:
    result.add astAstOne(token)

proc parse*(str: string): seq[NwtNode] =
  ## The nimja parser.
  ##
  ## Generates NwtNodes from template strings
  ## These can later be compiled or dynamically evaluated.
  # TODO extend must be the first token, but
  # comments can come before extend (for documentation purpose)
  var lexerTokens = toSeq(nwtTokenize(str))
  var firstStepTokens = parseFirstStep(lexerTokens)
  var pos = 0
  var secondsStepTokens = parseSecondStep(firstStepTokens, pos)
  when defined(dumpNwtAst): echo secondsStepTokens
  if secondsStepTokens[0].kind == NExtends:
    # echo "===== THIS TEMPLATE EXTENDS ====="
    # Load master template
    let masterStr = staticRead( getScriptDir() / secondsStepTokens[0].extendsPath)
    var masterLexerTokens = toSeq(nwtTokenize(masterStr))
    var masterFirstStepTokens = parseFirstStep(masterLexerTokens)
    var masterPos = 0
    var masterSecondsStepTokens = parseSecondStep(masterFirstStepTokens, masterPos)

    # Load THIS template (above)
    var toRender: seq[NwtNode] = @[]
    for masterSecondsStepToken in masterSecondsStepTokens:
      if masterSecondsStepToken.kind == NBlock:
        ## search the other template and put the stuff in toRender
        var found = false
        for secondsStepToken in secondsStepTokens[1..^1]:
          if secondsStepToken.kind == NExtends: raise newException(ValueError, "only one extend is allowed!")
          if secondsStepToken.kind == NBlock and secondsStepToken.blockName == masterSecondsStepToken.blockName:
            found = true
            for blockToken in secondsStepToken.blockBody:
              toRender.add blockToken
        if found == false:
          # not overwritten; render the block
          for blockToken in masterSecondsStepToken.blockBody:
            toRender.add blockToken
      else:
        toRender.add masterSecondsStepToken
    return toRender
  else:
    var toRender: seq[NwtNode] = @[]
    for token in secondsStepTokens:
      if token.kind == NBlock:
        for blockToken in token.blockBody:
          toRender.add blockToken
      else:
        toRender.add token
    return toRender


macro compileTemplateStr*(str: typed): untyped =
  ## Compiles a nimja template from a string.
  ##
  ## .. code-block:: Nim
  ##  proc yourFunc(yourParams: bool): string =
  ##    compileTemplateString("{%if yourParams%}TRUE{%endif%}")
  ##
  ##  echo yourFunc(true)
  ##
  let nwtNodes = parse(str.strVal)
  when defined(dumpNwtAst): echo nwtNodes
  when defined(dumpNwtAstPretty): echo nwtNodes.pretty
  result = newStmtList()
  for nwtNode in nwtNodes:
    result.add astAstOne(nwtNode)
  when defined(dumpNwtMacro): echo toStrLit(result)

macro compileTemplateFile*(path: static string): untyped =
  ## Compiles a nimja template from a file.
  ##
  ## .. code-block:: nim
  ##  proc yourFunc(yourParams: bool): string =
  ##    compileTemplateFile(getScriptDir() / "relative/path.nwt")
  ##
  ##  echo yourFunc(true)
  ##
  let str = staticRead(path)
  let nwtNodes = parse(str)
  when defined(dumpNwtAst): echo nwtNodes
  when defined(dumpNwtAstPretty): echo nwtNodes.pretty
  result = newStmtList()
  for nwtNode in nwtNodes:
    result.add astAstOne(nwtNode)
  when defined(dumpNwtMacro): echo toStrLit(result)

# # #################################################
# # Dynamic
# # #################################################
# https://github.com/haxscramper/hack/blob/master/testing/nim/compilerapi/nims_template.nim#L71
# https://github.com/haxscramper/hack/blob/d2324554cff3d9c3401715700e67383bb4474771/testing/nim/compilerapi/nims_template.nim#L62
include compiler/passes
import
  compiler/[
    nimeval, ast, astalgo, pathutils, vm, scriptconfig,
    modulegraphs, options, idents, condsyms, sem, modules, llstream,
    lineinfos, astalgo, msgs, parser, idgen, vmdef, #passes
  ]
import hnimast/hast_common ## haxscramper


var
  conf = newConfigRef()
  cache = newIdentCache()
  graph = newModuleGraph(cache, conf)

let stdlib = findNimStdLibCompileTime()
conf.libpath = AbsoluteDir stdlib

for p in @[
    stdlib,
    stdlib / "pure",
    stdlib / "core",
    stdlib / "pure" / "collections"
  ]:
  conf.searchPaths.add(AbsoluteDir p)

conf.cmd = cmdInteractive
conf.errorMax = high(int)
conf.structuredErrorHook =
  proc (config: ConfigRef; info: TLineInfo; msg: string; severity: Severity) =
    # assert false, &"{info.line}:{info.col} {msg}" # TODO?
    echo "TODO"

initDefines(conf.symbols)

defineSymbol(conf.symbols, "nimscript")
defineSymbol(conf.symbols, "nimconfig")

registerPass(graph, semPass)
registerPass(graph, evalPass)

var module = graph.makeModule(AbsoluteFile"scriptname.nim")
incl(module.flags, sfMainModule)
graph.vm = setupVM(module, cache, "scriptname.nim", graph)
graph.compileSystemModule()


# graph.vm.PEvalContext().registerCallback(
#   "customProc",
#   proc(args: VmArgs) =
#     echo "Called custom proc with arg [", args.getString(0), "]"
# )


proc processModule3(graph: ModuleGraph; module: PSym, n: PNode) =
  var a: TPassContextArray
  openPasses(graph, a, module)
  discard processTopLevelStmt(graph, n, a)
  closePasses(graph, a)

proc processModule4(node: PNode) =
  # uses globals
  var passContextArray: TPassContextArray
  openPasses(graph, passContextArray, module)
  discard processTopLevelStmt(graph, node, passContextArray)
  # echo repr a
  closePasses(graph, passContextArray)

proc getIdent(graph: ModuleGraph, name: string): PNode =
  newIdentNode(graph.cache.getIdent(name), TLineInfo())

proc empty(): PNode = nkEmpty.newTree()

# import hnimast
# import dynamic
# processModule3(nkCall.newTree(
#     graph.newIdent("echo"),
#     newStrNode(nkStrLit, "SSSSSSSSSSSSS"))))

###################################################
proc foo*(str: string): string =
  # var res = ""
  # processModule4(
  #   # nkCall.newTree(graph.newIdent("echo"), newStrNode(nkStrLit, str))
  #   # nkCall.newTree(graph.newIdent("&="), graph.newIdent("res") ,newStrNode(nkStrLit, str))
  #   nkCall.newTree(graph.newIdent("return"), newStrNode(nkStrLit, str))
  # )
  # return res
  var res = ""
  graph.vm.PEvalContext().registerCallback(
    "customProc",
    proc(args: VmArgs) =
      echo "Called custom proc with arg [", args.getString(0), "]"
      res = args.getString(0)
  )

  processModule4(
    nkStmtList.newTree(
      nkProcDef.newTree(
        graph.getIdent("customProc"),
        empty(),
        empty(),
        nkFormalParams.newTree(
          empty(),
          nkIdentDefs.newTree(graph.getIdent("arg"), graph.getIdent("string"), empty())),
        empty(),
        empty(),
        nkStmtList.newTree(nkDiscardStmt.newTree(empty()))),
    nkCall.newTree(graph.getIdent("customProc"), newStrNode(nkStrLit, "SSSSSSSSSSSSS"))))

  return res

  ## Dynamically evaluates your template,
  ## good for development withouth recompilation.
  ## When you're done, compile your templates for more speed.
  ##
  ## Dynamic evaluation uses the Nim Compilers VM for expanding your template.
  ##
  # discard
  # let stdlib = findNimStdLibCompileTime()
  # echo stdlib
  # var inter = createInterpreter(
  #   """C:\Users\david\projects\nimja\examples\fromReadme\dyn.nims""",
  #   [
  #     stdlib,
  #     $toAbsoluteDir("./"),
  #     """C:\Users\david\projects\nimja\src""",
  #     stdlib / "pure",
  #     stdlib / "core",
  #     stdlib / "pure/collections"
  #   ],
  #   defines = @[("nimscript", "true"), ("nimconfig", "true")],
  #   registerOps = true
# proc conv[N](ast: NwtNode): N =
#   case ast.kind:
#     of NIf:
#       result = newIf[N](
#         conv[N](ast.ifStmt),
#         conv[N](ast.nnThen),
#         conv[N](ast.nnElse))

#     of NStr:
#       result = newNLit[N, string](ast.strBody)

#     else:
#       discard
# #     of # ...

# proc compileTemplate*[N: NimNode | PNode](code: string): N =
#   result = newStmtList()
#   let asts: seq[NwtNode] = parse(code)
#   for ast in asts:
#     result.add conv[N](ast)

# # macro compileTemplateStr(str: static[string]): untyped =
#   ## Compile template to the nim node
#   # for compileTemplate[NimNode](str)

# # proc evalTemplateRuntime(str: string) =
# #   ## Evaluate template in the vm
# #   processModule(graph, m, compileTemplate[PNode](str))

# # # proc codegenTemplate(str: string): string =
# # #   ## Generate code for template
# # #   $compileTemplate[PNode](str)
