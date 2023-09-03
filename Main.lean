import Lean
import AutograderLib
-- Ensures Mathlib is compiled when the container is being uploaded:
-- import Mathlib
open Lean IO System Elab Command

def agPkgPathPrefix : FilePath := "lake-packages" / "autograder"
def solutionDirName := "AutograderTests"
def solutionModuleName := "Solution"
def submissionFileName := "Assignment.lean"
def submissionUploadDir : FilePath := "/autograder/submission"

-- Used for non-exercise-specific results (e.g., global failures)
structure FailureResult where
  output : String
  score : Float := 0.0
  output_format : String := "text"
  deriving ToJson

structure ExerciseResult where
  score : Float
  output : String
  name : Name
  status : String
  deriving ToJson

structure GradingResults where
  tests : Array ExerciseResult
  output: String
  output_format: String := "text"
  deriving ToJson

def Lean.Environment.moduleDataOf? (module : Name) (env : Environment)
  : Option ModuleData := do
  let modIdx : Nat ← env.getModuleIdx? module
  env.header.moduleData[modIdx]?

def Lean.Environment.moduleOfDecl? (decl : Name) (env : Environment)
  : Option Name := do
  let modIdx : Nat ← env.getModuleIdxFor? decl
  env.header.moduleNames[modIdx]?

def validAxioms : Array Name :=
  #["Classical.choice".toName,
    "Quot.sound".toName,
    "propext".toName,
    "funext".toName] 

def usedAxiomsAreValid (submissionAxioms : List Name) : Bool := 
  match submissionAxioms with 
  | [] => true
  | x :: xs => if validAxioms.contains x then usedAxiomsAreValid xs else false

def escapeHtml (s : String) :=
  [("<", "&lt;"), (">", "&gt;"), ("&", "&amp;"), ("\"", "&quot;")].foldl
    (λ acc (char, repl) => acc.replace char repl) s

def gradeSubmission (sheetName : Name) (sheet submission : Environment)
  : IO (Array ExerciseResult) := do
  let some sheetMod := sheet.moduleDataOf? sheetName
    | throw <| IO.userError s!"module name {sheetName} not found"
  let mut results := #[]

  for name in sheetMod.constNames, constInfo in sheetMod.constants do
    -- Only consider annotated, non-internal declarations
    if let some pts := problemAttr.getParam? sheet name then
    if not name.isInternal then
      let result ←
        -- exercise to be filled in
        if let some subConstInfo := submission.find? name then
          if subConstInfo.value?.any (·.hasSorry) then
            pure { name,
                   status := "failed",
                   output := "Proof contains sorry",
                   score := 0.0 }
          else
            if not (constInfo.type == subConstInfo.type) then
              pure { name,
                     status := "failed",
                     output := "Type is different than expected",
                     score := 0.0 }
            else
              let (_, submissionState) :=
                ((CollectAxioms.collect name).run submission).run {}
              if usedAxiomsAreValid submissionState.axioms.toList 
                then pure { name,
                            status := "passed",
                            score := pts,
                            output := "Passed all tests" }
              else 
                pure { name,
                       status := "failed",
                       output := "Contains unexpected axioms",
                       score := 0.0 }
        else
          pure { name,
                 status := "failed",
                 output := "Declaration not found in submission",
                 score := 0.0 }
      results := results.push result

  -- Gradescope will not accept an empty tests list, and this most likely
  -- indicates a misconfiguration anyway
  if results.size == 0 then
    throw <| IO.userError <|
      "There are no exercises annotated with points in the template, so the "
        ++ "submission can't be graded."
  return results

-- Throw error and show it to the student
def exitWithError (errMsg : String) : IO Unit := do
  let resultsPath : FilePath := ".." / "results" / "results.json"
  let result : FailureResult := {output := errMsg}
  IO.FS.writeFile resultsPath (toJson result).pretty
  throw <| IO.userError errMsg

-- Returns a tuple of (fileName, outputMessage)
def moveFilesIntoPlace : IO (String × String) := do
  -- Copy the assignment's config file to the autograder directory
  IO.FS.writeFile (agPkgPathPrefix / "autograder_config.json")
      (← IO.FS.readFile "config.json")

  -- Copy the student's submission to the autograder directory. They should only
  -- have uploaded one Lean file; if they submitted more, we pick the first
  let submittedFiles ← submissionUploadDir.readDir
  let leanFiles := submittedFiles.filter
    (λ f => f.path.extension == some "lean")
  let leanFile? := submittedFiles.get? (i := 0)
  if let some leanFile := leanFile? then
    IO.FS.writeFile submissionFileName (← IO.FS.readFile leanFile.path)
    let output :=
      if leanFiles.size > 1
      then "Warning: You submitted multiple Lean files. The autograder expects "
        ++ "you to submit a single Lean file containing your solutions, and it "
        ++ s!"will only grade a single file. It has picked {leanFile.fileName} "
        ++ "to grade; this may not be the file you intended to be graded.\n\n"
      else ""
    pure (leanFile.fileName, output)
  else
    exitWithError <| "No Lean file was found in your submission. Make sure to "
        ++ "upload a single .lean file containing your solutions."
    pure ("", "") 
  

