module Agent.SeaOfGoals.Scheduling.SpeculativeRunner
  ( SpeculativeChaseRunner (..)
  , SpeculativeChaseResult (..)
  , runSpeculativeChase
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Agent.SeaOfGoals.Scheduling.SpeculativeChase
  ( EffectSet
  , GoalEpoch (..)
  , SpeculativeGoalStatus (..)
  , SpeculativeState (..)
  , finishGoal
  , initialSpeculativeState
  , recordEffects
  , restartGoal
  )
import Control.Concurrent.Async
  ( Async
  , async
  , cancel
  , waitAnyCatch
  )
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , takeMVar
  )
import Control.Exception (displayException)
import Control.Monad (forM, forM_, unless)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

data SpeculativeChaseRunner = SpeculativeChaseRunner
  { speculativeChaseRunGoal
      :: GoalNode
      -> GoalEpoch
      -> (EffectSet -> IO ())
      -> IO (Either Text AgentRunResult)
  , speculativeChaseMergeGoal :: AgentRunResult -> IO (Either Text ())
  }

data SpeculativeChaseResult = SpeculativeChaseResult
  { speculativeChaseCompleted :: Map GoalNodeId AgentRunResult
  , speculativeChaseCommitOrder :: [GoalNodeId]
  , speculativeChaseRestarted :: [GoalNodeId]
  }
  deriving stock (Eq, Show)

data ActiveGoal = ActiveGoal
  { activeGoalEpoch :: GoalEpoch
  , activeGoalTask :: Async (Either Text AgentRunResult)
  }

data Runtime = Runtime
  { runtimeState :: SpeculativeState
  , runtimeActive :: Map GoalNodeId ActiveGoal
  , runtimeResults :: Map GoalNodeId AgentRunResult
  , runtimeCommitOrder :: [GoalNodeId]
  , runtimeRestarted :: [GoalNodeId]
  }

-- | Launch every goal against the initial workspace. Effects are reported at
-- tool boundaries; an earlier write immediately cancels every conflicting
-- later epoch. Only the original list order may commit.
runSpeculativeChase
  :: SpeculativeChaseRunner
  -> [GoalNode]
  -> IO (Either Text SpeculativeChaseResult)
