module Echidna.UI where

import Brick
import Brick.BChan
import Brick.Widgets.Dialog qualified as B
import Control.Concurrent (killThread, threadDelay)
import Control.Monad (forever, void, when, replicateM)
import Control.Monad.Catch (MonadCatch(..), catchAll)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader (MonadReader (ask), runReader, asks)
import Control.Monad.Random.Strict (MonadRandom, getRandom)
import Control.Monad.State (modify')
import Data.ByteString.Lazy qualified as BS
import Data.List (transpose)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Graphics.Vty qualified as V
import Graphics.Vty (Config, Event(..), Key(..), Modifier(..), defaultConfig, inputMap, mkVty)
import System.Posix.Terminal (queryTerminal)
import System.Posix.Types (Fd(..))
import UnliftIO (MonadUnliftIO)
import UnliftIO.IORef
import UnliftIO.Concurrent (forkIO, getNumCapabilities)
import UnliftIO.MVar (tryTakeMVar, newEmptyMVar, putMVar)

import EVM (VM, Contract)
import EVM.Types (Addr, W256)

import Echidna.ABI
import Echidna.Campaign (campaign)
import Echidna.Output.JSON qualified
import Echidna.Types.Campaign
import Echidna.Types.Test (EchidnaTest (..), TestState (..))
import Echidna.Types.Tx (Tx)
import Echidna.Types.World (World)
import Echidna.UI.Report
import Echidna.UI.Widgets
import Echidna.Types.Config

data UIEvent =
  CampaignUpdated Campaign
  | CampaignTimedout Campaign
  | CampaignCrashed String
  | FetchCacheUpdated (Map Addr (Maybe Contract)) (Map Addr (Map W256 (Maybe W256)))

-- TODO: sync corpus from time to time?
data WorkerSyncMessage
  = TestFalsified Int EchidnaTest -- TODO: rethink if whole test should be pushed
  | TestLimitReached Int
  | ShrinkLimitReached Int
  | TimeLimitReached -- timed out, exit

-- | Set up and run an Echidna 'Campaign' and display interactive UI or
-- print non-interactive output in desired format at the end
ui :: (MonadCatch m, MonadRandom m, MonadReader Env m, MonadUnliftIO m)
   => VM             -- ^ Initial VM state
   -> World          -- ^ Initial world state
   -> [EchidnaTest]  -- ^ Tests to evaluate
   -> GenDict
   -> [[Tx]]
   -> m Campaign
ui vm world ts dict initialCorpus = do
  conf <- asks (.cfg)
  let uiConf = conf.uiConf
  ref <- liftIO $ newIORef defaultCampaign
  terminalPresent <- liftIO isTerminal
  let effectiveMode = case uiConf.operationMode of
        Interactive | not terminalPresent -> NonInteractive Text
        other -> other

  numCapabilities <- getNumCapabilities
  -- TODO: Performance peaks around 12 jobs, even if there are 24 CPU threads
  -- available (Ryzen 5900X). Is it possible to tweak scheduler/GC?
  let njobs = numCapabilities -- max 12 numCapabilities
  -- Communication channels with workers
  ioRefs <- replicateM njobs $ newIORef defaultCampaign
  mVars <- replicateM njobs newEmptyMVar

  let worker (ioRef, mVar) = forkIO $ void $ do
        -- Generate a new seed for each worker
        seed <- getRandom
        let dict' = dict { defSeed = seed }
        campaign (syncWorker ioRef mVar ioRefs) vm world ts dict' initialCorpus

  {-
        (void $ do
          catchAll
            (runCampaign >>= \case
              Nothing -> liftIO $ updateUI CampaignTimedout
              Just _ -> liftIO $ updateUI CampaignUpdated)
            (liftIO . writeBChan bc . CampaignCrashed . show)
        )
        (const $ liftIO $ killThread ticker)
        -}

      maybeTimeout = secToUsec <$> uiConf.maxTime
      secToUsec = (* 1000000)

  {-workerSyncer = forkIO $ void $ do
        campaigns <- sequence $ readIORef <$> ioRefs
        pure undefined-}

  case effectiveMode of
    Interactive -> do
      -- Channel to push events to update UI
      bc <- liftIO $ newBChan 100

      env <- ask
      let updateUI e = do
            campaigns <- mapM readIORef ioRefs
            -- TODO: push MVar messages
            writeBChan bc $ e (mergeCampaigns campaigns)

      ticker <- liftIO $ forkIO $
        -- run UI update every 100ms
        forever $ do
          threadDelay 100000
          updateUI CampaignUpdated
          c <- readIORef env.fetchContractCache
          s <- readIORef env.fetchSlotCache
          writeBChan bc (FetchCacheUpdated c s)

      -- Timeouter thread, sleep for the timeout then order all workers
      -- to exit and update the UI
      case maybeTimeout of
        Just t -> liftIO $ void $ forkIO $ do
          threadDelay t
          killThread ticker
          mapM_ (`putMVar` TimeLimitReached) mVars
          updateUI CampaignTimedout
        Nothing -> pure ()

      _threadIds <- mapM worker (zip ioRefs mVars)

      -- UI initialization
      let buildVty = do
            v <- mkVty =<< vtyConfig
            V.setMode (V.outputIface v) V.Mouse True
            pure v
      initialVty <- liftIO buildVty
      app <- customMain initialVty buildVty (Just bc) <$> monitor
      liftIO $ void $ app UIState
        { campaign = defaultCampaign
        , status = Uninitialized
        , fetchedContracts = mempty
        , fetchedSlots = mempty
        , fetchedDialog = B.dialog (Just "Fetched contracts/slots") Nothing 80
        , displayFetchedDialog = False
        }

      mapM_ (`putMVar` TimeLimitReached) mVars

      campaigns <- mapM readIORef ioRefs
      final <- liftIO $ readIORef ref
      liftIO . putStrLn $ runReader (ppCampaign final) conf
      pure final

    NonInteractive outputFormat -> do
      -- Timeouter thread, sleep for the timeout then order all workers to exit
      -- TODO: this is similar to the UI one, think about extracting it?
      didTimeout <- newIORef False

      case maybeTimeout of
        Just t -> liftIO $ void $ forkIO $ do
          threadDelay t
          mapM_ (`putMVar` TimeLimitReached) mVars
          atomicWriteIORef didTimeout True
        Nothing -> pure ()

      _threadIds <- mapM worker (zip ioRefs mVars)

      -- TODO wait for threads
      liftIO $ threadDelay 1000000

      campaigns <- mapM readIORef ioRefs
      let final = mergeCampaigns campaigns

      case outputFormat of
        JSON ->
          liftIO . BS.putStr $ Echidna.Output.JSON.encodeCampaign final
        Text -> do
          liftIO . putStrLn $ runReader (ppCampaign final) conf
          timedout <- readIORef didTimeout
          when timedout $ liftIO $ putStrLn "TIMEOUT!"
        None ->
          pure ()
      pure final

  where
  syncWorker ioRef mVar _ioRefs = do
    c <- get
    -- push campaign update
    liftIO $ atomicWriteIORef ioRef c
    -- read a message if a breakthrough happened in another worker
    -- TODO use a channel instead of MVar as it could be block the UI thread a bit
    maybeMessage <- liftIO $ tryTakeMVar mVar
    case maybeMessage of
      Nothing -> pure False
      Just message -> do
        let (c', stop) = updateCampaign c message
        put c'
        pure stop
    where
    updateCampaign c = \case
      TestFalsified i t ->
        -- NOTE: the first worker wins, here we overwrite work that was
        -- done by the current worker, TODO: rethink this
        -- (c { tests = c.tests
        -- (c & tests . ix i .~ t, False)
        error "implement me"
      TestLimitReached _i ->
        -- bump the all? Open trials to max to stop fuzzing
        --case c ^. tests . at i of
        --  Nothing -> undefined
        --  Just t -> undefined
        error "implement me"
      ShrinkLimitReached _i ->
        -- bump the all? Open trials to max to stop fuzzing
        error "implement me"
      TimeLimitReached -> (c, True)


-- Summarize all campaigns from workers as a single campaign
-- TODO: this should return a richer data structure, good enough for now
mergeCampaigns :: [Campaign] -> Campaign
mergeCampaigns [] = error "won't happen, fix me with NonEmpty"
mergeCampaigns [c] = c -- don't even try
mergeCampaigns campaigns =
  defaultCampaign
    { _tests = mergeTests <$> transpose ((._tests) <$> campaigns)
    , _coverage = Map.unionsWith Set.union ((._coverage) <$> campaigns)
    , _gasInfo = mempty -- TODO
    , _genDict = defaultDict -- TODO
    , _corpus = mempty -- TODO
    , _ncallseqs = sum ((._ncallseqs) <$> campaigns)
    }
  where
  mergeTests :: [EchidnaTest] -> EchidnaTest
  mergeTests [] = error "won't happen, fix me with NonEmpty"
  mergeTests (f:ts) =
    foldl (\t acc ->
      case (t.testState, acc.testState) of
        -- update if better what we have so far
        (Solved, _) -> t
        (Large i, Large j) -> t { testState = Large (i+j) }
        (Large _, Open _) -> t
        (Large _, Passed) -> t -- shoudn't happen but just in case
        (Open i, Open j) -> t { testState = Open (i+j) }
        -- skip otherwise
        _ -> acc
      ) f ts

vtyConfig :: IO Config
vtyConfig = do
  config <- V.standardIOConfig
  pure config { inputMap = (Nothing, "\ESC[6;2~", EvKey KPageDown [MShift]) :
                           (Nothing, "\ESC[5;2~", EvKey KPageUp [MShift]) :
                           inputMap defaultConfig
              }

-- | Check if we should stop drawing (or updating) the dashboard, then do the right thing.
monitor :: MonadReader Env m => m (App UIState UIEvent Name)
monitor = do
  let drawUI :: EConfig -> UIState -> [Widget Name]
      drawUI conf uiState =
        [ if uiState.displayFetchedDialog
             then fetchedDialogWidget uiState
             else emptyWidget
        , runReader (campaignStatus uiState) conf]

      onEvent (AppEvent (CampaignUpdated c')) =
        modify' $ \state -> state { campaign = c', status = Running }
      onEvent (AppEvent (CampaignTimedout c')) =
        modify' $ \state -> state { campaign = c', status = Timedout }
      onEvent (AppEvent (CampaignCrashed e)) = do
        modify' $ \state -> state { status = Crashed e }
      onEvent (AppEvent (FetchCacheUpdated contracts slots)) =
        modify' $ \state -> state { fetchedContracts = contracts
                                  , fetchedSlots = slots }
      onEvent (VtyEvent (EvKey (KChar 'f') _)) =
        modify' $ \state -> state { displayFetchedDialog = not state.displayFetchedDialog }
      onEvent (VtyEvent (EvKey KEsc _))                         = halt
      onEvent (VtyEvent (EvKey (KChar 'c') l)) | MCtrl `elem` l = halt
      onEvent (MouseDown (SBClick el n) _ _ _) =
        case n of
          TestsViewPort -> do
            let vp = viewportScroll TestsViewPort
            case el of
              SBHandleBefore -> vScrollBy vp (-1)
              SBHandleAfter  -> vScrollBy vp 1
              SBTroughBefore -> vScrollBy vp (-10)
              SBTroughAfter  -> vScrollBy vp 10
              SBBar          -> pure ()
          _ -> pure ()
      onEvent _ = pure ()

  conf <- asks (.cfg)
  pure $ App { appDraw = drawUI conf
             , appStartEvent = pure ()
             , appHandleEvent = onEvent
             , appAttrMap = const attrs
             , appChooseCursor = neverShowCursor
             }

-- | Heuristic check that we're in a sensible terminal (not a pipe)
isTerminal :: IO Bool
isTerminal = (&&) <$> queryTerminal (Fd 0) <*> queryTerminal (Fd 1)
