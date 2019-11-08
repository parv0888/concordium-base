{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}
module Concordium.Types.Transactions where


import Data.Time.Clock
import Data.Time.Clock.POSIX
import Control.Exception
import Control.Monad
import qualified Data.ByteString as BS
import qualified Data.Serialize as S
import qualified Data.HashMap.Strict as HM
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Lens.Micro.Platform
import Lens.Micro.Internal

import qualified Concordium.Crypto.SHA256 as H
import Concordium.Crypto.SignatureScheme(Signature, KeyPair)
import Concordium.Crypto.SignatureScheme as SigScheme
import qualified Concordium.ID.Types as IDTypes
import qualified Concordium.ID.Account as AH

import qualified Data.Vector as Vec
import Data.Word

import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.Types.Execution

import Data.Int

newtype TransactionSignature = TransactionSignature { tsSignature :: Signature }
  deriving (Eq, Show)

-- |NB: Relies on the scheme and signature serialization to be sensibly defined as specified on the wiki!
instance S.Serialize TransactionSignature where
  put TransactionSignature{..} = S.put tsSignature
  get = TransactionSignature <$> S.get

type PayloadSize = Word32

type TransactionTime = Word64

-- |Get time in seconds since the unix epoch.
getTransactionTime :: IO TransactionTime
getTransactionTime = utcTimeToTransactionTime <$> getCurrentTime

utcTimeToTransactionTime :: UTCTime -> TransactionTime
utcTimeToTransactionTime = floor . utcTimeToPOSIXSeconds

-- | Data common to all transaction types.
--
--    * INVARIANT: @thSender = AH.accountAddress thSenderKey@.
--    * The last field is strictly redundant, but is here to avoid needless recomputation. In
--    serialization we do not output it, and when deserializing we compute it from other data.
data TransactionHeader = TransactionHeader {
    -- |Verification key of the sender.
    thSenderKey :: !IDTypes.AccountVerificationKey,
    -- |Per account nonce, strictly increasing, no gaps.
    thNonce :: !Nonce,
    -- |Amount of gas dedicated for the execution of this transaction.
    thGasAmount :: !Energy,
    -- |Size of the payload in bytes.
    thPayloadSize :: PayloadSize,
    -- |Sender account. Derived from the sender key as specified.
    thSender :: AccountAddress
    } deriving (Show)

-- |Eq instance ignores derived fields.
instance Eq TransactionHeader where
  th1 == th2 = thSenderKey th1 == thSenderKey th2 &&
               thNonce th1 == thNonce th2 &&
               thGasAmount th1 == thGasAmount th2 &&
               thPayloadSize th1 == thPayloadSize th2

-- |NB: Relies on the verify key serialization being defined as specified on the wiki.
instance S.Serialize TransactionHeader where
  put TransactionHeader{..} =
      S.put thSenderKey <>
      S.put thNonce <>
      S.put thGasAmount <>
      S.putWord32be thPayloadSize

  get = do
    thSenderKey <- S.get
    thNonce <- S.get
    thGasAmount <- S.get
    thPayloadSize <- S.getWord32be
    return $ makeTransactionHeader thSenderKey thPayloadSize thNonce thGasAmount

type TransactionHash = H.Hash

-- |Transaction without the metadata.
data BareTransaction = BareTransaction{
  btrSignature :: !TransactionSignature,
  btrHeader :: !TransactionHeader,
  btrPayload :: !EncodedPayload
  } deriving(Eq, Show)

instance S.Serialize BareTransaction where
  put BareTransaction{..} =
    S.put btrSignature <>
    S.put btrHeader <>
    putPayload btrPayload

  get = do
    btrSignature <- S.get
    btrHeader <- S.get
    btrPayload <- getPayload (thPayloadSize btrHeader)
    return $! BareTransaction{..}

fromBareTransaction :: TransactionTime -> BareTransaction -> Transaction
fromBareTransaction trArrivalTime trBareTransaction@BareTransaction{..} =
  let txBodyBytes = S.runPut (S.put btrHeader <> putPayload btrPayload)
      trHash = H.hash txBodyBytes
      trSize = BS.length txBodyBytes + BS.length (S.encode btrSignature)
  in Transaction{..}

