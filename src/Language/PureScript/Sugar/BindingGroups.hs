-- |
-- This module implements the desugaring pass which creates binding groups from sets of
-- mutually-recursive value declarations and mutually-recursive type declarations.
--
module Language.PureScript.Sugar.BindingGroups
  ( createBindingGroups
  , createBindingGroupsModule
  , collapseBindingGroups
  , collapseBindingGroupsModule
  ) where

import Prelude.Compat
import Protolude (ordNub)

import Control.Monad ((<=<))
import Control.Monad.Error.Class (MonadError(..))

import Data.Graph
import Data.List (intersect)
import Data.Maybe (isJust)
import qualified Data.List.NonEmpty as NEL
import qualified Data.Set as S

import Language.PureScript.AST
import Language.PureScript.Crash
import Language.PureScript.Environment
import Language.PureScript.Errors
import Language.PureScript.Names
import Language.PureScript.Types

-- |
-- Replace all sets of mutually-recursive declarations in a module with binding groups
--
createBindingGroupsModule
  :: (MonadError MultipleErrors m)
  => Module
  -> m Module
createBindingGroupsModule (Module ss coms name ds exps) =
  Module ss coms name <$> createBindingGroups name ds <*> pure exps

-- |
-- Collapse all binding groups in a module to individual declarations
--
collapseBindingGroupsModule :: [Module] -> [Module]
collapseBindingGroupsModule =
  fmap $ \(Module ss coms name ds exps) ->
    Module ss coms name (collapseBindingGroups ds) exps

createBindingGroups
  :: forall m
   . (MonadError MultipleErrors m)
  => ModuleName
  -> [Declaration]
  -> m [Declaration]
createBindingGroups moduleName = mapM f <=< handleDecls

  where
  (f, _, _) = everywhereOnValuesTopDownM return handleExprs return

  handleExprs :: Expr -> m Expr
  handleExprs (Let ds val) = flip Let val <$> handleDecls ds
  handleExprs other = return other

  -- |
  -- Replace all sets of mutually-recursive declarations with binding groups
  --
  handleDecls :: [Declaration] -> m [Declaration]
  handleDecls ds = do
    let values = filter isValueDecl ds
        dataDecls = filter isDataDecl ds
        allProperNames = fmap declTypeName dataDecls
        dataVerts = fmap (\d -> (d, declTypeName d, usedTypeNames moduleName d `intersect` allProperNames)) dataDecls
    dataBindingGroupDecls <- parU (stronglyConnComp dataVerts) toDataBindingGroup
    let allIdents = fmap declIdent values
        valueVerts = fmap (\d -> (d, declIdent d, usedIdents moduleName d `intersect` allIdents)) values
    bindingGroupDecls <- parU (stronglyConnComp valueVerts) (toBindingGroup moduleName)
    return $ filter isImportDecl ds ++
             filter isExternKindDecl ds ++
             filter isExternDataDecl ds ++
             dataBindingGroupDecls ++
             filter isTypeClassDeclaration ds ++
             filter isTypeClassInstanceDeclaration ds ++
             filter isFixityDecl ds ++
             filter isExternDecl ds ++
             bindingGroupDecls

-- |
-- Collapse all binding groups to individual declarations
--
collapseBindingGroups :: [Declaration] -> [Declaration]
collapseBindingGroups =
  let (f, _, _) = everywhereOnValues id collapseBindingGroupsForValue id
  in fmap f . concatMap go
  where
  go (DataBindingGroupDeclaration ds) = NEL.toList ds
  go (BindingGroupDeclaration ds) =
    NEL.toList $ fmap (\((sa, ident), nameKind, val) ->
      ValueDeclaration sa ident nameKind [] [MkUnguarded val]) ds
  go other = [other]

collapseBindingGroupsForValue :: Expr -> Expr
collapseBindingGroupsForValue (Let ds val) = Let (collapseBindingGroups ds) val
collapseBindingGroupsForValue other = other

