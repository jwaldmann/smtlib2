module Language.SMTLib2.Composite.Tuple where

import Language.SMTLib2
import Language.SMTLib2.Composite.Class
import Language.SMTLib2.Composite.Domains
import Language.SMTLib2.Composite.Container

import Data.GADT.Show
import Data.GADT.Compare
import Data.Type.Equality ((:~:)(Refl))
import Data.Proxy
import qualified Data.Map as Map

data CompTuple2 (a :: (Type -> *) -> *) (b :: (Type -> *) -> *) e
  = CompTuple2 { ctuple2_1 :: !(a e)
               , ctuple2_2 :: !(b e) }

data CompTuple3 (a :: (Type -> *) -> *) (b :: (Type -> *) -> *) (c :: (Type -> *) -> *) e
  = CompTuple3 { ctuple3_1 :: !(a e)
               , ctuple3_2 :: !(b e)
               , ctuple3_3 :: !(c e) }

data RevTuple2 a b tp
  = RevTuple2_1 !(RevComp a tp)
  | RevTuple2_2 !(RevComp b tp)

data RevTuple3 a b c tp
  = RevTuple3_1 !(RevComp a tp)
  | RevTuple3_2 !(RevComp b tp)
  | RevTuple3_3 !(RevComp c tp)

instance (Composite a,Composite b,GShow e) => Show (CompTuple2 a b e) where
  showsPrec p (CompTuple2 x y) = showChar '(' . compShow 0 x . showChar ',' . compShow 0 y . showChar ')'

instance (Composite a,Composite b) => Composite (CompTuple2 a b) where
  type RevComp (CompTuple2 a b) = RevTuple2 a b
  foldExprs f tup = do
    n1 <- foldExprs (f . RevTuple2_1) (ctuple2_1 tup)
    n2 <- foldExprs (f . RevTuple2_2) (ctuple2_2 tup)
    return $ CompTuple2 n1 n2
  mapExprs f tup = do
    n1 <- mapExprs f (ctuple2_1 tup)
    n2 <- mapExprs f (ctuple2_2 tup)
    return $ CompTuple2 n1 n2
  getRev (RevTuple2_1 r) (CompTuple2 x _) = getRev r x
  getRev (RevTuple2_2 r) (CompTuple2 _ x) = getRev r x
  setRev (RevTuple2_1 r) el (Just (CompTuple2 x y)) = do
    nx <- setRev r el (Just x)
    return $ CompTuple2 nx y
  setRev (RevTuple2_2 r) el (Just (CompTuple2 x y)) = do
    ny <- setRev r el (Just y)
    return $ CompTuple2 x ny
  setRev _ _ Nothing = Nothing
  compCombine f (CompTuple2 x1 y1) (CompTuple2 x2 y2) = do
    actX <- compCombine f x1 x2
    actY <- compCombine f y1 y2
    return $ do
      x3 <- actX
      y3 <- actY
      return $ CompTuple2 x3 y3
  compCompare (CompTuple2 x1 y1) (CompTuple2 x2 y2) = case compCompare x1 x2 of
    EQ -> compCompare y1 y2
    r -> r
  compIsSubsetOf f (CompTuple2 x1 y1) (CompTuple2 x2 y2)
    = compIsSubsetOf f x1 x2 &&
      compIsSubsetOf f y1 y2
  compShow = showsPrec
  compInvariant (CompTuple2 x y) = do
    invX <- compInvariant x
    invY <- compInvariant y
    return $ invX++invY
  revName (_::Proxy (CompTuple2 a b)) (RevTuple2_1 r) = "t0_"++revName (Proxy::Proxy a) r
  revName (_::Proxy (CompTuple2 a b)) (RevTuple2_2 r) = "t1_"++revName (Proxy::Proxy b) r

