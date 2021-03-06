{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Checker.Types where

import Control.Monad.State.Strict
import Data.List

import Language.Granule.Checker.Constraints.Compile

import Language.Granule.Checker.Kinds
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.SubstitutionContexts
import Language.Granule.Checker.Substitution
import Language.Granule.Checker.Variables

import Language.Granule.Syntax.Helpers
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type

import Language.Granule.Utils

lEqualTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator ->Type -> Type -> Checker (Bool, Type, Substitution)
lEqualTypesWithPolarity s pol = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy pol

equalTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator -> Type -> Type -> Checker (Bool, Type, Substitution)
equalTypesWithPolarity s pol = equalTypesRelatedCoeffectsAndUnify s Eq pol

lEqualTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> Checker (Bool, Type, Substitution)
lEqualTypes s = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy SndIsSpec

equalTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> Checker (Bool, Type, Substitution)
equalTypes s = equalTypesRelatedCoeffectsAndUnify s Eq SndIsSpec

equalTypesWithUniversalSpecialisation :: (?globals :: Globals)
  => Span -> Type -> Type -> Checker (Bool, Type, Substitution)
equalTypesWithUniversalSpecialisation s = equalTypesRelatedCoeffectsAndUnify s Eq SndIsSpec

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and unify the
     two types

     The first argument is taken to be possibly approximated by the second
     e.g., the first argument is inferred, the second is a specification
     being checked against
-}
equalTypesRelatedCoeffectsAndUnify :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -- Starting spec indication
  -> SpecIndicator
  -- Left type (usually the inferred)
  -> Type
  -- Right type (usually the specified)
  -> Type
  -- Result is a effectful, producing:
  --    * a boolean of the equality
  --    * the most specialised type (after the unifier is applied)
  --    * the unifier
  -> Checker (Bool, Type, Substitution)
equalTypesRelatedCoeffectsAndUnify s rel spec t1 t2 = do

   (eq, unif) <- equalTypesRelatedCoeffects s rel t1 t2 spec
   if eq
     then do
        t2 <- substitute unif t2
        return (eq, t2, unif)
     else return (eq, t1, [])

data SpecIndicator = FstIsSpec | SndIsSpec | PatternCtxt
  deriving (Eq, Show)

flipIndicator :: SpecIndicator -> SpecIndicator
flipIndicator FstIsSpec = SndIsSpec
flipIndicator SndIsSpec = FstIsSpec
flipIndicator PatternCtxt = PatternCtxt

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and a unifier
      Polarity indicates which -}
equalTypesRelatedCoeffects :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -> Type
  -> Type
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> Checker (Bool, Substitution)
equalTypesRelatedCoeffects s rel (FunTy t1 t2) (FunTy t1' t2') sp = do
  -- contravariant position (always approximate)
  (eq1, u1) <- equalTypesRelatedCoeffects s ApproximatedBy t1' t1 (flipIndicator sp)
   -- covariant position (depends: is not always over approximated)
  t2 <- substitute u1 t2
  t2' <- substitute u1 t2'
  (eq2, u2) <- equalTypesRelatedCoeffects s rel t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (eq1 && eq2, unifiers)

equalTypesRelatedCoeffects _ _ (TyCon con1) (TyCon con2) _ =
  return (con1 == con2, [])

-- THE FOLLOWING FOUR CASES ARE TEMPORARY UNTIL WE MAKE 'Effect' RICHER

-- Over approximation by 'IO' "monad"
equalTypesRelatedCoeffects s rel (Diamond ef t1) (Diamond ["IO"] t2) sp
    = equalTypesRelatedCoeffects s rel t1 t2 sp

-- Under approximation by 'IO' "monad"
equalTypesRelatedCoeffects s rel (Diamond ["IO"] t1) (Diamond ef t2) sp
    = equalTypesRelatedCoeffects s rel t1 t2 sp

-- Over approximation by 'Session' "monad"
equalTypesRelatedCoeffects s rel (Diamond ef t1) (Diamond ["Session"] t2) sp
    | "Com" `elem` ef || null ef
      = equalTypesRelatedCoeffects s rel t1 t2 sp

-- Under approximation by 'Session' "monad"
equalTypesRelatedCoeffects s rel (Diamond ["Session"] t1) (Diamond ef t2) sp
    | "Com" `elem` ef || null ef
      = equalTypesRelatedCoeffects s rel t1 t2 sp