usedIdents :: ModuleName -> Declaration -> [Ident]
usedIdents moduleName = ordNub . usedIdents' S.empty . getValue
  where
  def _ _ = []

  getValue (ValueDeclaration _ _ _ [] [MkUnguarded val]) = val
  getValue ValueDeclaration{} = internalError "Binders should have been desugared"
  getValue _ = internalError "Expected ValueDeclaration"

  (_, usedIdents', _, _, _) = everythingWithScope def usedNamesE def def def

  usedNamesE :: S.Set Ident -> Expr -> [Ident]
  usedNamesE scope (Var (Qualified Nothing name))
    | name `S.notMember` scope = [name]
  usedNamesE scope (Var (Qualified (Just moduleName') name))
    | moduleName == moduleName' && name `S.notMember` scope = [name]
  usedNamesE _ _ = []

usedImmediateIdents :: ModuleName -> Declaration -> [Ident]
usedImmediateIdents moduleName =
  let (f, _, _, _, _) = everythingWithContextOnValues True [] (++) def usedNamesE def def def
  in ordNub . f
  where
  def s _ = (s, [])

  usedNamesE :: Bool -> Expr -> (Bool, [Ident])
  usedNamesE True (Var (Qualified Nothing name)) = (True, [name])
  usedNamesE True (Var (Qualified (Just moduleName') name))
    | moduleName == moduleName' = (True, [name])
  usedNamesE True (Abs _ _) = (False, [])
  usedNamesE scope _ = (scope, [])

usedTypeNames :: ModuleName -> Declaration -> [ProperName 'TypeName]
usedTypeNames moduleName =
  let (f, _, _, _, _) = accumTypes (everythingOnTypes (++) usedNames)
  in ordNub . f
  where
  usedNames :: Type -> [ProperName 'TypeName]
  usedNames (ConstrainedType con _) =
    case con of
      (Constraint (Qualified (Just moduleName') name) _ _)
        | moduleName == moduleName' -> [coerceProperName name]
      _ -> []
  usedNames (TypeConstructor (Qualified (Just moduleName') name))
    | moduleName == moduleName' = [name]
  usedNames _ = []

declIdent :: Declaration -> Ident
declIdent (ValueDeclaration _ ident _ _ _) = ident
declIdent _ = internalError "Expected ValueDeclaration"

declTypeName :: Declaration -> ProperName 'TypeName
declTypeName (DataDeclaration _ _ pn _ _) = pn
declTypeName (TypeSynonymDeclaration _ pn _ _) = pn
declTypeName _ = internalError "Expected DataDeclaration"

-- |
-- Convert a group of mutually-recursive dependencies into a BindingGroupDeclaration (or simple ValueDeclaration).
--
--
toBindingGroup
  :: forall m
   . (MonadError MultipleErrors m)
   => ModuleName
   -> SCC Declaration
   -> m Declaration
toBindingGroup _ (AcyclicSCC d) = return d
toBindingGroup moduleName (CyclicSCC ds') = do
  -- Once we have a mutually-recursive group of declarations, we need to sort
  -- them further by their immediate dependencies (those outside function
  -- bodies). In particular, this is relevant for type instance dictionaries
  -- whose members require other type instances (for example, functorEff
  -- defines (<$>) = liftA1, which depends on applicativeEff). Note that
  -- superclass references are still inside functions, so don't count here.
  -- If we discover declarations that still contain mutually-recursive
  -- immediate references, we're guaranteed to get an undefined reference at
  -- runtime, so treat this as an error. See also github issue #365.
  BindingGroupDeclaration . NEL.fromList <$> mapM toBinding (stronglyConnComp valueVerts)
  where
  idents :: [Ident]
  idents = fmap (\(_, i, _) -> i) valueVerts

  valueVerts :: [(Declaration, Ident, [Ident])]
  valueVerts = fmap (\d -> (d, declIdent d, usedImmediateIdents moduleName d `intersect` idents)) ds'

  toBinding :: SCC Declaration -> m ((SourceAnn, Ident), NameKind, Expr)
  toBinding (AcyclicSCC d) = return $ fromValueDecl d
  toBinding (CyclicSCC ds) = throwError $ foldMap cycleError ds

  cycleError :: Declaration -> MultipleErrors
  cycleError (ValueDeclaration (ss, _) n _ _ [MkUnguarded _]) = errorMessage' ss $ CycleInDeclaration n
  cycleError _ = internalError "cycleError: Expected ValueDeclaration"

toDataBindingGroup
  :: MonadError MultipleErrors m
  => SCC Declaration
  -> m Declaration
toDataBindingGroup (AcyclicSCC d) = return d
toDataBindingGroup (CyclicSCC [d]) = case isTypeSynonym d of
  Just pn -> throwError . errorMessage' (declSourceSpan d) $ CycleInTypeSynonym (Just pn)
  _ -> return d
toDataBindingGroup (CyclicSCC ds')
  | all (isJust . isTypeSynonym) ds' = throwError . errorMessage' (declSourceSpan (head ds')) $ CycleInTypeSynonym Nothing
  | otherwise = return . DataBindingGroupDeclaration $ NEL.fromList ds'

isTypeSynonym :: Declaration -> Maybe (ProperName 'TypeName)
isTypeSynonym (TypeSynonymDeclaration _ pn _ _) = Just pn
isTypeSynonym _ = Nothing

fromValueDecl :: Declaration -> ((SourceAnn, Ident), NameKind, Expr)
fromValueDecl (ValueDeclaration sa ident nameKind [] [MkUnguarded val]) = ((sa, ident), nameKind, val)
fromValueDecl ValueDeclaration{} = internalError "Binders should have been desugared"
fromValueDecl _ = internalError "Expected ValueDeclaration"