instance (Composite a,Composite b) => Container (CompTuple2 a b) where
  data Index (CompTuple2 a b) el e where
    Tuple2_1 :: Index (CompTuple2 a b) a e
    Tuple2_2 :: Index (CompTuple2 a b) b e
  elementGet (CompTuple2 x _) Tuple2_1 = return x
  elementGet (CompTuple2 _ y) Tuple2_2 = return y

  elementSet (CompTuple2 _ y) Tuple2_1 x = return (CompTuple2 x y)
  elementSet (CompTuple2 x _) Tuple2_2 y = return (CompTuple2 x y)

  showIndex _ Tuple2_1 = showString "[1/2]"
  showIndex _ Tuple2_2 = showString "[2/2]"

instance (CompositeExtract a,CompositeExtract b)
  => CompositeExtract (CompTuple2 a b) where
  type CompExtract (CompTuple2 a b) = (CompExtract a,CompExtract b)
  compExtract f (CompTuple2 a b)
    = (\va vb -> (va,vb)) <$>
      compExtract f a <*>
      compExtract f b

instance (Composite a,Composite b,Composite c,GShow e)
         => Show (CompTuple3 a b c e) where
  showsPrec p (CompTuple3 x y z) = showChar '(' .
                                   compShow 0 x . showChar ',' .
                                   compShow 0 y . showChar ',' .
                                   compShow 0 z . showChar ')'

instance (Composite a,Composite b,Composite c) => Composite (CompTuple3 a b c) where
  type RevComp (CompTuple3 a b c) = RevTuple3 a b c
  foldExprs f tup = do
    n1 <- foldExprs (f . RevTuple3_1) (ctuple3_1 tup)
    n2 <- foldExprs (f . RevTuple3_2) (ctuple3_2 tup)
    n3 <- foldExprs (f . RevTuple3_3) (ctuple3_3 tup)
    return $ CompTuple3 n1 n2 n3
  mapExprs f tup = do
    n1 <- mapExprs f (ctuple3_1 tup)
    n2 <- mapExprs f (ctuple3_2 tup)
    n3 <- mapExprs f (ctuple3_3 tup)
    return $ CompTuple3 n1 n2 n3
  getRev (RevTuple3_1 r) (CompTuple3 x _ _) = getRev r x
  getRev (RevTuple3_2 r) (CompTuple3 _ x _) = getRev r x
  getRev (RevTuple3_3 r) (CompTuple3 _ _ x) = getRev r x
  setRev (RevTuple3_1 r) e (Just (CompTuple3 x y z)) = do
    nx <- setRev r e (Just x)
    return $ CompTuple3 nx y z
  setRev (RevTuple3_2 r) e (Just (CompTuple3 x y z)) = do
    ny <- setRev r e (Just y)
    return $ CompTuple3 x ny z
  setRev (RevTuple3_3 r) e (Just (CompTuple3 x y z)) = do
    nz <- setRev r e (Just z)
    return $ CompTuple3 x y nz
  setRev _ _ Nothing = Nothing
  compCombine f (CompTuple3 x1 y1 z1) (CompTuple3 x2 y2 z2) = do
    actX <- compCombine f x1 x2
    actY <- compCombine f y1 y2
    actZ <- compCombine f z1 z2
    return $ do
      x3 <- actX
      y3 <- actY
      z3 <- actZ
      return $ CompTuple3 x3 y3 z3
  compCompare (CompTuple3 x1 y1 z1) (CompTuple3 x2 y2 z2) = case compCompare x1 x2 of
    EQ -> case compCompare y1 y2 of
      EQ -> compCompare z1 z2
      r -> r
    r -> r
  compIsSubsetOf f (CompTuple3 x1 y1 z1) (CompTuple3 x2 y2 z2)
    = compIsSubsetOf f x1 x2 &&
      compIsSubsetOf f y1 y2 &&
      compIsSubsetOf f z1 z2
  compShow = showsPrec
  compInvariant (CompTuple3 x y z) = do
    invX <- compInvariant x
    invY <- compInvariant y
    invZ <- compInvariant z
    return $ invX++invY++invZ

