module Language.SMTLib2.Composite.Array.Static where

import Language.SMTLib2
import Language.SMTLib2.Composite.Class
import Language.SMTLib2.Composite.Domains

import Data.Map (Map)
import qualified Data.Map as Map
import Data.GADT.Compare
import Data.Type.Equality ((:~:)(Refl))
import Data.GADT.Show
import Text.Show
import Data.Functor.Identity

data StaticArray idx el (e :: Type -> *)
  = StaticArray { indexType' :: List Repr idx
                , defaultElement :: el e
                , stores :: Map (List Value idx) (el e) }

data RevStaticArray idx el (tp :: Type) where
  RevDefaultElement :: RevComp el tp -> RevStaticArray idx el tp
  RevStore :: List Value idx -> RevComp el tp -> RevStaticArray idx el tp

instance Composite el => Composite (StaticArray idx el) where
  type RevComp (StaticArray idx el) = RevStaticArray idx el
  foldExprs f arr = do
    ndef <- foldExprs (f . RevDefaultElement) (defaultElement arr)
    nstores <- Map.traverseWithKey
               (\idx el -> foldExprs (f . RevStore idx) el)
               (stores arr)
    return (StaticArray (indexType' arr) ndef nstores)
  mapExprs f arr = do
    ndef <- mapExprs f (defaultElement arr)
    nstores <- mapM (mapExprs f) (stores arr)
    return (StaticArray (indexType' arr) ndef nstores)
  getRev (RevDefaultElement r) arr = getRev r (defaultElement arr)
  getRev (RevStore idx r) arr = do
    el <- Map.lookup idx (stores arr)
    getRev r el
  setRev (RevDefaultElement r) e (Just arr) = do
    ndef <- setRev r e (Just $ defaultElement arr)
    return arr { defaultElement = ndef }
  setRev (RevStore idx r) e (Just arr) = do
    nstore <- setRev r e (Map.lookup idx $ stores arr)
    return arr { stores = Map.insert idx nstore (stores arr) }
  setRev _ _ Nothing = Nothing
  compCombine f (StaticArray i1 d1 st1) (StaticArray _ d2 st2) = do
    nd <- compCombine f d1 d2
    case nd of
      Nothing -> return Nothing
      Just nd' -> do
        nst <- sequence $ Map.mergeWithKey (\_ x y -> Just $ compCombine f x y)
          (fmap (\x -> compCombine f x d2))
          (fmap (\x -> compCombine f d1 x))
          st1 st2
        case sequence nst of
          Nothing -> return Nothing
          Just nst' -> return $ Just $ StaticArray i1 nd' nst'
  compCompare (StaticArray _ d1 st1) (StaticArray _ d2 st2)
    = case compCompare d1 d2 of
    EQ -> mconcat $ Map.elems $ Map.mergeWithKey (\_ x y -> Just $ compCompare x y) (fmap (const LT)) (fmap (const GT)) st1 st2
    r -> r
  compShow p (StaticArray idx d st) = showParen (p>10) $ showString "StaticArray " .
    showsPrec 11 idx . showChar ' ' .
    compShow 11 d . showChar ' ' .
    showListWith (\(val,el) -> showsPrec 10 val . showString " -> " . compShow 10 el) (Map.toList st)
  compInvariant (StaticArray _ d st) = do
    invD <- compInvariant d
    invSt <- mapM compInvariant st
    return $ invD++concat (Map.elems invSt)

instance Composite el => Wrapper (StaticArray idx el) where
  type ElementType (StaticArray idx el) = el
  elementType arr = foldl (\cur el -> let elType = compType el
                                      in case runIdentity $ compCombine (const return) cur elType of
                                           Just ncur -> ncur
                                           Nothing -> error "incompatible elements in static array"
                          ) defType (stores arr)
    where
      defType = compType $ defaultElement arr

instance (IsRanged idx,SingletonType idx ~ i,Composite el) => IsArray (StaticArray '[i] el) idx where
  newArray idx el = return $ StaticArray { indexType' = runIdentity (getSingleton idx) ::: Nil
                                         , defaultElement = el
                                         , stores = Map.empty }
  select arr idx = do
    idxRange <- getRange idx
    let itp = case indexType' arr of
           tp ::: Nil -> tp
        storeRange = rangeFromList itp (fmap (\(x:::Nil) -> x) $ Map.keys $ stores arr)
        --readRange = intersectionRange storeRange idxRange
        hasDefaultRead = not $ nullRange $ setMinusRange idxRange storeRange
        reads = Map.filterWithKey (\(k ::: Nil) _ -> includes k idxRange) (stores arr)
    nreads <- mapM (\(val ::: Nil,entr) -> do
                       cond <- getSingleton idx .==. constant val
                       return (cond,entr)
                   ) (Map.toList reads)
    defRead <- if hasDefaultRead
               then do
      cond <- true
      return [(cond,defaultElement arr)]
               else return []
    mkITE (nreads++defRead)
    where
      mkITE [(_,e)] = return (Just e)
      mkITE ((cond,ifT):rest) = do
        ifF <- mkITE rest
        case ifF of
          Nothing -> return Nothing
          Just ifF' -> compITE cond ifT ifF'
  store arr idx nel = do
    idxRange <- getRange idx
    case asFiniteRange idxRange of
      Nothing -> return Nothing
      Just trgs -> do
        nstores <- fmap sequence $ sequence $
                   Map.mergeWithKey (\(val:::Nil) el () -> Just $ do
                                        cond <- getSingleton idx .==. constant val
                                        compITE cond nel el)
                   (fmap (return.Just))
                   (fmap (\_ -> return $ Just nel))
                   (stores arr)
                   (Map.fromList [ (trg:::Nil,()) | trg <- trgs ])
        case nstores of
          Nothing -> return Nothing
          Just st -> return $ Just arr { stores = st }

instance Composite el => GEq (RevStaticArray idx el) where
  geq (RevDefaultElement r1) (RevDefaultElement r2) = do
    Refl <- geq r1 r2
    return Refl
  geq (RevStore i1 r1) (RevStore i2 r2)
    = if i1==i2
      then do
    Refl <- geq r1 r2
    return Refl
      else Nothing
  geq _ _ = Nothing

instance Composite el => GCompare (RevStaticArray idx el) where
  gcompare (RevDefaultElement r1) (RevDefaultElement r2) = case gcompare r1 r2 of
    GEQ -> GEQ
    GLT -> GLT
    GGT -> GGT
  gcompare (RevDefaultElement _) _ = GLT
  gcompare _ (RevDefaultElement _) = GGT
  gcompare (RevStore i1 r1) (RevStore i2 r2) = case compare i1 i2 of
    EQ -> case gcompare r1 r2 of
      GEQ -> GEQ
      GLT -> GLT
      GGT -> GGT
    LT -> GLT
    GT -> GGT

instance Composite el => Show (RevStaticArray idx el tp) where
  showsPrec p (RevDefaultElement r)
    = showParen (p>10) $
      showString "RevDefaultElement " .
      gshowsPrec 11 r
  showsPrec p (RevStore i r)
    = showParen (p>10) $
      showString "RevStore " .
      showsPrec 11 i . showChar ' ' .
      gshowsPrec 11 r

instance Composite el => GShow (RevStaticArray idx el) where
  gshowsPrec = showsPrec
