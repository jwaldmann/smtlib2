module Language.SMTLib2.Composite.Expression where

import Language.SMTLib2.Composite.Class
--import Language.SMTLib2.Composite.Lens

import Language.SMTLib2
import Language.SMTLib2.Internals.Embed
import Language.SMTLib2.Internals.Type
import Language.SMTLib2.Internals.Monad (backend)
import Language.SMTLib2.Internals.Backend (Var)
import qualified Language.SMTLib2.Internals.Expression as E
import qualified Language.SMTLib2.Internals.Type.List as List
import Control.Monad.Writer
import Control.Monad.State
import Control.Monad.Reader
import Data.GADT.Compare as GComp
import Data.GADT.Show
import Data.Dependent.Map (DMap)
import Data.Dependent.Sum (DSum(..))
import qualified Data.Dependent.Map as DMap
import Data.Functor.Identity
import Data.Proxy

newtype CompositeExpr a t = CompositeExpr { compositeExpr :: E.Expression (RevComp a) E.NoVar E.NoFun E.NoVar E.NoVar (CompositeExpr a) t }

compositeExprType :: Composite a => CompDescr a -> CompositeExpr a t -> Repr t
compositeExprType descr (CompositeExpr e)
  = runIdentity $ E.expressionType
    (return . revType descr)
    (return.getType) (return.getFunType) (return.getType)
    (return.getType) (return.compositeExprType descr) e

{-data CompositeExpr a t
  = CompositeExpr { compositeDescr :: CompDescr a
                  , compositeExpr :: E.Expression (RevComp a) E.NoVar E.NoFun E.NoVar E.NoVar (CompositeExpr a) t }

instance Composite a => GetType (CompositeExpr a) where
  getType (CompositeExpr descr e :: CompositeExpr a t)
    = runIdentity $ E.expressionType
      (return . revType descr)
      (return.getType) (return.getFunType) (return.getType)
      (return.getType) (return.getType) e-}

createRevComp :: (Composite arg,Embed m e,Monad m,GetType e)
              => (forall t. Repr t -> RevComp arg t -> m (EmVar m e t))
              -> CompDescr arg
              -> m (arg e,DMap (EmVar m e) (RevComp arg))
createRevComp f descr
  = runStateT (createComposite (\tp rev -> do
                                   v <- lift (f tp rev)
                                   e <- lift (embed $ pure $ E.Var v)
                                   modify (DMap.insert v rev)
                                   return e
                               ) descr
              ) DMap.empty

{-instance Composite a => GEq (CompositeExpr a) where
  geq (CompositeExpr dx x) (CompositeExpr dy y)
    = case compCompare dx dy of
        EQ -> geq x y
        _ -> Nothing
instance Composite a => GCompare (CompositeExpr a) where
  gcompare (CompositeExpr dx x) (CompositeExpr dy y)
    = case compCompare dx dy of
    EQ -> gcompare x y
    LT -> GLT
    GT -> GGT-}
instance Composite a => GEq (CompositeExpr a) where
  geq (CompositeExpr x) (CompositeExpr y) = geq x y
instance Composite a => GCompare (CompositeExpr a) where
  gcompare (CompositeExpr x) (CompositeExpr y) = gcompare x y
instance Composite a => Eq (CompositeExpr a t) where
  (==) = GComp.defaultEq
instance Composite a => Ord (CompositeExpr a t) where
  compare = defaultCompare

instance Composite a => Show (CompositeExpr a t) where
  showsPrec p (CompositeExpr e) = E.renderExprDefault E.SMTRendering e

instance Composite a => GShow (CompositeExpr a) where
  gshowsPrec = showsPrec

instance (Composite a,Monad m) => Embed (ReaderT (a Repr) m) (CompositeExpr a) where
  type EmVar (ReaderT (a Repr) m) (CompositeExpr a) = RevComp a
  type EmQVar (ReaderT (a Repr) m) (CompositeExpr a) = E.NoVar
  type EmFun (ReaderT (a Repr) m) (CompositeExpr a) = E.NoFun
  type EmFunArg (ReaderT (a Repr) m) (CompositeExpr a) = E.NoVar
  type EmLVar (ReaderT (a Repr) m) (CompositeExpr a) = E.NoVar
  embed e = do
    re <- e
    return (CompositeExpr re)
  embedQuantifier _ _ _ = error "CompositeExpr does not support quantifier"
  embedTypeOf = do
    descr <- ask
    return $ compositeExprType descr