-- |Transaction with all the metadata needed to avoid recomputation.
data Transaction = Transaction {
  -- |The actual transaction data.
  trBareTransaction :: !BareTransaction,

  -- |Size of the transaction in bytes, derived field.
  trSize :: !Int,
  -- |Hash of the transaction. Derived from the first three fields.
  trHash :: !TransactionHash,
  trArrivalTime :: !TransactionTime
  } deriving(Show) -- show is needed in testing

-- |NOTE: Eq and Ord instances based on hash comparison!
-- FIXME? Possibly we want to be defensive and check true equality in case hashes are equal.
instance Eq Transaction where
  t1 == t2 = trHash t1 == trHash t2

-- |The Ord instance does comparison only on hashes.
instance Ord Transaction where
  compare t1 t2 = compare (trHash t1) (trHash t2)

-- |Deserialize a transaction, checking its signature on the way.
getVerifiedTransaction :: TransactionTime -> S.Get Transaction
getVerifiedTransaction arTime = do
  t@Transaction{trBareTransaction=BareTransaction{..},..} <- getUnverifiedTransaction arTime
  unless (SigScheme.verify (thSenderKey btrHeader) (H.hashToByteString trHash) (tsSignature btrSignature)) $
      fail "Incorrect signature."
  return t

-- |Deserialize a transaction, but don't check it's signature.
getUnverifiedTransaction :: TransactionTime -> S.Get Transaction
getUnverifiedTransaction trArrivalTime = do
  sigStart <- S.bytesRead
  btrSignature <- S.get
  sigEnd <- S.bytesRead
  -- we use lookahead to deserialize the transaction without consuming the input.
  -- after that we read the bytes we just deserialized for further processing.
  (btrHeader, btrPayload, bodySize) <- S.lookAhead $! do
    start <- S.bytesRead
    trHeader <- S.get
    trPayload <- getPayload (thPayloadSize trHeader)
    end <- S.bytesRead
    return (trHeader, trPayload, end - start)
  txBytes <- S.getBytes bodySize
  let trHash = H.hash txBytes
  let sigSize = sigEnd - sigStart
  let trSize = bodySize + sigSize
  return Transaction{trBareTransaction=BareTransaction{..},..}

makeTransactionHeader ::
  IDTypes.AccountVerificationKey
  -> PayloadSize
  -> Nonce
  -> Energy
  -> TransactionHeader
makeTransactionHeader thSenderKey thPayloadSize thNonce thGasAmount =
  TransactionHeader{thSender = AH.accountAddress thSenderKey,..}

-- |Make a transaction out of minimal data needed.
makeTransaction :: TransactionTime -> TransactionSignature -> TransactionHeader -> EncodedPayload -> Transaction
makeTransaction trArrivalTime btrSignature btrHeader btrPayload =
    let txBodyBytes = S.runPut $ S.put btrHeader <> putPayload btrPayload
        -- transaction hash only refers to the body, not the signature of the transaction
        trHash = H.hash txBodyBytes
        trSize = BS.length txBodyBytes + BS.length (S.encode btrSignature)
        trBareTransaction = BareTransaction{..}
    in Transaction{..}

-- |FIXME: This method is inefficient (it creates temporary bytestrings which are
-- probably not necessary if we had a more appropriate sign function.)
-- |Sign a transaction with the given header and body. Uses serialization as defined on the wiki.
signTransaction :: KeyPair -> TransactionHeader -> EncodedPayload -> BareTransaction
signTransaction keys btrHeader btrPayload =
  let body = S.runPut (S.put btrHeader <> putPayload btrPayload)
      -- only sign the hash of the transaction
      bodyHash = H.hashToByteString (H.hash body)
      tsSignature = SigScheme.sign keys bodyHash
      btrSignature = TransactionSignature{..}
  in BareTransaction{..}

-- |Verify that the given transaction was signed by the sender's key.
verifyTransactionSignature :: TransactionData msg => msg -> Bool
verifyTransactionSignature tx =
  let bodyHash = H.hashToByteString (transactionHash tx)
      header = transactionHeader tx
      vfkey = thSenderKey header
      TransactionSignature sig = transactionSignature tx
  in SigScheme.verify vfkey bodyHash sig

