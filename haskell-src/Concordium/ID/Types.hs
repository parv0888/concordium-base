{-# LANGUAGE GeneralizedNewtypeDeriving, RecordWildCards, OverloadedStrings, LambdaCase #-}
{-# LANGUAGE TypeFamilies, ExistentialQuantification, FlexibleContexts, DeriveGeneric, DerivingVia, DeriveDataTypeable #-}
module Concordium.ID.Types where

import Data.Word
import Data.Data(Data, Typeable)
import Data.ByteString(ByteString)
import Data.ByteString.Short(ShortByteString)
import qualified Data.ByteString.Short as BSS
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Base16 as BS16
import Concordium.Crypto.SignatureScheme
import Data.Serialize as S
import GHC.Generics
import Data.Hashable
import qualified Data.Text.Read as Text
import qualified Text.Read as Text
import Data.Text.Encoding as Text
import Data.Aeson hiding (encode, decode)
import Data.Aeson.Types(toJSONKeyText)
import Data.Maybe(fromMaybe)
import qualified Data.Set as Set
import Control.Monad
import Control.Monad.Except
import qualified Data.Text as Text
import Control.DeepSeq
import System.Random
import qualified Data.Map.Strict as Map

import Data.Base58Encoding
import qualified Data.FixedByteString as FBS
import Concordium.Crypto.ByteStringHelpers
import Concordium.Crypto.FFIDataTypes
import qualified Concordium.Crypto.SHA256 as SHA256

accountAddressSize :: Int
accountAddressSize = 32
data AccountAddressSize
   deriving(Data, Typeable)
instance FBS.FixedLength AccountAddressSize where
    fixedLength _ = accountAddressSize

newtype AccountAddress =  AccountAddress (FBS.FixedByteString AccountAddressSize)
    deriving(Eq, Ord, Generic, Data, Typeable)

{-# WARNING randomAccountAddress "DO NOT USE IN PRODUCTION." #-}
randomAccountAddress :: RandomGen g => g -> (AccountAddress, g)
randomAccountAddress g =
  let (g1, g2) = split g
  in (AccountAddress (FBS.pack (take accountAddressSize (randoms g1))), g2)


instance Serialize AccountAddress where
    put (AccountAddress h) = putByteString $ FBS.toByteString h
    get = AccountAddress . FBS.fromByteString <$> getByteString accountAddressSize

instance Hashable AccountAddress where
    hashWithSalt s (AccountAddress b) = hashWithSalt s (FBS.toShortByteString b)
    hash (AccountAddress b) = fromIntegral (FBS.unsafeReadWord64 b)

-- |Show the address in base58check format.
instance Show AccountAddress where
  show = BS8.unpack . addressToBytes

-- |FIXME: Probably make sure the input size is not too big before doing base58check.
instance FromJSON AccountAddress where
  parseJSON v = do
    r <- addressFromText <$> parseJSON v
    case r of
      Left err -> fail err
      Right a -> return a

instance ToJSON AccountAddress where
  toJSON a = String (Text.decodeUtf8 (addressToBytes a))

addressFromText :: MonadError String m => Text.Text -> m AccountAddress
addressFromText = addressFromBytes . Text.encodeUtf8

-- |Convert an address to valid Base58 bytes.
-- Uses version byte 1 for the base58check encoding.
addressToBytes :: AccountAddress -> ByteString
addressToBytes (AccountAddress v) = raw (base58CheckEncode (BS.cons 1 bs))
    where bs = FBS.toByteString v


-- |Take bytes which are presumed valid base58 encoding, and try to deserialize
-- an address.
addressFromBytes :: MonadError String m => BS.ByteString -> m AccountAddress
addressFromBytes bs =
      case base58CheckDecode' bs of
        Nothing -> throwError "Base 58 checksum invalid."
        Just x | BS.length x == accountAddressSize + 1 ->
                 let version = BS.head x
                 in if version == 1 then return (AccountAddress (FBS.fromByteString (BS.tail x)))
                    else throwError "Unknown base58 check version byte."
               | otherwise -> throwError "Wrong address length."


addressFromRegId :: CredentialRegistrationID -> AccountAddress
addressFromRegId (RegIdCred fbs) = AccountAddress (FBS.FixedByteString addr) -- NB: This only works because the sizes are the same
  where SHA256.Hash (FBS.FixedByteString addr) = SHA256.hashShort (FBS.toShortByteString fbs)



-- |Index of the account key needed to determine what key the signature should
-- be checked with.
newtype KeyIndex = KeyIndex Word8
    deriving (Eq, Ord, Enum, Num, Real, Integral)
    deriving (Hashable, Show, Read, S.Serialize, FromJSON, FromJSONKey, ToJSON, ToJSONKey) via Word8

data AccountKeys = AccountKeys {
  akKeys :: Map.Map KeyIndex VerifyKey,
  akThreshold :: SignatureThreshold
  } deriving(Eq, Show, Ord)

makeAccountKeys :: [VerifyKey] -> SignatureThreshold -> AccountKeys
makeAccountKeys keys akThreshold =
  AccountKeys{
    akKeys = Map.fromAscList (zip [0..] keys), -- NB: fromAscList does not check preconditions
    ..
    }

makeSingletonAC :: VerifyKey -> AccountKeys
makeSingletonAC key = makeAccountKeys [key] 1

-- Build a map from an ascending list.
safeFromAscList :: (MonadFail m, Ord k) => [(k,v)] -> m (Map.Map k v)
safeFromAscList = go Map.empty Nothing
    where go mp _ [] = return mp
          go mp Nothing ((k,v):rest) = go (Map.insert k v mp) (Just k) rest
          go mp (Just k') ((k,v):rest)
              | k' < k = go (Map.insert k v mp) (Just k) rest
              | otherwise = fail "Keys not in ascending order, or duplicate keys."

instance S.Serialize AccountKeys where
  put AccountKeys{..} = do
    S.putWord8 (fromIntegral (length akKeys))
    forM_ (Map.toAscList akKeys) $ \(idx, key) -> S.put idx <> S.put key
    S.put akThreshold
  get = do
    len <- S.getWord8
    when (len == 0) $ fail "Number of keys out of bounds."
    akKeys <- safeFromAscList =<< replicateM (fromIntegral len) (S.getTwoOf S.get S.get)
    akThreshold <- S.get
    return AccountKeys{..}

instance FromJSON AccountKeys where
  parseJSON = withObject "AccountKeys" $ \v -> do
    akThreshold <- v .: "threshold"
    akKeys <- v .: "keys"
    return AccountKeys{..}

{-# INLINE getAccountKey #-}
getAccountKey :: KeyIndex -> AccountKeys -> Maybe VerifyKey
getAccountKey idx keys = Map.lookup idx (akKeys keys)

getKeyIndices :: AccountKeys -> Set.Set KeyIndex
getKeyIndices keys = Map.keysSet $ akKeys keys

-- |Name of Identity Provider
newtype IdentityProviderIdentity  = IP_ID Word32
    deriving (Eq, Hashable)
    deriving Show via Word32

instance Serialize IdentityProviderIdentity where
  put (IP_ID w) = S.putWord32be w

  get = IP_ID <$> S.getWord32be

-- Public key of the Identity provider
newtype IdentityProviderPublicKey = IP_PK PsSigKey
    deriving(Eq, Show, Serialize, NFData)

instance ToJSON IdentityProviderIdentity where
  toJSON (IP_ID v) = toJSON v

instance FromJSON IdentityProviderIdentity where
  parseJSON v = IP_ID <$> parseJSON v

-- Account signatures (eddsa key)
type AccountSignature = Signature

-- decryption key for accounts (Elgamal?)
newtype AccountDecryptionKey = DecKeyAcc ShortByteString
    deriving(Eq)
    deriving Show via Short65K
    deriving Serialize via Short65K

-- encryption key for accounts (Elgamal?)
newtype AccountEncryptionKey = AccountEncryptionKey CredentialRegistrationID
    deriving (Eq, Show, Serialize, FromJSON, ToJSON) via CredentialRegistrationID

makeEncryptionKey :: CredentialRegistrationID -> AccountEncryptionKey
makeEncryptionKey = AccountEncryptionKey

data RegIdSize

instance FBS.FixedLength RegIdSize where
  fixedLength _ = 48

-- |Credential Registration ID (48 bytes)
newtype CredentialRegistrationID = RegIdCred (FBS.FixedByteString RegIdSize)
    deriving (Eq, Ord)
    deriving Show via (FBSHex RegIdSize)
    deriving Serialize via (FBSHex RegIdSize)

instance ToJSON CredentialRegistrationID where
  toJSON v = String (Text.pack (show v))

-- Data (serializes with `putByteString :: Bytestring -> Put`)
instance FromJSON CredentialRegistrationID where
  parseJSON = withText "Credential registration ID in base16" deserializeBase16

newtype Proofs = Proofs ShortByteString
    deriving(Eq)
    deriving(Show) via ByteStringHex
    deriving(ToJSON) via ByteStringHex
    deriving(FromJSON) via ByteStringHex

-- |NB: This puts the length information up front, which is possibly not what we
-- want.
instance Serialize Proofs where
  put (Proofs bs) =
    putWord32be (fromIntegral (BSS.length bs)) <>
    putShortByteString bs
  get = do
    l <- fromIntegral <$> getWord32be
    Proofs <$> getShortByteString l

-- |We assume an non-negative integer.
newtype AttributeValue = AttributeValue ShortByteString
  deriving(Eq)

instance Show AttributeValue where
  show (AttributeValue bytes) = Text.unpack (Text.decodeUtf8 (BSS.fromShort bytes))

instance Serialize AttributeValue where
    put (AttributeValue bytes) =
      putWord8 (fromIntegral (BSS.length bytes)) <>
      putShortByteString bytes

    get = do
      l <- getWord8
      if l <= 31 then do
        bytes <- getShortByteString (fromIntegral l)
        return $! AttributeValue bytes
      else fail "Attribute malformed. Must fit into 31 bytes."

instance ToJSON AttributeValue where
  -- this is safe because the bytestring should contain
  toJSON (AttributeValue v) = String (Text.decodeUtf8 (BSS.fromShort v))

instance FromJSON AttributeValue where
  parseJSON = withText "Attribute value"$ \v -> do
    let s = Text.encodeUtf8 v
    unless (BS.length s <= 31) $ fail "Attribute values must fit into 31 bytes."
    return (AttributeValue (BSS.toShort s))

-- |ValidTo of a credential.
type CredentialValidTo = YearMonth

-- |CreatedAt of a credential.
type CredentialCreatedAt = YearMonth

-- |YearMonth used store expiry (validTo) and creation (createdAt).
-- The year is in Gregorian calendar and months are numbered from 1, i.e.,
-- 1 is January, ..., 12 is December.
-- Year must be a 4 digit year, i.e., between 1000 and 9999.
data YearMonth = YearMonth {
  ymYear :: !Word16,
  ymMonth :: !Word8
  } deriving(Eq, Ord)

-- Show in compressed form of YYYYMM
instance Show YearMonth where
  show YearMonth{..} = show ymYear ++ (if ymMonth < 10 then ("0" ++ show ymMonth) else (show ymMonth))

instance Serialize YearMonth where
  put YearMonth{..} =
    S.putWord16be ymYear <>
    S.putWord8 ymMonth
  get = do
    ymYear <- S.getWord16be
    unless (ymYear >= 1000 && ymYear < 10000) $ fail "Year must be 4 digits exactly."
    ymMonth <- S.getWord8
    unless (ymMonth >= 1 && ymMonth <= 12) $ fail "Month must be between 1 and 12 inclusive."
    return YearMonth{..}

newtype AttributeTag = AttributeTag Word8
 deriving (Eq, Show, Serialize, Ord, Enum, Num) via Word8

-- *NB: This mapping must be kept consistent with the mapping in id/types.rs.
attributeNames :: [Text.Text]
attributeNames = ["firstName",
                  "lastName",
                  "sex",
                  "dob",
                  "countryOfResidence",
                  "nationality",
                  "idDocType",
                  "idDocNo",
                  "idDocIssuer",
                  "idDocIssuedAt",
                  "idDocExpiresAt",
                  "nationalIdNo",
                  "taxIdNo"
                 ]

mapping :: Map.Map Text.Text AttributeTag
mapping = Map.fromList $ zip attributeNames [0..]

invMapping :: Map.Map AttributeTag Text.Text
invMapping = Map.fromList $ zip [0..] attributeNames

instance FromJSONKey AttributeTag where
  -- parse values with this key as objects (the default instance uses
  -- association list encoding
  fromJSONKey = FromJSONKeyTextParser (parseJSON . String)

instance ToJSONKey AttributeTag where
  toJSONKey = toJSONKeyText $ (\tag -> fromMaybe "UNKNOWN" $ Map.lookup tag invMapping)

instance FromJSON AttributeTag where
  parseJSON = withText "Attribute name" $ \text ->do
        case Map.lookup text mapping of
          Just x -> return x
          Nothing -> fail $ "Attribute " ++ Text.unpack text ++ " does not exist."

instance ToJSON AttributeTag where
  toJSON tag = maybe "UNKNOWN" toJSON $ Map.lookup tag invMapping

data Policy = Policy {
  -- |Validity of this credential.
  pValidTo :: CredentialValidTo,
  -- |Creation of this credential
  pCreatedAt :: CredentialCreatedAt,
  -- |List of items in this attribute list.
  pItems :: Map.Map AttributeTag AttributeValue
  } deriving(Eq, Show)

instance ToJSON YearMonth where
  toJSON ym = String (Text.pack (show ym))

instance FromJSON YearMonth where
  parseJSON = withText "YearMonth" $ \v -> do
    unless (Text.length v == 6) $ fail "YearMonth value must be exactly 6 characters."
    let (year, month) = Text.splitAt 4 v
    let eyear = Text.decimal year
    let emonth = Text.decimal month
    case eyear of
      Left err -> fail $ "Year not a valid numeric value: " ++ err
      Right (ymYear, rest) -> do
        unless (Text.null rest && ymYear >= 1000 && ymYear <= 10000) $ fail "Year not valid."
        case emonth of
          Left err -> fail $ "Month not a valid numeric value: " ++ err
          Right (ymMonth, rest') -> do
            unless (Text.null rest' && ymMonth >= 1 && ymMonth <= 12) $ fail "Month not within range."
            return YearMonth{..}

instance ToJSON Policy where
  toJSON Policy{..} = object [
    "validTo" .= pValidTo,
    "createdAt" .= pCreatedAt,
    "revealedAttributes" .= pItems
    ]

instance FromJSON Policy where
  parseJSON = withObject "Policy" $ \v -> do
    pValidTo <- v .: "validTo"
    pCreatedAt <- v .: "createdAt"
    pItems <- v .: "revealedAttributes"
    return Policy{..}

-- |Unique identifier of the anonymity revoker.
newtype ArIdentity = ArIdentity Word32
    deriving(Eq, Ord)
    deriving (Show, Hashable) via Word32

instance Serialize ArIdentity where
  put (ArIdentity n) = S.putWord32be n
  get = do
    n <- S.getWord32be
    when (n == 0) $ fail "ArIdentity must be at least 1."
    return (ArIdentity n)

-- |Public key of an anonymity revoker.
newtype AnonymityRevokerPublicKey = AnonymityRevokerPublicKey ElgamalPublicKey
    deriving(Eq, Serialize, NFData)
    deriving Show via ElgamalPublicKey

instance ToJSON ArIdentity where
  toJSON (ArIdentity v) = toJSON v

-- |NB: This just reads the string. No decoding.
instance FromJSON ArIdentity where
  parseJSON v = do
    n <- parseJSON v
    when (n == 0) $ fail "ArIdentity must be at least 1."
    return (ArIdentity n)

instance FromJSONKey ArIdentity where
  fromJSONKey = FromJSONKeyTextParser arIdFromText
      where arIdFromText t = do
              when (Text.length t > 10) $ fail "Out of bounds."
              case Text.readMaybe (Text.unpack t) of
                Nothing -> fail "Not an integral value."
                Just i -> do
                  when (i <= 0) $ fail "ArIdentity must be positive."
                  when (i > toInteger (maxBound :: Word32)) $ fail "ArIdentity out of bounds."
                  return (ArIdentity (fromInteger i))

-- NB: This instance relies on the show instance being the one of Word32.
instance ToJSONKey ArIdentity where
  toJSONKey = toJSONKeyText (Text.pack . show)

-- |Encryption of data with anonymity revoker's public key.
newtype AREnc = AREnc ElgamalCipher
    deriving(Eq, Serialize)
    deriving Show via ElgamalCipher
    deriving ToJSON via ElgamalCipher

instance FromJSON AREnc where
  parseJSON v = AREnc <$> parseJSON v

newtype ShareNumber = ShareNumber Word32
    deriving (Eq, Show, Ord)
    deriving (FromJSON, ToJSON) via Word32

instance Serialize ShareNumber where
  put (ShareNumber n) = S.putWord32be n
  get = ShareNumber <$> S.getWord32be

-- |Anonymity revocation threshold.
newtype Threshold = Threshold Word8
    deriving (Eq, Show, Ord)
    deriving (ToJSON) via Word8

instance FromJSON Threshold where
  parseJSON v = do
    n <- parseJSON v
    when (n == 0) $ fail "Threshold must be at least 1."
    return (Threshold n)

instance Serialize Threshold where
  put (Threshold n) = S.putWord8 n
  get = do
    n <- S.getWord8
    when (n == 0) $ fail "Threshold must be at least 1."
    return (Threshold n)

-- |Data needed on-chain to revoke anonymity of the account holder.
newtype ChainArData = ChainArData {
  -- |Encrypted share of id cred pub
  ardIdCredPubShare :: AREnc
  } deriving(Eq, Show)


instance ToJSON ChainArData where
  toJSON ChainArData{..} = object [
    "encIdCredPubShare" .=  ardIdCredPubShare
    ]

instance FromJSON ChainArData where
  parseJSON = withObject "ChainArData" $ \v -> do
    ardIdCredPubShare <- v .: "encIdCredPubShare"
    return ChainArData{..}

instance Serialize ChainArData where
  put ChainArData{..} =
    put ardIdCredPubShare
  get = ChainArData <$> get

type AccountVerificationKey = VerifyKey

-- |The number of keys required to sign the message.
-- The value is at least 1 and at most 255.
newtype SignatureThreshold = SignatureThreshold Word8
    deriving(Eq, Ord, Show, Enum, Num, Real, Integral)
    deriving (Serialize, Read) via Word8

instance ToJSON SignatureThreshold where
  toJSON (SignatureThreshold x) = toJSON x

instance FromJSON SignatureThreshold where
  parseJSON v = do
    x <- parseJSON v
    unless (x <= (255::Word) || x >= 1) $ fail "Signature threshold out of bounds."
    return $! SignatureThreshold (fromIntegral x)

-- |Data about which account this credential belongs to.
data CredentialAccount =
  ExistingAccount !AccountAddress
  -- | Create a new account. The list of keys must be non-empty and no longer
  -- than 255 elements.
  | NewAccount ![AccountVerificationKey] !SignatureThreshold
  deriving(Eq, Show)

instance ToJSON CredentialAccount where
  toJSON (ExistingAccount x) = toJSON x
  toJSON (NewAccount keys threshold) = object [
    "keys" .= keys,
    "threshold" .= threshold
    ]

instance FromJSON CredentialAccount where
  parseJSON (Object obj) = do
    keys <- obj .: "keys"
    when (null keys) $ fail "The list of keys must be non-empty."
    let len = length keys
    unless (len <= 255) $ fail "The list of keys must be no longer than 255 elements."
    threshold <- obj .:? "threshold" .!= fromIntegral (length keys) -- default to all the keys as a threshold
    return $! NewAccount keys threshold
  parseJSON v = ExistingAccount <$> parseJSON v

instance Serialize CredentialAccount where
  put (ExistingAccount x) = S.putWord8 0 <> S.put x
  put (NewAccount keys threshold) = S.putWord8 1 <> do
      S.putWord8 (fromIntegral (length keys))
      mapM_ S.put keys
      S.put threshold

  get =
    S.getWord8 >>= \case
      0 -> ExistingAccount <$> S.get
      1 -> do
        len <- S.getWord8
        unless (len >= 1) $ fail "The list of keys must be non-empty and at most 255 elements long."
        keys <- replicateM (fromIntegral len) S.get
        threshold <- S.get
        return $! NewAccount keys threshold
      _ -> fail "Input must be either an existing account or a new account with a list of keys and threshold."

data CredentialDeploymentValues = CredentialDeploymentValues {
  -- |Either an address of an existing account, or the list of keys the newly
  -- created account should have, together with a threshold for how many are needed
  -- Its address is derived from the registration id of this credential.
  cdvAccount :: !CredentialAccount,
  -- |Registration id of __this__ credential.
  cdvRegId     :: !CredentialRegistrationID,
  -- |Identity of the identity provider who signed the identity object from
  -- which this credential is derived.
  cdvIpId      :: !IdentityProviderIdentity,
  -- |Revocation threshold. Any set of this many anonymity revokers can reveal IdCredPub.
  cdvThreshold :: !Threshold,
  -- |Anonymity revocation data associated with this credential.
  cdvArData :: !(Map.Map ArIdentity ChainArData),
  -- |Policy. At the moment only opening of specific commitments.
  cdvPolicy :: !Policy
} deriving(Eq, Show)

credentialAccountAddress :: CredentialDeploymentValues -> AccountAddress
credentialAccountAddress cdv =
  case cdvAccount cdv of
    ExistingAccount addr -> addr
    _ -> addressFromRegId (cdvRegId cdv)

instance ToJSON CredentialDeploymentValues where
  toJSON CredentialDeploymentValues{..} =
    object [
    "account" .= cdvAccount,
    "regId" .= cdvRegId,
    "ipIdentity" .= cdvIpId,
    "revocationThreshold" .= cdvThreshold,
    "arData" .= cdvArData,
    "policy" .= cdvPolicy
    ]

instance FromJSON CredentialDeploymentValues where
  parseJSON = withObject "CredentialDeploymentValues" $ \v -> do
    cdvAccount <- v .: "account"
    cdvRegId <- v .: "regId"
    cdvIpId <- v .: "ipIdentity"
    cdvThreshold <- v.: "revocationThreshold"
    cdvArData <- v .: "arData"
    cdvPolicy <- v .: "policy"
    return CredentialDeploymentValues{..}

getPolicy :: Get Policy
getPolicy = do
  pValidTo <- get
  pCreatedAt <- get
  l <- fromIntegral <$> getWord16be
  pItems <- safeFromAscList =<< replicateM l (getTwoOf get get)
  return Policy{..}

putPolicy :: Putter Policy
putPolicy Policy{..} =
  let l = length pItems
  in put pValidTo <>
     put pCreatedAt <>
     putWord16be (fromIntegral l) <>
     mapM_ (putTwoOf put put) (Map.toAscList pItems)

instance Serialize CredentialDeploymentValues where
  get = do
    cdvAccount <- get
    cdvRegId <- get
    cdvIpId <- get
    cdvThreshold <- get
    l <- S.getWord16be
    cdvArData <- safeFromAscList =<< replicateM (fromIntegral l) get
    cdvPolicy <- getPolicy
    return CredentialDeploymentValues{..}

  put CredentialDeploymentValues{..} =
    put cdvAccount <>
    put cdvRegId <>
    put cdvIpId <>
    put cdvThreshold <>
    S.putWord16be (fromIntegral (length cdvArData)) <>
    mapM_ put (Map.toAscList cdvArData) <>
    putPolicy cdvPolicy

-- |The credential deployment information consists of values deployed and the
-- proofs about them.
data CredentialDeploymentInformation = CredentialDeploymentInformation {
  cdiValues :: CredentialDeploymentValues,
  -- |Proofs of validity of this credential. Opaque from the Haskell side, since
  -- we only pass them to Rust to check.
  cdiProofs :: Proofs
  }
  deriving (Show)

-- |NB: This must match the one defined in rust. In particular the
-- proof is serialized with 4 byte length.
instance Serialize CredentialDeploymentInformation where
  put CredentialDeploymentInformation{..} =
    put cdiValues <> put cdiProofs
  get = CredentialDeploymentInformation <$> get <*> get

-- |NB: This makes sense for well-formed data only and is consistent with how accounts are identified internally.
instance Eq CredentialDeploymentInformation where
  cdi1 == cdi2 = cdiValues cdi1 == cdiValues cdi2

instance FromJSON CredentialDeploymentInformation where
  parseJSON = withObject "CredentialDeploymentInformation" $ \v -> do
    cdiValues <- parseJSON (Object v)
    proofsText <- v .: "proofs"
    return CredentialDeploymentInformation{cdiProofs = Proofs (BSS.toShort . fst . BS16.decode . Text.encodeUtf8 $ proofsText),
                                           ..}
