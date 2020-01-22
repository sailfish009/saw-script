{- |
Module      : SAWScript.Crucible.LLVM.X86
Description : Implements a SAWScript primitive for verifying x86_64 functions
              against LLVM specifications.
Maintainer  : sbreese
Stability   : provisional
-}

{-# Language OverloadedStrings #-}
{-# Language FlexibleContexts #-}
{-# Language ScopedTypeVariables #-}
{-# Language TypeOperators #-}
{-# Language PatternSynonyms #-}
{-# Language LambdaCase #-}
{-# Language TupleSections #-}
{-# Language ImplicitParams #-}
{-# Language TypeApplications #-}
{-# Language GADTs #-}
{-# Language DataKinds #-}

module SAWScript.Crucible.LLVM.X86
  ( crucible_llvm_verify_x86
  ) where

import System.IO (stdout)

import Control.Exception (catch)
import Control.Lens (view, (^.))
import Control.Monad.ST (stToIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (execStateT)

import Data.Type.Equality ((:~:)(..), testEquality)
import Data.Foldable (foldlM, forM_)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Map as Map
import Data.Map (Map)

import qualified Text.LLVM.AST as LLVM

import Data.Parameterized.Some (Some(..))
import Data.Parameterized.NatRepr (knownNat)
import Data.Parameterized.Context (EmptyCtx, (::>), singleton)
import Data.Parameterized.Nonce (globalNonceGenerator)
import qualified Data.Parameterized.Context as Ctx

import SAWScript.Prover.SBV
import SAWScript.Prover.SolverStats
import SAWScript.TopLevel
import SAWScript.Value
import SAWScript.Options
import SAWScript.X86
  ( RelevantElf(..), X86Error(..)
  , findSymbol, getElf, getGoals, getRelevant, gGoal, loadGlobal, posFn
  )
import SAWScript.X86Spec
  ( Sym, Unit(..)
  , freshRegister, mkGlobalMap
  )

import qualified SAWScript.Crucible.Common.MethodSpec as MS
import qualified SAWScript.Crucible.Common.Setup.Type as Setup

import SAWScript.Crucible.LLVM.Builtins
  ( displayVerifExceptionOpts, findDecl, setupLLVMCrucibleContext
  )
import SAWScript.Crucible.LLVM.MethodSpecIR
import SAWScript.Crucible.LLVM.ResolveSetupValue
  ( resolveSetupVal, typeOfSetupValue
  )

import Verifier.SAW.SharedTerm

import qualified What4.Expr as W4
import qualified What4.FunctionName as W4
import qualified What4.Interface as W4
import qualified What4.ProgramLoc as W4

import qualified Lang.Crucible.Analysis.Postdom as C
import qualified Lang.Crucible.Backend as C
import qualified Lang.Crucible.Backend.SAWCore as C
import qualified Lang.Crucible.CFG.Core as C
import qualified Lang.Crucible.FunctionHandle as C
import qualified Lang.Crucible.Simulator.EvalStmt as C
import qualified Lang.Crucible.Simulator.ExecutionTree as C
import qualified Lang.Crucible.Simulator.GlobalState as C
import qualified Lang.Crucible.Simulator.Operations as C
import qualified Lang.Crucible.Simulator.OverrideSim as C
import qualified Lang.Crucible.Simulator.RegMap as C
import qualified Lang.Crucible.Simulator.SimError as C

import qualified Lang.Crucible.LLVM.Bytes as C.LLVM
import qualified Lang.Crucible.LLVM.DataLayout as C.LLVM
import qualified Lang.Crucible.LLVM.Extension as C.LLVM
import qualified Lang.Crucible.LLVM.Intrinsics as C.LLVM
import qualified Lang.Crucible.LLVM.MemModel as C.LLVM
import qualified Lang.Crucible.LLVM.MemType as C.LLVM
import qualified Lang.Crucible.LLVM.Translation as C.LLVM
import qualified Lang.Crucible.LLVM.TypeContext as C.LLVM

import qualified Data.Macaw.Types as Macaw
import qualified Data.Macaw.Discovery as Macaw
import qualified Data.Macaw.Memory as Macaw
import qualified Data.Macaw.Symbolic as Macaw
import qualified Data.Macaw.Symbolic.Backend as Macaw
import qualified Data.Macaw.X86.Symbolic as Macaw
import qualified Data.Macaw.X86 as Macaw
import qualified Data.Macaw.X86.X86Reg as Macaw

-- | Verify that an x86_64 function (following the System V AMD64 ABI) conforms
-- to an LLVM specification. This allows for compositional verification of LLVM
-- functions that call x86_64 functions (but not the other way around).
crucible_llvm_verify_x86 ::
  BuiltinContext ->
  Options ->
  Some LLVMModule {- ^ Module to associate with method spec -} ->
  FilePath {- ^ Path to ELF file -} ->
  String {- ^ Function's symbol in ELF file -} ->
  [(String, Integer)] {- ^ Global variable symbol names and sizes (in bytes) -} ->
  LLVMCrucibleSetupM () {- ^ Specification to verify against -} ->
  TopLevel (SomeLLVM MS.CrucibleMethodSpecIR)
crucible_llvm_verify_x86 bic opts (Some (llvmModule :: LLVMModule x)) path nm globsyms setup
  | Just Refl <- testEquality (C.LLVM.X86Repr $ knownNat @64) . C.LLVM.llvmArch
                 $ llvmModule ^. modTrans . C.LLVM.transContext = do
      let sc = biSharedContext bic
      sym <- liftIO $ C.newSAWCoreBackend W4.FloatRealRepr sc globalNonceGenerator
      halloc <- getHandleAlloc
      mvar <- liftIO $ C.LLVM.mkMemVar halloc
      sfs <- liftIO $ Macaw.newSymFuns sym

      (C.SomeCFG cfg, elf, addr) <- liftIO $ buildCFG opts halloc path nm
      addrInt <- if Macaw.segmentBase (Macaw.segoffSegment addr) == 0
        then pure . toInteger $ Macaw.segmentOffset (Macaw.segoffSegment addr) + Macaw.segoffOffset addr
        else fail $ mconcat ["Address of \"", nm, "\" is not an absolute address"]
      let maxAddr = addrInt + toInteger (Macaw.segmentSize $ Macaw.segoffSegment addr)

      let
        cc :: LLVMCrucibleContext x
        cc = LLVMCrucibleContext
             { _ccLLVMModule = llvmModule
             , _ccBackend = sym
             , _ccBasicSS = biBasicSS bic

             -- It's unpleasant that we need to do this to use resolveSetupVal.
             , _ccLLVMSimContext = error "Attempted to access ccLLVMSimContext"
             , _ccLLVMGlobals = error "Attempted to access ccLLVMGlobals"
             }

      liftIO $ printOutLn opts Info "Examining specification to determine preconditions"
      methodSpec <- buildMethodSpec bic opts llvmModule nm (show addr) setup
      (globs :: Macaw.GlobalMap Sym 64, mem, regs, env) <-
        liftIO $ initialMemory sym elf cc maxAddr globsyms methodSpec

      let
        ctx :: C.SimContext (Macaw.MacawSimulatorState Sym) Sym (Macaw.MacawExt Macaw.X86_64)
        ctx = C.SimContext
              { C._ctxSymInterface = sym
              , C.ctxSolverProof = id
              , C.ctxIntrinsicTypes = C.LLVM.llvmIntrinsicTypes
              , C.simHandleAllocator = halloc
              , C.printHandle = stdout
              , C.extensionImpl =
                Macaw.macawExtensions (Macaw.x86_64MacawEvalFn sfs) mvar globs
                $ Macaw.LookupFunctionHandle $ \_ _ _ ->
                  fail "Attempted to call a function during x86 verification"
              , C._functionBindings =
                C.insertHandleMap (C.cfgHandle cfg) (C.UseCFG cfg $ C.postdomInfo cfg) C.emptyHandleMap
              , C._cruciblePersonality = Macaw.MacawSimulatorState
              , C._profilingMetrics = Map.empty
              }
        globals = C.insertGlobal mvar mem C.emptyGlobals
        macawStructRepr = C.StructRepr $ Macaw.crucArchRegTypes Macaw.x86_64MacawSymbolicFns
        initial = C.InitialState ctx globals C.defaultAbortHandler macawStructRepr
                  $ C.runOverrideSim macawStructRepr
                  $ Macaw.crucGenArchConstraints Macaw.x86_64MacawSymbolicFns
                  $ do r <- C.callCFG cfg $ C.RegMap $ singleton $ C.RegEntry macawStructRepr regs
                       mem' <- C.readGlobal mvar
                       liftIO $ printOutLn opts Info
                         "Examining specification to determine postconditions"
                       liftIO $ assertPost sym cc env methodSpec (mem, mem') (regs, C.regValue r)
                       pure $ C.regValue r

      liftIO $ printOutLn opts Info "Simulating function"
      liftIO $ C.executeCrucible [] initial >>= \case
        C.FinishedResult{} -> pure ()
        C.AbortedResult{} -> printOutLn opts Warn "Warning: function never returns"
        C.TimeoutResult{} -> fail "Execution timed out"

      liftIO $ checkGoals sym opts sc
 
      pure $ SomeLLVM methodSpec
  | otherwise = fail "LLVM module must be 64-bit"

--------------------------------------------------------------------------------
-- ** Computing the CFG

-- | Load the given ELF file and use Macaw to construct a Crucible CFG.
buildCFG ::
  Options ->
  C.HandleAllocator ->
  String {- ^ Path to ELF file -} ->
  String {- ^ Function's symbol in ELF file -} ->
  IO ( C.SomeCFG
       (Macaw.MacawExt Macaw.X86_64)
       (EmptyCtx ::> Macaw.ArchRegStruct Macaw.X86_64)
       (Macaw.ArchRegStruct Macaw.X86_64)
     , RelevantElf
     , Macaw.MemSegmentOff 64
     )
buildCFG opts halloc path nm = do
  printOutLn opts Info $ mconcat ["Finding symbol for \"", nm, "\""]
  elf <- getElf path >>= getRelevant
  (addr :: Macaw.MemSegmentOff 64) <- findSymbol (symMap elf) . encodeUtf8 $ Text.pack nm
  printOutLn opts Info $ mconcat ["Found symbol at address ", show addr, ", building CFG"]
  (_, Some finfo) <- stToIO . Macaw.analyzeFunction (const $ pure ()) addr Macaw.UserRequest
    $ Macaw.emptyDiscoveryState (memory elf) (funSymMap elf) Macaw.x86_64_linux_info
  scfg <- Macaw.mkFunCFG Macaw.x86_64MacawSymbolicFns halloc (W4.functionNameFromText $ Text.pack nm) posFn finfo
  pure (scfg, elf, addr)


--------------------------------------------------------------------------------
-- ** Computing the specification

-- | Construct the method spec like we normally would in crucible_llvm_verify.
-- Unlike in crucible_llvm_verify, we can't reuse the simulator state (due to the
-- different memory layout / RegMap).
buildMethodSpec ::
  BuiltinContext ->
  Options ->
  LLVMModule LLVMArch ->
  String {- ^ Name of method -} ->
  String {- ^ Source location for method spec (here, we use the address) -} ->
  LLVMCrucibleSetupM () ->
  TopLevel (MS.CrucibleMethodSpecIR LLVM)
buildMethodSpec bic opts lm nm loc setup =
  setupLLVMCrucibleContext bic opts lm $ \cc -> do
    let methodId = LLVMMethodId nm Nothing
    let programLoc = W4.mkProgramLoc (W4.functionNameFromText $ Text.pack nm) . W4.OtherPos $ Text.pack loc
    let LLVMModule _ _ mtrans = lm
    let lc = mtrans ^. C.LLVM.transContext . C.LLVM.llvmTypeCtx
    (args, ret) <- case llvmSignature opts lm nm of
      Left err -> fail $ mconcat ["Could not find declaration for \"", nm, "\": ", err]
      Right x -> pure x
    (mtargs, mtret) <- case (,) <$> mapM (llvmTypeToMemType lc) args <*> mapM (llvmTypeToMemType lc) ret of
      Left err -> fail err
      Right x -> pure x
    let initialMethodSpec = MS.makeCrucibleMethodSpecIR @(C.LLVM.LLVM (C.LLVM.X86 64)) methodId mtargs mtret programLoc lm
    view Setup.csMethodSpec <$> execStateT (runLLVMCrucibleSetupM setup) (Setup.makeCrucibleSetupState cc initialMethodSpec)

llvmTypeToMemType ::
  C.LLVM.TypeContext ->
  LLVM.Type ->
  Either String C.LLVM.MemType
llvmTypeToMemType lc t = let ?lc = lc in C.LLVM.liftMemType t

-- | Find a function declaration in the LLVM AST and return its signature.
llvmSignature ::
  Options ->
  LLVMModule LLVMArch ->
  String ->
  Either String ([LLVM.Type], Maybe LLVM.Type)
llvmSignature opts llvmModule nm =
  case findDecl (llvmModule ^. modAST) nm of
    Left err -> Left $ displayVerifExceptionOpts opts err
    Right decl -> pure
      ( LLVM.decArgs decl
      , case LLVM.decRetType decl of
          LLVM.PrimType LLVM.Void -> Nothing
          x -> Just x
      )

--------------------------------------------------------------------------------
-- ** Precondition

-- | Given the method spec, build the initial memory, register map, and global map.
initialMemory ::
  Sym ->
  RelevantElf ->
  LLVMCrucibleContext LLVMArch ->
  Integer {- ^ Minimum size of the global allocation (here, the end of the .text segment -} ->
  [(String, Integer)] {- ^ Global variable symbol names and sizes (in bytes) -} ->
  MS.CrucibleMethodSpecIR LLVM ->
  IO (Macaw.GlobalMap Sym 64, Mem, Regs, Map MS.AllocIndex Ptr)
initialMemory sym elf cc endText globsyms ms = do
  let ?ptrWidth = knownNat @64
  mem <- C.LLVM.emptyMem C.LLVM.LittleEndian
  regs <- Ctx.traverseWithIndex (freshRegister sym) C.knownRepr

  (globs, mem' ) <- setupGlobals sym elf mem endText globsyms

  -- Allocate a reasonable amount of stack (4 KiB + 1 qword for IP)
  (rsp, mem'') <- allocateStack sym mem' 4096
  regs' <- setReg Macaw.RSP rsp regs

  let tyenv = ms ^. MS.csPreState . MS.csAllocs
      nameEnv = MS.csTypeNames ms

  (env, mem''') <- foldlM (executeAllocation sym) (Map.empty, mem'') . Map.assocs
    $ tyenv

  mem'''' <- foldlM (executePointsTo sym cc env tyenv nameEnv) mem'''
    $ ms ^. MS.csPreState . MS.csPointsTos

  regs'' <- setArgs sym cc env tyenv nameEnv mem'''' regs' . fmap snd . Map.elems
    $ ms ^. MS.csArgBindings

  pure (globs, mem'''', regs'', env)

-- | Given an alist of symbol names and sizes (in bytes), allocate space and copy
-- the corresponding globals from the Macaw memory to the Crucible LLVM memory model.
setupGlobals ::
  Sym ->
  RelevantElf ->
  Mem ->
  Integer {- ^ Minimum size of the global allocation -} ->
  [(String, Integer)] {- ^ Global variable symbol names and sizes (in bytes) -} ->
  IO (Macaw.GlobalMap Sym 64, Mem)
setupGlobals sym elf mem endText globsyms = do
  let ?ptrWidth = knownNat @64
  globs <- mconcat <$> mapM readInitialGlobal globsyms
  sz <- W4.bvLit sym knownNat . maximum $ endText:(globalEnd <$> globs)
  (base, mem') <- C.LLVM.doMalloc sym C.LLVM.GlobalAlloc C.LLVM.Immutable "globals" mem sz C.LLVM.noAlignment
  mem'' <- foldlM (writeGlobal base) mem' globs
  pure (mkGlobalMap $ Map.singleton 0 base, mem'')
  where
    readInitialGlobal :: (String, Integer) -> IO [(String, Integer, [Integer])]
    readInitialGlobal (nm, sz) = do
      res <- loadGlobal elf (encodeUtf8 $ Text.pack nm, sz, Bytes)
      pure $ (\(n, a, _, b) -> (n, a, b)) <$> res
    globalEnd :: (String, Integer, [Integer]) -> Integer
    globalEnd (_nm, addr, bytes) = addr + toInteger (length bytes)
    writeByte :: Ptr -> Mem -> (Integer, Integer) -> IO Mem
    writeByte base m (addr, byte) = do
      let ?ptrWidth = knownNat @64
      ptr <- C.LLVM.doPtrAddOffset sym m base =<< W4.bvLit sym knownNat addr
      val <- C.LLVM.LLVMValInt <$> W4.natLit sym 0 <*> W4.bvLit sym (knownNat @8) byte
      C.LLVM.storeConstRaw sym m ptr (C.LLVM.bitvectorType 1) C.LLVM.noAlignment val
    writeGlobal :: Ptr -> Mem -> (String, Integer, [Integer]) -> IO Mem
    writeGlobal base m (_nm, addr, bytes) = foldlM (writeByte base) m $ zip [addr, addr+1..] bytes

-- | Allocate memory for the stack, and pushes a fresh pointer as the return
-- address. Note that this function only returns a pointer to the top-of-stack,
-- and does not set RSP.
allocateStack ::
  Sym ->
  Mem ->
  Integer {- ^ Stack size in bytes -} ->
  IO (Ptr, Mem)
allocateStack sym mem szInt = do
  let ?ptrWidth = knownNat @64
  sz <- W4.bvLit sym knownNat $ szInt + 8
  (base, mem') <- C.LLVM.doMalloc sym C.LLVM.HeapAlloc C.LLVM.Mutable "stack_alloc" mem sz C.LLVM.noAlignment
  sn <- case W4.userSymbol "stack" of
    Left err -> fail $ "Invalid symbol for stack: " <> show err
    Right sn -> pure sn
  fresh <- C.LLVM.LLVMPointer <$> W4.natLit sym 0 <*> W4.freshConstant sym sn (W4.BaseBVRepr $ knownNat @64)
  ptr <- C.LLVM.doPtrAddOffset sym mem' base =<< W4.bvLit sym knownNat szInt
  (ptr,) <$> C.LLVM.doStore sym mem' ptr (C.LLVM.LLVMPointerRepr $ knownNat @64) (C.LLVM.bitvectorType 8) C.LLVM.noAlignment fresh

-- | Process a crucible_alloc statement, allocating the requested memory and
-- associating a pointer to that memory with the appropriate index.
executeAllocation ::
  Sym ->
  ( Map MS.AllocIndex Ptr {- ^ Associates each previous AllocIndex with the corresponding allocation -}
  , Mem
  ) ->
  (MS.AllocIndex, LLVMAllocSpec) {- ^ crucible_alloc statement -} ->
  IO (Map MS.AllocIndex Ptr, Mem)
executeAllocation sym (env, mem) (i, LLVMAllocSpec mut _memTy sz loc) = do
  let ?ptrWidth = knownNat @64
  sz' <- liftIO $ W4.bvLit sym knownNat $ C.LLVM.bytesToInteger sz
  (ptr, mem') <- C.LLVM.doMalloc sym C.LLVM.HeapAlloc mut (show $ W4.plSourceLoc loc) mem sz' C.LLVM.noAlignment
  pure (Map.insert i ptr env, mem')

-- | Process a crucible_points_to statement, writing some SetupValue to a pointer.
executePointsTo ::
  Sym ->
  LLVMCrucibleContext LLVMArch ->
  Map MS.AllocIndex Ptr {- ^ Associates each AllocIndex with the corresponding allocation -} ->
  Map MS.AllocIndex LLVMAllocSpec {- ^ Associates each AllocIndex with its specification -} ->
  Map MS.AllocIndex C.LLVM.Ident {- ^ Associates each AllocIndex with its name -} ->
  Mem ->
  LLVMPointsTo LLVMArch {- ^ crucible_points_to statement from the precondition -} ->
  IO Mem
executePointsTo sym cc env tyenv nameEnv mem (LLVMPointsTo _ tptr tval) = do
  let ?ptrWidth = knownNat @64
  ptr <- C.LLVM.unpackMemValue sym (C.LLVM.LLVMPointerRepr $ knownNat @64)
    =<< resolveSetupVal cc mem env tyenv Map.empty tptr
  val <- resolveSetupVal cc mem env tyenv Map.empty tval
  storTy <- C.LLVM.toStorableType =<< typeOfSetupValue cc tyenv nameEnv tval
  C.LLVM.storeConstRaw sym mem ptr storTy C.LLVM.noAlignment val

-- | Write each SetupValue passed to crucible_execute_func to the appropriate
-- x86_64 register from the calling convention.
setArgs ::
  Sym ->
  LLVMCrucibleContext LLVMArch ->
  Map MS.AllocIndex Ptr {- ^ Associates each AllocIndex with the corresponding allocation -} ->
  Map MS.AllocIndex LLVMAllocSpec {- ^ Associates each AllocIndex with its specification -} ->
  Map MS.AllocIndex C.LLVM.Ident {- ^ Associates each AllocIndex with its name -} ->
  Mem ->
  Regs ->
  [MS.SetupValue LLVM] {- ^ Arguments passed to crucible_execute_func -} ->
  IO Regs
setArgs sym cc env tyenv nameEnv mem regs args
  | length args > length argRegs = fail "More arguments than would fit into registers"
  | otherwise = foldlM setRegSetupValue regs $ zip argRegs args
  where
    argRegs :: [Register]
    argRegs = [Macaw.RDI, Macaw.RSI, Macaw.RDX, Macaw.RCX, Macaw.R8, Macaw.R9]
    setRegSetupValue rs (reg, sval) = do
      let ?ptrWidth = knownNat @64
      val <- C.LLVM.unpackMemValue sym (C.LLVM.LLVMPointerRepr $ knownNat @64)
        =<< resolveSetupVal cc mem env tyenv nameEnv sval
      setReg reg val rs

--------------------------------------------------------------------------------
-- ** Postcondition

-- | Assert the postcondition for the spec, given the final memory and register map.
assertPost ::
  Sym ->
  LLVMCrucibleContext LLVMArch ->
  Map MS.AllocIndex Ptr ->
  MS.CrucibleMethodSpecIR LLVM ->
  (Mem, Mem) {- ^ The state of memory before and after simulation -} ->
  (Regs, Regs) {- ^ The state of the registers before and after simulation -} ->
  IO ()
assertPost sym cc env ms (premem, postmem) (preregs, postregs) = do
  let ?ptrWidth = knownNat @64
  let tyenv = ms ^. MS.csPreState . MS.csAllocs
      nameEnv = MS.csTypeNames ms
  forM_ (ms ^. MS.csPostState . MS.csPointsTos)
    $ assertPointsTo sym cc env tyenv nameEnv postmem

  prersp <- getReg Macaw.RSP preregs
  expectedIP <- C.LLVM.doLoad sym premem prersp (C.LLVM.bitvectorType 8) (C.LLVM.LLVMPointerRepr $ knownNat @64) C.LLVM.noAlignment
  actualIP <- getReg Macaw.X86_IP postregs
  correctRetAddr <- C.LLVM.ptrEq sym C.LLVM.PtrWidth actualIP expectedIP
  C.addAssertion sym . C.LabeledPred correctRetAddr . C.SimError W4.initializationLoc
    $ C.AssertFailureSimError "Instruction pointer not set to return address" ""

  stack <- C.LLVM.doPtrAddOffset sym premem prersp =<< W4.bvLit sym knownNat 1
  postrsp <- getReg Macaw.RSP postregs
  correctStack <- C.LLVM.ptrEq sym C.LLVM.PtrWidth stack postrsp
  C.addAssertion sym . C.LabeledPred correctStack . C.SimError W4.initializationLoc
    $ C.AssertFailureSimError "Stack not preserved" ""

  -- TODO: Match return value in RAX

-- | Assert that a points-to postcondition holds.
assertPointsTo ::
  Sym ->
  LLVMCrucibleContext LLVMArch ->
  Map MS.AllocIndex Ptr {- ^ Associates each AllocIndex with the corresponding allocation -} ->
  Map MS.AllocIndex LLVMAllocSpec {- ^ Associates each AllocIndex with its specification -} ->
  Map MS.AllocIndex C.LLVM.Ident {- ^ Associates each AllocIndex with its name -} ->
  Mem ->
  LLVMPointsTo LLVMArch {- ^ crucible_points_to statement from the precondition -} ->
  IO ()
assertPointsTo sym cc env tyenv nameEnv mem (LLVMPointsTo _ tptr texpected) = do
  let ?ptrWidth = knownNat @64
  ptr <- C.LLVM.unpackMemValue sym (C.LLVM.LLVMPointerRepr $ knownNat @64)
    =<< resolveSetupVal cc mem env tyenv Map.empty tptr
  storTy <- C.LLVM.toStorableType =<< typeOfSetupValue cc tyenv nameEnv texpected
  _actual <- C.LLVM.assertSafe sym =<< C.LLVM.loadRaw sym mem ptr storTy C.LLVM.noAlignment
  -- TODO: actually do matching between actual and expected
  -- For now, we only make sure we can load the memory
  pure ()

-- | Gather and run the solver on goals from the simulator.
checkGoals ::
  Sym ->
  Options ->
  SharedContext ->
  IO ()
checkGoals sym opts sc = do
  liftIO $ printOutLn opts Info "Simulation finished, running solver on goals"
  gs <- liftIO $ getGoals sym
  liftIO $ print gs
  liftIO . forM_ gs $ \g ->
    do term <- gGoal sc g
       (mb, stats) <- proveUnintSBV z3 [] Nothing sc term
       putStrLn $ ppStats stats
       case mb of
         Nothing -> printOutLn opts Info "Goal succeeded"
         Just ex -> fail $ "Failure, counterexample: " <> show ex
    `catch` \(X86Error e) -> fail $ "Failure, error: " <> e
  liftIO $ printOutLn opts Info "All goals succeeded"

-------------------------------------------------------------------------------
-- ** Utility type synonyms and functions

type LLVMArch = C.LLVM.X86 64
type LLVM = C.LLVM.LLVM LLVMArch
type Regs = Ctx.Assignment (C.RegValue' Sym) (Macaw.MacawCrucibleRegTypes Macaw.X86_64)
type Register = Macaw.X86Reg (Macaw.BVType 64)
type Mem = C.LLVM.MemImpl Sym
type Ptr = C.LLVM.LLVMPtr Sym 64

setReg ::
  Register ->
  C.RegValue Sym (C.LLVM.LLVMPointerType 64) ->
  Regs ->
  IO Regs
setReg reg val regs
  | Just regs' <- Macaw.updateX86Reg reg (C.RV . const val) regs = pure regs'
  | otherwise = fail $ mconcat ["Invalid register: ", show reg]

getReg ::
  Register ->
  Regs ->
  IO (C.RegValue Sym (C.LLVM.LLVMPointerType 64))
getReg reg regs = case Macaw.lookupX86Reg reg regs of
  Just (C.RV val) -> pure val
  Nothing -> fail $ mconcat ["Invalid register: ", show reg]

allocate ::
  Sym ->
  Mem ->
  String ->
  C.LLVM.MemType ->
  C.LLVM.Mutability ->
  IO (Ptr, Mem)
allocate sym mem nm mt mut = do
  let ?ptrWidth = knownNat @64
  sz <- W4.bvLit sym knownNat . C.LLVM.bytesToInteger $ C.LLVM.memTypeSize C.LLVM.defaultDataLayout mt
  C.LLVM.doMalloc sym C.LLVM.HeapAlloc mut nm mem sz C.LLVM.noAlignment