equalTypesRelatedCoeffects s rel (Diamond ef1 t1) (Diamond ef2 t2) sp = do
  (eq, unif) <- equalTypesRelatedCoeffects s rel t1 t2 sp
  if ef1 == ef2
    then return (eq, unif)
    else
      -- Effect approximation
      if all (`elem` ef2) ef1
      then return (eq, unif)
      else
        -- Communication effect analysis is idempotent
        if (nub ef1 == ["Com"] && nub ef2 == ["Com"])
        then return (eq, unif)
        else
          throw EffectMismatch{ errLoc = s, effExpected = ef1, effActual = ef2 }

equalTypesRelatedCoeffects s rel x@(Box c t) y@(Box c' t') sp = do
  -- Debugging messages
  debugM "equalTypesRelatedCoeffects (pretty)" $ pretty c <> " == " <> pretty c'
  debugM "equalTypesRelatedCoeffects (show)" $ "[ " <> show c <> " , " <> show c' <> "]"
  -- Unify the coeffect kinds of the two coeffects
  kind <- mguCoeffectTypes s c c'
  -- subst <- unify c c'
  case sp of
    SndIsSpec -> addConstraint (rel s c c' kind)
    FstIsSpec -> addConstraint (rel s c' c kind)
    _ -> throw UnificationDisallowed { errLoc = s, errTy1 = x, errTy2 = y }

  equalTypesRelatedCoeffects s rel t t' sp
  --(eq, subst') <- equalTypesRelatedCoeffects s rel uS t t' sp
  --case subst of
  --  Just subst -> do
--      substFinal <- combineSubstitutions s subst subst'
--      return (eq, substFinal)
  --  Nothing -> return (False, [])

equalTypesRelatedCoeffects s _ (TyVar n) (TyVar m) _ | n == m = do
  checkerState <- get
  case lookup n (tyVarContext checkerState) of
    Just _ -> return (True, [])
    Nothing -> throw UnboundTypeVariable { errLoc = s, errId = n }

equalTypesRelatedCoeffects s _ (TyVar n) (TyVar m) sp = do
  checkerState <- get
  debugM "variable equality" $ pretty n <> " ~ " <> pretty m <> " where "
                            <> pretty (lookup n (tyVarContext checkerState)) <> " and "
                            <> pretty (lookup m (tyVarContext checkerState))

  case (lookup n (tyVarContext checkerState), lookup m (tyVarContext checkerState)) of

    -- Two universally quantified variables are unequal
    (Just (_, ForallQ), Just (_, ForallQ)) ->
        return (False, [])

    -- We can unify a universal a dependently bound universal
    (Just (k1, ForallQ), Just (k2, BoundQ)) ->
      tyVarConstraint (k1, n) (k2, m)

    (Just (k1, BoundQ), Just (k2, ForallQ)) ->
      tyVarConstraint (k1, n) (k2, m)


    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (k1, InstanceQ), Just (k2, ForallQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (k1, ForallQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    (t1, t2) -> error $ pretty s <> "-" <> show sp <> "\n"
              <> pretty n <> " : " <> show t1
              <> "\n" <> pretty m <> " : " <> show t2
  where
    tyVarConstraint (k1, n) (k2, m) = do
      case k1 `joinKind` k2 of
        Just (KPromote (TyCon kc)) -> do

          k <- inferKindOfType s (TyCon kc)
          -- Create solver vars for coeffects
          case k of
            KCoeffect -> addConstraint (Eq s (CVar n) (CVar m) (TyCon kc))
            _         -> return ()
          return (True, [(n, SubstT $ TyVar m)])
        Just _ ->
          return (True, [(m, SubstT $ TyVar n)])
        Nothing ->
          return (False, [])


-- Duality is idempotent (left)
equalTypesRelatedCoeffects s rel (TyApp (TyCon d') (TyApp (TyCon d) t)) t' sp
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffects s rel t t' sp

-- Duality is idempotent (right)
equalTypesRelatedCoeffects s rel t (TyApp (TyCon d') (TyApp (TyCon d) t')) sp
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffects s rel t t' sp

equalTypesRelatedCoeffects s rel (TyVar n) t sp = do
  checkerState <- get
  debugM "Types.equalTypesRelatedCoeffects on TyVar"
          $ "span: " <> show s
          <> "\nTyVar: " <> show n <> " with " <> show (lookup n (tyVarContext checkerState))
          <> "\ntype: " <> show t <> "\nspec indicator: " <> show sp

  k2 <- inferKindOfType s t

  -- Do an occurs check for types
  case k2 of
    KType ->
       if n `elem` freeVars t
         then throw OccursCheckFail { errLoc = s, errVar = n, errTy = t }
         else return ()
    _ -> return ()

  case lookup n (tyVarContext checkerState) of
    -- We can unify an instance with a concrete type
    (Just (k1, q)) | (q == BoundQ) || (q == InstanceQ && sp /= PatternCtxt) -> do

      case k1 `joinKind` k2 of
        Nothing -> throw UnificationKindError
          { errLoc = s, errTy1 = (TyVar n), errK1 = k1, errTy2 = t, errK2 = k2 }

        -- If the kind is Nat, then create a solver constraint
        Just (KPromote (TyCon (internalName -> "Nat"))) -> do
          nat <- compileNatKindedTypeToCoeffect s t
          addConstraint (Eq s (CVar n) nat (TyCon $ mkId "Nat"))
          return (True, [(n, SubstT t)])

        Just _ -> return (True, [(n, SubstT t)])

    -- NEW

    (Just (k1, ForallQ)) -> do
       -- Infer the kind of this equality
       k2 <- inferKindOfType s t
       let kind = k1 `joinKind` k2

       -- If the kind if nat then set up and equation as there might be a
       -- pausible equation involving the quantified variable
       if (kind == Just (KPromote (TyCon (Id "Nat" "Nat"))))
         then do
           c1 <- compileNatKindedTypeToCoeffect s (TyVar n)
           c2 <- compileNatKindedTypeToCoeffect s t
           addConstraint $ Eq s c1 c2 (TyCon $ mkId "Nat")
           return (True, [(n, SubstT t)])

         else throw UnificationFail{ errLoc = s, errVar = n, errKind = k1, errTy = t }

    (Just (_, InstanceQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    (Just (_, BoundQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    Nothing -> throw UnboundTypeVariable { errLoc = s, errId = n }


equalTypesRelatedCoeffects s rel t (TyVar n) sp =
  equalTypesRelatedCoeffects s rel (TyVar n) t (flipIndicator sp)

-- Do duality check (left) [special case of TyApp rule]
equalTypesRelatedCoeffects s rel (TyApp (TyCon d) t) t' sp
  | internalName d == "Dual" = isDualSession s rel t t' sp

equalTypesRelatedCoeffects s rel t (TyApp (TyCon d) t') sp
  | internalName d == "Dual" = isDualSession s rel t t' sp

-- Equality on type application
equalTypesRelatedCoeffects s rel (TyApp t1 t2) (TyApp t1' t2') sp = do
  (one, u1) <- equalTypesRelatedCoeffects s rel t1 t1' sp
  t2  <- substitute u1 t2
  t2' <- substitute u1 t2'
  (two, u2) <- equalTypesRelatedCoeffects s rel t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (one && two, unifiers)


equalTypesRelatedCoeffects s rel t1 t2 t = do
  debugM "equalTypesRelatedCoeffects" $ "called on: " <> show t1 <> "\nand:\n" <> show t2
  equalOtherKindedTypesGeneric s t1 t2

{- | Equality on other types (e.g. Nat and Session members) -}
equalOtherKindedTypesGeneric :: (?globals :: Globals)
    => Span
    -> Type
    -> Type
    -> Checker (Bool, Substitution)
equalOtherKindedTypesGeneric s t1 t2 = do
  k1 <- inferKindOfType s t1
  k2 <- inferKindOfType s t2
  if k1 == k2 then
    case k1 of
      KPromote (TyCon (internalName -> "Nat")) -> do
        c1 <- compileNatKindedTypeToCoeffect s t1
        c2 <- compileNatKindedTypeToCoeffect s t2
        addConstraint $ Eq s c1 c2 (TyCon $ mkId "Nat")
        return (True, [])

      KPromote (TyCon (internalName -> "Protocol")) ->
        sessionInequality s t1 t2

      KType -> throw UnificationError{ errLoc = s, errTy1 = t1, errTy2 = t2}

      _ ->
       throw UndefinedEqualityKindError
        { errLoc = s, errTy1 = t1, errK1 = k1, errTy2 = t2, errK2 = k2 }
  else throw UnificationError{ errLoc = s, errTy1 = t1, errTy2 = t2}

-- Essentially use to report better error messages when two session type
-- are not equality
sessionInequality :: (?globals :: Globals)
    => Span -> Type -> Type -> Checker (Bool, Substitution)
sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Send" && internalName c' == "Send" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Recv" && internalName c' == "Recv" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionInequality s (TyCon c) (TyCon c')
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

sessionInequality s t1 t2 = throw TypeError{ errLoc = s, tyExpected = t1, tyActual = t2 }

isDualSession :: (?globals :: Globals)
    => Span
       -- Explain how coeffects should be related by a solver constraint
    -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
    -> Type
    -> Type
    -- Indicates whether the first type or second type is a specification
    -> SpecIndicator
    -> Checker (Bool, Substitution)
isDualSession sp rel (TyApp (TyApp (TyCon c) t) s) (TyApp (TyApp (TyCon c') t') s') ind
  |  (internalName c == "Send" && internalName c' == "Recv")
  || (internalName c == "Recv" && internalName c' == "Send") = do
  (eq1, u1) <- equalTypesRelatedCoeffects sp rel t t' ind
  (eq2, u2) <- isDualSession sp rel s s' ind
  u <- combineSubstitutions sp u1 u2
  return (eq1 && eq2, u)

isDualSession _ _ (TyCon c) (TyCon c') _
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

isDualSession sp rel t (TyVar v) ind =
  equalTypesRelatedCoeffects sp rel (TyApp (TyCon $ mkId "Dual") t) (TyVar v) ind

isDualSession sp rel (TyVar v) t ind =
  equalTypesRelatedCoeffects sp rel (TyVar v) (TyApp (TyCon $ mkId "Dual") t) ind

isDualSession sp _ t1 t2 _ = throw
  SessionDualityError{ errLoc = sp, errTy1 = t1, errTy2 = t2 }


-- Essentially equality on types but join on any coeffects
joinTypes :: (?globals :: Globals) => Span -> Type -> Type -> Checker Type
joinTypes s t t' | t == t' = return t

joinTypes s (FunTy t1 t2) (FunTy t1' t2') = do
  t1j <- joinTypes s t1' t1 -- contravariance
  t2j <- joinTypes s t2 t2'
  return (FunTy t1j t2j)

joinTypes _ (TyCon t) (TyCon t') | t == t' = return (TyCon t)

joinTypes s (Diamond ef t) (Diamond ef' t') = do
  tj <- joinTypes s t t'
  if ef `isPrefixOf` ef'
    then return (Diamond ef' tj)
    else
      if ef' `isPrefixOf` ef
      then return (Diamond ef tj)
      else throw EffectMismatch{ errLoc = s, effExpected = ef, effActual = ef' }

joinTypes s (Box c t) (Box c' t') = do
  coeffTy <- mguCoeffectTypes s c c'
  -- Create a fresh coeffect variable
  topVar <- freshTyVarInContext (mkId "") (promoteTypeToKind coeffTy)
  -- Unify the two coeffects into one
  addConstraint (ApproximatedBy s c  (CVar topVar) coeffTy)
  addConstraint (ApproximatedBy s c' (CVar topVar) coeffTy)
  tUpper <- joinTypes s t t'
  return $ Box (CVar topVar) tUpper

joinTypes s (TyInt n) (TyVar m) = do
  -- Create a fresh coeffect variable
  let ty = TyCon $ mkId "Nat"
  var <- freshTyVarInContext m (KPromote ty)
  -- Unify the two coeffects into one
  addConstraint (Eq s (CNat n) (CVar var) ty)
  return $ TyInt n

joinTypes s (TyVar n) (TyInt m) = joinTypes s (TyInt m) (TyVar n)

joinTypes s (TyVar n) (TyVar m) = do
  -- Create fresh variables for the two tyint variables
  -- TODO: how do we know they are tyints? Looks suspicious
  --let kind = TyCon $ mkId "Nat"
  --nvar <- freshTyVarInContext n kind
  --mvar <- freshTyVarInContext m kind
  -- Unify the two variables into one
  --addConstraint (ApproximatedBy s (CVar nvar) (CVar mvar) kind)
  --return $ TyVar n
  -- TODO: FIX. The above can't be right.
  error $ "Trying to join two type variables: " ++ pretty n ++ " and " ++ pretty m

joinTypes s (TyApp t1 t2) (TyApp t1' t2') = do
  t1'' <- joinTypes s t1 t1'
  t2'' <- joinTypes s t2 t2'
  return (TyApp t1'' t2'')

-- TODO: Create proper substitutions
joinTypes s (TyVar _) t = return t
joinTypes s t (TyVar _) = return t

joinTypes s t1 t2 = throw
  NoUpperBoundError{ errLoc = s, errTy1 = t1, errTy2 = t2 }