instance (CompositeExtract a,CompositeExtract b,CompositeExtract c)
  => CompositeExtract (CompTuple3 a b c) where
  type CompExtract (CompTuple3 a b c) = (CompExtract a,CompExtract b,CompExtract c)
  compExtract f (CompTuple3 a b c) = do
    va <- compExtract f a
    vb <- compExtract f b
    vc <- compExtract f c
    return (va,vb,vc)

instance (Composite a,Composite b) => Show (RevTuple2 a b tp) where
  showsPrec p (RevTuple2_1 r) = showParen (p>10) $
    showString "[1/2] " .
    gshowsPrec 0 r
  showsPrec p (RevTuple2_2 r) = showParen (p>10) $
    showString "[2/2] " .
    gshowsPrec 0 r

instance (Composite a,Composite b,Composite c) => Show (RevTuple3 a b c tp) where
  showsPrec p (RevTuple3_1 r) = showParen (p>10) $
    showString "[1/3] " .
    gshowsPrec 0 r
  showsPrec p (RevTuple3_2 r) = showParen (p>10) $
    showString "[2/3] " .
    gshowsPrec 0 r
  showsPrec p (RevTuple3_3 r) = showParen (p>10) $
    showString "[3/3] " .
    gshowsPrec 0 r

instance (Composite a,Composite b) => GShow (RevTuple2 a b) where
  gshowsPrec = showsPrec

instance (Composite a,Composite b,Composite c) => GShow (RevTuple3 a b c) where
  gshowsPrec = showsPrec

instance (Composite a,Composite b) => GEq (RevTuple2 a b) where
  geq (RevTuple2_1 r1) (RevTuple2_1 r2) = do
    Refl <- geq r1 r2
    return Refl
  geq (RevTuple2_2 r1) (RevTuple2_2 r2) = do
    Refl <- geq r1 r2
    return Refl
  geq _ _ = Nothing

instance (Composite a,Composite b,Composite c) => GEq (RevTuple3 a b c) where
  geq (RevTuple3_1 r1) (RevTuple3_1 r2) = do
    Refl <- geq r1 r2
    return Refl
  geq (RevTuple3_2 r1) (RevTuple3_2 r2) = do
    Refl <- geq r1 r2
    return Refl
  geq (RevTuple3_3 r1) (RevTuple3_3 r2) = do
    Refl <- geq r1 r2
    return Refl
  geq _ _ = Nothing

instance (Composite a,Composite b) => GCompare (RevTuple2 a b) where
  gcompare (RevTuple2_1 r1) (RevTuple2_1 r2) = case gcompare r1 r2 of
    GEQ -> GEQ
    GLT -> GLT
    GGT -> GGT
  gcompare (RevTuple2_1 _) _ = GLT
  gcompare _ (RevTuple2_1 _) = GGT
  gcompare (RevTuple2_2 r1) (RevTuple2_2 r2) = case gcompare r1 r2 of
    GEQ -> GEQ
    GLT -> GLT
    GGT -> GGT

instance (Composite a,Composite b,Composite c) => GCompare (RevTuple3 a b c) where
  gcompare (RevTuple3_1 r1) (RevTuple3_1 r2) = case gcompare r1 r2 of
    GEQ -> GEQ
    GLT -> GLT
    GGT -> GGT
  gcompare (RevTuple3_1 _) _ = GLT
  gcompare _ (RevTuple3_1 _) = GGT
  gcompare (RevTuple3_2 r1) (RevTuple3_2 r2) = case gcompare r1 r2 of
    GEQ -> GEQ
    GLT -> GLT
    GGT -> GGT
  gcompare (RevTuple3_2 _) _ = GLT
  gcompare _ (RevTuple3_2 _) = GGT
  gcompare (RevTuple3_3 r1) (RevTuple3_3 r2) = case gcompare r1 r2 of
    GEQ -> GEQ
    GLT -> GLT
    GGT -> GGT

