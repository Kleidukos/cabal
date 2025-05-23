{-# LANGUAGE FlexibleContexts #-}

-----------------------------------------------------------------------------

-----------------------------------------------------------------------------

-- |
-- Module      :  Distribution.Client.JobControl
-- Copyright   :  (c) Duncan Coutts 2012
-- License     :  BSD-like
--
-- Maintainer  :  cabal-devel@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- A job control concurrency abstraction
module Distribution.Client.JobControl
  ( JobControl
  , newSerialJobControl
  , newParallelJobControl
  , newSemaphoreJobControl
  , spawnJob
  , collectJob
  , remainingJobs
  , cancelJobs
  , cleanupJobControl
  , jobControlSemaphore
  , JobLimit
  , newJobLimit
  , withJobLimit
  , Lock
  , newLock
  , criticalSection

    -- * Higher level utils
  , newJobControlFromParStrat
  , withJobControl
  , mapConcurrentWithJobs
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import Control.Concurrent (forkIO, forkIOWithUnmask, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar)
import Control.Concurrent.STM.TChan
import Control.Exception (bracket, bracket_, mask_, try)
import Control.Monad (forever, replicateM_)
import Distribution.Client.Compat.Semaphore
import Distribution.Client.Utils (numberOfProcessors)
import Distribution.Compat.Stack
import Distribution.Simple.Compiler
import Distribution.Simple.Utils
import Distribution.Types.ParStrat
import System.Semaphore

-- | A simple concurrency abstraction. Jobs can be spawned and can complete
-- in any order. This allows both serial and parallel implementations.
data JobControl m a = JobControl
  { spawnJob :: m a -> m ()
  -- ^ Add a new job to the pool of jobs
  , collectJob :: m a
  -- ^ Wait until one job is complete
  , remainingJobs :: m Bool
  -- ^ Returns True if there are any outstanding jobs
  -- (ie spawned but yet to be collected)
  , cancelJobs :: m ()
  -- ^ Try to cancel any outstanding but not-yet-started jobs.
  -- Call 'remainingJobs' after this to find out if any jobs are left
  -- (ie could not be cancelled).
  , cleanupJobControl :: m ()
  -- ^ cleanup any resources created by the JobControl, intended to be used
  -- as the finaliser for `bracket`.
  , jobControlSemaphore :: Maybe SemaphoreName
  -- ^ Name of the semaphore which can be used to control parallelism, if one
  -- is available for that job control type.
  }

-- | Make a 'JobControl' that executes all jobs serially and in order.
-- It only executes jobs on demand when they are collected, not eagerly.
--
-- Cancelling will cancel /all/ jobs that have not been collected yet.
newSerialJobControl :: IO (JobControl IO a)
newSerialJobControl = do
  qVar <- newTChanIO
  return
    JobControl
      { spawnJob = spawn qVar
      , collectJob = collect qVar
      , remainingJobs = remaining qVar
      , cancelJobs = cancel qVar
      , cleanupJobControl = return ()
      , jobControlSemaphore = Nothing
      }
  where
    spawn :: TChan (IO a) -> IO a -> IO ()
    spawn qVar job = atomically $ writeTChan qVar job

    collect :: TChan (IO a) -> IO a
    collect qVar =
      join $ atomically $ readTChan qVar

    remaining :: TChan (IO a) -> IO Bool
    remaining qVar = fmap not $ atomically $ isEmptyTChan qVar

    cancel :: TChan (IO a) -> IO ()
    cancel qVar = do
      _ <- atomically $ readAllTChan qVar
      return ()

-- | Make a 'JobControl' that eagerly executes jobs in parallel, with a given
-- maximum degree of parallelism.
--
-- Cancelling will cancel jobs that have not yet begun executing, but jobs
-- that have already been executed or are currently executing cannot be
-- cancelled.
newParallelJobControl :: WithCallStack (Int -> IO (JobControl IO a))
newParallelJobControl n
  | n < 1 || n > 1000 =
      error $ "newParallelJobControl: not a sensible number of jobs: " ++ show n
newParallelJobControl maxJobLimit = do
  inqVar <- newTChanIO
  outqVar <- newTChanIO
  countVar <- newTVarIO 0
  replicateM_ maxJobLimit $
    forkIO $
      worker inqVar outqVar
  return
    JobControl
      { spawnJob = spawn inqVar countVar
      , collectJob = collect outqVar countVar
      , remainingJobs = remaining countVar
      , cancelJobs = cancel inqVar countVar
      , cleanupJobControl = return ()
      , jobControlSemaphore = Nothing
      }
  where
    worker :: TChan (IO a) -> TChan (Either SomeException a) -> IO ()
    worker inqVar outqVar =
      forever $ do
        job <- atomically $ readTChan inqVar
        res <- try job
        atomically $ writeTChan outqVar res

    spawn :: TChan (IO a) -> TVar Int -> IO a -> IO ()
    spawn inqVar countVar job =
      atomically $ do
        modifyTVar' countVar (+ 1)
        writeTChan inqVar job

    collect :: TChan (Either SomeException a) -> TVar Int -> IO a
    collect outqVar countVar = do
      res <- atomically $ do
        modifyTVar' countVar (subtract 1)
        readTChan outqVar
      either throwIO return res

    remaining :: TVar Int -> IO Bool
    remaining countVar = fmap (/= 0) $ atomically $ readTVar countVar

    cancel :: TChan (IO a) -> TVar Int -> IO ()
    cancel inqVar countVar =
      atomically $ do
        xs <- readAllTChan inqVar
        modifyTVar' countVar (subtract (length xs))

readAllTChan :: TChan a -> STM [a]
readAllTChan qvar = go []
  where
    go xs = do
      mx <- tryReadTChan qvar
      case mx of
        Nothing -> return (reverse xs)
        Just x -> go (x : xs)

-- | Make a 'JobControl' where the parallelism is controlled by a semaphore.
--
-- This uses the GHC -jsem option to allow GHC to take additional semaphore slots
-- if we are not using them all.
newSemaphoreJobControl :: WithCallStack (Verbosity -> Int -> IO (JobControl IO a))
newSemaphoreJobControl _ n
  | n < 1 || n > 1000 =
      error $ "newParallelJobControl: not a sensible number of jobs: " ++ show n
newSemaphoreJobControl verbosity maxJobLimit = do
  sem <- freshSemaphore "cabal_semaphore" maxJobLimit
  info verbosity $
    "Created semaphore called "
      ++ getSemaphoreName (semaphoreName sem)
      ++ " with "
      ++ show maxJobLimit
      ++ " slots."
  outqVar <- newTChanIO
  inqVar <- newTChanIO
  countVar <- newTVarIO 0
  void (forkIO (worker sem inqVar outqVar))
  return
    JobControl
      { spawnJob = spawn inqVar countVar
      , collectJob = collect outqVar countVar
      , remainingJobs = remaining countVar
      , cancelJobs = cancel inqVar countVar
      , cleanupJobControl = destroySemaphore sem
      , jobControlSemaphore = Just (semaphoreName sem)
      }
  where
    worker :: Semaphore -> TChan (IO a) -> TChan (Either SomeException a) -> IO ()
    worker sem inqVar outqVar =
      forever $ do
        job <- atomically $ readTChan inqVar
        -- mask here, as we need to ensure that the thread which contains the
        -- release action is spawned. Otherwise, there is the chance that an
        -- async exception is thrown between the semaphore being taken and the
        -- thread being spawned.
        mask_ $ do
          waitOnSemaphore sem
          void $ forkIOWithUnmask $ \unmask -> do
            res <- try (unmask job)
            releaseSemaphore sem 1
            atomically $ writeTChan outqVar res
        -- Try to give GHC enough time to compute the module graph and then
        -- request some additional capabilities if it can make use of them. The
        -- ideal situation is that we have 1 GHC process running which has taken
        -- all the capabilities in the semaphore, as this will reduce memory usage.
        --
        -- 0.25s is chosen by discussion between MP and SD on Mar 17th 2023 as a number
        -- which isn't too big and not too small but also, not scientifically.
        threadDelay 250000

    spawn :: TChan (IO a) -> TVar Int -> IO a -> IO ()
    spawn inqVar countVar job =
      atomically $ do
        modifyTVar' countVar (+ 1)
        writeTChan inqVar job

    collect :: TChan (Either SomeException a) -> TVar Int -> IO a
    collect outqVar countVar = do
      res <- atomically $ do
        modifyTVar' countVar (subtract 1)
        readTChan outqVar
      either throwIO return res

    remaining :: TVar Int -> IO Bool
    remaining countVar = fmap (/= 0) $ atomically $ readTVar countVar

    cancel :: TChan (IO a) -> TVar Int -> IO ()
    cancel inqVar countVar =
      atomically $ do
        xs <- readAllTChan inqVar
        modifyTVar' countVar (subtract (length xs))

-------------------------
-- Job limits and locks
--

data JobLimit = JobLimit QSem

newJobLimit :: Int -> IO JobLimit
newJobLimit n =
  fmap JobLimit (newQSem n)

withJobLimit :: JobLimit -> IO a -> IO a
withJobLimit (JobLimit sem) =
  bracket_ (waitQSem sem) (signalQSem sem)

newtype Lock = Lock (MVar ())

newLock :: IO Lock
newLock = fmap Lock $ newMVar ()

criticalSection :: Lock -> IO a -> IO a
criticalSection (Lock lck) act = bracket_ (takeMVar lck) (putMVar lck ()) act

--------------------------------------------------------------------------------
-- More high level utils
--------------------------------------------------------------------------------

newJobControlFromParStrat
  :: Verbosity
  -> Maybe Compiler
  -- ^ The compiler, used to determine whether Jsem is supported.
  -- When Nothing, Jsem is assumed to be unsupported.
  -> ParStratInstall
  -- ^ The parallel strategy
  -> Maybe Int
  -- ^ A cap on the number of jobs (e.g. to force a maximum of 2 concurrent downloads despite a -j8 parallel strategy)
  -> IO (JobControl IO a)
newJobControlFromParStrat verbosity mcompiler parStrat numJobsCap = case parStrat of
  Serial -> newSerialJobControl
  NumJobs n -> newParallelJobControl (capJobs (fromMaybe numberOfProcessors n))
  UseSem n ->
    case mcompiler of
      Just compiler
        | jsemSupported compiler ->
            newSemaphoreJobControl verbosity (capJobs n)
        | otherwise ->
            do
              warn verbosity "-jsem is not supported by the selected compiler, falling back to normal parallelism control."
              newParallelJobControl (capJobs n)
      Nothing ->
        -- Don't warn in the Nothing case, as there isn't really a "selected" compiler.
        newParallelJobControl (capJobs n)
  where
    capJobs n = min (fromMaybe maxBound numJobsCap) n

withJobControl :: IO (JobControl IO a) -> (JobControl IO a -> IO b) -> IO b
withJobControl mkJC = bracket mkJC cleanupJobControl

-- | Concurrently execute actions on a list using the given JobControl.
-- The maximum number of concurrent jobs is tied to the JobControl instance.
-- The resulting list does /not/ preserve the original order!
mapConcurrentWithJobs :: JobControl IO b -> (a -> IO b) -> [a] -> IO [b]
mapConcurrentWithJobs jobControl f xs = do
  traverse_ (spawnJob jobControl . f) xs
  traverse (const $ collectJob jobControl) xs
