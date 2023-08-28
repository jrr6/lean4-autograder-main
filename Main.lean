import Lean
-- import Mathlib -- ensures Mathlib is compiled when the container is being uploaded
open Lean IO System Elab Command

-- Attribute for point values
syntax (name := problem) scientific "points" : attr
initialize problemAttr : ParametricAttribute Float ←
  registerParametricAttribute {
    name := `problem
    descr := "specify a point value of a problem"
    -- applicationTime := .afterCompilation
    getParam := λ _ stx => match stx with
      | `(attr| $pts:scientific points) => 
        let (n, s, d) := pts.getScientific
        return Float.ofScientific n s d
      | _  => throwError "invalid problem attribute"
    afterSet := λ _ _ => do pure ()
  }

structure ExerciseResult where
  score : Float
  name : Name
  status : String
  output : String
  deriving ToJson

structure GradingResults where
  tests : Array ExerciseResult
  deriving ToJson

def Lean.Environment.moduleDataOf? (module : Name) (env : Environment) : Option ModuleData := do
  let modIdx : Nat ← env.getModuleIdx? module
  env.header.moduleData[modIdx]?

def Lean.Environment.moduleOfDecl? (decl : Name) (env : Environment) : Option Name := do
  let modIdx : Nat ← env.getModuleIdxFor? decl
  env.header.moduleNames[modIdx]?

def validAxioms : Array Name := #["Classical.choice".toName, "Quot.sound".toName, "propext".toName] 

def usedAxiomsAreValid (submissionAxioms : List Name) : Bool := 
  match submissionAxioms with 
  | [] => true
  | x :: xs => if validAxioms.contains x then usedAxiomsAreValid xs else false

def gradeSubmission (sheetName : Name) (sheet submission : Environment) : IO (Array ExerciseResult) := do
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
            pure { name, status := "failed", output := "Proof contains sorry", score := 0.0 }
          else
            if not (constInfo.type == subConstInfo.type) then
              pure { name, status := "failed", output := "Type is different than expected", score := 0.0 }
            else
              let (_, submissionState) := ((CollectAxioms.collect name).run submission).run {}
              if usedAxiomsAreValid submissionState.axioms.toList 
                then pure { name, status := "passed", score := pts, output := "Passed all tests" }
              else 
                pure { name, status := "failed", output := "Contains unexpected axioms", score := 0.0 }
        else
          pure { name, status := "failed", output := "Declaration not found in submission", score := 0.0 }
      results := results.push result

  -- TODO: do we actually need this?
  if results.size == 0 then  
    throw <| IO.userError "There are no exercises annotated with points in the template; thus, the submission can't be graded."
  return results

def main (args : List String) : IO Unit := do
  let usage := throw <| IO.userError s!"Usage: autograder Exercise.Sheet.Module submission-file.lean"
  let [sheetName, submission] := args | usage
  let submission : FilePath := submission
  let some sheetName := Syntax.decodeNameLit ("`" ++ sheetName) | usage
  searchPathRef.set (← addSearchPathFromEnv {})
  let sheet ← importModules [{module := sheetName}] {}
  let submissionBuildDir : FilePath := "build" / "submission"
  FS.createDirAll submissionBuildDir
  let submissionOlean := submissionBuildDir / "Submission.olean"
  if ← submissionOlean.pathExists then FS.removeFile submissionOlean
  let mut errors := #[]
  let submissionEnv ←
    try
      let out ← IO.Process.output {
        cmd := "lean"
        args := #[submission.toString, "-o", submissionOlean.toString]
      }
      if out.exitCode != 0 then
        let result : ExerciseResult := { name := toString submission, status := "failed", output := out.stderr , score := 0.0 }
        let results : GradingResults := { tests := #[result] }
        IO.FS.writeFile "../results/results.json" (toJson results).pretty
        throw <| IO.userError s!"Lean exited with code {out.exitCode}:\n{out.stderr}"
      searchPathRef.modify fun sp => submissionBuildDir :: sp
      importModules [{module := `Submission}] {}
    catch ex =>
      errors := errors.push ex.toString
      importModules sheet.header.imports.toList {}
  let tests ← gradeSubmission sheetName sheet submissionEnv
  let results : GradingResults := { tests }
  if errors.size == 0 then
    IO.FS.writeFile "../results/results.json" (toJson results).pretty
