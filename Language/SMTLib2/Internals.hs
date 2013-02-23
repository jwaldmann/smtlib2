{-# LANGUAGE OverloadedStrings,GADTs,FlexibleInstances,MultiParamTypeClasses,RankNTypes,DeriveDataTypeable,TypeSynonymInstances,TypeFamilies,FlexibleContexts #-}
module Language.SMTLib2.Internals where

import Data.Attoparsec
import qualified Data.AttoLisp as L
import Data.ByteString as BS
import Blaze.ByteString.Builder
import System.Process
import System.IO as IO
import Data.Monoid
import Control.Monad.Reader
import Control.Monad.State
import Data.Text as T
import Data.Typeable
import Data.Map as Map hiding (assocs)
import Data.Set as Set
import Data.List as List (mapAccumL,find)

-- Monad stuff
import Control.Applicative (Applicative(..))
import Control.Monad.State.Lazy as Lazy (StateT)
import Control.Monad.Cont (ContT)
import Control.Monad.Error (ErrorT, Error)
import Control.Monad.Trans.Identity (IdentityT)
import Control.Monad.List (ListT)
import Control.Monad.Trans.Maybe (MaybeT)
import Control.Monad.State.Strict as Strict (StateT)
import Control.Monad.Writer.Lazy as Lazy (WriterT)
import Control.Monad.Writer.Strict as Strict (WriterT)

-- | Haskell types which can be represented in SMT
class (Eq t,Typeable t,Typeable (SMTAnnotation t)) => SMTType t where
  type SMTAnnotation t
  getSort :: t -> SMTAnnotation t -> L.Lisp
  getSort u _ = getSortBase u
  getSortBase :: t -> L.Lisp
  declareType :: t -> SMTAnnotation t -> SMT ()
  additionalConstraints :: t -> SMTAnnotation t -> SMTExpr t -> [SMTExpr Bool]
  additionalConstraints _ _ _ = []

-- | Haskell values which can be represented as SMT constants
class SMTType t => SMTValue t where
  unmangle :: L.Lisp -> SMTAnnotation t -> Maybe t
  mangle :: t -> SMTAnnotation t -> L.Lisp

-- | All records which can be expressed in SMT
class SMTType t => SMTRecordType t where
  getFieldAnn :: (SMTType f,Typeable (SMTAnnotation f)) => Field t f -> SMTAnnotation t -> SMTAnnotation f

-- | A type class for all types which support arithmetic operations in SMT
class (SMTValue t,Num t) => SMTArith t

-- | A type class for all types which support bitvector operations in SMT
class (SMTValue t) => SMTBV t

-- | Lifts the 'Ord' class into SMT
class (SMTType t) => SMTOrd t where
  (.<.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.>=.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.>.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.<=.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool

infix 4 .<., .<=., .>=., .>.

-- | Represents a function in the SMT solver. /a/ is the argument of the function in SMT terms, /b/ is the argument in haskell types and /r/ is the result type of the function.
data SMTFun a r = SMTFun deriving (Eq,Typeable)

-- | An array which maps indices of type /i/ to elements of type /v/.
data SMTArray i v = SMTArray deriving (Eq,Typeable)

class (SMTType a,SMTType b,SMTType (ConcatResult a b)) => Concatable a b where
    type ConcatResult a b
    concat' :: a -> SMTAnnotation a -> b -> SMTAnnotation b -> ConcatResult a b
    concatAnn :: a -> b -> SMTAnnotation a -> SMTAnnotation b -> SMTAnnotation (ConcatResult a b)

class Extractable a b where
    extract' :: a -> b -> Integer -> Integer -> SMTAnnotation a -> SMTAnnotation b

type SMTRead = (Handle, Handle)
type SMTState = (Map String Integer,Map TyCon DeclaredType,Map T.Text TypeRep)

-- | The SMT monad used for communating with the SMT solver
newtype SMT a = SMT { runSMT :: ReaderT SMTRead (Lazy.StateT SMTState IO) a }

instance Functor SMT where
  fmap f = SMT . fmap f . runSMT

instance Monad SMT where
  return = SMT . return
  m >>= f = SMT $ (runSMT m) >>= runSMT . f

instance MonadIO SMT where
  liftIO = SMT . liftIO

instance MonadFix SMT where
  mfix f = SMT $ mfix (runSMT . f)

instance Applicative SMT where
  pure = return
  (<*>) = ap

askSMT :: SMT SMTRead
askSMT = SMT ask

getSMT :: SMT SMTState
getSMT = SMT get

putSMT :: SMTState -> SMT ()
putSMT = SMT . put

modifySMT :: (SMTState -> SMTState) -> SMT ()
modifySMT f = SMT $ modify f

-- | Lift an SMT action into an arbitrary monad (like liftIO).
class Monad m => MonadSMT m where
  liftSMT :: SMT a -> m a

instance MonadSMT SMT where
  liftSMT = id

instance MonadSMT m => MonadSMT (ContT r m) where
  liftSMT = lift . liftSMT

instance (Error e, MonadSMT m) => MonadSMT (ErrorT e m) where
  liftSMT = lift . liftSMT

instance MonadSMT m => MonadSMT (IdentityT m) where
  liftSMT = lift . liftSMT

instance MonadSMT m => MonadSMT (ListT m) where
  liftSMT = lift . liftSMT

instance MonadSMT m => MonadSMT (MaybeT m) where
  liftSMT = lift . liftSMT

instance MonadSMT m => MonadSMT (ReaderT r m) where
  liftSMT = lift . liftSMT

instance MonadSMT m => MonadSMT (Lazy.StateT s m) where
  liftSMT = lift . liftSMT

instance MonadSMT m => MonadSMT (Strict.StateT s m) where
  liftSMT = lift . liftSMT

instance (Monoid w, MonadSMT m) => MonadSMT (Lazy.WriterT w m) where
  liftSMT = lift . liftSMT

instance (Monoid w, MonadSMT m) => MonadSMT (Strict.WriterT w m) where
  liftSMT = lift . liftSMT

-- | An abstract SMT expression
data SMTExpr t where
  Var :: SMTType t => Text -> SMTAnnotation t -> SMTExpr t
  Const :: SMTValue t => t -> SMTAnnotation t -> SMTExpr t
  Eq :: SMTType a => SMTExpr (SMTFun (SMTExpr a,SMTExpr a) Bool)
  Ge :: (Num a,SMTType a) => SMTExpr (SMTFun (SMTExpr a,SMTExpr a) Bool)
  Gt :: (Num a,SMTType a) => SMTExpr (SMTFun (SMTExpr a,SMTExpr a) Bool)
  Le :: (Num a,SMTType a) => SMTExpr (SMTFun (SMTExpr a,SMTExpr a) Bool)
  Lt :: (Num a,SMTType a) => SMTExpr (SMTFun (SMTExpr a,SMTExpr a) Bool)
  Distinct :: SMTType a => [SMTExpr a] -> SMTExpr Bool
  Plus :: SMTArith t => SMTExpr (SMTFun (SMTExpr t,SMTExpr t) t)
  Minus :: SMTArith t => SMTExpr (SMTFun (SMTExpr t,SMTExpr t) t)
  Mult :: SMTArith t => SMTExpr (SMTFun (SMTExpr t,SMTExpr t) t)
  Div :: SMTExpr (SMTFun (SMTExpr Integer,SMTExpr Integer) Integer)
  Mod :: SMTExpr (SMTFun (SMTExpr Integer,SMTExpr Integer) Integer)
  Rem :: SMTExpr (SMTFun (SMTExpr Integer,SMTExpr Integer) Integer)
  Divide :: SMTExpr (SMTFun (SMTExpr Rational,SMTExpr Rational) Rational)
  Neg :: SMTArith t => SMTExpr (SMTFun (SMTExpr t) t)
  Abs :: SMTExpr (SMTFun (SMTExpr Integer) Integer)
  ToReal :: SMTExpr Integer -> SMTExpr Rational
  ToInt :: SMTExpr Rational -> SMTExpr Integer
  ITE :: SMTType t => SMTExpr Bool -> SMTExpr t -> SMTExpr t -> SMTExpr t
  And :: SMTExpr (SMTFun (SMTExpr Bool,SMTExpr Bool) Bool)
  Or :: SMTExpr (SMTFun (SMTExpr Bool,SMTExpr Bool) Bool)
  XOr :: SMTExpr (SMTFun (SMTExpr Bool,SMTExpr Bool) Bool)
  Implies :: SMTExpr (SMTFun (SMTExpr Bool,SMTExpr Bool) Bool)
  Not :: SMTExpr (SMTFun (SMTExpr Bool) Bool)
  Select :: (Args i,SMTType v) => SMTExpr (SMTArray i v) -> i -> SMTExpr v
  Store :: (Args i,SMTType v) => SMTExpr (SMTArray i v) -> i -> SMTExpr v -> SMTExpr (SMTArray i v)
  AsArray :: (Args i,SMTType v) => SMTExpr (SMTFun i v) -> SMTExpr (SMTArray i v)
  ConstArray :: (Args i,SMTType v) => SMTExpr v -> ArgAnnotation i -> SMTExpr (SMTArray i v)
  BVAdd :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVSub :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVMul :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVURem :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVSRem :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVUDiv :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVSDiv :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVULE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVULT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVUGE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVUGT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSLE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSLT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSGE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSGT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSHL :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr t
  BVLSHR :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr t
  BVASHR :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr t
  BVExtract :: (SMTType t1,SMTType t2,Extractable t1 t2) => Integer -> Integer -> SMTAnnotation t2 -> SMTExpr t1 -> SMTExpr t2
  BVConcat :: (Concatable t1 t2,t3 ~ ConcatResult t1 t2)
              => SMTExpr t1 -> SMTExpr t2 -> SMTExpr t3
  BVConcats :: (SMTType t1,SMTType t2,Concatable t2 t1,t2 ~ ConcatResult t2 t1)
               => [SMTExpr t1] -> SMTExpr t2
  BVXor :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVAnd :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVOr :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVNot :: SMTExpr t -> SMTExpr t
  Forall :: Args a => ArgAnnotation a -> (a -> SMTExpr Bool) -> SMTExpr Bool
  Exists :: Args a => ArgAnnotation a -> (a -> SMTExpr Bool) -> SMTExpr Bool
  Let :: (Args a) => ArgAnnotation a -> a -> (a -> SMTExpr b) -> SMTExpr b
  Fun :: (Args a,SMTType r) => Text -> ArgAnnotation a -> SMTAnnotation r -> SMTExpr (SMTFun a r)
  App :: (Args a,SMTType r) => SMTExpr (SMTFun a r) -> a -> SMTExpr r
  Map :: (Mapable a i,SMTAnnotation (SMTArray i r) ~ (ArgAnnotation i,SMTAnnotation r),Typeable r) => SMTExpr (SMTFun a r) -> ArgAnnotation i -> SMTExpr (SMTFun (MapArgument a i) (SMTArray i r))
  ConTest :: SMTType a => Constructor a -> SMTExpr a -> SMTExpr Bool
  FieldSel :: (SMTRecordType a,SMTType f) => Field a f -> SMTExpr a -> SMTExpr f
  Head :: SMTExpr [a] -> SMTExpr a
  Tail :: SMTExpr [a] -> SMTExpr [a]
  Insert :: SMTExpr a -> SMTExpr [a] -> SMTExpr [a]
  Named :: SMTExpr a -> Text -> SMTExpr a
  InternalFun :: [L.Lisp] -> SMTExpr (SMTFun (SMTExpr Bool) Bool)
  Undefined :: SMTExpr a
  deriving Typeable

instance Eq a => Eq (SMTExpr a) where
  (==) = eqExpr 0

eqExpr :: Integer -> SMTExpr a -> SMTExpr a -> Bool
eqExpr n lhs rhs = case (lhs,rhs) of
  (Var v1 _,Var v2 _) -> v1 == v2
  (Const v1 _,Const v2 _) -> v1 == v2
  (Eq,Eq) -> True
  (Ge,Ge) -> True
  (Gt,Gt) -> True
  (Le,Le) -> True
  (Lt,Lt) -> True
  (Distinct x1,Distinct x2) -> eqExprs' n x1 x2
  (Plus,Plus) -> True
  (Minus,Minus) -> True
  (Mult,Mult) -> True
  (Div,Div) -> True
  (Mod,Mod) -> True
  (Rem,Rem) -> True
  (Divide,Divide) -> True
  (Neg,Neg) -> True
  (Abs,Abs) -> True
  (ToReal x,ToReal y) -> eqExpr n x y
  (ToInt x,ToInt y) -> eqExpr n x y
  (ITE c1 l1 r1,ITE c2 l2 r2) -> eqExpr n c1 c2 &&
                                 eqExpr' n l1 l2 && 
                                 eqExpr' n r1 r2
  (And,And) -> True
  (Or,Or) -> True
  (XOr,XOr) -> True
  (Implies,Implies) -> True
  (Not,Not) -> True
  (Select a1 i1,Select a2 i2) -> eqExpr' n a1 a2 && 
                                 (case cast i2 of
                                     Nothing -> False
                                     Just i2' -> i1 == i2')
  (Store a1 i1 v1,Store a2 i2 v2) -> eqExpr n a1 a2 &&
                                     i1 == i2 &&
                                     eqExpr n v1 v2
  (AsArray f1,AsArray f2) -> eqExpr' n f1 f2
  (ConstArray c1 _,ConstArray c2 _) -> eqExpr' n c1 c2
  (BVAdd l1 r1,BVAdd l2 r2) -> eqExpr n l1 l2 &&
                               eqExpr n r1 r2
  (BVSub l1 r1,BVSub l2 r2) -> eqExpr n l1 r2 &&
                               eqExpr n r1 r2
  (BVMul l1 r1,BVMul l2 r2) -> eqExpr n l1 l2 && 
                               eqExpr n r1 r2
  (BVURem l1 r1,BVURem l2 r2) -> eqExpr n l1 l2 &&
                                 eqExpr n r1 r2
  (BVSRem l1 r1,BVSRem l2 r2) -> eqExpr n l1 l2 &&
                                 eqExpr n r1 r2
  (BVUDiv l1 r1,BVUDiv l2 r2) -> eqExpr n l1 l2 &&
                                 eqExpr n r1 r2
  (BVSDiv l1 r1,BVSDiv l2 r2) -> eqExpr n l1 l2 &&
                                 eqExpr n r1 r2
  (BVULE l1 r1,BVULE l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVULT l1 r1,BVULT l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVUGE l1 r1,BVUGE l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVUGT l1 r1,BVUGT l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVSLE l1 r1,BVSLE l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVSLT l1 r1,BVSLT l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVSGE l1 r1,BVSGE l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVSGT l1 r1,BVSGT l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVSHL l1 r1,BVSHL l2 r2) -> eqExpr' n l1 l2 && eqExpr n r1 r2
  (BVExtract l1 u1 _ e1,BVExtract l2 u2 _ e2) -> l1 == l2 && u1 == u2 && eqExpr' n e1 e2
  (BVConcat l1 r1,BVConcat l2 r2) -> eqExpr' n l1 l2 && eqExpr' n r1 r2
  (BVConcats x,BVConcats y) -> eqExprs' n x y
  (BVXor l1 r1,BVXor l2 r2) -> eqExpr n l1 l2 && eqExpr n r1 r2
  (BVAnd l1 r1,BVAnd l2 r2) -> eqExpr n l1 l2 && eqExpr n r1 r2
  (BVOr l1 r1,BVOr l2 r2) -> eqExpr n l1 l2 && eqExpr n r1 r2
  (BVNot x,BVNot y) -> eqExpr n x y
  (Forall a1 f1,Forall a2 f2) -> let name i = T.pack $ "internal_eq_check"++show i
                                     (n',v) = foldExprs (\i _ ann -> (i+1,Var (name i) ann)) n undefined a1
                                 in case cast f2 of
                                   Nothing -> False
                                   Just f2' -> eqExpr n' (f1 v) (f2' v)
  (Exists a1 f1,Exists a2 f2) -> let name i = T.pack $ "internal_eq_check"++show i
                                     (n',v) = foldExprs (\i _ ann -> (i+1,Var (name i) ann)) n undefined a1
                                 in case cast f2 of
                                   Nothing -> False
                                   Just f2' -> eqExpr n' (f1 v) (f2' v)
  (Let a1 x1 f1,Let a2 x2 f2) -> eqExpr n (f1 x1) (f2 x2)
  (ConTest c1 e1,ConTest c2 e2) -> case gcast c2 of
    Nothing -> False
    Just c2' -> c1 == c2' && eqExpr' n e1 e2
  (FieldSel (Field f1) e1,FieldSel (Field f2) e2) -> f1 == f2 && eqExpr' n e1 e2
  (Head x,Head y) -> eqExpr n x y
  (Tail x,Tail y) -> eqExpr n x y
  -- This doesn't work for unknown reasons
  --(Insert x xs,Insert y ys) = eqExpr n x y && eqExpr n xs ys
  (Named e1 n1,Named e2 n2) -> eqExpr n e1 e2 && n1==n2
  (InternalFun arg1,InternalFun arg2) -> arg1 == arg2
  (Undefined,Undefined) -> True
  (App f1 arg1,App f2 arg2) -> case gcast f2 of
      Nothing -> False
      Just f2' -> case cast arg2 of
        Nothing -> False
        Just arg2' -> eqExpr n f1 f2' && arg1 == arg2'
  (Fun name1 _ _,Fun name2 _ _) -> name1 == name2
  (Map f1 _,Map f2 _) -> case gcast f2 of
      Nothing -> False
      Just f2' -> eqExpr n f1 f2'
  _ -> False
  where
    eqExpr' :: (Typeable a,Typeable b) => Integer -> SMTExpr a -> SMTExpr b -> Bool
    eqExpr' n lhs rhs = case gcast rhs of
      Nothing -> False
      Just rhs' -> eqExpr n lhs rhs'

    eqExprs' :: (Eq a,Typeable a,Typeable b) => Integer -> [SMTExpr a] -> [SMTExpr b] -> Bool
    eqExprs' n xs ys = case cast ys of
      Nothing -> False
      Just ys' -> eqExprs n xs ys'

    eqExprs :: (Eq a) => Integer -> [SMTExpr a] -> [SMTExpr a] -> Bool
    eqExprs n (x:xs) (y:ys) = eqExpr n x y && eqExprs n xs ys
    eqExprs _ [] [] = True
    eqExprs _ _ _ = False

-- | Represents a constructor of a datatype /a/
--   Can be obtained by using the template haskell extension module
data Constructor a = Constructor Text deriving (Eq,Show)

-- | Represents a field of the datatype /a/ of the type /f/
data Field a f = Field Text deriving (Eq,Show)

newtype InterpolationGroup = InterpolationGroup Text

-- | Options controling the behaviour of the SMT solver
data SMTOption
     = PrintSuccess Bool -- ^ Whether or not to print \"success\" after each operation
     | ProduceModels Bool -- ^ Produce a satisfying assignment after each successful checkSat
     | ProduceProofs Bool -- ^ Produce a proof of unsatisfiability after each failed checkSat
     | ProduceUnsatCores Bool -- ^ Enable the querying of unsatisfiable cores after a failed checkSat
     deriving (Show,Eq,Ord)

-- | A piece of information of type /r/ that can be obtained by the SMT solver
class SMTInfo i where
  type SMTInfoResult i
  getInfo :: i -> SMT (SMTInfoResult i)

-- | The name of the SMT solver
data SMTSolverName = SMTSolverName deriving (Show,Eq,Ord)

instance SMTInfo SMTSolverName where
  type SMTInfoResult SMTSolverName = String
  getInfo _ = do
    putRequest (L.List [L.Symbol "get-info",L.Symbol ":name"])
    res <- parseResponse
    case res of
      L.List [L.Symbol ":name",L.String name] -> return $ T.unpack name
      _ -> error "Invalid solver response to 'get-info' name query"

-- | The version of the SMT solver
data SMTSolverVersion = SMTSolverVersion deriving (Show,Eq,Ord)

instance SMTInfo SMTSolverVersion where
  type SMTInfoResult SMTSolverVersion = String
  getInfo _ = do
    putRequest (L.List [L.Symbol "get-info",L.Symbol ":version"])
    res <- parseResponse
    case res of
      L.List [L.Symbol ":version",L.String name] -> return $ T.unpack name
      _ -> error "Invalid solver response to 'get-info' version query"

-- | Instances of this class may be used as arguments for constructed functions and quantifiers.
class (Eq a,Typeable a,Typeable (ArgAnnotation a)) => Args a where
  type ArgAnnotation a
  foldExprs :: (forall t. SMTType t => s -> SMTExpr t -> SMTAnnotation t -> (s,SMTExpr t)) -> s -> a -> ArgAnnotation a -> (s,a)

class (Args (MapArgument a i),Args i,Args a) => Mapable a i where
  type MapArgument a i
  getMapArgumentAnn :: a -> i -> ArgAnnotation a -> ArgAnnotation i -> ArgAnnotation (MapArgument a i)

data DeclaredType where
  DeclaredType :: SMTType a => a -> SMTAnnotation a -> DeclaredType
  DeclaredValueType :: SMTValue a => a -> SMTAnnotation a -> DeclaredType

withDeclaredType :: (forall a. SMTType a => a -> SMTAnnotation a -> b) -> DeclaredType -> b
withDeclaredType f (DeclaredType u ann) = f u ann
withDeclaredType f (DeclaredValueType u ann) = f u ann

withDeclaredValueType :: (forall a. SMTValue a => a -> SMTAnnotation a -> b) -> DeclaredType -> Maybe b
withDeclaredValueType f (DeclaredValueType u ann) = Just $ f u ann
withDeclaredValueType _ _ = Nothing

declaredTypeCon :: DeclaredType -> TyCon
declaredTypeCon d = fst $ splitTyConApp $ declaredTypeRep d

declaredTypeRep :: DeclaredType -> TypeRep
declaredTypeRep = withDeclaredType (\u _ -> typeOf u)

declForSMTType :: L.Lisp -> Map TyCon DeclaredType -> DeclaredType
declForSMTType l mp = case List.find (\(_,d) -> withDeclaredType (\u ann -> (getSort u ann) == l) d) (Map.toList mp) of
  Nothing -> error $ "smtlib2: Can't convert type "++show l++" to haskell."
  Just (_,d) -> d

argSorts :: Args a => a -> ArgAnnotation a -> [L.Lisp]
argSorts arg ann = Prelude.reverse res
    where
      (res,_) = foldExprs (\tps e ann' -> ((getSort (getUndef e) ann'):tps,e)) [] arg ann

allOf :: Args a => (forall t. SMTExpr t) -> a
allOf x = snd $ foldExprs (\_ _ _ -> ((),x)) () undefined undefined

unpackArgs :: Args a => (forall t. SMTType t => SMTExpr t -> SMTAnnotation t -> Integer -> (c,Integer)) -> a -> ArgAnnotation a -> Integer -> ([c],Integer)
unpackArgs f x ann i = fst $ foldExprs (\(res,ci) e ann' -> let (p,ni) = f e ann' ci
                                                            in ((res++[p],ni),e)
                                       ) ([],i) x ann

declareArgTypes :: Args a => a -> ArgAnnotation a -> SMT ()
declareArgTypes arg ann
  = fst $ foldExprs (\act e ann' -> (act >> declareType (getUndef e) ann',e)) (return ()) arg ann

declareType' :: DeclaredType -> SMT () -> SMT ()
declareType' decl act = do
  let con = declaredTypeCon decl
  (c,decls,mp) <- getSMT
  if Map.member con decls
    then return ()
    else (do
             putSMT (c,Map.insert con decl decls,mp)
             act)

defaultDeclareValue :: SMTValue a => a -> SMTAnnotation a -> SMT ()
defaultDeclareValue u ann = declareType' (DeclaredValueType u ann) (return ())

defaultDeclareType :: SMTType a => a -> SMTAnnotation a -> SMT ()
defaultDeclareType u ann = declareType' (DeclaredType u ann) (return ())

createArgs :: Args a => ArgAnnotation a -> Integer -> (a,[(Text,L.Lisp)],Integer)
createArgs ann i = let ((tps,ni),res) = foldExprs (\(tps',ci) e ann' -> let name = T.pack $ "arg_"++show ci
                                                                            sort' = getSort (getUndef e) ann'
                                                                        in ((tps'++[(name,sort')],ci+1),Var name ann')
                                                  ) ([],i) (error "Evaluated the argument to createArgs") ann
                   in (res,tps,ni)

-- | An extension of the `Args` class: Instances of this class can be represented as native haskell data types.
class Args a => LiftArgs a where
  type Unpacked a
  -- | Converts a haskell value into its SMT representation.
  liftArgs :: Unpacked a -> ArgAnnotation a -> a
  -- | Converts a SMT representation back into a haskell value.
  unliftArgs :: a -> SMT (Unpacked a)

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust ((Just x):_) = Just x
firstJust (Nothing:xs) = firstJust xs

getUndef :: SMTExpr t -> t
getUndef _ = error "Don't evaluate the result of 'getUndef'"

getFunUndef :: Args a => SMTExpr (SMTFun a r) -> (a,r)
getFunUndef _ = (error "Don't evaluate the first result of 'getFunUndef'",
                 error "Don't evaluate the second result of 'getFunUndef'")

getArrayUndef :: Args i => SMTExpr (SMTArray i v) -> (i,Unpacked i,v)
getArrayUndef _ = (undefined,undefined,undefined)

declareFun :: Text -> [L.Lisp] -> L.Lisp -> SMT ()
declareFun name tps rtp
  = putRequest $ L.List [L.Symbol "declare-fun"
                        ,L.Symbol name
                        ,args tps
                        ,rtp
                        ]

defineFun :: Text -> [(Text,L.Lisp)] -> L.Lisp -> L.Lisp -> SMT ()
defineFun name arg rtp body = putRequest $ L.List [L.Symbol "define-fun"
                                                  ,L.Symbol name
                                                  ,args [ L.List [ L.Symbol n, tp ]
                                                        | (n,tp) <- arg ]
                                                  ,rtp
                                                  ,body ]

declareDatatypes :: [Text] -> [(Text,[(Text,[(Text,L.Lisp)])])] -> SMT ()
declareDatatypes params dts
  = putRequest $ L.List [L.Symbol "declare-datatypes"
                        ,args (fmap L.Symbol params)
                        ,L.List
                         [ L.List $ [L.Symbol name] 
                           ++ [ L.List $ [L.Symbol conName] 
                                ++ [ L.List [L.Symbol fieldName,tp]
                                   | (fieldName,tp) <- fields ]
                              | (conName,fields) <- constructor ]
                         | (name,constructor) <- dts ]
                        ]

args :: [L.Lisp] -> L.Lisp
args [] = L.Symbol "()"
args xs = L.List xs

-- | Check if the model is satisfiable (e.g. if there is a value for each variable so that every assertion holds)
checkSat :: SMT Bool
checkSat = do
  (_,hout) <- askSMT
  clearInput
  putRequest (L.List [L.Symbol "check-sat"])
  res <- liftIO $ BS.hGetLine hout
  case res of
    "sat" -> return True
    "sat\r" -> return True
    "unsat" -> return False
    "unsat\r" -> return False
    _ -> error $ "unknown check-sat response: "++show res

-- | Perform a stacked operation, meaning that every assertion and declaration made in it will be undone after the operation.
stack :: SMT a -> SMT a
stack act = do
  putRequest (L.List [L.Symbol "push",L.toLisp (1::Integer)])
  res <- act
  putRequest (L.List [L.Symbol "pop",L.toLisp (1::Integer)])
  return res

-- | Insert a comment into the SMTLib2 command stream.
--   If you aren't looking at the command stream for debugging, this will do nothing.
comment :: String -> SMT ()
comment msg = do
  (hin,_) <- askSMT
  liftIO $ IO.hPutStr hin $ Prelude.unlines (fmap (';':) (Prelude.lines msg))

-- | Spawn a shell command that is used as a SMT solver via stdin/-out to process the given SMT operation.
withSMTSolver :: String -- ^ The shell command to execute
                 -> SMT a -- ^ The SMT operation to perform
                 -> IO a
withSMTSolver solver f = do
  let cmd = CreateProcess { cmdspec = ShellCommand solver
                          , cwd = Nothing
                          , env = Nothing
                          , std_in = CreatePipe
                          , std_out = CreatePipe
                          , std_err = Inherit
                          , close_fds = False
                          , create_group = False
                          }
  (Just hin,Just hout,_,handle) <- createProcess cmd
  res <- evalStateT (runReaderT (runSMT $ do
                                 res <- f
                                 putRequest (L.List [L.Symbol "exit"])
                                 return res
                                ) (hin,hout)) (Map.empty,Map.empty,Map.empty)
  hClose hin
  hClose hout
  terminateProcess handle
  _ <- waitForProcess handle
  return res

clearInput :: SMT ()
clearInput = do
  (_,hout) <- askSMT
  r <- liftIO $ hReady hout
  if r
    then (do
             _ <- liftIO $ BS.hGetSome hout 1024
             clearInput)
    else return ()

putRequest :: L.Lisp -> SMT ()
putRequest e = do
  clearInput
  (hin,_) <- askSMT
  liftIO $ toByteStringIO (BS.hPutStr hin) (mappend (L.fromLispExpr e) flush)
  liftIO $ BS.hPutStrLn hin ""
  liftIO $ hFlush hin

parseResponse :: SMT L.Lisp
parseResponse = do
  (_,hout) <- askSMT
  str <- liftIO $ BS.hGetLine hout
  let continue (Done _ r) = return r
      continue res@(Partial _) = do
        line <- BS.hGetLine hout
        continue (feed res line)
      continue (Fail str' ctx msg) = error $ "Error parsing "++show str'++" response in "++show ctx++": "++msg
  liftIO $ continue $ parse L.lisp str

-- | Declare a new sort with a specified arity
declareSort :: T.Text -> Integer -> SMT ()
declareSort name arity = putRequest (L.List [L.Symbol "declare-sort",L.Symbol name,L.toLisp arity])

escapeName :: String -> String
escapeName [] = []
escapeName ('_':xs) = '_':'_':escapeName xs
escapeName (x:xs) = x:escapeName xs

freeName :: String -> SMT Text
freeName name = do
  (names,decl,mp) <- getSMT
  let c = case Map.lookup name names of
        Nothing -> 0
        Just c' -> c'
  putSMT (Map.insert name (c+1) names,decl,mp)
  return $ T.pack $ (escapeName name)++(case c of
                                           0 -> ""
                                           _ -> "_"++show c)

removeLets :: L.Lisp -> L.Lisp
removeLets = removeLets' Map.empty
  where
    removeLets' mp (L.List [L.Symbol "let",L.List decls,body])
      = let nmp = Map.union mp 
                  (Map.fromList
                   [ (name,removeLets' nmp expr)
                   | L.List [L.Symbol name,expr] <- decls ])
        in removeLets' nmp body
    removeLets' mp (L.Symbol sym) = case Map.lookup sym mp of
      Nothing -> L.Symbol sym
      Just r -> r
    removeLets' mp (L.List entrs) = L.List $ fmap (removeLets' mp) entrs
    removeLets' _ x = x