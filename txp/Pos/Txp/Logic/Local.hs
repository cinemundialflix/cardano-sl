{-# LANGUAGE RankNTypes #-}

-- | Logic for local processing of transactions.
-- Local transaction is transaction which hasn't been added in the blockchain yet.

module Pos.Txp.Logic.Local
       ( txProcessTransaction
       , txProcessTransactionNoLock
       , txNormalize
       ) where

import           Universum

import           Control.Lens         (makeLenses)
import           Control.Monad.Except (MonadError (..), runExceptT)
import           Data.Default         (Default (def))
import qualified Data.List.NonEmpty   as NE
import qualified Data.Map             as M (fromList)
import           Formatting           (build, sformat, (%))
import           System.Wlog          (WithLogger, logDebug)

import           Pos.Core             (BlockVersionData, EpochIndex, GenesisWStakeholders,
                                       HeaderHash, siEpoch)
import           Pos.DB.Class         (MonadDBRead, MonadGState (..))
import qualified Pos.DB.GState.Common as GS
import           Pos.Infra.Semaphore  (BlkSemaphore, withBlkSemaphore)
import           Pos.Slotting         (MonadSlots (..))
import           Pos.Txp.Core         (Tx (..), TxAux (..), TxId, TxUndo)
import           Pos.Txp.MemState     (MonadTxpMem, TxpLocalDataPure, getLocalTxs,
                                       getUtxoModifier, modifyTxpLocalData,
                                       setTxpLocalData)
import           Pos.Txp.Toil         (GenericToilModifier (..), MonadUtxoRead (..),
                                       ToilModifier, ToilT, ToilVerFailure (..), Utxo,
                                       execToilTLocal, normalizeToil, processTx,
                                       runDBToil, runToilTLocal, utxoGetReader)
import           Pos.Util.Util        (HasLens (..), HasLens')

type TxpLocalWorkMode ctx m =
    ( MonadIO m
    , MonadDBRead m
    , MonadGState m
    , MonadSlots ctx m
    , MonadTxpMem () ctx m
    , WithLogger m
    , HasLens' ctx GenesisWStakeholders
    )

-- Base context for tx processing in.
data ProcessTxContext = ProcessTxContext
    { _ptcGenStakeholders :: !GenesisWStakeholders
    , _ptcAdoptedBVData   :: !BlockVersionData
    , _ptcUtxoBase        :: !Utxo
    }

makeLenses ''ProcessTxContext

instance HasLens GenesisWStakeholders ProcessTxContext GenesisWStakeholders where
    lensOf = ptcGenStakeholders

instance HasLens Utxo ProcessTxContext Utxo where
    lensOf = ptcUtxoBase

-- Base monad for tx processing in.
type ProcessTxMode = Reader ProcessTxContext

instance MonadUtxoRead ProcessTxMode where
    utxoGet = utxoGetReader

instance MonadGState ProcessTxMode where
    gsAdoptedBVData = view ptcAdoptedBVData

-- | Process transaction. 'TxId' is expected to be the hash of
-- transaction in 'TxAux'. Separation is supported for optimization
-- only.
txProcessTransaction
    :: (TxpLocalWorkMode ctx m, HasLens' ctx BlkSemaphore, MonadMask m)
    => (TxId, TxAux) -> m (Either ToilVerFailure ())
txProcessTransaction itw =
    withBlkSemaphore $ \__tip -> txProcessTransactionNoLock itw

-- | Unsafe version of 'txProcessTransaction' which doesn't take a
-- lock. Can be used in tests.
txProcessTransactionNoLock
    :: (TxpLocalWorkMode ctx m)
    => (TxId, TxAux) -> m (Either ToilVerFailure ())
txProcessTransactionNoLock itw@(txId, txAux) = runExceptT $ do
    let UnsafeTx {..} = taTx txAux
    -- Note: we need to read tip from the DB and check that it's the
    -- same as the one in mempool. That's because mempool state is
    -- valid only with respect to the tip stored there. Normally tips
    -- will match, because whenever we apply/rollback blocks we
    -- normalize mempool. However, there is a corner case when we
    -- receive an unexpected exception after modifying GState and
    -- before normalization. In this case normalization can fail and
    -- tips will differ. Rejecting transactions in this case should be
    -- fine, because the fact that we receive exceptions likely
    -- indicates that something is bad and we have more serious issues.
    --
    -- Also note that we don't need to use a snapshot here and can be
    -- sure that GState won't change, because changing it requires
    -- 'BlkSemaphore' which we own inside this function.
    tipDB <- GS.getTip
    bvd <- gsAdoptedBVData
    epoch <- siEpoch <$> (note ToilSlotUnknown =<< getCurrentSlot)
    bootHolders <- view (lensOf @GenesisWStakeholders)
    localUM <- lift $ getUtxoModifier @()
    let runUM um = runToilTLocal um def mempty
    (resolvedOuts, _) <- runDBToil $ runUM localUM $ mapM utxoGet _txInputs
    -- Resolved are unspent transaction outputs corresponding to input
    -- of given transaction.
    let resolved =
            M.fromList $
            catMaybes $
            toList $ NE.zipWith (liftM2 (,) . Just) _txInputs resolvedOuts
    let ctx =
            ProcessTxContext
            { _ptcGenStakeholders = bootHolders
            , _ptcAdoptedBVData = bvd
            , _ptcUtxoBase = resolved
            }
    pRes <-
        lift $
        modifyTxpLocalData "txProcessTransaction" $
        processTxDo epoch ctx tipDB itw
    case pRes of
        Left er -> do
            logDebug $ sformat ("Transaction processing failed: " %build) txId
            throwError er
        Right _ ->
            logDebug
                (sformat ("Transaction is processed successfully: " %build) txId)
  where
    processTxDo ::
           EpochIndex
        -> ProcessTxContext
        -> HeaderHash
        -> (TxId, TxAux)
        -> TxpLocalDataPure
        -> (Either ToilVerFailure (), TxpLocalDataPure)
    processTxDo curEpoch ctx tipDB tx txld@(uv, mp, undo, tip, ())
        | tipDB /= tip = (Left $ ToilTipsMismatch tipDB tip, txld)
        | otherwise =
            let action :: ExceptT ToilVerFailure (ToilT () ProcessTxMode) TxUndo
                action = processTx curEpoch tx
                res :: (Either ToilVerFailure TxUndo, ToilModifier)
                res =
                    usingReader ctx $
                    runToilTLocal uv mp undo $ runExceptT action
            in case res of
                   (Left er, _) -> (Left er, txld)
                   (Right _, ToilModifier {..}) ->
                       ( Right ()
                       , (_tmUtxo, _tmMemPool, _tmUndos, tip, _tmExtra))

-- | 1. Recompute UtxoView by current MemPool
-- | 2. Remove invalid transactions from MemPool
-- | 3. Set new tip to txp local data
txNormalize
    :: ( TxpLocalWorkMode ctx m
       , MonadSlots ctx m)
    => m ()
txNormalize = getCurrentSlot >>= \case
    Nothing -> do
        tip <- GS.getTip
        -- Clear and update tip
        setTxpLocalData "txNormalize" (mempty, def, mempty, tip, def)
    Just (siEpoch -> epoch) -> do
        utxoTip <- GS.getTip
        localTxs <- getLocalTxs
        ToilModifier {..} <-
            runDBToil $ execToilTLocal mempty def mempty $ normalizeToil epoch localTxs
        setTxpLocalData "txNormalize" (_tmUtxo, _tmMemPool, _tmUndos, utxoTip, _tmExtra)