-- |The 'TransactionData' class abstracts away from the particular data
-- structure. It makes it possible to unify operations on 'Transaction' as well
-- as other types providing the same data (such as partially serialized
-- transactions).
class TransactionData t where
    transactionHeader :: t -> TransactionHeader
    transactionSender :: t -> AccountAddress
    transactionNonce :: t -> Nonce
    transactionGasAmount :: t -> Energy
    transactionPayload :: t -> EncodedPayload
    transactionSignature :: t -> TransactionSignature
    transactionHash :: t -> H.Hash
    transactionSize :: t -> Int

instance TransactionData BareTransaction where
    transactionHeader = btrHeader
    transactionSender = thSender . btrHeader
    transactionNonce = thNonce . btrHeader
    transactionGasAmount = thGasAmount . btrHeader
    transactionPayload = btrPayload
    transactionSignature = btrSignature
    transactionHash t = H.hash (S.runPut $ S.put (btrHeader t) <> putPayload (btrPayload t))
    transactionSize t = BS.length serialized
      where serialized = S.encode t

instance TransactionData Transaction where
    transactionHeader = btrHeader . trBareTransaction
    transactionSender = thSender . btrHeader . trBareTransaction
    transactionNonce = thNonce . btrHeader . trBareTransaction
    transactionGasAmount = thGasAmount . btrHeader . trBareTransaction
    transactionPayload = btrPayload . trBareTransaction
    transactionSignature = btrSignature . trBareTransaction
    transactionHash = getHash
    transactionSize = trSize

instance HashableTo H.Hash Transaction where
    getHash = trHash

data AccountNonFinalizedTransactions = AccountNonFinalizedTransactions {
    -- |Non-finalized transactions (for an account) indexed by nonce.
    _anftMap :: Map.Map Nonce (Set.Set Transaction),
    -- |The next available nonce at the last finalized block.
    -- 'anftMap' should only contain nonces that are at least 'anftNextNonce'.
    _anftNextNonce :: Nonce
} deriving (Eq)
makeLenses ''AccountNonFinalizedTransactions

emptyANFT :: AccountNonFinalizedTransactions
emptyANFT = AccountNonFinalizedTransactions Map.empty minNonce

data TransactionTable = TransactionTable {
    -- |Map from transaction hashes to transactions.  Contains all transactions.
    _ttHashMap :: HM.HashMap TransactionHash (Transaction, Slot),
    _ttNonFinalizedTransactions :: HM.HashMap AccountAddress AccountNonFinalizedTransactions
}
makeLenses ''TransactionTable

emptyTransactionTable :: TransactionTable
emptyTransactionTable = TransactionTable {
        _ttHashMap = HM.empty,
        _ttNonFinalizedTransactions = HM.empty
    }

-- |A pending transaction table records whether transactions are pending after
-- execution of a particular block.  For each account address, if there are
-- pending transactions, then it should be in the map with value @(nextNonce, highNonce)@,
-- where @nextNonce@ is the next nonce for the account address (i.e. 1+nonce of last executed transaction),
-- and @highNonce@ is the highest nonce known for a transaction associated with that account.
-- @highNonce@ should always be at least @nextNonce@ (otherwise, what transaction is pending?).
-- If an account has no pending transactions, then it should not be in the map.
type PendingTransactionTable = HM.HashMap AccountAddress (Nonce, Nonce)

emptyPendingTransactionTable :: PendingTransactionTable
emptyPendingTransactionTable = HM.empty

-- |Insert an additional element in the pending transaction table.
-- If the account does not yet exist create it.
-- NB: This only updates the pending table, and does not ensure that invariants elsewhere are maintained.
-- PRECONDITION: the next nonce should be less than or equal to the transaction nonce.
extendPendingTransactionTable :: TransactionData t => Nonce -> t -> PendingTransactionTable -> PendingTransactionTable
extendPendingTransactionTable nextNonce tx pt = assert (nextNonce <= nonce) $
  HM.alter (\case Nothing -> Just (nextNonce, nonce)
                  Just (l, u) -> Just (l, max u nonce)) (transactionSender tx) pt
  where nonce = transactionNonce tx

