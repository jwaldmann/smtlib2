{- | Gives interfaces to some common SMT solvers.
 -}
module Language.SMTLib2.Solver where

import Language.SMTLib2
import Control.Monad.Trans (MonadIO)

-- | Z3 is a solver by Microsoft <http://research.microsoft.com/en-us/um/redmond/projects/z3>.
withZ3 :: MonadIO m => SMT' m a -> m a
withZ3 = withSMTSolver "z3 -smt2 -in"

-- | MathSAT <http://mathsat.fbk.eu>.
withMathSat :: MonadIO m => SMT' m a -> m a
withMathSat = withSMTSolver "mathsat"

-- | CVC4 is an open-source SMT solver <http://cs.nyu.edu/acsys/cvc4>
withCVC4 :: MonadIO m => SMT' m a -> m a
withCVC4 = withSMTSolver "cvc4 --lang smt2"

-- | SMTInterpol is an experimental interpolating SMT solver <http://ultimate.informatik.uni-freiburg.de/smtinterpol>
withSMTInterpol :: MonadIO m => SMT' m a -> m a
withSMTInterpol = withSMTSolver "java -jar /usr/local/share/java/smtinterpol.jar -q"
