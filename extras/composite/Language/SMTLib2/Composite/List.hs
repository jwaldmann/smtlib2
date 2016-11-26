module Language.SMTLib2.Composite.List where

import Language.SMTLib2
import Language.SMTLib2.Composite.Class
import Language.SMTLib2.Composite.Container
import Language.SMTLib2.Composite.Domains
import Language.SMTLib2.Composite.Null

import Data.List (genericIndex)
import Data.Maybe (catMaybes)
import Data.GADT.Show
import Data.GADT.Compare
import Text.Show
import Data.Foldable

data RevList a tp = RevList Integer (RevComp a tp)

newtype CompList a (e :: Type -> *) = CompList { compList :: [a e] }

instance Composite a => Composite (CompList a) where
  type RevComp (CompList a) = RevList a
  foldExprs f (CompList lst) = do
    nlst <- mapM (\(n,el) -> foldExprs (f . RevList n) el) (zip [0..] lst)
    return (CompList nlst)
  getRev (RevList n r) (CompList lst) = do
    el <- safeGenericIndex lst n
    getRev r el
  setRev (RevList n r) x (Just (CompList lst)) = do
    nel <- setRev r x (safeGenericIndex lst n)
    nlst <- safeGenericInsertAt n nel lst
    return $ CompList nlst
  setRev _ _ _ = Nothing
  compCombine f (CompList xs) (CompList ys) = fmap (fmap CompList) $ merge xs ys
    where
      merge [] ys = return (Just ys)
      merge xs [] = return (Just xs)
      merge (x:xs) (y:ys) = do
        z <- compCombine f x y
        case z of
          Just z' -> do
            zs <- merge xs ys
            return $ fmap (z':) zs
          Nothing -> return Nothing
  compCompare (CompList xs) (CompList ys) = comp xs ys
    where
      comp [] [] = EQ
      comp [] _  = LT
      comp _ []  = GT
      comp (x:xs) (y:ys) = case compCompare x y of
        EQ -> comp xs ys
        r -> r
  compShow = showsPrec
  compInvariant (CompList xs) = fmap concat $ mapM compInvariant xs

instance Container CompList where
  type CIndex CompList = NoComp Integer
  elementGet (NoComp i) (CompList lst) = case safeGenericIndex lst i of
    Nothing -> error $ "elementGet{CompList}: Index "++show i++" out of range."
    Just res -> return res
  elementSet (NoComp i) x (CompList lst)
    = case safeGenericUpdateAt i (\_ -> Just x) lst of
    Just nlst -> return (CompList nlst)
    Nothing -> error $ "elementSet{CompList}: Index "++show i++" out of range."

dynamicAt :: (Composite a,Integral (Value tp),Embed m e,Monad m,GetType e)
          => Maybe (Range tp) -> e tp
          -> Accessor (CompList a) (NoComp Integer) a m e
dynamicAt (Just (asFiniteRange -> Just [val])) _
  = at (NoComp $ toInteger val)
dynamicAt rng i = Accessor get set
  where
    get (CompList lst) = fmap catMaybes $
                         mapM (\(el,idx) -> do
                                  let vidx = fromInteger idx
                                  case rng of
                                    Just rng'
                                      | includes vidx rng' -> do
                                          cond <- i .==. constant vidx
                                          return $ Just (NoComp idx,[cond],el)
                                    _ -> return Nothing
                              ) (zip lst [0..])
    set upd (CompList lst) = return $ CompList $ merge upd 0 lst
    merge [] _ lst = lst
    merge upd@((NoComp i,el):upd') p (x:xs)
      | i==p      = el:merge upd' (p+1) xs
      | otherwise = x:merge upd (p+1) xs

instance (Composite a,GShow e) => Show (CompList a e) where
  showsPrec _ (CompList xs) = showListWith (compShow 0) xs

{-instance (Composite a,IsRanged idx,
          Enum (Value (SingletonType idx))
         ) => IsArray (CompList a) idx where
  type ElementType (CompList a) = a
  select (CompList xs) idx = ites trgs
    where
      rng = getRange idx
      trgs = [ (x,i) | (x,i) <- zip xs [toEnum 0..]
                     , includes i rng ]
      ites [] = return Nothing
      ites [(el,_)] = return (Just el)
      ites ((el,v):rest) = do
        ifF <- ites rest
        case ifF of
          Nothing -> return Nothing
          Just ifF' -> do
            cond <- getSingleton idx .==. constant v
            compITE cond el ifF'
  store (CompList xs) idx nel = do
    nxs <- sequence updated
    return $ fmap CompList $ sequence nxs
    where
      rng = getRange idx
      updated = case isConst rng of
        Nothing -> [ if includes i rng
                     then do
                       cond <- getSingleton idx .==. constant i
                       compITE cond nel x
                     else return (Just x)
                   | (x,i) <- zip xs [toEnum 0..] ]
        Just ri -> [ if i==ri
                     then return (Just nel)
                     else return (Just x)
                   | (x,i) <- zip xs [toEnum 0..] ]-}

instance CompositeExtract a => CompositeExtract (CompList a) where
  type CompExtract (CompList a) = [CompExtract a]
  compExtract f (CompList xs) = mapM (compExtract f) xs

instance Composite a => Show (RevList a tp) where
  showsPrec p (RevList n r)
    = showParen (p>10) $ showString "RevList " .
      showsPrec 11 n . showChar ' ' . gshowsPrec 11 r

instance Composite a => GShow (RevList a) where
  gshowsPrec = showsPrec

instance Composite a => GEq (RevList a) where
  geq (RevList n1 r1) (RevList n2 r2) = if n1==n2
                                        then do
    Refl <- geq r1 r2
    return Refl
                                        else Nothing

instance Composite a => GCompare (RevList a) where
  gcompare (RevList n1 r1) (RevList n2 r2) = case compare n1 n2 of
    EQ -> case gcompare r1 r2 of
      GEQ -> GEQ
      GLT -> GLT
      GGT -> GGT
    LT -> GLT
    GT -> GGT

safeGenericIndex :: (Num i,Eq i) => [a] -> i -> Maybe a
safeGenericIndex (x:xs) 0 = Just x
safeGenericIndex (_:xs) n = safeGenericIndex xs (n-1)
safeGenericIndex [] _ = Nothing

safeGenericInsertAt :: (Num i,Eq i) => i -> a -> [a] -> Maybe [a]
safeGenericInsertAt 0 x (_:ys) = Just $ x:ys
safeGenericInsertAt n x (y:ys) = do
  ys' <- safeGenericInsertAt (n-1) x ys
  return $ y:ys'
safeGenericInsertAt _ _ [] = Nothing

safeGenericUpdateAt :: (Num i,Eq i) => i -> (a -> Maybe a) -> [a] -> Maybe [a]
safeGenericUpdateAt 0 f (x:xs) = do
  nx <- f x
  return $ nx:xs
safeGenericUpdateAt n f (x:xs) = do
  nxs <- safeGenericUpdateAt (n-1) f xs
  return $ x:nxs
safeGenericUpdateAt _ _ [] = Nothing

instance StaticByteWidth a => StaticByteWidth (CompList a) where
  staticByteWidth (CompList xs) = sum $ fmap staticByteWidth xs
