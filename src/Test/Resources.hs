
module Test.Resources(main) where

import Development.Shake
import Test.Type
import Data.List
import System.FilePath
import Control.Exception.Extra hiding (assert)
import System.Time.Extra
import Control.Monad
import Data.IORef


main = shakenCwd test $ \args obj -> do
    -- test I have good Ord and Show
    want args
    do
        r1 <- newResource "test" 2
        r2 <- newResource "special" 67
        unless (r1 < r2 || r2 < r1) $ error "Resources should have a good ordering"
        unless ("special" `isInfixOf` show r2) $ error "Resource should contain their name when shown"

    -- test you are capped to a maximum value
    do
        let cap = 2
        inside <- liftIO $ newIORef 0
        res <- newResource "test" cap
        phony "cap" $ need [obj $ "c_file" ++ show i ++ ".txt" | i <- [1..4]]
        obj "c_*.txt" %> \out ->
            withResource res 1 $ do
                old <- liftIO $ atomicModifyIORef inside $ \i -> (i+1,i)
                when (old >= cap) $ error "Too many resources in use at one time"
                liftIO $ sleep 0.1
                liftIO $ atomicModifyIORef inside $ \i -> (i-1,i)
                writeFile' out ""

    -- test things can still run while you are blocked on a resource
    do
        done <- liftIO $ newIORef 0
        lock <- newResource "lock" 1
        phony "schedule" $ do
            need $ map (\x -> obj $ "s_" ++ x) $ "lock1":"done":["free" ++ show i | i <- [1..10]] ++ ["lock2"]
        obj "s_done" %> \out -> do
            need [obj "s_lock1",obj "s_lock2"]
            done <- liftIO $ readIORef done
            when (done < 10) $ error "Not all managed to schedule while waiting"
            writeFile' out ""
        obj "s_lock*" %> \out -> do
            withResource lock 1 $ liftIO $ sleep 0.5
            writeFile' out ""
        obj "s_free*" %> \out -> do
            liftIO $ atomicModifyIORef done $ \i -> (i+1,())
            writeFile' out ""

    -- test that throttle works properly
    do
        res <- newThrottle "throttle" 2 0.4
        phony "throttle" $ need $ map obj ["t_file1.1","t_file2.1","t_file3.2","t_file4.1","t_file5.2"]
        obj "t_*.*" %> \out -> do
            withResource res (read $ drop 1 $ takeExtension out) $
                when (takeBaseName out == "t_file3") $ liftIO $ sleep 0.2
            writeFile' out ""


test build obj = do
    build ["-j2","cap","--clean"]
    build ["-j4","cap","--clean"]
    build ["-j10","cap","--clean"]
    build ["-j2","schedule","--clean"]

    forM_ ["-j1","-j8"] $ \flags ->
        -- we are sometimes over the window if the machine is "a bit loaded" at some particular time
        -- therefore we rerun the test three times, and only fail if it fails on all of them
        retry 3 $ do
            (s, _) <- duration $ build [flags,"throttle","--no-report","--clean"]
            -- the 0.1s cap is a guess at an upper bound for how long everything else should take
            -- and should be raised on slower machines
            assert (s >= 1.4 && s < 1.6) $
                "Bad throttling, expected to take 1.4s + computation time (cap of 0.2s), took " ++ show s ++ "s"