runSpeculativeChase runner nodes = do
  runtime <- newMVar (emptyRuntime (initialSpeculativeState nodes))
  launchGoals runtime [(node, GoalEpoch 0) | node <- nodes]
  loop runtime
 where
  emptyRuntime state =
    Runtime
      { runtimeState = state
      , runtimeActive = Map.empty
      , runtimeResults = Map.empty
      , runtimeCommitOrder = []
      , runtimeRestarted = []
      }

  report runtime goalId epoch effects = do
    aborted <-
      modifyMVar runtime $ \current ->
        case Map.lookup goalId (runtimeActive current) of
          Just active | activeGoalEpoch active == epoch ->
            let (nextState, invalidated) = recordEffects goalId effects (runtimeState current)
             in pure (current{runtimeState = nextState}, invalidated)
          _ -> pure (current, [])
    forM_ aborted $ \laterGoal -> do
      maybeTask <- Map.lookup laterGoal . runtimeActive <$> readRuntime runtime
      forM_ maybeTask (cancel . activeGoalTask)

  loop runtime = do
    current <- readRuntime runtime
    if speculativeNextCommit (runtimeState current) == length nodes && Map.null (runtimeActive current)
      then
        pure
          ( Right
              SpeculativeChaseResult
                { speculativeChaseCompleted = runtimeResults current
                , speculativeChaseCommitOrder = runtimeCommitOrder current
                , speculativeChaseRestarted = runtimeRestarted current
                }
          )
      else
        case Map.toList (runtimeActive current) of
          [] -> pure (Left "speculative chase is blocked without an active goal")
          activeGoals -> do
            (task, outcome) <- waitAnyCatch (activeGoalTask . snd <$> activeGoals)
            case find ((== task) . activeGoalTask . snd) activeGoals of
              Nothing -> loop runtime
              Just (goalId, ActiveGoal _ _) -> do
                status <- removeActive runtime goalId
                case status of
                  Just (SpeculativeAborted _) -> do
                    loop runtime
                  _ ->
                    case outcome of
                      Left err -> pure (Left (Text.pack (displayException err)))
                      Right (Left err) -> pure (Left err)
                      Right (Right result)
                        | agentRunResultGoal result /= goalId ->
                            pure (Left "agent result goal id does not match speculative goal")
                        | otherwise -> do
                            committed <- finishAndStore runtime goalId result
                            merged <- mergeCommitted committed runtime
                            case merged of
                              Left err -> do
                                cancelActive runtime
                                pure (Left err)
                              Right () -> do
                                restartAborted runtime
                                loop runtime

  launchGoals runtime launches = do
    staged <-
      forM launches $ \(node, epoch) -> do
        gate <- newEmptyMVar
        task <- async $ do
          takeMVar gate
          speculativeChaseRunGoal runner node epoch (report runtime (goalNodeId node) epoch)
        pure (goalNodeId node, epoch, gate, task)
    modifyMVar_ runtime $ \current ->
      pure
        current
          { runtimeActive =
              foldr
                (\(goalId, epoch, _, task) -> Map.insert goalId (ActiveGoal epoch task))
                (runtimeActive current)
                staged
          }
    forM_ staged $ \(_, _, gate, _) -> putMVar gate ()

  removeActive runtime goalId =
    modifyMVar runtime $ \current ->
      let previousStatus = Map.lookup goalId (speculativeGoalStatus (runtimeState current))
       in pure (current{runtimeActive = Map.delete goalId (runtimeActive current)}, previousStatus)

  finishAndStore runtime goalId result =
    modifyMVar runtime $ \current ->
      let
        (nextState, committed) = finishGoal goalId (runtimeState current)
        nextResults = Map.insert goalId result (runtimeResults current)
       in pure (current{runtimeState = nextState, runtimeResults = nextResults}, committed)

  mergeCommitted committed runtime =
    go committed
   where
    go [] = pure (Right ())
    go (goalId : remaining) = do
      maybeResult <- Map.lookup goalId . runtimeResults <$> readRuntime runtime
      case maybeResult of
        Nothing -> pure (Left "committed speculative goal has no result")
        Just result -> do
          merged <- speculativeChaseMergeGoal runner result
          case merged of
            Left err -> pure (Left err)
            Right () -> do
              modifyMVar_ runtime $ \current ->
                pure current{runtimeCommitOrder = runtimeCommitOrder current <> [goalId]}
              go remaining

  restartAborted runtime = do
    launches <-
      modifyMVar runtime $ \current ->
        let
          aborted =
            [ goalId
            | (goalId, SpeculativeAborted _) <- Map.toList (speculativeGoalStatus (runtimeState current))
            , goalId `Map.notMember` runtimeActive current
            ]
          nextState = foldr restartGoal (runtimeState current) aborted
          restartEpoch goalId =
            case Map.lookup goalId (speculativeGoalStatus nextState) of
              Just (SpeculativeRunning epoch) -> Just epoch
              _ -> Nothing
          nextRuntime =
            current
              { runtimeState = nextState
              , runtimeRestarted = runtimeRestarted current <> aborted
              }
       in
            pure
              ( nextRuntime
              , [ (node, epoch)
                | node <- nodes
                , goalNodeId node `elem` aborted
                , Just epoch <- [restartEpoch (goalNodeId node)]
                ]
              )
    unless (null launches) (launchGoals runtime launches)

  cancelActive runtime = do
    active <- runtimeActive <$> readRuntime runtime
    forM_ (Map.elems active) (cancel . activeGoalTask)

readRuntime :: MVar Runtime -> IO Runtime
readRuntime runtime = modifyMVar runtime (\current -> pure (current, current))