def getTemplateFromGitHub : IO Unit := do
  -- Read JSON config
  let configRaw ← IO.FS.readFile (agPkgPathPrefix / "autograder_config.json")
  let config ← IO.ofExcept <| Json.parse configRaw
  let templateFile : FilePath :=
    agPkgPathPrefix / solutionDirName / s!"{solutionModuleName}.lean"
  if ← templateFile.pathExists then FS.removeFile templateFile
  let repoURLPath ← IO.ofExcept <| config.getObjValAs? String "public_repo"
  let some repoName := (repoURLPath.splitOn "/").getLast? 
    | throw <|
      IO.userError "Invalid public_repo found in autograder_config.json"
  
  -- Download the repo
  let repoLocalPath : FilePath := agPkgPathPrefix / repoName
  let out ← IO.Process.output {
    cmd := "git"
    args := #["clone", s!"https://github.com/{repoURLPath}",
              repoLocalPath.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"Failed to download public repo from GitHub"
  
  -- Move the assignment to the correct location; delete the cloned repo
  let assignmentPath ← IO.ofExcept <|
    config.getObjValAs? String "assignment_path"
  let curAsgnFilePath : FilePath := agPkgPathPrefix / repoName / assignmentPath
  IO.FS.rename curAsgnFilePath templateFile
  IO.FS.removeDirAll repoLocalPath

def compileAutograder : IO Unit := do
  -- Check that the template compiles sans student submission
  let compileArgs : Process.SpawnArgs := {
    cmd := "/root/.elan/bin/lake"
    args := #["build", "autograder", solutionDirName]
  }
  let out ← IO.Process.output compileArgs
  if out.exitCode != 0 then
    exitWithError <|
      "The autograder failed to compile itself. This is unexpected. Please let "
        ++ "your instructor know and provide a link to this Gradescope "
        ++ "submission."

def getErrorsStr (ml : MessageLog) : IO String := do
  let errorMsgs := ml.msgs.filter (λ m => m.severity == .error)
  let errors ← errorMsgs.mapM (λ m => m.toString)
  let errorTxt := errors.foldl (λ acc e => acc ++ "\n" ++ e) ""
  return errorTxt

def main : IO Unit := do
  -- Get files into their appropriate locations
  let (studentFileName, output) ← moveFilesIntoPlace
  getTemplateFromGitHub
  compileAutograder

  -- Import the template (as a module, since it is known to compile)
  let sheetName := s!"{solutionDirName}.{solutionModuleName}".toName
  searchPathRef.set (← addSearchPathFromEnv {})
  let sheet ← importModules [{module := sheetName}] {}

  -- Grade the student submission
  -- Source: https://github.com/adamtopaz/lean_grader/blob/master/Main.lean
  let submissionContents ← IO.FS.readFile submissionFileName
  let inputCtx := Parser.mkInputContext submissionContents studentFileName
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let (headerEnv, messages) ← processHeader header {} messages inputCtx

  if messages.hasErrors then
    exitWithError <|
      "Your Lean file could not be processed because its header contains "
      ++ "errors. This is likely because you are attempting to import a module "
      ++ "that does not exist. A log of these errors is provided below; please "
      ++ "correct them and resubmit:\n\n"
      ++ (← getErrorsStr messages)

  let cmdState : Command.State := Command.mkState headerEnv messages {}
  let frontEndState ← IO.processCommands inputCtx parserState cmdState
  let messages := frontEndState.commandState.messages
  let submissionEnv := frontEndState.commandState.env

  let output := output ++
    if messages.hasErrors
    then "Warning: Your submission contains one or more errors, which are "
          ++ "listed below. You should attempt to correct these errors prior "
          ++ "to your final submission. Any responses with errors will be "
          ++ "treated by the autograder as containing \"sorry.\"\n"
          ++ (← getErrorsStr messages)
    else ""
  
  -- Provide debug info for staff
  IO.println "Submission compilation output:\n"
  let os ← messages.toList.mapM (λ m => m.toString)
  IO.println <| os.foldl (·++·) ""

  let tests ← gradeSubmission sheetName sheet submissionEnv
  let results : GradingResults := { tests, output }
  IO.FS.writeFile "../results/results.json" (toJson results).pretty