-- |Insert an additional element in the pending transaction table.
-- Does nothing if the next nonce is greater than the transaction nonce.
-- If the account does not yet exist create it.
-- NB: This only updates the pending table, and does not ensure that invariants elsewhere are maintained.
checkedExtendPendingTransactionTable :: TransactionData t => Nonce -> t -> PendingTransactionTable -> PendingTransactionTable
checkedExtendPendingTransactionTable nextNonce tx pt = if nextNonce > nonce then pt else
  HM.alter (\case Nothing -> Just (nextNonce, nonce)
                  Just (l, u) -> Just (l, max u nonce)) (transactionSender tx) pt
  where nonce = transactionNonce tx


forwardPTT :: [Transaction] -> PendingTransactionTable -> PendingTransactionTable
forwardPTT trs ptt0 = foldl forward1 ptt0 trs
    where
        forward1 :: PendingTransactionTable -> Transaction -> PendingTransactionTable
        forward1 ptt tr = ptt & at (transactionSender tr) %~ upd
            where
                upd Nothing = error "forwardPTT : forwarding transaction that is not pending"
                upd (Just (low, high)) =
                    assert (low == transactionNonce tr) $ assert (low <= high) $
                        if low == high then Nothing else Just (low+1,high)

reversePTT :: [Transaction] -> PendingTransactionTable -> PendingTransactionTable
reversePTT trs ptt0 = foldr reverse1 ptt0 trs
    where
        reverse1 :: Transaction -> PendingTransactionTable -> PendingTransactionTable
        reverse1 tr = at (transactionSender tr) %~ upd
            where
                upd Nothing = Just (transactionNonce tr, transactionNonce tr)
                upd (Just (low, high)) =
                        assert (low == transactionNonce tr + 1) $
                        Just (low-1,high)

-- |Record special transactions as well for logging purposes.
data SpecialTransactionOutcome =
  BakingReward !AccountAddress !Amount
  deriving(Show)

instance S.Serialize SpecialTransactionOutcome where
    put (BakingReward addr amt) = S.put addr >> S.put amt
    get = BakingReward <$> S.get <*> S.get

-- |Values of this datatype must satisfy the invariant that the values in the
-- map are exactly the indices in the vector.
data TransactionOutcomes = TransactionOutcomes {
    outcomeIndex :: !(HM.HashMap TransactionHash Int),
    outcomeValues :: !(Vec.Vector ValidResult),
    _outcomeSpecial :: ![SpecialTransactionOutcome]
}

makeLenses ''TransactionOutcomes

instance Show TransactionOutcomes where
    show (TransactionOutcomes _ v s) = "Normal transactions: " ++ show (Vec.toList v) ++ ", special transactions: " ++ show s

instance S.Serialize TransactionOutcomes where
    put TransactionOutcomes{..} = do
        S.put (HM.toList outcomeIndex)
        S.put (Vec.toList outcomeValues)
        S.put _outcomeSpecial
    get = TransactionOutcomes <$> (HM.fromList <$> S.get) <*> (Vec.fromList <$> S.get) <*> S.get

emptyTransactionOutcomes :: TransactionOutcomes
emptyTransactionOutcomes = TransactionOutcomes HM.empty Vec.empty []

transactionOutcomesFromList :: [(TransactionHash, ValidResult)] -> TransactionOutcomes
transactionOutcomesFromList l =
  let outcomeValues = Vec.fromList (map snd l)
      outcomeIndex = HM.fromList (zip (map fst l) [0..])
      _outcomeSpecial = []
  in TransactionOutcomes{..}

type instance Index TransactionOutcomes = TransactionHash
type instance IxValue TransactionOutcomes = ValidResult

instance Ixed TransactionOutcomes where
  ix idx f outcomes@TransactionOutcomes{..} = -- result type is f TransactionOutcomes
    case outcomeIndex ^. at idx of
      Nothing -> pure outcomes
      Just i -> (\ov -> TransactionOutcomes{outcomeValues=ov,..}) <$> ix i f outcomeValues