instance (ByteWidth a idx,ByteWidth b idx) => ByteWidth (CompTuple2 a b) idx where
  byteWidth (CompTuple2 x y) r = do
    wx <- byteWidth x r
    wy <- byteWidth y r
    unJust $ compositePlus wx wy

instance (StaticByteWidth a,StaticByteAccess a el,StaticByteAccess b el,CanConcat el)
         => StaticByteAccess (CompTuple2 a b) el where
  staticByteRead (CompTuple2 x y) idx sz = do
    let wx = staticByteWidth x
    if idx >= wx
      then staticByteRead y (idx-wx) sz
      else do
      rx <- staticByteRead x idx sz
      case rx of
        Nothing -> return Nothing
        Just (rx',restx) -> if restx==0
                            then return $ Just (rx',0)
                            else do
          ry <- staticByteRead y (idx-wx) restx
          case ry of
            Nothing -> return Nothing
            Just (ry',resty) -> do
              res <- compConcat [rx',ry']
              case res of
                Nothing -> return Nothing
                Just res' -> return $ Just (res',resty)

instance (StaticByteWidth a,ByteAccess a idx el,ByteAccess b idx el,CanConcat el)
         => ByteAccess (CompTuple2 a b) idx el where
  byteRead (CompTuple2 x y) (idx :: idx e) sz = do
    rx <- byteRead x idx sz
    reads1 <- case fullRead rx of
      Just r -> do
        cond <- fullReadCond rx
        cond' <- case cond of
          [] -> true
          [c] -> return c
          _ -> and' cond
        return [(ByteRead Map.empty Nothing (Just r) (readImprecision rx),cond')]
      Nothing -> return []
    reads2 <- sequence [ do
                           let Just zero' = compositeFromInteger 0 (compType idx)
                           zero <- mapExprs constant zero'
                           r <- byteRead y (zero::idx e) rest
                           nr <- concatRead part r
                           return (nr,cond)
                       | (rest,(part,cond)) <- Map.toList $ overreads rx ]
    reads3 <- case readOutside rx of
      Nothing -> return []
      Just cond -> do
        let wx = staticByteWidth x
            Just vwx = compositeFromInteger wx (compType idx)
        wx' <- mapExprs constant vwx
        nidx <- unJust $ compositeMinus idx wx'
        ry <- byteRead y nidx sz
        return [(ry,cond)]
    byteReadITE (reads1++reads2++reads3)
  byteWrite (CompTuple2 x y) (idx::idx e) el = do
    wx <- byteWrite x idx el
    writes1 <- case fullWrite wx of
      Just w -> do
        cond <- fullWriteCond wx
        cond' <- case cond of
          [] -> true
          [c] -> return c
          _ -> and' cond
        return [(ByteWrite [] Nothing (Just (CompTuple2 w y)) (writeImprecision wx),cond')]
      Nothing -> return []
    writes2 <- sequence [ do
                            let Just zero' = compositeFromInteger 0
                                             (compType idx)
                            zero <- mapExprs constant zero'
                            wy <- byteWrite y (zero::idx e) rest
                            return $ (wy { fullWrite = case fullWrite wx of
                                             Nothing -> case fullWrite wy of
                                               Nothing -> Nothing
                                               Just y' -> Just $ CompTuple2 x y'
                                             Just x' -> case fullWrite wy of
                                               Nothing -> Just $ CompTuple2 x' y
                                               Just y' -> Just $ CompTuple2 x' y' },cond)
                        | (rest,cond) <- overwrite wx ]
    writes3 <- case writeOutside wx of
      Nothing -> return []
      Just cond -> do
        let szx = staticByteWidth x
            Just vszx = compositeFromInteger szx (compType idx)
        szx' <- mapExprs constant vszx
        nidx <- unJust $ compositeMinus idx szx'
        wy <- byteWrite y nidx el
        return [(wy { fullWrite = case fullWrite wy of
                        Nothing -> Nothing
                        Just y' -> Just $ CompTuple2 x y'
                    },cond)]
    byteWriteITE (writes1++writes2++writes3)