instance Composite a => Extract () (CompositeExpr a) where
  type ExVar () (CompositeExpr a) = RevComp a
  type ExQVar () (CompositeExpr a) = E.NoVar
  type ExFun () (CompositeExpr a) = E.NoFun
  type ExFunArg () (CompositeExpr a) = E.NoVar
  type ExLVar () (CompositeExpr a) = E.NoVar
  extract _ (CompositeExpr x) = Just x

mkCompExpr :: Composite arg
           => (arg (CompositeExpr arg) -> Reader (CompDescr arg) res)
           -> CompDescr arg
           -> res
mkCompExpr f descr
  = runReader (do
                  arg <- createComposite (\_ rev -> return (CompositeExpr (E.Var rev))) descr
                  f arg) descr

concretizeExpr :: (Embed m e,Monad m,Composite arg)
               => arg e
               -> CompositeExpr arg tp
               -> m (e tp)
concretizeExpr arg (CompositeExpr (E.Var rev)) = case getRev rev arg of
  Just r -> return r
  Nothing -> error $ "concretizeExpr: Unknown key "++gshow rev
concretizeExpr arg (CompositeExpr (E.App fun args)) = do
  nfun <- E.mapFunction undefined fun
  nargs <- List.mapM (concretizeExpr arg) args
  embed $ pure $ E.App nfun nargs
concretizeExpr arg (CompositeExpr (E.Const c)) = embed $ pure $ E.Const c
concretizeExpr arg (CompositeExpr (E.AsArray fun)) = do
  nfun <- E.mapFunction undefined fun
  embed $ pure $ E.AsArray nfun

relativizeExpr :: (Backend b,Composite arg)
               => CompDescr arg
               -> DMap (Var b) (RevComp arg)
               -> Expr b tp
               -> SMT b (CompositeExpr arg tp)
relativizeExpr descr mp expr = do
  st <- get
  return $ relativizeExpr' descr mp DMap.empty (BackendInfo (backend st)) expr

relativizeExpr' :: (Extract i e,Composite arg,GShow (ExVar i e))
                => CompDescr arg
                -> DMap (ExVar i e) (RevComp arg)
                -> DMap (ExLVar i e) (CompositeExpr arg)
                -> i
                -> e tp
                -> CompositeExpr arg tp
relativizeExpr' descr mp lmp info e = case extract info e of
  Just (E.Var v) -> case DMap.lookup v mp of
    Just rev -> CompositeExpr (E.Var rev)
    Nothing -> error $ "Failed to relativize: "++gshowsPrec 0 v ""
  Just (E.LVar v) -> case DMap.lookup v lmp of
    Just e -> e
  Just (E.App fun args)
    -> let nfun = runIdentity $ E.mapFunction undefined fun
           nargs = runIdentity $ List.mapM (return . relativizeExpr' descr mp lmp info) args
       in CompositeExpr (E.App nfun nargs)
  Just (E.Const c) -> CompositeExpr (E.Const c)
  Just (E.AsArray fun)
    -> let nfun = runIdentity $ E.mapFunction undefined fun
       in CompositeExpr (E.AsArray nfun)
  -- TODO: Find a way not to flatten let bindings
  Just (E.Let bind body) -> relativizeExpr' descr mp nlmp info body
    where
      nlmp = foldl (\lmp (E.LetBinding v e)
                    -> DMap.insert v
                       (relativizeExpr' descr mp lmp info e) lmp
                   ) lmp bind

collectRevVars :: Composite arg
               => DMap (RevComp arg) E.NoVar
               -> CompositeExpr arg tp
               -> DMap (RevComp arg) E.NoVar
collectRevVars mp (CompositeExpr (E.Var v))
  = DMap.insert v E.NoVar' mp
collectRevVars mp (CompositeExpr (E.App fun args))
  = runIdentity $ List.foldM (\mp e -> return $ collectRevVars mp e) mp args
collectRevVars mp (CompositeExpr (E.Const _)) = mp
collectRevVars mp (CompositeExpr (E.AsArray _)) = mp
