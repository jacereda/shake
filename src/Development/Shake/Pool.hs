
-- | Thread pool implementation.
module Development.Shake.Pool(
    Pool, runPool,
    addPool, addPoolPriority,
    increasePool
    ) where

import Control.Concurrent.Extra
import System.Time.Extra
import Control.Exception
import Control.Monad
import General.Timing
import qualified Data.HashSet as Set
import qualified Data.Sequence as S
import System.Random


---------------------------------------------------------------------
-- UNFAIR/RANDOM QUEUE

-- Monad for non-deterministic (but otherwise pure) computations
type NonDet a = IO a

data Queue a = Queue [a] (S.Seq a) Bool

newQueue :: Bool -> Queue a
newQueue = Queue [] S.empty

enqueuePriority :: a -> Queue a -> Queue a
enqueuePriority x (Queue p t det) = Queue (x:p) t det

enqueue :: a -> Queue a -> NonDet (Queue a)
enqueue x (Queue p xs True) = return $ Queue p (xs S.|> x) True
enqueue x (Queue p xs False) = do
  r <- randomIO
  return $ Queue p (if r then xs S.|> x else x S.<| xs) False

dequeue :: Queue a -> Maybe (a, Queue a)
dequeue (Queue (p:ps) t det) = Just (p, Queue ps t det)
dequeue (Queue [] xs det) | S.null xs = Nothing
                        | otherwise = Just (xs `S.index` 0, Queue [] (S.drop 1 xs) det)


---------------------------------------------------------------------
-- THREAD POOL

{-
Must keep a list of active threads, so can raise exceptions in a timely manner
If any worker throws an exception, must signal to all the other workers
-}

data Pool = Pool
    !(Var (Maybe S)) -- Current state, 'Nothing' to say we are aborting
    !(Barrier (Either SomeException S)) -- Barrier to signal that we are

data S = S
    {threads :: !(Set.HashSet ThreadId) -- IMPORTANT: Must be strict or we leak thread stacks
    ,threadsLimit :: {-# UNPACK #-} !Int -- user supplied thread limit, Set.size threads <= threadsLimit
    ,threadsMax :: {-# UNPACK #-} !Int -- high water mark of Set.size threads (accounting only)
    ,threadsSum :: {-# UNPACK #-} !Int -- number of threads we have been through (accounting only)
    ,todo :: !(Queue (IO ())) -- operations waiting a thread
    }


emptyS :: Int -> Bool -> S
emptyS n deterministic = S Set.empty n 0 0 $ newQueue deterministic


-- | Given a pool, and a function that breaks the S invariants, restore them
--   They are only allowed to touch threadsLimit or todo
step :: Pool -> (S -> NonDet S) -> IO ()
step pool@(Pool var done) op = do
    let onVar act = modifyVar_ var $ maybe (return Nothing) act
    onVar $ \s -> do
        s <- op s
        case (dequeue $ todo s) of
            Just (now, todo2) | Set.size (threads s) < threadsLimit s -> do
                -- spawn a new worker
                t <- forkFinally now $ \res -> case res of
                    Left e -> onVar $ \s -> do
                        t <- myThreadId
                        mapM_ killThread $ Set.toList $ Set.delete t $ threads s
                        signalBarrier done $ Left e
                        return Nothing
                    Right _ -> do
                        t <- myThreadId
                        step pool $ \s -> return s{threads = Set.delete t $ threads s}
                let threads2 = Set.insert t $ threads s
                return $ Just s{todo = todo2, threads = threads2
                               ,threadsSum = threadsSum s + 1, threadsMax = threadsMax s `max` Set.size threads2}
            Nothing | Set.null $ threads s -> do
                signalBarrier done $ Right s
                return Nothing
            _ -> return $ Just s


-- | Add a new task to the pool, may be cancelled by sending it an exception
addPool :: Pool -> IO a -> IO ()
addPool pool act = step pool $ \s -> do
    todo <- enqueue (void act) (todo s)
    return s{todo = todo}

-- | Add a new task to the pool, may be cancelled by sending it an exception.
--   Takes priority over everything else.
addPoolPriority :: Pool -> IO a -> IO ()
addPoolPriority pool act = step pool $ \s -> return s{todo = enqueuePriority (void act) (todo s)}


-- | Temporarily increase the pool by 1 thread. Call the cleanup action to restore the value.
--   After calling cleanup you should requeue onto a new thread.
increasePool :: Pool -> IO (IO ())
increasePool pool = do
    step pool $ \s -> return s{threadsLimit = threadsLimit s + 1}
    return $ step pool $ \s -> return s{threadsLimit = threadsLimit s - 1}


-- | Run all the tasks in the pool on the given number of works.
--   If any thread throws an exception, the exception will be reraised.
runPool :: Bool -> Int -> (Pool -> IO ()) -> IO () -- run all tasks in the pool
runPool deterministic n act = do
    s <- newVar $ Just $ emptyS n deterministic
    done <- newBarrier

    let cleanup = modifyVar_ s $ \s -> do
            -- if someone kills our thread, make sure we kill our child threads
            case s of
                Just s -> mapM_ killThread $ Set.toList $ threads s
                Nothing -> return ()
            return Nothing

    let ghc10793 = do
            -- if this thread dies because it is blocked on an MVar there's a chance we have
            -- a better error in the done barrier, and GHC raised the exception wrongly, see:
            -- https://ghc.haskell.org/trac/ghc/ticket/10793
            sleep 1 -- give it a little bit of time for the finally to run
                    -- no big deal, since the blocked indefinitely takes a while to fire anyway
            res <- waitBarrierMaybe done
            case res of
                Just (Left e) -> throwIO e
                _ -> throwIO BlockedIndefinitelyOnMVar
    handle (\BlockedIndefinitelyOnMVar -> ghc10793) $ flip onException cleanup $ do
        let pool = Pool s done
        addPool pool $ act pool
        res <- waitBarrier done
        case res of
            Left e -> throwIO e
            Right s -> addTiming $ "Pool finished (" ++ show (threadsSum s) ++ " threads, " ++ show (threadsMax s) ++ " max)"
